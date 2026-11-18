"""浏览器会话层：抖音 / 微博 / 小红书 共用。

设计取舍（已实测）：
  * 抖音：无需登录即可在 www.douyin.com 页面内 fetch 用户资料接口，
          但必须有真实浏览器上下文（a_bogus 签名由页面 JS 生成）。
  * 微博：weibo.com/u/<uid> 页面内 fetch /ajax/profile/info 返回精确数字，
          游客态可用；登录态更稳。
  * 小红书：游客态强制跳登录页，必须提供登录 cookie 才能读主页。

Playwright 用本机 Chrome（channel="chrome"），数据目录持久化，登录一次长期复用。

容器化适配：
  * SW_BROWSER_CHANNEL 可覆盖浏览器通道；容器内设为空字符串则使用 Playwright
    自带的 chromium（镜像里没有 Google Chrome）。
  * SW_BROWSER_NO_SANDBOX=1 时追加 --no-sandbox / --disable-dev-shm-usage，
    供容器内以 root 运行时使用。
  * SW_STATE_FILE 指向一个 storage_state JSON，登录态可以从宿主机导出后
    注入容器，解决容器内无法扫码登录的问题。
"""
from __future__ import annotations

import json
import os
import random
import re
import socket
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")


def _avatar_url(*candidates) -> str | None:
    """从多种可能的字段形态里解析出头像 URL。

    兼容：纯字符串 / {'url': ...} / {'urlDefault': ...} / {'url_list': [...]} / [...]
    小红书新版接口的 basic.image 有时返回对象，抖音的 avatar_thumb 也各版本不一。
    """
    def one(v):
        if isinstance(v, str):
            return v or None
        if isinstance(v, dict):
            for k in ("url", "urlDefault", "url_default", "uri"):
                if isinstance(v.get(k), str) and v[k]:
                    return v[k]
            if isinstance(v.get("url_list"), list) and v["url_list"]:
                return one(v["url_list"][0])
        if isinstance(v, (list, tuple)) and v:
            return one(v[0])
        return None
    for c in candidates:
        got = one(c)
        if got:
            return got
    return None


def _browser_channel() -> str | None:
    """None 表示使用 Playwright 自带的 chromium。"""
    ch = os.environ.get("SW_BROWSER_CHANNEL", "chrome").strip()
    return ch or None


def _no_sandbox() -> bool:
    return os.environ.get("SW_BROWSER_NO_SANDBOX", "").strip() in ("1", "true", "yes")


def profile_root() -> Path:
    """浏览器 profile 的根目录。

    容器与宿主机必须用不同的根目录：两边共用同一个目录时，
    Linux Chromium 会覆写 macOS 的 profile（cookie 加密格式不同），
    结果是登录态被清空、两边互相破坏。
    通过 SW_PROFILE_ROOT 环境变量切换即可。
    """
    root = os.environ.get("SW_PROFILE_ROOT", "").strip()
    return Path(root) if root else Path("data/browser")


def profile_path(name: str) -> Path:
    """取某个用途独立的 profile 目录（status / resolve / login / retry）。"""
    return profile_root() / name if name else profile_root()


def _jitter(a: float = 0.6, b: float = 1.6) -> None:
    """随机停顿，模拟真人操作节奏，降低被风控的概率。"""
    time.sleep(random.uniform(a, b))


def _chromium_path(pw) -> str | None:
    """返回 Playwright 自带的完整 chromium 可执行文件路径。

    headless 模式下 Playwright 默认会去找 headless shell，但镜像里未必装了它。
    显式指定完整 chromium 可以避开这个坑。
    """
    try:
        path = pw.chromium.executable_path
    except Exception:  # noqa: BLE001
        return None
    if path and os.path.exists(path):
        return path
    return None


def _clean_stale_locks(profile_dir: Path) -> None:
    """清理 profile 目录里残留的 Chrome 单例锁。

    Chrome 崩溃或被强杀时不会删除 SingletonLock，下次启动会报
    "The profile appears to be in use by another Chromium process"，
    尤其在容器里（主机名变化）锁永远解不开。

    只在确认是孤儿锁时才清理：锁文件里记录的是「主机名-pid」。
    如果主机名与当前一致，说明可能还有活着的进程在用，保留；
    主机名不同（容器重建、macOS 重启）则一定是残留。
    """
    lock = profile_dir / "SingletonLock"
    current_host = socket.gethostname().split(".")[0]
    stale = True
    try:
        if lock.exists():
            # Linux 下是符号链接，指向 "<host>-<pid>"
            target = os.readlink(lock) if lock.is_symlink() else lock.read_text().strip()
            host = target.rsplit("-", 1)[0] if "-" in target else target
            if host == current_host:
                # 同一台机器，可能是活进程持有，不动
                stale = False
    except OSError:
        stale = True

    if not stale:
        return
    for name in ("SingletonLock", "SingletonCookie", "SingletonSocket"):
        p = profile_dir / name
        try:
            if p.exists() or p.is_symlink():
                p.unlink()
        except OSError:
            pass


class Browser:
    """一个可复用的浏览器上下文，供所有平台采集器共享。"""

    def __init__(self, profile_dir: Path, headless: bool = True,
                 state_file: Path | None = None, display: str | None = None):
        self.profile_dir = Path(profile_dir)
        self.profile_dir.mkdir(parents=True, exist_ok=True)
        self.headless = headless
        self.state_file = Path(state_file) if state_file else None
        self.display = display
        self._pw = None
        self._ctx = None

    def __enter__(self) -> "Browser":
        self._pw = sync_playwright().start()
        args = ["--no-first-run", "--no-default-browser-check",
                "--disable-blink-features=AutomationControlled"]
        if _no_sandbox():
            args += ["--no-sandbox", "--disable-dev-shm-usage"]
        if not self.headless:
            # headful（配合 Xvfb 用于网页扫码登录）：容器里没有 GPU，
            # 不关掉会直接崩溃
            args += ["--disable-gpu", "--disable-software-rasterizer",
                     "--window-size=1280,900", "--window-position=0,0",
                     # 网易云等重页面在容器里渲染会 OOM 崩溃，限制一下内存
                     "--js-flags=--max-old-space-size=512",
                     "--disable-dev-shm-usage",
                     "--renderer-process-limit=2",
                     "--disable-features=CalculateNativeWinOcclusion"]

        _clean_stale_locks(self.profile_dir)

        channel = _browser_channel()
        launch: dict = {
            "user_data_dir": str(self.profile_dir),
            "headless": self.headless,
            "user_agent": UA,
            "locale": "zh-CN",
            "viewport": {"width": 1440, "height": 900},
            "args": args,
        }
        if self.display:
            launch["env"] = {**os.environ, "DISPLAY": self.display}
        if channel:
            launch["channel"] = channel
        else:
            # 用 Playwright 自带的完整 chromium，避免依赖 headless shell
            exe = _chromium_path(self._pw)
            if exe:
                launch["executable_path"] = exe

        self._ctx = self._pw.chromium.launch_persistent_context(**launch)
        self._ctx.set_default_timeout(30000)
        self._inject_state()
        return self

    def _inject_state(self) -> None:
        """把宿主机导出的登录态注入当前上下文（容器内扫码登录的替代方案）。"""
        if not self.state_file or not self.state_file.exists():
            return
        try:
            data = json.loads(self.state_file.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            return
        cookies = data.get("cookies") if isinstance(data, dict) else None
        if cookies:
            try:
                self._ctx.add_cookies(cookies)
            except Exception:  # noqa: BLE001
                pass

    def __exit__(self, *exc) -> None:
        try:
            if self._ctx:
                self._ctx.close()
        finally:
            if self._pw:
                self._pw.stop()

    def new_page(self):
        page = self._ctx.new_page()
        page.add_init_script(
            "Object.defineProperty(navigator,'webdriver',{get:()=>undefined});"
        )
        return page

    def has_cookie(self, domain_part: str, name: str | None = None) -> bool:
        for c in self._ctx.cookies():
            if domain_part in c.get("domain", ""):
                if name is None or c.get("name") == name:
                    return True
        return False

    def cookie_status(self) -> dict[str, bool]:
        return cookie_status(self._ctx)


# ---------------------------------------------------------------- 登录态检测
def _has_cookie(ctx, domain_part: str, name: str | None = None) -> bool:
    for c in ctx.cookies():
        if domain_part in c.get("domain", ""):
            if name is None or c.get("name") == name:
                return True
    return False


def _weibo_logged_in(ctx) -> bool:
    """微博：调登录态接口，游客态返回的 user 里没有个人昵称。"""
    try:
        page = ctx.new_page()
    except Exception:  # noqa: BLE001
        return True  # 打不开页面时不误报
    try:
        page.goto("https://weibo.com/", wait_until="domcontentloaded", timeout=25000)
        time.sleep(2.0)
        raw = page.evaluate(
            """async () => {
              const r = await fetch('/ajax/profile/info?uid=1749127163',
                {credentials:'include'});
              const j = await r.json();
              const u = (j && j.data && j.data.user) || {};
              return {isLogin: u.isLogin, hasMore: j && j.data && !!j.data.more};
            }"""
        )
        d = json.loads(raw) if isinstance(raw, str) else raw
        # isLogin 明确为 true，或返回了登录态才有的 more 字段
        return bool(d.get("isLogin")) or bool(d.get("hasMore"))
    except Exception:  # noqa: BLE001
        return True  # 探测失败时保守处理，不误报为未登录
    finally:
        try:
            page.close()
        except Exception:  # noqa: BLE001
            pass


def _xhs_visitor(ctx) -> bool:
    """小红书：游客态会被强制跳转到 /login。"""
    try:
        page = ctx.new_page()
    except Exception:  # noqa: BLE001
        return False
    try:
        page.goto("https://www.xiaohongshu.com/explore",
                  wait_until="domcontentloaded", timeout=25000)
        time.sleep(2.5)
        return "/login" in page.url
    except Exception:  # noqa: BLE001
        return False
    finally:
        try:
            page.close()
        except Exception:  # noqa: BLE001
            pass


def cookie_status(ctx) -> dict[str, bool]:
    """各平台真实登录态。

    不能只看 cookie 是否存在——实测游客态也会拿到这些：
      * 微博游客态有 SUB
      * 小红书游客态有 web_session
      * 抖音游客态自动有 ttwid
      * 网易云游客态 JSESSIONID 正常
    所以改成探测「只有登录后才有的东西」：
      * 网易云：MUSIC_U cookie（游客态确实没有，可靠）
      * 微博：调接口看登录后字段 isLogin / data.more
      * 小红书：web_session 且没有跳转到 /login
      * 抖音：登录后才有 sessionid / sid_tt
    """
    return {
        "netease": _has_cookie(ctx, "music.163.com", "MUSIC_U"),
        "douyin": (_has_cookie(ctx, "douyin.com", "sessionid")
                   or _has_cookie(ctx, "douyin.com", "sid_tt")
                   or _has_cookie(ctx, "douyin.com", "sessionid_ss")),
        "weibo": _has_cookie(ctx, "weibo.com", "SUB") and _weibo_logged_in(ctx),
        # 小红书游客态也有 web_session，且访客探测页会被反爬跳到 /login，
        # 两者都会误判。实测只有 id_token 是登录态专属，直接看本地 cookie 最可靠。
        "xiaohongshu": _has_cookie(ctx, "xiaohongshu.com", "id_token"),
    }


# ---------------------------------------------------------------- 抖音
def douyin_profile(browser: Browser, sec_uid: str) -> dict:
    page = browser.new_page()
    try:
        page.goto("https://www.douyin.com/", wait_until="domcontentloaded", timeout=40000)
        _jitter(2.0, 3.5)
        raw = page.evaluate(
            """async (sec) => {
              const url = '/aweme/v1/web/user/profile/other/?device_platform=webapp&aid=6383'
                + '&channel=channel_pc_web&sec_user_id=' + sec
                + '&publish_video_strategy_type=2&version_code=170400&version_name=17.4.0'
                + '&cookie_enabled=true&platform=PC&downlink=10';
              const r = await fetch(url, {headers:{'accept':'application/json'}, credentials:'include'});
              return await r.text();
            }""",
            sec_uid,
        )
        d = json.loads(raw)
        if d.get("status_code") not in (0, None) or not d.get("user"):
            raise RuntimeError(f"抖音接口异常 status_code={d.get('status_code')} msg={d.get('status_msg')}")
        u = d["user"]
        avatar_urls = ((u.get("avatar_thumb") or {}).get("url_list")
                       or (u.get("avatar_larger") or {}).get("url_list") or [])
        return {
            "kind": "douyin",
            "sec_uid": sec_uid,
            "nickname": u.get("nickname"),
            "avatar": _avatar_url(avatar_urls, u.get("avatar_thumb"), u.get("avatar_larger")),
            "unique_id": u.get("unique_id") or u.get("short_id"),
            "followers": u.get("follower_count"),
            "following": u.get("following_count"),
            "likes": u.get("total_favorited"),
            "works": u.get("aweme_count"),
        }
    finally:
        page.close()


def douyin_resolve(browser: Browser, raw: str) -> str:
    """把 分享链接/抖音号 解析为 sec_uid。"""
    raw = raw.strip()
    m = re.search(r"(MS4wLjABAAAA[\w\-]+)", raw)
    if m:
        return m.group(1)
    if re.fullmatch(r"\d{6,}", raw):
        # 纯数字可能是短 id / 抖音号，先试 H5 分享页
        pass
    page = browser.new_page()
    try:
        if raw.startswith("http"):
            page.goto(raw, wait_until="domcontentloaded", timeout=40000)
            _jitter(2.0, 3.0)
            html = page.content()
            m = re.search(r"(MS4wLjABAAAA[\w\-]+)", html)
            if m:
                return m.group(1)
        # 用搜索接口兜底
        page.goto(f"https://www.douyin.com/search/{raw}?type=user", wait_until="domcontentloaded", timeout=40000)
        _jitter(3.0, 4.5)
        html = page.content()
        ids = list(dict.fromkeys(re.findall(r"(MS4wLjABAAAA[\w\-]+)", html)))
        if ids:
            return ids[0]
        raise RuntimeError(f"无法解析抖音账号：{raw}")
    finally:
        page.close()


# ---------------------------------------------------------------- 微博
def weibo_profile(browser: Browser, uid: str) -> dict:
    page = browser.new_page()
    try:
        page.goto(f"https://weibo.com/u/{uid}", wait_until="domcontentloaded", timeout=40000)
        _jitter(1.5, 2.6)
        raw = page.evaluate(
            """async (uid) => {
              const r = await fetch('/ajax/profile/info?uid=' + uid,
                {headers:{'accept':'application/json'}, credentials:'include'});
              return [r.status, await r.text()];
            }""",
            uid,
        )
        status, text = raw
        if status != 200:
            raise RuntimeError(f"微博接口 HTTP {status}")
        d = json.loads(text)
        if d.get("ok") != 1:
            raise RuntimeError(f"微博接口异常：{str(d)[:160]}")
        u = d["data"]["user"]
        return {
            "kind": "weibo",
            "uid": uid,
            "nickname": u.get("screen_name"),
            "avatar": u.get("profile_image_url") or u.get("avatar_hd"),
            "followers": u.get("followers_count"),
            "following": u.get("friends_count"),
            "posts": u.get("statuses_count"),
            "followers_str": u.get("followers_count_str"),
        }
    finally:
        page.close()


def weibo_resolve(browser: Browser, raw: str) -> tuple[str, str | None]:
    """返回 (uid, 昵称猜测)。支持 u/<uid>、数字 uid、个性域名。"""
    raw = raw.strip()
    m = re.search(r"(?:weibo\.com/u/|^)(\d{6,})", raw)
    if m:
        return m.group(1), None
    dom = re.search(r"weibo\.com/(?:u/)?([A-Za-z][\w\-]*)", raw)
    if dom and not dom.group(1).isdigit():
        page = browser.new_page()
        try:
            page.goto(f"https://weibo.com/{dom.group(1)}", wait_until="domcontentloaded", timeout=40000)
            _jitter(2.0, 3.0)
            m2 = re.search(r'"idstr"\s*:\s*"(\d+)"', page.content())
            if m2:
                return m2.group(1), dom.group(1)
        finally:
            page.close()
    if re.fullmatch(r"\d{6,}", raw):
        return raw, None
    raise RuntimeError(f"无法解析微博账号：{raw}")


# ---------------------------------------------------------------- 小红书
def _xhs_from_initial_state(html: str, user_id: str) -> dict | None:
    """从小红书用户主页内嵌的 window.__INITIAL_STATE__ 提取目标用户资料。

    小红书把「被访问用户」的资料直接 SSR 进页面，无需调用接口——这正是
    最稳的数据源。旧接口 /api/sns/web/v1/user/otherinfo 现在 www 域返回
    500、edith 域返回 406（要签名），已不可靠。

    数据位置固定为 "userPageData":{"...basicInfo":{"nickname":...}}，
    紧跟其后的 "interactions":[{type:follows/fans/interaction,count:...}]。
    __INITIAL_STATE__ 含 Vue 响应式循环引用，不能整体 JSON 解析，
    因此用正则从 userPageData 段精确取字段——这样能避开当前登录者
    （user.userInfo）的干扰。
    """
    try:
        m = re.search(r"window\.__INITIAL_STATE__\s*=\s*(\{.+?\})</script>", html, re.S)
        if not m:
            return None
        raw = m.group(1)

        # 定位目标用户数据段：userPageData 是被访问用户，user.userInfo 是当前登录者
        idx = raw.find('"userPageData"')
        if idx < 0:
            return None
        seg = raw[idx: idx + 2000]

        def grab(pattern: str, text: str):
            hit = re.search(pattern, text)
            return hit.group(1) if hit else None

        nickname = grab(r'"nickname":"([^"]*)"', seg)
        avatar = (grab(r'"imageb":"([^"]+)"', seg)
                  or grab(r'"images":"([^"]+)"', seg)
                  or grab(r'"image":"([^"]+)"', seg))
        if avatar:
            avatar = avatar.replace("\\u002F", "/").replace("\\/", "/")
        follows = grab(r'"type":"follows"[^}]*?"count":"([^"]*)"', seg)
        fans = grab(r'"type":"fans"[^}]*?"count":"([^"]*)"', seg)
        likes = grab(r'"type":"interaction"[^}]*?"count":"([^"]*)"', seg)

        if not (nickname or fans or follows):
            return None

        def as_int(v):
            if v is None:
                return None
            # 兼容 "1.2万" / "12.2K" 这类缩写
            s = str(v).strip().upper()
            mult = 1
            if s.endswith("万"):
                mult, s = 10000, s[:-1]
            elif s.endswith("K"):
                mult, s = 1000, s[:-1]
            try:
                return int(float(s) * mult)
            except ValueError:
                return v

        return {
            "kind": "xiaohongshu",
            "user_id": user_id,
            "nickname": nickname,
            "avatar": avatar,
            "followers": as_int(fans),
            "following": as_int(follows),
            "likes": as_int(likes),
            "notes": None,
        }
    except Exception:  # noqa: BLE001
        return None


def xhs_profile(browser: Browser, user_id: str) -> dict:
    if not browser.has_cookie("xiaohongshu.com", "web_session"):
        raise RuntimeError("小红书需要登录 cookie（web_session）。请先运行 login 命令扫码登录。")
    page = browser.new_page()
    try:
        page.goto(f"https://www.xiaohongshu.com/user/profile/{user_id}",
                  wait_until="domcontentloaded", timeout=40000)
        # 等待 SSR 数据注入（用户资料在 __INITIAL_STATE__ 里，可能晚于 DOM）
        for _ in range(10):
            if page.evaluate("() => !!window.__INITIAL_STATE__"):
                break
            time.sleep(0.8)
        if "login" in page.url:
            raise RuntimeError("小红书登录态已失效，请重新扫码登录。")

        # 首选：页面内嵌数据（最稳，无需接口签名）
        result = _xhs_from_initial_state(page.content(), user_id)
        if result:
            return result

        # 兜底：老接口（部分环境仍可用）
        raw = page.evaluate(
            """async (uid) => {
              const r = await fetch('/api/sns/web/v1/user/otherinfo?target_user_id=' + uid,
                {headers:{'accept':'application/json'}, credentials:'include'});
              return [r.status, await r.text()];
            }""",
            user_id,
        )
        status, text = raw
        if status != 200:
            raise RuntimeError(f"小红书接口 HTTP {status}（页面数据也未解析到）")
        d = json.loads(text)
        if not d.get("success", True) and d.get("code") not in (0, None):
            raise RuntimeError(f"小红书接口异常：{text[:160]}")
        data = (d.get("data") or {}).get("basic_info") or d.get("data") or {}
        basic = d.get("data", {}).get("basic_info", data)
        return {
            "kind": "xiaohongshu",
            "user_id": user_id,
            "nickname": basic.get("nickname"),
            "avatar": _avatar_url(basic.get("image"), basic.get("avatar"),
                                  basic.get("images"), basic.get("image_list")),
            "followers": basic.get("fans") or basic.get("fans_count"),
            "following": basic.get("follows") or basic.get("follow_count"),
            "likes": basic.get("interaction") or basic.get("liked"),
            "notes": basic.get("note_num") or basic.get("notes"),
        }
    finally:
        page.close()


def xhs_resolve(raw: str) -> str:
    raw = raw.strip()
    m = re.search(r"/user/profile/([0-9a-f]{24})", raw)
    if m:
        return m.group(1)
    if re.fullmatch(r"[0-9a-f]{24}", raw):
        return raw
    raise RuntimeError(f"无法解析小红书账号：{raw}（请填主页链接或 24 位 user_id）")
