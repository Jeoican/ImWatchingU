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

import calendar
import json
import os
import random
import re
import socket
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

from .. import config as _config

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
    return _config.profile_root()


def profile_path(name: str) -> Path:
    """取某个用途独立的 profile 目录（status / resolve / login / retry）。"""
    return _config.profile_path(name)


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
    """微博：检测登录态专属 cookie（ALF / SSOLoginState）。

    曾经用 /ajax/profile/info 的 isLogin/more 判定，但 2026-11 微博接口改版
    移除了这两个字段，登录态与游客态返回一致（实测 data 只有 user/tabList/
    blockText），导致扫码登录后徽章仍显示未登录。
    ALF / SSOLoginState 是登录态专属：游客态访问首页只会拿到 SUB/SUBP/WBPSESS，
    不会有这两个。本地 cookie 判定，不受接口改版影响。
    """
    return (_has_cookie(ctx, "weibo.com", "ALF")
            or _has_cookie(ctx, "weibo.com", "SSOLoginState"))


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

        # 最近发布内容：在同一个已打开的页面里顺带 fetch 一次用户微博列表，
        # 不新开导航、风险低；失败只影响"最近内容"展示，不影响粉丝数等主数据。
        # 同一次响应里就带 pic_infos（配图）和互动数，无需额外请求。
        recent_posts: list[dict] = []
        try:
            raw2 = page.evaluate(
                """async (uid) => {
                  const r = await fetch('/ajax/statuses/mymblog?uid=' + uid + '&page=1&feature=0',
                    {headers:{'accept':'application/json'}, credentials:'include'});
                  return [r.status, await r.text()];
                }""",
                uid,
            )
            if raw2 and raw2[0] == 200:
                d2 = json.loads(raw2[1])
                recent_posts = _weibo_post_items(
                    ((d2.get("data") or {}).get("list") or [])[:8], uid)
                # 评论：只给有评论的前几条补，控制请求数（每条一次请求，最多 3 条）
                _weibo_attach_comments(page, recent_posts, limit=3)
        except Exception:  # noqa: BLE001
            pass

        return {
            "kind": "weibo",
            "uid": uid,
            "nickname": u.get("screen_name"),
            "avatar": u.get("profile_image_url") or u.get("avatar_hd"),
            "followers": u.get("followers_count"),
            "following": u.get("friends_count"),
            "posts": u.get("statuses_count"),
            "followers_str": u.get("followers_count_str"),
            "recent_posts": recent_posts,
        }
    finally:
        page.close()


_WB_TIME_RE = re.compile(r"([A-Z][a-z]{2}) ([A-Z][a-z]{2}) (\d{1,2}) (\d{2}):(\d{2}):(\d{2}) ([+-]\d{4}) (\d{4})")
_WB_MONTH = {m: i + 1 for i, m in enumerate(
    ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"))}


def _weibo_ts(s: str | None) -> int | None:
    """把微博的 'Sun Jun 28 20:34:54 +0800 2026' 转成 unix 秒。"""
    m = _WB_TIME_RE.match((s or "").strip())
    if not m:
        return None
    _, mon, day, hh, mm, ss, tz, year = m.groups()
    try:
        offset = int(tz[:3]) * 3600 + (1 if tz[0] == "-" else -1) * int(tz[3:]) * 60
        return int(calendar.timegm((int(year), _WB_MONTH[mon], int(day),
                                    int(hh), int(mm), int(ss), 0, 1, 0)) - offset)
    except Exception:  # noqa: BLE001
        return None


def _weibo_clean(txt: str) -> str:
    """微博正文去表情 img / 标签 / 冗余空白。"""
    txt = re.sub(r"<img[^>]*>", "", txt or "")
    txt = re.sub(r"<[^>]+>", "", txt)
    return re.sub(r"\s+", " ", txt).strip()


def _weibo_post_items(items: list[dict], uid: str) -> list[dict]:
    """把接口返回的每一条微博整理成前端需要的结构（含配图）。"""
    out: list[dict] = []
    for s in items:
        txt = _weibo_clean(s.get("text_raw") or s.get("text") or "")
        # 转发微博：把原微博内容也带上，否则只剩一句"转发微博"
        rt = s.get("retweeted_status") or {}
        rt_txt = ""
        if rt:
            rt_txt = _weibo_clean(rt.get("text_raw") or rt.get("text") or "")
        # 配图：pic_infos 里选 bmiddle（360 宽，缩略图够用且省流量）
        pics: list[str] = []
        pi = s.get("pic_infos") or {}
        for pid in (s.get("pic_ids") or [])[:4]:
            info = pi.get(pid) or {}
            url = ((info.get("bmiddle") or {}).get("url")
                   or (info.get("thumbnail") or {}).get("url")
                   or (info.get("large") or {}).get("url"))
            if url:
                pics.append(url if url.startswith("http") else "https:" + url)
        mid = s.get("mblogid") or s.get("mid")
        item = {
            "text": txt[:180],
            "images": pics,
            "images_total": int(s.get("pic_num") or len(s.get("pic_ids") or [])),
            "comments_count": int(s.get("comments_count") or 0),
            "reposts": int(s.get("reposts_count") or 0),
            "likes": int(s.get("attitudes_count") or 0),
            "at": _weibo_ts(s.get("created_at")),
            "id": str(s.get("id") or ""),
            "url": f"https://weibo.com/{uid}/{mid}" if mid else "",
        }
        if rt_txt:
            item["retweet"] = rt_txt[:120]
        out.append(item)
    return out


def _weibo_attach_comments(page, posts: list[dict], limit: int = 3) -> None:
    """给前 limit 条有评论的微博补上热门评论（每条一次请求）。

    微博评论接口必须带 flow=0&is_reload=1，否则返回 400 参数错误。
    """
    done = 0
    for p in posts:
        if done >= limit:
            break
        if not p.get("id") or p.get("comments_count", 0) <= 0:
            continue
        try:
            raw = page.evaluate(
                """async (mid) => {
                  const r = await fetch('/ajax/statuses/buildComments?flow=0&is_reload=1&id='
                    + mid + '&is_show_bulletin=2&is_mix=0&count=6',
                    {headers:{'accept':'application/json'}, credentials:'include'});
                  return [r.status, await r.text()];
                }""",
                p["id"],
            )
            if not raw or raw[0] != 200:
                continue
            data = (json.loads(raw[1]).get("data") or [])[:3]
            cm: list[dict] = []
            for c in data:
                txt = _weibo_clean(c.get("text_raw") or c.get("text") or "")
                if not txt:
                    continue
                cm.append({
                    "by": (c.get("user") or {}).get("screen_name") or "",
                    "text": txt[:100],
                    "likes": int(c.get("like_counts") or 0),
                })
            if cm:
                p["comments"] = cm
                done += 1
        except Exception:  # noqa: BLE001
            continue


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

        # 笔记：SSR 页面里 notes 是已加载的笔记数组，数 noteCard 得到条数，
        # 顺带取标题/封面/点赞作为"最近发布内容"展示（零额外接口请求）。
        note_count = None
        recent_posts: list[dict] = []
        # notes 数组可能在 userPageData 起点 1000+ 字符之后，2000 的窗口会截断，
        # 所以从 raw 里单独取更大范围来数 noteCard / 取标题。
        notes_seg = raw[idx: idx + 30000]
        npos = notes_seg.find('"notes"')
        if npos >= 0:
            notes_seg = notes_seg[npos:]
            note_count = notes_seg.count('"noteCard"') or None
            recent_posts = _xhs_post_items(notes_seg, user_id)

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
            "notes": note_count,
            "recent_posts": recent_posts,
        }
    except Exception:  # noqa: BLE001
        return None


def _xhs_unjson(s: str | None) -> str:
    """SSR 里的字符串是 JSON 转义过的，还原成正常文本 / URL。"""
    if not s:
        return ""
    try:
        out = json.loads('"' + s.replace('"', '\\"') + '"')
    except Exception:  # noqa: BLE001
        out = s
    return (out.replace("\\u002F", "/").replace("\\/", "/")
            .replace("\\u003C", "<").replace("\\u003E", ">").strip())


def _xhs_post_items(notes_seg: str, user_id: str) -> list[dict]:
    """从 SSR 的 notes 段里取最近笔记（标题 / 封面 / 点赞 / 链接 / xsecToken）。

    小红书 SSR 的 noteCard 结构：
      "noteCard":{"type":"normal","interactInfo":{"likedCount":"50"},
                  "cover":{"urlDefault":"http:\\u002F\\u002Fsns-webpic...!nc_n_webp_mw_1"},
                  "noteId":"...","displayTitle":"...","time":1782650480,
                  "xsecToken":"AB6Dxu..."}

    重要：**用户主页 SSR 只暴露封面 1 张**（cover.urlDefault），多图笔记
    在主页上看也是 1 张。要拿全部图片必须带 xsecToken 打开
    /explore/<noteId>?xsec_token=... 的笔记详情页，其 SSR 的
    note.imageList 才是完整列表。所以这里必须把 xsecToken 一并带出去，
    否则调用方拿不到详情页（无 token 的详情页 SSR 是空的）。
    """
    out: list[dict] = []
    # 按 noteCard 切片，避免把相邻笔记的字段串到一起
    parts = notes_seg.split('"noteCard"')[1:]
    for part in parts:
        if len(out) >= 8:
            break
        title_m = re.search(r'"displayTitle":"([^"]*)"', part)
        title = _xhs_unjson(title_m.group(1)) if title_m else ""
        cover_m = re.search(r'"urlDefault":"([^"]*)"', part)
        if not cover_m:
            cover_m = re.search(r'"url":"(http[^"]*xhscdn[^"]*)"', part)
        cover = _xhs_unjson(cover_m.group(1)) if cover_m else ""
        if cover.startswith("http://"):
            cover = "https://" + cover[7:]
        # cover 里的 width/height 是封面图的真实尺寸，留着给前端算格子比例
        cw_m = re.search(r'"height":(\d+),"width":(\d+)', part)
        cw = int(cw_m.group(2)) if cw_m else 0
        ch = int(cw_m.group(1)) if cw_m else 0
        liked_m = re.search(r'"likedCount":"?(\d+)"?', part)
        likes = int(liked_m.group(1)) if liked_m else 0
        nid_m = re.search(r'"noteId":"([^"]*)"', part)
        nid = nid_m.group(1) if nid_m else ""
        # xsecToken 是详情页的准入票据，不带就拿不到 imageList
        tk_m = re.search(r'"xsecToken":"([^"]*)"', part)
        xsec = _xhs_unjson(tk_m.group(1)) if tk_m else ""
        time_m = re.search(r'"time":(\d{10,})', part)
        at = int(int(time_m.group(1)) / 1000) if time_m else None
        vtype_m = re.search(r'"type":"(video|normal)"', part)
        vtype = vtype_m.group(1) if vtype_m else "normal"
        if not (title or cover or nid):
            continue
        out.append({
            "text": title[:180] or "（无标题）",
            "images": [cover] if cover else [],
            # 主页 SSR 只知道封面这一张；真实张数由详情页补全（见 xhs_fill_images）
            "images_cover": True,
            "images_total": 1 if cover else 0,
            "cover_w": cw, "cover_h": ch,
            "xsec_token": xsec,
            "likes": likes,
            "at": at,
            "id": nid,
            "video": vtype == "video",
            "url": (f"https://www.xiaohongshu.com/explore/{nid}"
                    if nid else f"https://www.xiaohongshu.com/user/profile/{user_id}"),
        })
    return out


def xhs_note_images(page, note_id: str, xsec_token: str = "") -> list[dict]:
    """打开笔记详情页，取 imageList 里全部图片（含每张的真实宽高）。

    返回 [{"url":..., "width":..., "height":...}]，失败返回空列表。

    为什么必须走详情页：用户主页 SSR 的 cover 只有 1 张，多图笔记在主页
    也只露封面。详情页的 note.imageList 才是完整列表（实测 9 张笔记
    在主页显示 1 张、详情页 9 张）。
    详情页必须有 xsec_token，否则 SSR 里 noteDetailMap 的 key 是
    "undefined"、note 是空对象 —— 这是之前一直"只有一张图"的根本原因。
    """
    url = f"https://www.xiaohongshu.com/explore/{note_id}"
    if xsec_token:
        url += f"?xsec_token={xsec_token}&xsec_source=pc_user"
    try:
        page.goto(url, wait_until="domcontentloaded", timeout=45000)
    except Exception:  # noqa: BLE001
        return []
    # SSR 注入可能晚于 DOM，最多等 6 秒
    for _ in range(12):
        try:
            got = page.evaluate(
                """()=>{
                const s=window.__INITIAL_STATE__;
                const m=(s&&s.note&&s.note.noteDetailMap)||{};
                for(const k of Object.keys(m)){
                  const n=m[k] && m[k].note;
                  if(n && n.imageList && n.imageList.length) {
                    return n.imageList.map(x=>({
                      url: x.urlDefault||'',
                      width: x.width||0, height: x.height||0,
                      infos: (x.infoList||[]).map(i=>({scene:i.imageScene, url:i.url})),
                    }));
                  }
                }
                return null;
              }"""
            )
        except Exception:  # noqa: BLE001
            got = None
        if got:
            out = []
            for i, x in enumerate(got):
                # 选最大档：infoList 里优先取非预览场景，否则退回 urlDefault
                best = x.get("url") or ""
                for it in x.get("infos") or []:
                    sc = (it.get("scene") or "").upper()
                    if sc and "PRV" not in sc and it.get("url"):
                        best = it["url"]
                        break
                best = (best or "").replace("\\u002F", "/")
                if best.startswith("http://"):
                    best = "https://" + best[7:]
                if best:
                    out.append({"url": best, "width": x.get("width") or 0,
                                "height": x.get("height") or 0, "seq": i + 1})
            return out
        page.wait_for_timeout(500)
    return []


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
