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

import hashlib
import json
import logging
import os
import re
import threading
import time
import traceback
import urllib.error
import urllib.request
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urljoin, urlparse

import yaml

from . import config
from .core import auth
from .core import report
from .core.store import Store
from . import notify
from . import runner
from .platforms import browser as platforms

ROOT = config.ROOT
CFG = config.CFG
DB = config.DB
PROFILE = platforms.profile_root()
STATE_FILE = config.STATE_FILE

PAGE = config.PAGE

log = logging.getLogger("imwatching.webapp")

# 鉴权实例：进程内单例，token 清单改动后调 invalidate() 让下次读盘
AUTH = auth.AuthStore(config.auth_file())

#: 不需要鉴权的接口。
#: - /api/health：Docker healthcheck 在容器内请求，带不了 token
#: - /api/auth/login：登录本身当然不能要求已登录
#: - /api/auth/status：前端启动时先问"要不要登录"，避免闪一下 401
_AUTH_EXEMPT = ("/api/health", "/api/auth/login", "/api/auth/status")

#: POST 的鉴权豁免：只有登录/登出。签发与吊销 token 必须已登录，
#: 否则等于给人一个"自助发钥匙"的接口。
_POST_AUTH_EXEMPT = ("/api/auth/login", "/api/auth/logout")

_check_thread_lock = threading.Lock()
_check_thread: threading.Thread | None = None
_check_thread_state: dict = {"running": False, "started_at": None, "finished_at": None,
                             "last_result": None}

# 图片代理缓存：前端轮询会反复请求同一批头像/封面外链，缓存后大幅降低对第三方图床的请求。
_img_cache: dict[str, tuple[bytes, str, float]] = {}
_img_cache_lock = threading.Lock()
_IMG_TTL = 6 * 3600   # 图片 URL 通常带签名且有效期内不变，缓存 6 小时
_IMG_MAX = 400        # 最多缓存 400 张，超出清理最早的一批

# /api/state 全量数据短缓存：只是聚合本地数据库 + 登录态，本身不打上游，
# 但每 30 秒一次轮询重复查库、重建 JSON 也浪费；短缓存让前端刷新更轻。
_state_cache: dict = {"at": 0.0, "data": None}
_state_cache_lock = threading.Lock()
_STATE_TTL = 8  # 秒；巡检/配置变更后立即失效


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
    invalidate_state_cache()


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
                invalidate_state_cache()

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


_WB_TIER_SEGS = ("large", "mw2000", "orj960", "orj1080", "bmiddle",
                 "wap360", "wap180", "thumbnail", "cmw960", "largecover")


def _weibo_thumb_url(url: str) -> str | None:
    """把微博图 URL 的档位段换成 360 宽缩略图。

    https://wx4.sinaimg.cn/orj1080/006xxx.jpg  →  .../wap360/006xxx.jpg

    微博图片 CDN 用路径第一段表示档位，同一张图各档位只差这一段、文件名不变。
    列表缩略图用 wap360（约 68KB）即可；详情页才读本地原图（3–7MB）。
    若列表 76 个格子都拉原图，一次进列表就是 300MB 流量，显然不可行。
    """
    try:
        u = urlparse(url)
        parts = u.path.lstrip("/").split("/")
        if len(parts) < 2 or parts[0].lower() not in _WB_TIER_SEGS:
            return None
        parts[0] = "wap360"
        return f"{u.scheme}://{u.netloc}/{'/'.join(parts)}"
    except Exception:  # noqa: BLE001
        return None


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


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """禁止 urllib 自动跟随 30x。

    为什么必须禁：白名单只校验了**首个** URL 的 host，但 urllib 默认会
    自动跟随重定向。若某个 CDN 域名存在开放重定向（或被 DNS 劫持），
    攻击者构造 `sinaimg.cn/xxx?to=<内网地址>` 就能绕过白名单打到内网或
    云元数据服务 —— 这就是典型 SSRF。禁用后手动处理每一跳，
    每一跳都要重新过白名单。
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_opener = urllib.request.build_opener(_NoRedirect)

#: 重定向最多跟几跳。图片 CDN 通常 0–1 跳，3 跳足够且能防环。
_MAX_HOPS = 3


def fetch_image(url: str) -> tuple[bytes, str] | None:
    """拉取远程图片，返回 (字节, content-type)；失败或非法地址返回 None。

    带内存缓存：头像/封面 URL 在多次 /api/state 之间不变，前端每 30 秒轮询会
    反复请求同一外链。缓存命中直接返回，显著降低对第三方图床的请求频率，
    也避免被对方风控。缓存按 URL 索引，带 TTL 和容量上限。
    """
    now = time.time()
    with _img_cache_lock:
        hit = _img_cache.get(url)
        if hit and now - hit[2] < _IMG_TTL:
            return hit[0], hit[1]
    try:
        cur = url
        ref = _img_referer(urlparse(cur).hostname or "")
        for _ in range(_MAX_HOPS + 1):
            u = urlparse(cur)
            # 每一跳都重新校验：包括首跳和所有重定向目标
            if u.scheme not in ("http", "https") or not _img_host_allowed(u.hostname or ""):
                return None
            req = urllib.request.Request(cur, headers={
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                              "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
                "Referer": ref,
            })
            try:
                with _opener.open(req, timeout=12) as r:
                    if r.status in (301, 302, 303, 307, 308):
                        nxt = urljoin(cur, r.headers.get("Location") or "")
                        if not nxt or nxt == cur:
                            return None
                        cur = nxt
                        continue
                    data = r.read()
                    ctype = r.headers.get("Content-Type") or "image/jpeg"
            except urllib.error.HTTPError as e:
                # 被 _NoRedirect 拦下的 30x 以 HTTPError 抛出
                if e.code in (301, 302, 303, 307, 308):
                    nxt = urljoin(cur, e.headers.get("Location") or "")
                    if not nxt or nxt == cur:
                        return None
                    cur = nxt
                    continue
                raise
            if not ctype.startswith("image/") or not data:
                return None
            with _img_cache_lock:
                # 容量上限：超了就清掉最早插入的一批，避免长期运行内存膨胀
                if len(_img_cache) >= _IMG_MAX:
                    for k in list(_img_cache)[: _IMG_MAX // 4]:
                        _img_cache.pop(k, None)
                _img_cache[url] = (data, ctype, now)
            return data, ctype
        return None  # 跳数用尽
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
    invalidate_state_cache()
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
    invalidate_state_cache()
    return {"ok": True, "message": "目标已更新"}


def delete_target(idx: int) -> dict:
    cfg = load_cfg()
    targets = cfg.get("targets") or []
    if not (0 <= idx < len(targets)):
        return {"ok": False, "message": "目标不存在"}
    removed = targets.pop(idx)
    save_cfg(cfg)
    invalidate_state_cache()
    return {"ok": True, "message": f"已删除 {removed.get('name') or removed.get('id')}"}


def invalidate_state_cache() -> None:
    """数据发生变化时让 /api/state 缓存立即失效，前端下次刷新拿到最新数据。"""
    with _state_cache_lock:
        _state_cache["at"] = 0.0
        _state_cache["data"] = None


# ---------------------------------------------------------------- 通知配置
def save_notify(body: dict) -> dict:
    """保存通知配置。

    密钥写进 data/notify.json（gitignore），开关/通道写进 config.yaml。
    环境变量里已有的密钥优先级更高，此时会提示「由环境变量提供」，
    避免用户改了文件却以为没生效。
    """
    from . import notify as notify_mod

    cfg = load_cfg()
    nc = cfg.get("notify")
    if not isinstance(nc, dict):
        nc = {}
        cfg["notify"] = nc

    if "enabled" in body:
        nc["enabled"] = bool(body.get("enabled"))
    ch_in = body.get("channels")
    if isinstance(ch_in, dict):
        ch = nc.get("channels")
        if not isinstance(ch, dict):
            ch = {}
            nc["channels"] = ch
        for name in ("serverchan", "bark"):
            if name in ch_in:
                ch[name] = bool(ch_in.get(name))
    if "max_names_per_group" in body:
        try:
            nc["max_names_per_group"] = max(1, int(body["max_names_per_group"]))
        except (TypeError, ValueError):
            pass
    if "dashboard_url" in body:
        url = str(body.get("dashboard_url") or "").strip()
        if url:
            nc["dashboard_url"] = url
        else:
            nc.pop("dashboard_url", None)

    secrets = notify_mod.load_secrets()
    # 传空字符串表示「清空」；不传该字段表示「保持不变」
    if "serverchan_key" in body:
        secrets["serverchan_key"] = str(body.get("serverchan_key") or "").strip()
    if "bark_key" in body:
        secrets["bark_key"] = str(body.get("bark_key") or "").strip()
    if "bark_server" in body:
        server = str(body.get("bark_server") or "").strip()
        secrets["bark_server"] = server or "https://api.day.app"
    if "bark_via_serverchan" in body:
        secrets["bark_via_serverchan"] = bool(body.get("bark_via_serverchan"))
    if "proxy" in body:
        secrets["proxy"] = str(body.get("proxy") or "").strip()

    try:
        notify_mod.save_secrets(secrets)
        save_cfg(cfg)
        invalidate_state_cache()  # 让 /api/state 立即返回新的通知状态
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "message": f"保存失败：{type(exc).__name__}: {exc}"}

    st = notify_mod.status(cfg)
    msgs = []
    if st["serverchan"]["key_set"] and st["serverchan"]["from_env"]:
        msgs.append("Server酱密钥由环境变量提供，修改文件不会生效")
    if st["bark"]["key_set"] and st["bark"]["from_env"]:
        msgs.append("Bark 密钥由环境变量提供，修改文件不会生效")
    return {"ok": True, "message": "；".join(msgs) or "通知配置已保存", **st}


def test_notify(channel: str | None = None) -> dict:
    """发送测试通知。channel 为空时测所有已开启通道。"""
    from . import notify as notify_mod

    cfg = load_cfg()
    if not channel:
        # 手工测试不应该被 enabled=false 挡住，临时打开
        if not notify_mod.enabled_channels(cfg):
            tmp = dict(cfg)
            tmp["notify"] = {**(cfg.get("notify") or {}),
                             "enabled": True,
                             "channels": {"serverchan": True, "bark": True}}
            cfg = tmp
    res = notify_mod.send_test(cfg, only=channel)
    chs = res.get("channels") or {}
    ok = any(v.get("ok") for v in chs.values())
    detail = []
    for name, v in chs.items():
        label = {"serverchan": "Server酱", "bark": "Bark"}.get(name, name)
        if v.get("ok"):
            detail.append(f"{label} 已发送")
        elif v.get("skipped"):
            detail.append(f"{label} 跳过：{v.get('reason') or '未配置'}")
        else:
            detail.append(f"{label} 失败：{v.get('error') or '未知错误'}")
    return {"ok": ok, "message": "；".join(detail) or res.get("error") or "未发送",
            "channels": chs}


# ---------------------------------------------------------------- 状态组装
def build_state() -> dict:
    now = time.time()
    with _state_cache_lock:
        cached = _state_cache["data"]
        if cached is not None and now - _state_cache["at"] < _STATE_TTL:
            return cached
    payload = _build_state_uncached()
    with _state_cache_lock:
        _state_cache["at"] = time.time()
        _state_cache["data"] = payload
    return payload


def _build_state_uncached() -> dict:
    cfg = load_cfg()
    store = Store(DB)
    payload = report.collect_payload(store, cfg)
    # 归档概况：每条目标已存多少原文/图片，供卡片显示与内容库页签使用
    try:
        from .core import archive as _arc
        from .core import archive_query as _aq
        _conn = _arc.connect(DB)
        try:
            _st = _aq.stats(_conn)
        finally:
            _conn.close()
        payload["archive_stats"] = _st
        for c in payload.get("cards") or []:
            c["archive"] = _st.get(c["key"]) or {
                "total": 0, "alive": 0, "deleted": 0, "hidden": 0,
                "media": 0, "media_bytes": 0}
    except Exception:  # noqa: BLE001
        payload["archive_stats"] = {}

    payload["targets"] = [_target_public(t, i)
                          for i, t in enumerate(cfg.get("targets") or [])]
    payload["config"] = {
        "poll_interval_minutes": cfg.get("poll_interval_minutes", 60),
        "browser_headless": cfg.get("browser_headless", True),
    }
    # 通知配置状态（不含明文密钥），供页面「通知设置」面板直接渲染
    try:
        payload["notify"] = notify.status(cfg)
    except Exception:  # noqa: BLE001
        payload["notify"] = {"enabled": False, "channels": {}}
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

    def _send(self, code: int, body: bytes, ctype: str = "application/json; charset=utf-8",
              extra_headers: dict | None = None, cache_control: str = "no-store"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache_control)
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, obj, code: int = 200, extra_headers: dict | None = None):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"),
                   extra_headers=extra_headers)

    # ---- 错误载荷 ----
    def _err_payload(self, e: Exception) -> dict:
        """500 响应的内容。是否带 traceback 取决于部署形态：

        traceback 会把源码路径、函数名、行号甚至局部变量直接吐给调用方。
        挂到公网后，这些信息足够帮攻击者定位可利用的代码分支。

        所以判据是「鉴权是否启用」，不是「调用方是否已登录」：
          鉴权关闭（本机自用）→ 返回 traceback，调试最省事，也没有外人
          鉴权启用（已上公网）→ 只回一句话，全量写服务端日志

        即便自己人看，公网上也没必要把堆栈传出去 —— 日志里一样查得到。
        """
        log.error("接口异常 %s %s: %s", self.command, self.path, e, exc_info=True)
        if AUTH.enabled():
            return {"ok": False, "message": "服务端错误，详情见容器日志"}
        return {"ok": False, "message": f"{type(e).__name__}: {e}",
                "traceback": traceback.format_exc()[-1500:]}

    # ---- 鉴权 ----
    def _client_token(self) -> str:
        """从请求里取凭证：优先 Bearer，其次 Cookie。

        两者都支持是因为不同客户端有不同限制：
          * App / 脚本 → Authorization 头，干净且不受浏览器策略影响
          * 网页 → Cookie，因为 <img src> 发不出自定义头
        """
        h = self.headers.get("Authorization") or ""
        if h.startswith("Bearer "):
            return h[7:].strip()
        return auth.parse_cookies(self.headers.get("Cookie")).get(auth.COOKIE_NAME, "")

    def _auth_ok(self) -> bool:
        """鉴权是否通过。未配置 token 清单时一律放行（保持原有可用性）。"""
        if not AUTH.enabled():
            return True
        return AUTH.verify(self._client_token()) is not None

    def _need_auth(self):
        """需要在调用处直接 return 的守卫，返回 True 表示"已拒绝，别再往下走"。"""
        if self._auth_ok():
            return False
        self._json({"ok": False, "message": "未授权：请提供 Bearer Token 或登录"},
                   code=401, extra_headers={"WWW-Authenticate": 'Bearer realm="socialwatch"'})
        return True

    def _send_file(self, p: Path, ctype: str, max_age: int = 0):
        """发静态图片，带 ETag / Last-Modified / 304 / Range 支持。

        三个缓存头缺一不可：
          ETag          —— 浏览器回访时只发 If-None-Match，命中返 304 不重传
          Last-Modified —— 弱校验，给不支持 ETag 的客户端兜底
          max-age       —— 缩略图内容不变，可长缓存；原图被重下过要短缓存

        Range 对 iOS 尤其重要：Safari / WKWebView 加载大 JPEG 会发
        `Range: bytes=0-` 做渐进解码，不实现的话部分图片会显示成灰块。
        """
        try:
            st = p.stat()
        except OSError:
            self._send(404, b"not found", "text/plain; charset=utf-8")
            return

        etag = f'"{st.st_mtime_ns:x}-{st.st_size:x}"'
        last_mod = formatdate(st.st_mtime, usegmt=True)

        if self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.end_headers()
            return

        # Range 请求：只回请求的片段，回 206
        rng = self.headers.get("Range")
        start, end = 0, st.st_size - 1
        partial = False
        if rng and rng.startswith("bytes="):
            try:
                seg = rng.split("=", 1)[1].split(",")[0]
                a, _, b = seg.partition("-")
                if a:
                    start = int(a)
                    if b:
                        end = min(int(b), st.st_size - 1)
                elif b:                       # bytes=-500 取末尾 500 字节
                    start = max(0, st.st_size - int(b))
                partial = True
            except ValueError:
                start, end, partial = 0, st.st_size - 1, False
        if start > end or start >= st.st_size:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{st.st_size}")
            self.end_headers()
            return

        length = end - start + 1
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", etag)
        self.send_header("Last-Modified", last_mod)
        self.send_header("Cache-Control",
                         f"public, max-age={max_age}" if max_age
                         else "no-cache")
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{st.st_size}")
        self.end_headers()

        # 分块读写：一张 7MB 的原图整读进内存 × 并发数会顶爆容器
        try:
            with open(p, "rb") as f:
                f.seek(start)
                left = length
                while left > 0:
                    chunk = f.read(min(262144, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

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

            # 全部 /api/* 统一鉴权，只有下面白名单例外。
            # 集中拦截而不是逐路由加守卫：新增接口不会因为忘记加而裸奔。
            if path.startswith("/api/") and path not in _AUTH_EXEMPT:
                if self._need_auth():
                    return

            if path == "/api/auth/status":
                # 前端首屏调用：告诉它要不要弹登录框。
                # 这里不回传 token 清单明细，只回"是否启用"和"当前是否已通过"。
                self._json({
                    "ok": True,
                    "auth_enabled": AUTH.enabled(),
                    "authenticated": self._auth_ok(),
                })
                return

            if path == "/api/auth/tokens":
                if self._need_auth():
                    return
                self._json({"ok": True, "tokens": AUTH.public_list()})
                return

            if path == "/api/state":
                self._json(build_state())
                return

            # ---------------- 网易云歌单 / 播放 ----------------
            if path == "/api/music/playlists":
                from .core import music as _music
                cfg = load_cfg()
                store = Store(DB)
                self._json({"ok": True, "playlists": _music.playlists(store, cfg)})
                return

            if path == "/api/music/songs":
                from .core import music as _music
                pid = (q.get("playlist") or [""])[0]
                if not pid:
                    self._json({"ok": False, "message": "缺少 playlist"}, 400)
                    return
                cfg = load_cfg()
                store = Store(DB)
                songs = _music.songs(store, cfg, pid, target_key=(q.get("target") or [None])[0])
                self._json({"ok": True, "playlist": pid, "songs": songs})
                return

            if path == "/api/music/url":
                from .core import music as _music
                raw = (q.get("ids") or [""])[0]
                ids = [x for x in raw.split(",") if x.strip()]
                if not ids:
                    self._json({"ok": False, "message": "缺少 ids"}, 400)
                    return
                self._json({"ok": True, "urls": _music.play_urls(ids)})
                return

            if path == "/api/music/lyric":
                from .core import music as _music
                sid = (q.get("id") or [""])[0]
                if not sid:
                    self._json({"ok": False, "message": "缺少 id"}, 400)
                    return
                got = _music.lyric(sid)
                self._json({"ok": True, "id": sid,
                            "lines": got["lines"], "none": got["none"]})
                return

            if path == "/api/img":
                url = (q.get("url") or [""])[0]
                got = fetch_image(url)
                if not got:
                    self._send(404, b"not found", "text/plain; charset=utf-8")
                    return
                data, ctype = got
                # 头像/封面 URL 固定、内容极少变：用内容 hash 做 ETag，
                # 让 iOS URLSession 落磁盘缓存。重启 App 后带 If-None-Match
                # 回访，命中返 304 不重传（省流量也少打第三方图床）。
                etag = '"' + hashlib.sha1(data).hexdigest()[:20] + '"'
                if self.headers.get("If-None-Match") == etag:
                    self.send_response(304)
                    self.send_header("ETag", etag)
                    self.send_header("Cache-Control", "public, max-age=86400")
                    self.end_headers()
                    return
                self._send(200, data, ctype,
                           extra_headers={"ETag": etag},
                           cache_control="public, max-age=86400")
                return

            # ---------------- 内容归档 ----------------
            if path == "/api/archive/list":
                from .core import archive as arc
                from .core import archive_query as aq
                conn = arc.connect(DB)
                try:
                    res = aq.list_content(
                        conn,
                        target_key=(q.get("target") or [None])[0],
                        platform=(q.get("platform") or [None])[0],
                        state=(q.get("state") or [None])[0],
                        before_key=(q.get("cursor") or [None])[0],
                        limit=int((q.get("limit") or ["30"])[0]),
                    )
                    res["stats"] = aq.stats(conn)
                finally:
                    conn.close()
                self._json({"ok": True, **res})
                return

            if path == "/api/archive/item":
                from .core import archive as arc
                from .core import archive_query as aq
                cid = int((q.get("id") or ["0"])[0] or 0)
                conn = arc.connect(DB)
                try:
                    item = aq.get_content(conn, cid)
                finally:
                    conn.close()
                if not item:
                    self._json({"ok": False, "message": "不存在"}, 404)
                    return
                self._json({"ok": True, "item": item})
                return

            if path == "/api/archive/media":
                # 本地已归档的图：直接吐文件，不依赖第三方图床。
                #
                # thumb=2   → 200px 小图（~10KB），列表 56px 格子用
                # thumb=1   → 900px 预览图（~120KB），详情页图片格子用
                # thumb=0   → 原图（3–7MB），仅用户点开大图时才取
                #
                # 三档分开是因为体积差两个数量级：列表 30 条×3 张，用 900px 版
                # 要 9.4MB，用 200px 版只要 0.9MB。早先用微博 CDN 的 wap360
                # （360px 宽）在 1180px 宽的详情页里糊成马赛克，所以详情页必须
                # 用本地生成的 900px 预览图。
                cid = int((q.get("id") or ["0"])[0] or 0)
                seq = int((q.get("seq") or ["1"])[0] or 1)
                thumb_raw = (q.get("thumb") or ["0"])[0]
                from .core import archive as arc
                from .core import thumbs as th
                thumb_edge = {"1": th.THUMB_LONG_EDGE, "2": th.THUMB_LIST_EDGE}.get(thumb_raw)
                conn = arc.connect(DB)
                try:
                    row = conn.execute(
                        "SELECT local_path, remote_url, bytes FROM content_media "
                        "WHERE content_id=? AND seq=?", (cid, seq),
                    ).fetchone()
                finally:
                    conn.close()
                p = Path(row["local_path"]) if row and row["local_path"] else None
                if not p or not p.exists():
                    # 未归档成功时回落到远端原图地址（下轮巡检会补下来）
                    if row and row["remote_url"]:
                        got = fetch_image(row["remote_url"])
                        if got:
                            self._send(200, got[0], got[1])
                            return
                    self._send(404, b"not archived", "text/plain; charset=utf-8")
                    return

                if thumb_edge:
                    tp = th.ensure_thumb(config.archive_root(), p, thumb_edge)
                    if tp and tp.exists():
                        self._send_file(tp, "image/jpeg", max_age=86400)
                        return
                    # 生不出缩略图（GIF / SVG / 压失败）→ 直接给原图，别让格子空着

                ext = p.suffix.lower()
                ctype = {".png": "image/png", ".webp": "image/webp",
                         ".gif": "image/gif", ".heic": "image/heic"}.get(
                             ext, "image/jpeg")
                self._send_file(p, ctype, max_age=604800 if not thumb_edge else 0)
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

            if path == "/api/notify":
                self._json({"ok": True, **notify.status(load_cfg())})
                return

            if path == "/api/health":
                store = Store(DB)
                cfg = load_cfg()
                targets = [t for t in (cfg.get("targets") or []) if t.get("enabled")]
                # 未鉴权的健康检查只给最小信息：这个接口必须豁免鉴权（Docker
                # healthcheck 在容器内 curl，带不了 token），但不能因此泄漏
                # "有哪些监控目标、各平台登录态是否有效"这类情报。
                if not self._auth_ok():
                    self._json({"ok": True, "auth_required": AUTH.enabled()})
                    return
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
            self._json(self._err_payload(e), 500)

    # ---- POST ----
    def do_POST(self):  # noqa: N802
        u = urlparse(self.path)
        path = u.path
        body = self._body()
        try:
            # POST 也要统一鉴权，除登录/登出外。
            # 「登录」必须豁免，否则第一次进来无处可登。
            if path.startswith("/api/") and path not in _POST_AUTH_EXEMPT:
                if self._need_auth():
                    return

            if path == "/api/auth/login":
                # 用 token 换一枚 Cookie，供网页端长期使用。
                # App 端不走这条路：它直接保存 token 发 Authorization 头。
                tok = (body.get("token") or self._client_token() or "").strip()
                if not AUTH.enabled():
                    self._json({"ok": True, "message": "服务未启用鉴权"})
                    return
                if not AUTH.verify(tok):
                    self._json({"ok": False, "message": "Token 无效"}, 401)
                    return
                self._json({"ok": True}, extra_headers={
                    "Set-Cookie": auth.cookie_header(tok)})
                return

            if path == "/api/auth/logout":
                self._json({"ok": True}, extra_headers={
                    "Set-Cookie": auth.cookie_clear_header()})
                return

            if path == "/api/auth/tokens/issue":
                name = (body.get("name") or "").strip()
                note = (body.get("note") or "").strip()
                try:
                    tok = AUTH.issue(name, note)
                except ValueError as e:
                    self._json({"ok": False, "message": str(e)}, 400)
                    return
                # 明文只在这里出现一次，之后服务端只有哈希。
                # 前端必须提示用户立刻复制走。
                self._json({"ok": True, "name": name, "token": tok})
                return

            if path == "/api/auth/tokens/revoke":
                name = (body.get("name") or "").strip()
                ok = AUTH.revoke(name)
                self._json({"ok": ok,
                            "message": "已吊销" if ok else "没有这个 token"})
                return

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
            if path == "/api/notify/save":
                self._json(save_notify(body))
                return
            if path == "/api/notify/test":
                self._json(test_notify((body.get("channel") or "").strip() or None))
                return
            if path == "/api/notify/probe":
                self._json({"ok": True, **notify.probe(load_cfg())})
                return
            self._json({"ok": False, "message": "not found"}, 404)
        except Exception as e:  # noqa: BLE001
            self._json(self._err_payload(e), 500)

    # ---- PUT / DELETE ----
    # 这两个也必须过鉴权。早先只在 GET/POST 上加了集中拦截，
    # PUT/DELETE 漏在外面 —— 意味着公网上任何人 curl -X DELETE 就能删掉
    # 全部监控目标、curl -X PUT 就能改配置。集中拦截要覆盖所有方法，
    # 否则「新增接口不会漏」的设计前提不成立。
    def do_PUT(self):  # noqa: N802
        u = urlparse(self.path)
        m = u.path.rstrip("/").split("/")
        body = self._body()
        try:
            if self._need_auth():
                return
            if len(m) == 4 and m[1] == "api" and m[2] == "targets":
                self._json(update_target(int(m[3]), body))
                return
            self._json({"ok": False, "message": "not found"}, 404)
        except Exception as e:  # noqa: BLE001
            self._json(self._err_payload(e), 500)

    def do_DELETE(self):  # noqa: N802
        u = urlparse(self.path)
        m = u.path.rstrip("/").split("/")
        try:
            if self._need_auth():
                return
            if len(m) == 4 and m[1] == "api" and m[2] == "targets":
                self._json(delete_target(int(m[3])))
                return
            self._json({"ok": False, "message": "not found"}, 404)
        except Exception as e:  # noqa: BLE001
            self._json(self._err_payload(e), 500)


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
