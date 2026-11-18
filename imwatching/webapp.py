"""Web 服务：把监控数据以网页形式实时查看。

刻意只用 Python 标准库实现，避免引入 Web 框架依赖——
容器镜像更小、启动更快、也更少踩依赖版本冲突的坑。

提供：
  GET  /                    监控面板
  GET  /api/state           全量状态（卡片 + 事件 + 运行记录 + 登录态）
  GET  /api/events          变更事件（可按 target/platform 过滤）
  POST /api/check           手动触发一次巡检
  POST /api/targets         新增监控目标
  PUT  /api/targets/<idx>   修改目标（启停、选项）
  DELETE /api/targets/<idx> 删除目标
  GET  /api/health          健康检查
"""
from __future__ import annotations

import json
import os
import re
import threading
import time
import traceback
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urljoin, urlparse

import yaml

from . import config
from .core import report
from .core.store import Store
from . import runner
from .platforms import browser as platforms

ROOT = config.ROOT
CFG = config.CFG
DB = config.DB
PROFILE = platforms.profile_root()
STATE_FILE = config.STATE_FILE

PAGE = config.PAGE

_check_thread_lock = threading.Lock()
_check_thread: threading.Thread | None = None
_check_thread_state: dict = {"running": False, "started_at": None, "finished_at": None,
                             "last_result": None}


# ---------------------------------------------------------------- 配置读写
def load_cfg() -> dict:
    try:
        with open(CFG, encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except FileNotFoundError:
        return {}


def save_cfg(cfg: dict) -> None:
    """写入配置文件。

    注意：容器里 config.yaml 是 bind mount 进来的，macOS 的文件共享层
    不允许对挂载文件做 rename（会报 Device or resource busy），
    所以这里改为「先写临时文件 → 读回校验 → 原地覆盖」。
    """
    text = yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False)
    tmp = CFG.with_suffix(".yaml.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())

    # 校验临时文件可被解析，避免写入损坏的配置
    try:
        with open(tmp, encoding="utf-8") as f:
            yaml.safe_load(f)
    except Exception:  # noqa: BLE001
        tmp.unlink(missing_ok=True)
        raise

    try:
        # 原子替换（本地文件系统可用）
        tmp.replace(CFG)
        return
    except OSError:
        pass

    # bind mount 场景：rename 不可用，退回原地覆盖
    try:
        with open(CFG, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
    finally:
        tmp.unlink(missing_ok=True)


def make_browser(headless: bool = True, profile: Path | None = None) -> platforms.Browser:
    prof = profile or PROFILE
    return platforms.Browser(prof, headless=headless, state_file=STATE_FILE)


# ---------------------------------------------------------------- 登录态
_login_cache: dict = {"at": 0, "data": {}, "state_mtime": 0}
_login_lock = threading.Lock()


def invalidate_login_cache() -> None:
    """登录成功后调用：让状态检测立即重跑，不再返回旧的「未登录」缓存。"""
    with _login_lock:
        _login_cache["at"] = 0
        _login_cache["data"] = {}


def login_status(max_age: int = 60, force: bool = False) -> dict:
    """检测各平台 cookie 状态。缓存 60 秒，避免频繁启动浏览器。

    浏览器 profile 目录同一时刻只能被一个进程使用。若此时正在巡检
    （调度器或手动触发占用着浏览器），直接返回缓存值，不去抢 profile。
    """
    now = time.time()
    # state.json 一变（登录刚保存凭证），旧的「未登录」缓存立即作废
    try:
        cur_mtime = STATE_FILE.stat().st_mtime
    except OSError:
        cur_mtime = 0
    if cur_mtime and cur_mtime != _login_cache.get("state_mtime"):
        with _login_lock:
            _login_cache["at"] = 0
            _login_cache["data"] = {}
            _login_cache["state_mtime"] = cur_mtime
    with _login_lock:
        cached = _login_cache["data"] or {}
        if not force and now - _login_cache["at"] < max_age and cached:
            return cached

        busy = _check_thread_state["running"]
        if not busy:
            try:
                from . import scheduler
                busy = scheduler.status().get("running", False)
            except Exception:  # noqa: BLE001
                busy = False
        if not busy:
            try:
                from . import loginsession
                for s in loginsession.MANAGER._sessions.values():
                    if s.state in ("starting", "waiting"):
                        busy = True
                        break
            except Exception:  # noqa: BLE001
                pass

        if busy:
            # 正在占用浏览器：复用最近一次已知状态，避免争抢 profile 锁。
            # 没有历史值时返回明确的"检测中"，而不是空字典。
            # 注意不写缓存 —— 否则 60 秒内会一直返回"检测中"而不再重试。
            if cached:
                return cached
            return {k: None for k in ("netease", "douyin", "weibo", "xiaohongshu")} | {
                "_checking": True}

        try:
            # 优先用独立 profile 目录检测：主 profile 可能正被巡检占用，
            # 同一目录不能被两个浏览器进程同时打开。
            # 登录 cookie 通过 state.json 注入，结果等价且不会抢锁。
            # 没有 state.json 时回退到主 profile（此时它多半是空闲的）。
            if STATE_FILE.exists():
                prof = platforms.profile_path("status")
            else:
                prof = PROFILE
            with make_browser(headless=True, profile=prof) as br:
                data = br.cookie_status()
        except Exception as e:  # noqa: BLE001
            data = {"error": f"{type(e).__name__}: {e}"}
        _login_cache["at"] = now
        _login_cache["data"] = data
        return data


# ---------------------------------------------------------------- 巡检触发
def trigger_check(target_filter: str | None = None, source: str = "manual") -> dict:
    """异步触发一轮巡检，立即返回，不阻塞 HTTP 请求。"""
    global _check_thread
    with _check_thread_lock:
        if _check_thread and _check_thread.is_alive():
            return {"ok": False, "message": "已有巡检在运行中"}

        def work():
            _check_thread_state["running"] = True
            _check_thread_state["started_at"] = int(time.time())
            try:
                cfg = load_cfg()
                store = Store(DB)
                res = runner.run_check(cfg, store, target_filter,
                                       browser_factory=make_browser)
                _check_thread_state["last_result"] = res
            except Exception as e:  # noqa: BLE001
                _check_thread_state["last_result"] = {
                    "ok": False, "error": f"{type(e).__name__}: {e}",
                    "traceback": traceback.format_exc()[-2000:],
                }
            finally:
                _check_thread_state["running"] = False
                _check_thread_state["finished_at"] = int(time.time())

        _check_thread = threading.Thread(target=work, daemon=True,
                                         name="manual-check")
        _check_thread.start()
    return {"ok": True, "message": "巡检已启动", "source": source}


# ---------------------------------------------------------------- 主页链接识别
# 从用户复制的主页链接 / 分享文本里自动提取平台和账号 ID。
# 只请求已知短链域名，避免把服务当成任意 URL 抓取器。
_LINK_PATTERNS = [
    ("netease", r"music\.163\.com/[^\s]*?[?&]id=(\d+)"),
    ("weibo", r"(?:m\.)?(?:weibo\.com|weibo\.cn)/(?:u/)?(\d+)"),
    # 抖音短链会跳到 iesdouyin.com/share/user/<sec_uid>，和网页版 /user/ 不同
    ("douyin", r"(?:iesdouyin|douyin)\.com/(?:share/)?user/([A-Za-z0-9_-]{12,})"),
    ("douyin", r"[?&]sec_uid=([A-Za-z0-9_-]{12,})"),
    ("xiaohongshu", r"xiaohongshu\.com/user/profile/([0-9a-zA-Z]{16,})"),
]
_SHORT_DOMAINS = ("t.cn", "v.douyin.com", "xhslink.cn", "xhslink.com", "dwz.cn")
_RESOLVE_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
               "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """不自动跟随跳转，改为手动收集每一跳的 Location。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _follow_short_link(url: str) -> tuple[str, list[str], str]:
    """跟随短链，返回 (最终URL, 所有中间跳转URL, 页面HTML)。

    必须收集中间跳转：小红书最终会跳到 /login?redirectPath=...，
    干净的 user/profile/<id> 只出现在第一跳的 Location 里。
    """
    hops: list[str] = []
    html = ""
    current = url
    opener = urllib.request.build_opener(_NoRedirect)
    for _ in range(6):
        try:
            req = urllib.request.Request(current, headers={"User-Agent": _RESOLVE_UA})
            resp = opener.open(req, timeout=12)
        except urllib.error.HTTPError as e:
            loc = e.headers.get("Location")
            if e.code in (301, 302, 303, 307, 308) and loc:
                current = urljoin(current, loc)
                hops.append(current)
                continue
            break
        except Exception:  # noqa: BLE001
            break
        try:
            html = resp.read(200000).decode("utf-8", "ignore")
        except Exception:  # noqa: BLE001
            html = ""
        return resp.geturl(), hops, html
    return current, hops, html


def resolve_target_link(text: str) -> dict:
    """识别主页链接中的平台与账号 ID，供新增/编辑表单自动填充。"""
    raw = (text or "").strip()
    if not raw:
        return {"ok": False, "message": "请先粘贴主页链接"}

    # 用户常直接粘贴整句分享文案，先把里面的链接抠出来
    m = re.search(r"https?://[^\s\"'<>，,]+", raw)
    url = m.group(0).rstrip(".,;:!?，。；！？)）") if m else ""
    if not url:
        # 常见 ID 形态：抖音 sec_uid / 小红书 user_id
        if re.fullmatch(r"MS4wLjABAAAA[A-Za-z0-9_-]{8,}", raw):
            return {"ok": True, "platform": "douyin", "id": raw, "source": "id"}
        if re.fullmatch(r"[0-9a-fA-F]{24}", raw):
            return {"ok": True, "platform": "xiaohongshu", "id": raw, "source": "id"}
        return {"ok": False, "message": "没有检测到链接，请粘贴用户主页地址"}

    final_url, hops, html = url, [], ""
    host = (urlparse(url).hostname or "").lower()
    # 完整主页链接直接从 URL 提取即可，不必发请求（更快，也更少触发风控）
    if any(host == d or host.endswith("." + d) for d in _SHORT_DOMAINS):
        final_url, hops, html = _follow_short_link(url)

    # 优先匹配原始 URL 和跳转链（最准确），最后才退回页面 HTML
    sources = [url] + [h for h in hops if h != url]
    if final_url and final_url not in sources:
        sources.append(final_url)
    for source in sources + ([html] if html else []):
        if not source:
            continue
        for plat, pattern in _LINK_PATTERNS:
            hit = re.search(pattern, source, re.I)
            if hit:
                return {"ok": True, "platform": plat, "id": hit.group(1),
                        "source": "page" if source == html else "url"}
    return {"ok": False,
            "message": "无法从链接识别账号 ID，请确认复制的是「用户主页」链接"}


# ---------------------------------------------------------------- 图片代理
# 第三方头像/封面走服务端转发，绕开浏览器防盗链与混合内容限制。
# 仅允许下列图片 CDN 域名，防止被当作开放代理（SSRF）。
_IMG_HOSTS = (
    "music.126.net", "music.163.com",          # 网易云
    "sinaimg.cn", "sinajs.cn",                  # 微博
    "byteimg.com", "bytecdn.cn", "ixigua.com",  # 抖音
    "douyinpic.com", "douyin.com",              # 抖音头像 CDN
    "xhscdn.com", "xiaohongshu.com",            # 小红书
)


def _img_host_allowed(host: str) -> bool:
    host = (host or "").lower()
    return any(host == h or host.endswith("." + h) for h in _IMG_HOSTS)


def _img_referer(host: str) -> str:
    """按图片 CDN 选用能放行的 Referer。"""
    host = (host or "").lower()
    if "music.126.net" in host or "music.163.com" in host:
        return "https://music.163.com/"
    if "douyin" in host or "byteimg" in host or "bytecdn" in host or "ixigua" in host:
        return "https://www.douyin.com/"
    if "xhscdn" in host or "xiaohongshu" in host:
        return "https://www.xiaohongshu.com/"
    return "https://weibo.com/"  # 微博及其它：任意第三方 Referer 即可


def fetch_image(url: str) -> tuple[bytes, str] | None:
    """拉取远程图片，返回 (字节, content-type)；失败或非法地址返回 None。"""
    try:
        u = urlparse(url)
        if u.scheme not in ("http", "https") or not _img_host_allowed(u.hostname or ""):
            return None
        ref = _img_referer(u.hostname or "")
        req = urllib.request.Request(url, headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                          "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            "Referer": ref,
        })
        with urllib.request.urlopen(req, timeout=12) as r:
            data = r.read()
        ctype = r.headers.get("Content-Type") or "image/jpeg"
        if not ctype.startswith("image/") or not data:
            return None
        return data, ctype
    except Exception:  # noqa: BLE001
        return None


# ---------------------------------------------------------------- 目标增删改
def _target_public(t: dict, idx: int) -> dict:
    return {
        "index": idx,
        "name": t.get("name") or t.get("id"),
        "platform": t.get("platform"),
        "id": t.get("id"),
        "enabled": bool(t.get("enabled")),
        "options": t.get("options") or {},
    }


def add_target(body: dict) -> dict:
    cfg = load_cfg()
    plat = body.get("platform")
    tid = (body.get("id") or "").strip()
    if plat not in ("netease", "weibo", "douyin", "xiaohongshu"):
        return {"ok": False, "message": "platform 必须是 netease/weibo/douyin/xiaohongshu"}
    if not tid:
        return {"ok": False, "message": "缺少 id"}
    cfg.setdefault("targets", [])
    for t in cfg["targets"]:
        if t.get("platform") == plat and str(t.get("id")) == tid:
            return {"ok": False, "message": "该目标已存在"}
    opts = body.get("options") or {}
    people = opts.get("people") or []
    cfg["targets"].append({
        "name": (body.get("name") or f"{plat}-{tid}").strip(),
        "platform": plat,
        "id": tid,
        "enabled": bool(body.get("enabled", True)),
        "options": {
            "watch_playlists": opts.get("watch_playlists", "all"),
            "metrics": opts.get("metrics", ["followers", "following"]),
            "people": people,
            "max_users": int(opts.get("max_users") or 500),
        },
    })
    save_cfg(cfg)
    return {"ok": True, "message": "目标已添加"}


def update_target(idx: int, body: dict) -> dict:
    """修改目标：名称、ID、启用状态、采集选项。"""
    cfg = load_cfg()
    targets = cfg.get("targets") or []
    if not (0 <= idx < len(targets)):
        return {"ok": False, "message": "目标不存在"}
    t = targets[idx]

    if "enabled" in body:
        t["enabled"] = bool(body["enabled"])

    if "name" in body:
        name = (body["name"] or "").strip()
        if not name:
            return {"ok": False, "message": "名称不能为空"}
        t["name"] = name

    if "id" in body:
        new_id = str(body["id"]).strip()
        if not new_id:
            return {"ok": False, "message": "账号 ID 不能为空"}
        if new_id != str(t.get("id")):
            for other in targets:
                if other is not t and other.get("platform") == t.get("platform") \
                        and str(other.get("id")) == new_id:
                    return {"ok": False, "message": "已存在相同平台和 ID 的目标"}
        t["id"] = new_id

    if "platform" in body and body["platform"] != t.get("platform"):
        plat = body["platform"]
        if plat not in ("netease", "weibo", "douyin", "xiaohongshu"):
            return {"ok": False, "message": "不支持的平台"}
        t["platform"] = plat

    if "options" in body and isinstance(body["options"], dict):
        opts = t.setdefault("options", {})
        o = body["options"]
        if "people" in o:
            people = o["people"] or []
            if not isinstance(people, list):
                return {"ok": False, "message": "people 必须是数组"}
            opts["people"] = [p for p in people if p in ("following", "followers")]
        if "metrics" in o:
            metrics = o["metrics"] or []
            if not isinstance(metrics, list):
                return {"ok": False, "message": "metrics 必须是数组"}
            opts["metrics"] = metrics
        if "watch_playlists" in o:
            opts["watch_playlists"] = o["watch_playlists"]
        if "max_users" in o:
            try:
                opts["max_users"] = max(1, min(5000, int(o["max_users"])))
            except (TypeError, ValueError):
                return {"ok": False, "message": "max_users 必须是数字"}

    save_cfg(cfg)
    return {"ok": True, "message": "目标已更新"}


def delete_target(idx: int) -> dict:
    cfg = load_cfg()
    targets = cfg.get("targets") or []
    if not (0 <= idx < len(targets)):
        return {"ok": False, "message": "目标不存在"}
    removed = targets.pop(idx)
    save_cfg(cfg)
    return {"ok": True, "message": f"已删除 {removed.get('name') or removed.get('id')}"}


# ---------------------------------------------------------------- 状态组装
def build_state() -> dict:
    cfg = load_cfg()
    store = Store(DB)
    payload = report.collect_payload(store, cfg)
    payload["targets"] = [_target_public(t, i)
                          for i, t in enumerate(cfg.get("targets") or [])]
    payload["config"] = {
        "poll_interval_minutes": cfg.get("poll_interval_minutes", 60),
        "browser_headless": cfg.get("browser_headless", True),
    }
    payload["login"] = login_status()
    # 合并手动触发与调度器两条通道的状态，让页面能看到真实巡检情况
    sched = {}
    try:
        from . import scheduler
        sched = scheduler.status()
    except Exception:  # noqa: BLE001
        sched = {}
    manual_running = _check_thread_state["running"]
    payload["check"] = {
        "running": manual_running or bool(sched.get("running")),
        "manual_running": manual_running,
        "scheduler_running": bool(sched.get("running")),
        "started_at": _check_thread_state["started_at"] or sched.get("started_at"),
        "finished_at": _check_thread_state["finished_at"] or sched.get("finished_at"),
        "last_result": _check_thread_state["last_result"] or sched.get("last_result"),
        "scheduler_runs": sched.get("runs", 0),
        "scheduler_errors": sched.get("errors", 0),
    }
    payload["server_time"] = int(time.time())
    return payload


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "SocialWatch"

    def log_message(self, fmt, *args):  # 静音默认访问日志
        pass

    def _send(self, code: int, body: bytes, ctype: str = "application/json; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, obj, code: int = 200):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"))

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception:  # noqa: BLE001
            return {}

    # ---- GET ----
    def do_GET(self):  # noqa: N802
        u = urlparse(self.path)
        path = u.path
        q = parse_qs(u.query)
        try:
            if path in ("/", "/index.html"):
                if not PAGE.exists():
                    self._send(404, b"page not found", "text/plain; charset=utf-8")
                    return
                self._send(200, PAGE.read_bytes(), "text/html; charset=utf-8")
                return

            if path == "/api/state":
                self._json(build_state())
                return

            if path == "/api/img":
                url = (q.get("url") or [""])[0]
                got = fetch_image(url)
                if not got:
                    self._send(404, b"not found", "text/plain; charset=utf-8")
                    return
                data, ctype = got
                self._send(200, data, ctype)
                return

            if path == "/api/events":
                store = Store(DB)
                limit = min(int((q.get("limit") or ["200"])[0]), 1000)
                tk = (q.get("target") or [None])[0]
                pf = (q.get("platform") or [None])[0]
                evs = store.recent_events(limit=limit, target_key=tk)
                if pf:
                    evs = [e for e in evs if e.get("platform") == pf]
                self._json({"ok": True, "events": evs})
                return

            if path == "/api/login/status":
                plat = (q.get("platform") or [""])[0]
                from . import loginsession
                s = loginsession.MANAGER.get(plat)
                if not s:
                    self._json({"ok": True, "state": "idle", "message": "未开始"})
                    return
                self._json({"ok": True, **s.status()})
                return

            if path == "/api/login/shot":
                plat = (q.get("platform") or [""])[0]
                from . import loginsession
                s = loginsession.MANAGER.get(plat)
                if not s:
                    self._json({"ok": False, "message": "没有进行中的登录"}, 404)
                    return
                b64 = s.shot()
                if not b64:
                    self._json({"ok": False, "message": "截图尚未就绪", **s.status()}, 404)
                    return
                self._json({"ok": True, "shot": b64, "shot_at": s.shot_at})
                return

            if path == "/api/health":
                store = Store(DB)
                cfg = load_cfg()
                targets = [t for t in (cfg.get("targets") or []) if t.get("enabled")]
                problems = []
                for t in targets:
                    key = f"{t['platform']}:{t['id']}"
                    with store._conn() as c:
                        rows = c.execute(
                            "SELECT status FROM run_log WHERE target_key=? "
                            "ORDER BY ran_at DESC LIMIT 5", (key,)).fetchall()
                    fails = sum(1 for r in rows if r["status"] == "error")
                    oks = sum(1 for r in rows if r["status"] == "ok")
                    # 最近几次里有成功就不算故障——失败可能被后续成功覆盖了
                    if fails >= 3 and oks == 0:
                        problems.append({"target": key, "fails": fails})
                self._json({
                    "ok": not problems,
                    "targets": len(targets),
                    "problems": problems,
                    "login": login_status(),
                    "check_running": _check_thread_state["running"],
                })
                return

            self._json({"ok": False, "message": "not found"}, 404)
        except Exception as e:  # noqa: BLE001
            self._json({"ok": False, "message": f"{type(e).__name__}: {e}",
                        "traceback": traceback.format_exc()[-1500:]}, 500)

    # ---- POST ----
    def do_POST(self):  # noqa: N802
        u = urlparse(self.path)
        path = u.path
        body = self._body()
        try:
            if path == "/api/check":
                tf = body.get("target") or None
                self._json(trigger_check(tf))
                return
            if path == "/api/targets":
                self._json(add_target(body))
                return
            if path == "/api/resolve":
                self._json(resolve_target_link(body.get("url") or ""))
                return
            if path == "/api/login/start":
                plat = (body.get("platform") or "").strip()
                if plat not in ("netease", "weibo", "douyin", "xiaohongshu"):
                    self._json({"ok": False, "message": "不支持的平台"}, 400)
                    return
                from . import loginsession
                s = loginsession.MANAGER.start(plat)
                self._json({"ok": True, "platform": plat, **s.status()})
                return
            if path == "/api/login/cancel":
                plat = (body.get("platform") or "").strip()
                from . import loginsession
                ok = loginsession.MANAGER.cancel(plat)
                self._json({"ok": ok, "message": "已取消" if ok else "没有进行中的登录"})
                return
            self._json({"ok": False, "message": "not found"}, 404)
        except Exception as e:  # noqa: BLE001
            self._json({"ok": False, "message": f"{type(e).__name__}: {e}",
                        "traceback": traceback.format_exc()[-1500:]}, 500)

    # ---- PUT / DELETE ----
    def do_PUT(self):  # noqa: N802
        u = urlparse(self.path)
        m = u.path.rstrip("/").split("/")
        body = self._body()
        try:
            if len(m) == 4 and m[1] == "api" and m[2] == "targets":
                self._json(update_target(int(m[3]), body))
                return
            self._json({"ok": False, "message": "not found"}, 404)
        except Exception as e:  # noqa: BLE001
            self._json({"ok": False, "message": f"{type(e).__name__}: {e}"}, 500)

    def do_DELETE(self):  # noqa: N802
        u = urlparse(self.path)
        m = u.path.rstrip("/").split("/")
        try:
            if len(m) == 4 and m[1] == "api" and m[2] == "targets":
                self._json(delete_target(int(m[3])))
                return
            self._json({"ok": False, "message": "not found"}, 404)
        except Exception as e:  # noqa: BLE001
            self._json({"ok": False, "message": f"{type(e).__name__}: {e}"}, 500)


def serve(host: str = "0.0.0.0", port: int = 8080, with_scheduler: bool = True) -> None:
    # 登录凭证保存后主动清缓存，让平台状态立即刷新
    from . import loginsession
    loginsession.set_saved_callback(invalidate_login_cache)

    if with_scheduler:
        from . import scheduler
        scheduler.start_background(run_immediately=True)
        print("  调度器已随 Web 服务启动")

    srv = ThreadingHTTPServer((host, port), Handler)
    srv.daemon_threads = True
    print(f"Web 面板已启动： http://{host}:{port}")
    print(f"  数据目录：{ROOT / 'data'}")
    print(f"  配置文件：{CFG}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    p = int(os.environ.get("PORT", "8080"))
    serve(os.environ.get("HOST", "0.0.0.0"), p)
