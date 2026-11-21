"""网页登录会话：在容器内用 Xvfb 起一个可见浏览器，把画面截图传给前端。

容器里没有图形界面，但 Playwright 官方镜像自带 Xvfb，可以跑 headful 浏览器。
做法：
  1. 用 Xvfb 起一个虚拟显示（:99）
  2. 用 headless=False 打开目标平台的登录页
  3. 定时截图，前端轮询取图，用户直接扫屏幕上的二维码
  4. 检测到登录成功（cookie 变化）后写入 state.json，容器采集时自动注入
"""
from __future__ import annotations

import base64
import io
import json
import os
import queue
import shutil
import subprocess
import threading
import time
from pathlib import Path

from . import config
from .platforms import browser as platforms

ROOT = config.ROOT
DATA = config.DATA
STATE_FILE = config.STATE_FILE

# 登录成功后由 webapp 注册的回调（清状态缓存），避免反向 import 造成循环依赖
_on_login_saved = None


def set_saved_callback(fn) -> None:
    global _on_login_saved
    _on_login_saved = fn


DISPLAY = ":99"
# 登录页地址。网易云首页资源很重且登录框在 iframe 里，
# 直接用轻量的登录页更稳；其它平台用首页即可。
LOGIN_URLS = {
    "netease": "https://music.163.com/#/login",
    "douyin": "https://www.douyin.com/",
    # 微博不要用 weibo.com 首页：游客态会被 passport visitor 机制重定向回首页
    # 信息流，点「登录/注册」还会在新标签页反复开 newlogin，二维码始终不出现。
    # 直接用官方 passport 登录页，二维码直接渲染在页面上。
    "weibo": "https://passport.weibo.com/sso/signin",
    "xiaohongshu": "https://www.xiaohongshu.com/explore",
}

# 每个平台登录成功的判定 cookie（游客态不会有这些）
LOGIN_MARKERS = {
    "netease": ("music.163.com", "MUSIC_U"),
    "douyin": ("douyin.com", "sessionid"),
    "douyin_alt": ("douyin.com", "sid_tt"),
    "weibo": ("weibo.com", "SUBP"),
    "xiaohongshu": ("xiaohongshu.com", "web_session"),
}


# 登录界面上可能承载二维码的容器（按优先级排列）
LOGIN_SHOT_SELECTORS = [
    # 微博 passport 登录页：二维码父容器 / 整个登录卡片
    ".w-45.h-45", ".w-82\\.5", "[class*='border-r']",
    ".login-container", ".login-box", ".qrcode-box", ".qr-box",
    ".scan-box", ".login-modal", ".login-panel",
    "[class*='qrcode']", "[class*='qr-code']", "[class*='QRCode']",
    "[class*='login-container']", "[class*='loginBox']",
    "[class*='loginDialog']", "[class*='login_modal']",
    "[class*='scan']",
]


def _display_ready() -> bool:
    """检查 Xvfb 是否真的在跑。

    只看 socket 文件不够：Xvfb 崩掉后 /tmp/.X11-unix/X99 会残留，
    会误判成「显示可用」，结果 Chrome 报 "Missing X server or $DISPLAY"。
    所以要同时确认进程存在。
    """
    disp = DISPLAY.lstrip(":").split(":")[0]
    sock = Path(f"/tmp/.X11-unix/X{disp}")
    if not sock.exists():
        return False
    # 确认 Xvfb 进程还在
    try:
        out = subprocess.run(
            ["pgrep", "-f", f"Xvfb :{disp}"],
            capture_output=True, text=True, timeout=5)
        return out.returncode == 0 and bool(out.stdout.strip())
    except Exception:  # noqa: BLE001
        return False


def ensure_xvfb() -> bool:
    """确保 Xvfb 虚拟显示可用，返回是否成功。"""
    if _display_ready():
        return True
    if not shutil.which("Xvfb"):
        return False
    disp = DISPLAY.lstrip(":").split(":")[0]
    # 清掉残留的 socket，避免 Xvfb 启动时因地址被占用而失败
    for p in (Path(f"/tmp/.X11-unix/X{disp}"), Path(f"/tmp/.X{disp}-lock")):
        try:
            if p.exists() or p.is_symlink():
                p.unlink()
        except OSError:
            pass
    env = os.environ.copy()
    env["DISPLAY"] = DISPLAY
    subprocess.Popen(
        ["Xvfb", DISPLAY, "-screen", "0", "1280x900x24", "-nolisten", "tcp"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        env=env, start_new_session=True,
    )
    for _ in range(40):
        time.sleep(0.25)
        if _display_ready():
            return True
    return False


class LoginWorker:
    """固定的登录工作线程。

    Playwright 的同步 API 只能在创建它的线程里用，而且一次只能驱动一个浏览器。
    把所有登录会话排队到这个线程执行，既保证线程安全，
    又能让浏览器在会话之间复用（第二次登录从 7 秒降到 0.5 秒）。
    """

    def __init__(self):
        self._q: "queue.Queue" = queue.Queue()
        self._thread = threading.Thread(target=self._loop, daemon=True, name="login-worker")
        self._thread.start()

    def submit(self, fn) -> None:
        self._q.put(fn)

    def _loop(self) -> None:
        while True:
            fn = self._q.get()
            if fn is None:
                return
            try:
                fn()
            except Exception:  # noqa: BLE001
                pass
            finally:
                self._q.task_done()


WORKER = LoginWorker()


class SharedBrowser:
    """登录浏览器管理。

    注意：Playwright 的同步 API **不是线程安全的**——一个 Playwright 实例
    只能在创建它的线程里用。所以浏览器不能跨会话共享，
    只能在同一线程内复用（同一线程内的连续会话）。

    实现方式：按线程缓存浏览器实例。同一线程的后续登录直接复用，
    换成 0.5 秒；换线程则重新启动（约 3-4 秒）。
    """

    _local = threading.local()
    _lock = threading.Lock()
    IDLE_LIMIT = 300  # 5 分钟后没人用就关掉，避免长期占资源

    @classmethod
    def acquire(cls):
        """返回 (playwright, context)。"""
        pw = getattr(cls._local, "pw", None)
        ctx = getattr(cls._local, "ctx", None)
        started = getattr(cls._local, "started", 0.0)
        now = time.time()

        if ctx is not None and now - started > cls.IDLE_LIMIT:
            cls._destroy_local()
            pw = ctx = None

        if ctx is None:
            if not ensure_xvfb():
                raise RuntimeError("容器内缺少 Xvfb，无法显示登录界面")
            os.environ["DISPLAY"] = DISPLAY
            os.environ.setdefault("SW_BROWSER_CHANNEL", "")
            os.environ.setdefault("SW_BROWSER_NO_SANDBOX", "1")
            from playwright.sync_api import sync_playwright
            pw = sync_playwright().start()
            profile = platforms.profile_path("login")
            platforms._clean_stale_locks(profile)
            args = ["--no-first-run", "--no-default-browser-check",
                    "--disable-blink-features=AutomationControlled",
                    "--no-sandbox", "--disable-dev-shm-usage",
                    "--disable-gpu", "--disable-software-rasterizer",
                    "--window-size=1280,900", "--window-position=0,0",
                    "--js-flags=--max-old-space-size=512"]
            ctx = pw.chromium.launch_persistent_context(
                user_data_dir=str(profile),
                headless=False,
                user_agent=platforms.UA,
                locale="zh-CN",
                viewport={"width": 1280, "height": 860},
                args=args,
                env={**os.environ, "DISPLAY": DISPLAY},
            )
            ctx.set_default_timeout(30000)
            cls._local.pw = pw
            cls._local.ctx = ctx
        cls._local.started = now
        return pw, ctx

    @classmethod
    def _destroy_local(cls) -> None:
        ctx = getattr(cls._local, "ctx", None)
        pw = getattr(cls._local, "pw", None)
        for obj, meth in ((ctx, "close"), (pw, "stop")):
            if obj is None:
                continue
            try:
                getattr(obj, meth)()
            except Exception:  # noqa: BLE001
                pass
        cls._local.ctx = None
        cls._local.pw = None

    @classmethod
    def release(cls) -> None:
        """标记最近使用时间（保持热启动，不真的关）。"""
        cls._local.started = time.time()

    @classmethod
    def shutdown(cls) -> None:
        cls._destroy_local()


class LoginSession:
    """一次登录会话：起浏览器 → 持续截图 → 检测登录成功。"""

    def __init__(self, platform: str):
        self.platform = platform
        self.id = f"{platform}_{int(time.time() * 1000)}"
        self.state = "starting"      # starting | waiting | success | failed | cancelled
        self.message = "正在准备浏览器…"
        self.shot_b64: str | None = None
        self.shot_at = 0.0
        self.error: str | None = None
        self.started_at = time.time()
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None

    # ---------- 对外 ----------
    def start(self) -> None:
        # 投递到固定的登录工作线程：Playwright 同步 API 非线程安全，
        # 所有会话都在同一线程跑，浏览器才能真正复用（省 3 秒启动）
        WORKER.submit(self._run)

    def cancel(self) -> None:
        self._stop.set()
        self.state = "cancelled"
        self.message = "已取消"

    def status(self) -> dict:
        return {
            "id": self.id,
            "platform": self.platform,
            "state": self.state,
            "message": self.message,
            "error": self.error,
            "has_shot": self.shot_b64 is not None,
            "shot_at": self.shot_at,
            "elapsed": int(time.time() - self.started_at),
        }

    def shot(self) -> str | None:
        with self._lock:
            return self.shot_b64

    # ---------- 内部 ----------
    def _run(self) -> None:
        try:
            if not ensure_xvfb():
                self.state = "failed"
                self.error = "容器内缺少 Xvfb，无法显示登录界面"
                self.message = "启动失败"
                return

            os.environ["DISPLAY"] = DISPLAY
            os.environ.setdefault("SW_BROWSER_CHANNEL", "")
            os.environ.setdefault("SW_BROWSER_NO_SANDBOX", "1")

            url = LOGIN_URLS.get(self.platform)
            if not url:
                self.state = "failed"
                self.error = f"不支持的平台：{self.platform}"
                return

            self.state = "waiting"
            self.message = "正在加载登录页…"

            # 复用常驻浏览器：比每次重启 Chromium 快 2-3 秒
            pw, ctx = SharedBrowser.acquire()
            page = ctx.new_page()
            try:
                # 只等 domcontentloaded，登录框由前端 JS 渲染，
                # 等 networkidle 反而更慢
                page.goto(url, wait_until="domcontentloaded", timeout=45000)
                self.message = f"请在下方二维码处扫码登录（{self.platform}）"

                # 先立刻出一帧（哪怕还没渲染完），让用户马上看到画面在加载，
                # 而不是干等好几秒才有反应
                try:
                    self._capture(page)
                except Exception:  # noqa: BLE001
                    pass

                # 边渲染边刷新：不等页面完全加载完，
                # 每 1 秒截一次，二维码一出现就能扫
                last_check = 0.0
                last_expired_check = 0.0
                last_open_try = 0.0
                while not self._stop.is_set():
                    try:
                        self._capture(page)
                    except Exception as e:  # noqa: BLE001
                        self.error = f"截图失败：{str(e)[:120]}"
                    now = time.time()

                    # 登录框可能要等几秒才渲染出来，渲染好之前每 2 秒试着点一次
                    if now - last_open_try >= 2.0:
                        last_open_try = now
                        if not self._has_qr(page):
                            self._try_open_login_dialog(page)

                    # 每 1.5 秒检查一次登录状态
                    if now - last_check >= 1.5:
                        last_check = now
                        if self._logged_in(ctx):
                            self._save_state(ctx)
                            self.state = "success"
                            self.message = "✅ 登录成功，凭证已保存"
                            return
                    # 每 8 秒检查一次二维码是否过期，过期就自动刷新。
                    # 刷新前再确认一次登录态：扫码成功后 cookie 可能刚写入，
                    # 页面上还残留着上一张二维码的失效文案，绝不能把已成功的
                    # 登录会话刷掉。
                    if now - last_expired_check >= 8.0:
                        last_expired_check = now
                        if not self._logged_in(ctx) and self._qr_expired(page):
                            self._refresh_qr(page, url)
                    self._stop.wait(0.8)

                self.state = "cancelled"
                self.message = "已取消"
            finally:
                try:
                    page.close()
                except Exception:  # noqa: BLE001
                    pass
                SharedBrowser.release()
        except Exception as e:  # noqa: BLE001
            self.state = "failed"
            self.error = f"{type(e).__name__}: {str(e)[:200]}"
            self.message = "登录会话出错"

    def _wait_render(self, page) -> None:
        """等待页面渲染完成，避免截到空白页。

        不逐个等选择器（有些平台的登录框没有稳定的类名，等太久反而卡住），
        改成固定等待 + 提前结束：一旦页面有可见内容就返回。
        """
        try:
            page.wait_for_load_state("load", timeout=20000)
        except Exception:  # noqa: BLE001
            pass
        # 最多再等 8 秒，期间一旦页面有实质内容就提前返回
        deadline = time.time() + 8.0
        while time.time() < deadline:
            try:
                ready = page.evaluate(
                    """() => {
                      const b = document.body;
                      if (!b) return false;
                      // 页面里有 canvas / img / iframe 一般就意味着登录框渲染了
                      if (document.querySelector('canvas, img, iframe')) return true;
                      return (b.innerText || '').trim().length > 80;
                    }"""
                )
                if ready:
                    break
            except Exception:  # noqa: BLE001
                break
            time.sleep(0.5)
        time.sleep(2.5)
        # 有些平台（抖音）登录框要点击「登录」才弹出来
        self._try_open_login_dialog(page)

    def _try_open_login_dialog(self, page) -> None:
        """尝试点开登录弹窗：抖音等平台默认不展示二维码，需要主动点登录。"""
        candidates = [
            "text=登录", "text=立即登录", "text=登录/注册",
            "[class*='login-btn']", "[class*='loginBtn']",
            "[data-e2e='login-button']", "button:has-text('登录')",
            "[class*='douyin-header'] [class*='login']",
        ]
        for sel in candidates:
            try:
                el = page.query_selector(sel)
                if not el:
                    continue
                if not el.is_visible():
                    continue
                el.click(timeout=3000)
                time.sleep(2.5)
                return
            except Exception:  # noqa: BLE001
                continue

    def _has_qr(self, page) -> bool:
        """页面上是否已经出现二维码/登录框。"""
        try:
            return bool(page.evaluate(
                """() => {
                  // 微博 passport 二维码来自 v2.qr.weibo.cn，src 不含 qrcode 字样
                  if (location.hostname.indexOf('passport.weibo.com') >= 0 &&
                      document.querySelector('img[src*="qr.weibo.cn"]')) return true;
                  const sel = 'canvas, img[src*=qrcode], img[src*="qr.weibo"], ' +
                              'img[class*=qrcode], .qrcode, .qr-code, ' +
                              '.login-container, [class*=loginBox]';
                  const els = document.querySelectorAll(sel);
                  for (const el of els) {
                    const r = el.getBoundingClientRect();
                    if (r.width > 60 && r.height > 60) return true;
                  }
                  return false;
                }"""
            ))
        except Exception:  # noqa: BLE001
            return False

    def _qr_expired(self, page) -> bool:
        """检测二维码是否**真正**过期。

        这里曾经踩过一个坑：旧规则用「二维码已」「请刷新」「重新扫码」这类
        宽泛关键词做匹配，而扫码成功后页面会显示「二维码已扫描，请在手机上
        确认」「重新扫码登录其它账号」等文案，结果把「扫描成功」当成过期，
        自动刷新页面，把正在确认的登录流程打断 —— 表现就是永远登录不成功。

        现在的规则：
          1. 先识别「已扫描 / 待手机确认」，只要命中就绝不刷新；
          2. 只匹配明确的失效文案，且必须和二维码直接相关。
        """
        try:
            text = page.evaluate(
                """() => {
                  const el = document.querySelector('.login-container,[class*=login],[class*=Login]');
                  return el ? (el.innerText || '') : (document.body.innerText || '');
                }"""
            )
        except Exception:  # noqa: BLE001
            return False
        if not text:
            return False

        # 已扫描、正在等待手机确认 —— 这是登录成功的必经状态，绝对不能刷新
        for kw in ("已扫描", "扫描成功", "扫码成功", "请在手机", "请在手机上确认",
                   "请确认登录", "确认登录", "待确认", "登录中", "正在登录"):
            if kw in text:
                return False

        # 明确的失效文案才刷新
        for kw in ("二维码已失效", "二维码已过期", "二维码失效", "二维码过期",
                   "二维码已无效", "二维码无效", "请重新扫码", "刷新二维码"):
            if kw in text:
                return True
        return False

    def _refresh_qr(self, page, url: str) -> None:
        """二维码过期了，刷新页面拿新的。"""
        self.message = "二维码已过期，正在自动刷新…"
        try:
            page.reload(wait_until="domcontentloaded", timeout=40000)
            time.sleep(2.0)
            self._try_open_login_dialog(page)
        except Exception:  # noqa: BLE001
            try:
                page.goto(url, wait_until="domcontentloaded", timeout=40000)
            except Exception:  # noqa: BLE001
                pass
        self._expired_at = 0.0

    def _capture(self, page) -> None:
        """截图并压缩成 JPEG 以减小传输体积。

        优先只截登录框/二维码所在元素，这样在网页上显示得更大更清晰；
        找不到合适的元素时退回整页截图。
        """
        png = None
        for sel in LOGIN_SHOT_SELECTORS:
            try:
                el = page.query_selector(sel)
                if not el:
                    continue
                box = el.bounding_box()
                if not box or box["width"] < 120 or box["height"] < 120:
                    continue
                # 留点边距，别切掉二维码
                pad = 24
                clip = {
                    "x": max(0, box["x"] - pad),
                    "y": max(0, box["y"] - pad),
                    "width": min(box["width"] + pad * 2, 1200),
                    "height": min(box["height"] + pad * 2, 900),
                }
                png = page.screenshot(clip=clip)
                break
            except Exception:  # noqa: BLE001
                continue
        if png is None:
            png = page.screenshot()

        try:
            from PIL import Image
            img = Image.open(io.BytesIO(png)).convert("RGB")
            img.thumbnail((1100, 1100))
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=78, optimize=True)
            data = buf.getvalue()
        except Exception:  # noqa: BLE001  —— 没装 Pillow 就直接用 PNG
            data = png
        with self._lock:
            self.shot_b64 = base64.b64encode(data).decode()
            self.shot_at = time.time()

    # 各平台「登录态专属」cookie：游客态拿不到这些，可直接在本地判定，
    # 不必跳转页面被反爬拦截后误判为未登录。
    _LOGIN_COOKIES = {
        "netease": ("music.163.com", ("MUSIC_U",)),
        "douyin": ("douyin.com", ("sessionid", "sessionid_ss", "sid_tt")),
        # 微博游客态访问首页就会自动种下 SUBP，用它判定会在「什么都没干」时
        # 误报登录成功，登录会话瞬间结束、二维码根本来不及显示。
        # 这里刻意不列 weibo，强制走下方 cookie_status() 的
        # /ajax/profile/info isLogin 接口验证（游客态 isLogin=false）。
        # 小红书游客态也有 web_session，只有 id_token 是登录态专属。
        "xiaohongshu": ("xiaohongshu.com", ("id_token",)),
    }

    def _weibo_strict_logged_in(self, ctx) -> bool:
        """微博登录会话专用判定：检测登录态专属 cookie。

        历史教训（两次踩坑，务必保留注释）：
          1. 最早用 SUBP 判定 —— 微博游客态访问首页就会种下 SUBP，导致
             「什么都没干就提示登录成功」，二维码来不及显示。
          2. 后来改调 /ajax/profile/info 看 isLogin/more —— 2026-11 微博接口
             改版移除了这两个字段，登录态与游客态返回完全一致（实测 data 只有
             user/tabList/blockText），导致扫码成功后永远判定失败、会话卡在
             waiting、cookie 写不回 state.json，徽章和列表采集都停在游客态。

        现在改用 ALF / SSOLoginState：这是微博登录态专属 cookie，游客态访问
        任何页面都不会种下（实测游客态只有 SUB/SUBP/WBPSESS/tid）。本地判定，
        不依赖会变的接口字段，稳定可靠。
        """
        try:
            dom = ctx.cookies()
        except Exception:  # noqa: BLE001
            return False
        for c in dom:
            if c.get("name") in ("ALF", "SSOLoginState") and \
                    "weibo" in c.get("domain", ""):
                return True
        return False

    def _logged_in(self, ctx) -> bool:
        """检测是否已登录。ctx 是 BrowserContext。

        注意：这里早先错写成 platforms.Browser.cookie_status(ctx) —— 那是实例
        方法，ctx 被当成 self，执行 self._ctx 时抛异常被吞掉；小红书又没有
        cookie 兜底，于是「页面明明已登录」却永远检测不到、登录会话卡在 waiting。
        现在直接用模块级函数 + 本地 cookie 双重判定。
        """
        # 微博走专用严格判定：游客态 SUBP 不能作数，接口探测失败也不算成功
        if self.platform == "weibo":
            return self._weibo_strict_logged_in(ctx)
        try:
            dom = ctx.cookies()
        except Exception:  # noqa: BLE001
            return False
        domain, names = self._LOGIN_COOKIES.get(self.platform, ("", ()))
        if domain and any(c["name"] in names
                          for c in dom if domain in c.get("domain", "")):
            return True
        # 再走一次基于页面的检测（其它平台需要确认接口返回值）
        try:
            st = platforms.cookie_status(ctx)
            if st.get(self.platform):
                return True
        except Exception:  # noqa: BLE001
            pass
        return False

    def _save_state(self, ctx) -> None:
        """把登录后的 cookie 合并进 state.json（容器采集时会自动注入）。"""
        try:
            cookies = ctx.cookies()
        except Exception:  # noqa: BLE001
            return
        existing = {"cookies": [], "origins": []}
        if STATE_FILE.exists():
            try:
                existing = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            except Exception:  # noqa: BLE001
                existing = {"cookies": [], "origins": []}
        merged = {(c.get("domain"), c.get("name"), c.get("path")): c
                  for c in (existing.get("cookies") or [])}
        for c in cookies:
            merged[(c.get("domain"), c.get("name"), c.get("path"))] = c
        STATE_FILE.write_text(
            json.dumps({"cookies": list(merged.values()), "origins": []},
                       ensure_ascii=False, indent=2),
            encoding="utf-8")
        # 通知 Web 端清掉旧的登录态缓存，页面下次刷新就能看到「已登录」
        try:
            if _on_login_saved:
                _on_login_saved()
        except Exception:  # noqa: BLE001
            pass


class LoginManager:
    """管理登录会话，同一平台只允许一个进行中的会话。"""

    def __init__(self):
        self._sessions: dict[str, LoginSession] = {}
        self._lock = threading.Lock()

    def start(self, platform: str) -> LoginSession:
        with self._lock:
            old = self._sessions.get(platform)
            if old and old.state in ("starting", "waiting"):
                return old
            s = LoginSession(platform)
            self._sessions[platform] = s
        s.start()
        return s

    def get(self, platform: str) -> LoginSession | None:
        with self._lock:
            return self._sessions.get(platform)

    def cancel(self, platform: str) -> bool:
        with self._lock:
            s = self._sessions.get(platform)
        if not s:
            return False
        s.cancel()
        return True

MANAGER = LoginManager()
