"""变更通知：把一轮巡检的事件汇总后推送到微信（Server酱）和 iPhone（Bark）。

设计原则：
1. 密钥优先从环境变量读，也允许存进 data/notify.json（已 gitignore，
   便于在网页设置面板里填写，不用改 compose）；两者都不进 config.yaml、日志；
2. 通知失败不能影响巡检本身，所有异常都在这里吞掉并返回状态；
3. 一轮巡检只发一条汇总消息，避免粉丝列表大批量变动时刷屏。

Bark 有两种送法：
  * 直连 Bark 服务（默认）：POST {bark_server}/push，需要容器能访问 api.day.app；
  * 经 Server酱 中转（bark_via_serverchan: true）：往 sctapi 发 channel=8，
    由 Server酱 服务端转发到你绑定的 Bark DeviceToken。容器访问不了
    api.day.app 时（常见于出口网络/代理拦截 TLS 握手）用这个，不额外消耗额度，
    还能和微信合并成一次请求。

环境变量：
  SW_NOTIFY_SERVERCHAN_KEY   Server酱 Turbo 的 SCT SendKey（推微信）
  SW_NOTIFY_BARK_KEY         Bark 的 device key（推 iPhone）
  SW_NOTIFY_BARK_SERVER      自建 Bark 服务地址，默认 https://api.day.app
  SW_NOTIFY_PROXY            访问推送服务用的 HTTP 代理，如 http://host.docker.internal:7890
  SW_DASHBOARD_URL           看板公网地址，可选，消息末尾附链接
  SW_NOTIFY_SECRETS          密钥文件路径，默认 data/notify.json
"""
from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import OrderedDict
from pathlib import Path
from typing import Any

from . import config as _config

SERVERCHAN_KEY_ENV = "SW_NOTIFY_SERVERCHAN_KEY"
BARK_KEY_ENV = "SW_NOTIFY_BARK_KEY"
BARK_SERVER_ENV = "SW_NOTIFY_BARK_SERVER"
PROXY_ENV = "SW_NOTIFY_PROXY"
DASHBOARD_URL_ENV = "SW_DASHBOARD_URL"
SECRETS_ENV = "SW_NOTIFY_SECRETS"

_CHANNELS = ("serverchan", "bark")
_USER_AGENT = "SocialWatch/1.0"

# Server酱 channel 参数取值：方糖服务号=9，Bark iOS=8。
# 详见 sct.ftqq.com 控制台「消息通道」页面。
_SC_CHANNEL_CODE = {"serverchan": 9, "bark": 8}


# ---------------------------------------------------------------- 密钥存储
def secrets_path() -> Path:
    """密钥文件位置：默认 data/notify.json（已 gitignore，不会进仓库）。"""
    custom = os.environ.get(SECRETS_ENV, "").strip()
    return Path(custom) if custom else _config.DATA / "notify.json"


def load_secrets() -> dict:
    """读取本地密钥文件；不存在或损坏都当作空配置。"""
    p = secrets_path()
    try:
        with open(p, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (FileNotFoundError, ValueError, OSError):
        return {}


def save_secrets(data: dict) -> None:
    """写入密钥文件。这里必然含明文密钥，所以只落在 data/ 下且权限收紧。"""
    p = secrets_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    tmp.replace(p)


def _key(name: str) -> str:
    """取密钥：环境变量优先，其次本地文件。"""
    env = os.environ.get(name, "").strip()
    if env:
        return env
    field = {SERVERCHAN_KEY_ENV: "serverchan_key",
             BARK_KEY_ENV: "bark_key",
             BARK_SERVER_ENV: "bark_server"}.get(name)
    if not field:
        return ""
    return str(load_secrets().get(field) or "").strip()


def _proxy() -> str:
    """访问推送服务的 HTTP 代理，空字符串表示直连。

    容器常见场景：宿主机上有 Clash 之类的代理，但容器自己直连某些域名
    会被掐掉 TLS 握手。这时把代理地址填成 http://host.docker.internal:端口 即可。
    """
    env = os.environ.get(PROXY_ENV, "").strip()
    if env:
        return env
    return str(load_secrets().get("proxy") or "").strip()


def bark_via_serverchan() -> bool:
    """Bark 是否走 Server酱 中转（容器访问不了 api.day.app 时的首选）。"""
    return bool(load_secrets().get("bark_via_serverchan"))


def _bark_server() -> str:
    return (_key(BARK_SERVER_ENV)
            or os.environ.get(BARK_SERVER_ENV, "").strip()
            or "https://api.day.app")


def mask(key: str) -> str:
    """给前端看用的脱敏展示：只留首尾几个字符。"""
    key = (key or "").strip()
    if not key:
        return ""
    if len(key) <= 8:
        return key[:2] + "…"
    return f"{key[:5]}…{key[-3:]}"


def status(cfg: dict | None) -> dict:
    """通知配置的公开状态（绝不含完整密钥）。"""
    nc = _notify_cfg(cfg)
    sc_key = _key(SERVERCHAN_KEY_ENV)
    bk_key = _key(BARK_KEY_ENV)
    via_sc = bark_via_serverchan()
    return {
        "enabled": bool(nc.get("enabled", False)),
        "channels": {c: bool((nc.get("channels") or {}).get(c)) for c in _CHANNELS},
        "serverchan": {
            "key_set": bool(sc_key),
            "key_mask": mask(sc_key),
            "from_env": bool(os.environ.get(SERVERCHAN_KEY_ENV, "").strip()),
        },
        "bark": {
            "key_set": bool(bk_key),
            "key_mask": mask(bk_key),
            "server": _bark_server(),
            "server_from_env": bool(os.environ.get(BARK_SERVER_ENV, "").strip()),
            "from_env": bool(os.environ.get(BARK_KEY_ENV, "").strip()),
            "via_serverchan": via_sc,
            # 走 Server酱 中转需要 SendKey + 在控制台绑过 Bark DeviceToken
            "ready": bool(bk_key and (sc_key or not via_sc)),
        },
        "proxy": _proxy(),
        "proxy_from_env": bool(os.environ.get(PROXY_ENV, "").strip()),
        "dashboard_url": _dashboard_url(cfg),
        "max_names_per_group": _max_names(cfg),
    }


# ---------------------------------------------------------------- 配置
def _notify_cfg(cfg: dict | None) -> dict:
    return ((cfg or {}).get("notify") or {})


def enabled_channels(cfg: dict | None) -> list[str]:
    """返回本轮要发送的通道列表。配置关闭时返回空列表。"""
    nc = _notify_cfg(cfg)
    if not nc.get("enabled", False):
        return []
    channels = nc.get("channels") or {}
    if isinstance(channels, (list, tuple, set)):
        return [c for c in _CHANNELS if c in channels]
    if isinstance(channels, dict):
        return [c for c in _CHANNELS if channels.get(c, False)]
    return []


def _dashboard_url(cfg: dict | None) -> str:
    return (os.environ.get(DASHBOARD_URL_ENV, "").strip()
            or str(_notify_cfg(cfg).get("dashboard_url") or "").strip())


def _max_names(cfg: dict | None) -> int:
    try:
        return max(1, int(_notify_cfg(cfg).get("max_names_per_group", 10)))
    except (TypeError, ValueError):
        return 10


# ---------------------------------------------------------------- 消息格式化
def _describe(event: dict) -> tuple[str, str, str]:
    """把一个事件拆成 (分组键, 前缀, 名称)，便于同类事件合并成一行。"""
    et = event.get("event_type") or "event"
    name = str(event.get("item_name") or event.get("item_id") or "").strip()
    extra = event.get("item_extra") or {}

    if et in ("count_up", "count_down"):
        label = event.get("item_name") or "数值"
        before, after = extra.get("before"), extra.get("after")
        delta = event.get("delta")
        if delta is None and before is not None and after is not None:
            try:
                delta = int(after) - int(before)
            except (TypeError, ValueError):
                delta = None
        arrow = "↑" if et == "count_up" else "↓"
        if delta is None:
            detail = f"{label} {arrow}"
        else:
            detail = f"{label} {arrow} {abs(int(delta))}"
            if before is not None and after is not None:
                detail += f"（{before}→{after}）"
        return (f"{et}:{event.get('item_id')}", detail, "")

    if et in ("track_added", "track_removed"):
        scope = event.get("scope_name") or event.get("scope") or "歌单"
        verb = "新增" if et == "track_added" else "移除"
        return (f"{et}:{event.get('scope')}", f"歌单《{scope}》{verb}歌曲：", name)

    if et in ("playlist_added", "playlist_removed"):
        verb = "新增" if et == "playlist_added" else "移除"
        return (et, f"{verb}歌单：", name)

    if et == "person_fan_added":
        return (et, "新增粉丝：", name)
    if et == "person_fan_removed":
        return (et, "粉丝取关：", name)
    if et == "person_follow_added":
        return (et, "TA 新关注：", name)
    if et == "person_follow_removed":
        return (et, "TA 取消关注：", name)

    labels = {"count_up": "数值增加", "count_down": "数值减少"}
    return (et, f"{labels.get(et, et)}：", name)


def build_message(cfg: dict | None, results: list[dict], total: int | None = None) -> tuple[str, str]:
    """把巡检结果渲染成 (title, desp)，desp 为 Server酱 支持的 Markdown。"""
    if total is None:
        total = sum(len(r.get("events") or []) for r in (results or []))

    groups: OrderedDict[str, OrderedDict[str, dict]] = OrderedDict()
    for result in results or []:
        target = (result.get("target")
                  or f"{result.get('platform')}:{result.get('id')}")
        buckets = groups.setdefault(target, OrderedDict())
        for event in result.get("events") or []:
            key, prefix, name = _describe(event)
            bucket = buckets.setdefault(key, {"prefix": prefix, "names": [], "count": 0})
            bucket["count"] += 1
            if name:
                bucket["names"].append(name)

    now = time.strftime("%m-%d %H:%M")
    title = f"SocialWatch：{total} 项变更（{now}）"
    lines = [f"## SocialWatch 变更 · {now}", "", f"共 **{total}** 项变更。", ""]

    limit = _max_names(cfg)
    for target, buckets in groups.items():
        lines.append(f"### {target}")
        for bucket in buckets.values():
            prefix = bucket["prefix"]
            names = bucket["names"]
            if names:
                shown = names[:limit]
                text = "、".join(shown)
                if bucket["count"] > len(shown):
                    text += f" 等 {bucket['count']} 项"
                lines.append(f"- {prefix}{text}")
            else:
                # 数值型事件没有名字，前缀本身已经是完整描述
                lines.append(f"- {prefix.rstrip('：')}")
        lines.append("")

    url = _dashboard_url(cfg)
    if url:
        lines.extend(["---", f"[打开看板]({url})"])
    return title, "\n".join(lines).strip()


def _plain(markdown: str) -> str:
    """Bark 不渲染 Markdown，转成便于通知中心阅读的纯文本。"""
    text = re.sub(r"^#{1,6}\s*", "", markdown, flags=re.MULTILINE)
    text = text.replace("**", "")
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1：\2", text)
    text = re.sub(r"^---\s*$", "", text, flags=re.MULTILINE)
    return text.strip()[:4000]


# ---------------------------------------------------------------- 通道实现
def _serverchan_endpoint(key: str) -> str:
    if key.startswith("SCT"):
        return f"https://sctapi.ftqq.com/{key}.send"
    # Server酱³ 的 key 形如 sctp123txxxx，推送到独立 App，不是微信服务号
    match = re.match(r"^sctp(\d+)t", key)
    if match:
        return f"https://{match.group(1)}.push.ft07.com/send/{key}.send"
    raise ValueError("SendKey 格式不对：微信推送需要 SCT 开头的 Server酱 Turbo key")


def _opener() -> urllib.request.OpenerDirector | None:
    """按代理配置构造 opener；未配置代理时返回 None（用默认 opener）。"""
    proxy = _proxy()
    if not proxy:
        return None
    handler = urllib.request.ProxyHandler({"http": proxy, "https": proxy})
    return urllib.request.build_opener(handler)


def _friendly_error(exc: Exception, url: str) -> str:
    """把底层网络异常翻译成能照着做的提示，避免只丢一串 OpenSSL 术语。"""
    text = f"{type(exc).__name__}: {exc}"
    if isinstance(exc, urllib.error.URLError) and "CERTIFICATE_VERIFY_FAILED" in str(exc):
        return f"{text}（证书校验失败：检查容器时间是否准确）"
    if "UNEXPECTED_EOF_WHILE_READING" in text or "SSL_ERROR_SYSCALL" in text:
        host = urllib.parse.urlparse(url).netloc
        return (f"{text}（到 {host} 的 TLS 握手被中途断开，通常是容器出口网络/代理拦截。"
                f"可改用「Bark 经 Server酱 中转」，或给通知设置 SW_NOTIFY_PROXY 代理）")
    if isinstance(exc, urllib.error.URLError) and isinstance(exc.reason, TimeoutError):
        return f"{text}（连接超时：检查容器能否直连 {urllib.parse.urlparse(url).netloc}）"
    return text


def _post(url: str, data: bytes, content_type: str) -> str:
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": content_type, "User-Agent": _USER_AGENT,
                 "Connection": "close"},
        method="POST",
    )
    try:
        opener = _opener()
        resp = (opener.open(req, timeout=12) if opener
                else urllib.request.urlopen(req, timeout=12))
        with resp:
            return resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")[:300]
        raise RuntimeError(f"HTTP {exc.code}: {body}") from exc


def send_serverchan(title: str, desp: str, key: str,
                    channels: list[str] | None = None) -> None:
    """Server酱 Turbo：title 一行标题，desp 支持 Markdown。成功返回 code=0。

    channels 指定本次投递的通道（serverchan / bark），留空则用控制台默认通道。
    最多两个通道，Server酱 会按 channel=9|8 的形式一次投递。
    """
    url = _serverchan_endpoint(key)
    form = {"title": title, "desp": desp}
    if channels:
        codes = [_SC_CHANNEL_CODE[c] for c in channels if c in _SC_CHANNEL_CODE]
        if codes:
            form["channel"] = "|".join(str(c) for c in codes[:2])
    payload = urllib.parse.urlencode(form).encode("utf-8")
    raw = _post(url, payload, "application/x-www-form-urlencoded")
    try:
        result = json.loads(raw)
    except (ValueError, TypeError):
        return  # HTTP 200 且非 JSON，按成功处理
    if result.get("code") not in (0, None):
        raise RuntimeError(f"Server酱返回 code={result.get('code')}: "
                           f"{str(result.get('message') or '')[:200]}")


def send_bark(title: str, body: str, key: str, server: str | None = None) -> None:
    """Bark：直连 POST /push，device_key 放请求体。成功返回 code=200。"""
    base = (server or _bark_server()).strip().rstrip("/")
    if not base.startswith(("http://", "https://")):
        raise ValueError("Bark 服务地址必须以 http:// 或 https:// 开头")
    payload = json.dumps(
        {"device_key": key, "title": title, "body": body, "group": "SocialWatch"},
        ensure_ascii=False,
    ).encode("utf-8")
    raw = _post(f"{base}/push", payload, "application/json; charset=utf-8")
    try:
        result = json.loads(raw)
    except (ValueError, TypeError):
        return
    if result.get("code") not in (200, None):
        raise RuntimeError(f"Bark 返回 code={result.get('code')}: "
                           f"{str(result.get('message') or '')[:200]}")


# ---------------------------------------------------------------- 统一入口
def _deliver(channel: str, title: str, desp: str) -> dict[str, Any]:
    """给单个通道投递。返回 {ok/...}，绝不抛异常。

    Bark 有两种送法：
      * 直连 api.day.app（或自建服务）；
      * 经 Server酱 的 Bark 通道（channel=8）中转，适合容器连不上 Bark 域名时。
    """
    env_name = SERVERCHAN_KEY_ENV if channel == "serverchan" else BARK_KEY_ENV
    key = _key(env_name)
    if not key:
        return {"ok": False, "skipped": True, "reason": "未配置密钥"}
    try:
        if channel == "serverchan":
            send_serverchan(title, desp, key)
            return {"ok": True}
        if bark_via_serverchan():
            sc_key = _key(SERVERCHAN_KEY_ENV)
            if not sc_key:
                return {"ok": False, "skipped": True,
                        "reason": "Bark 走 Server酱 中转需要同时配置 SendKey"}
            # 只投 Bark 通道，避免和微信通道重复发送
            send_serverchan(title, desp, sc_key, channels=["bark"])
            return {"ok": True, "via": "serverchan"}
        send_bark(title, _plain(desp), key)
        return {"ok": True, "via": "direct"}
    except Exception as exc:  # noqa: BLE001
        # 密钥和完整响应都不能进日志，只留错误摘要
        url = (f"https://sctapi.ftqq.com/…"
               if channel == "serverchan" or bark_via_serverchan()
               else f"{_bark_server()}/push")
        return {"ok": False, "error": _friendly_error(exc, url)[:320]}


def _send_all(cfg: dict | None, title: str, desp: str, only: str | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {"channels": {}}
    targets = [c for c in enabled_channels(cfg) if not only or c == only]
    # 微信 + Bark 走同一套 Server酱 凭据又都开中转时，合成一次请求更省额度
    if (not only and set(targets) == {"serverchan", "bark"}
            and _key(SERVERCHAN_KEY_ENV) and bark_via_serverchan()):
        try:
            send_serverchan(title, desp, _key(SERVERCHAN_KEY_ENV),
                            channels=["serverchan", "bark"])
            out["channels"]["serverchan"] = {"ok": True, "via": "serverchan|bark"}
            out["channels"]["bark"] = {"ok": True, "via": "serverchan|bark"}
            return out
        except Exception as exc:  # noqa: BLE001
            err = _friendly_error(exc, "https://sctapi.ftqq.com/…")[:320]
            out["channels"]["serverchan"] = {"ok": False, "error": err}
            out["channels"]["bark"] = {"ok": False, "error": err}
            return out
    for channel in targets:
        out["channels"][channel] = _deliver(channel, title, desp)
    return out


def dispatch(cfg: dict | None, results: list[dict]) -> dict[str, Any]:
    """一轮巡检结束后调用：没有变更就跳过，失败只返回状态不抛异常。"""
    try:
        results = results or []
        total = sum(len(r.get("events") or []) for r in results)
        if total == 0:
            return {"sent": False, "reason": "no_events", "channels": {}}
        title, desp = build_message(cfg, results, total)
        out = _send_all(cfg, title, desp)
        out["sent"] = any(s.get("ok") for s in out["channels"].values())
        return out
    except Exception as exc:  # noqa: BLE001
        return {"sent": False, "error": f"{type(exc).__name__}: {str(exc)[:300]}",
                "channels": {}}


def send_test(cfg: dict | None, only: str | None = None) -> dict[str, Any]:
    """发送一条测试消息，用来验证 SendKey / Bark key 是否配置正确。

    only 指定时只测那一个通道（前端「测试」按钮按通道分开点）。
    """
    title = "SocialWatch 通知测试"
    desp = ("## SocialWatch 通知测试\n\n"
            "如果你看到这条消息，说明当前通道已经配置成功。\n\n"
            "之后账号数据发生变化时，会把每轮巡检的变更汇总推送到这里。")
    try:
        if only:
            # 单通道测试时，即使该通道在配置里被关掉也要能测
            return _send_one(cfg, only, title, desp)
        return _send_all(cfg, title, desp)
    except Exception as exc:  # noqa: BLE001
        return {"channels": {}, "error": f"{type(exc).__name__}: {str(exc)[:300]}"}


def _send_one(cfg: dict | None, channel: str, title: str, desp: str) -> dict[str, Any]:
    """无视 config 里的开关，强制给指定通道发一条（用于设置面板的测试按钮）。"""
    if channel not in _CHANNELS:
        raise ValueError(f"未知通道：{channel}")
    return {"channels": {channel: _deliver(channel, title, desp)}}


def probe(cfg: dict | None = None) -> dict[str, Any]:
    """连通性自检：分别探测 Server酱 与 Bark，用于解释「为什么测试失败」。

    走和真实发送完全相同的请求路径（同一个 opener、同一个代理），只是发的是
    无需鉴权的只读请求（`/ping`、首页），因此不消耗推送额度、不会打扰手机。
    """
    proxy = _proxy()

    def check(url: str) -> dict[str, Any]:
        req = urllib.request.Request(
            url, headers={"User-Agent": _USER_AGENT, "Connection": "close"}, method="GET")
        try:
            opener = _opener()
            resp = (opener.open(req, timeout=10) if opener
                    else urllib.request.urlopen(req, timeout=10))
            with resp:
                body = resp.read(200).decode("utf-8", "replace")
            return {"ok": True, "status": resp.status, "sample": body[:80]}
        except urllib.error.HTTPError as exc:
            # 能收到 HTTP 响应就说明网络可达，403/404 之类不算不通
            return {"ok": True, "status": exc.code}
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "error": _friendly_error(exc, url)[:240]}

    base = _bark_server().strip().rstrip("/")
    bark_host = urllib.parse.urlparse(base).netloc or "api.day.app"
    return {
        "serverchan": {"host": "sctapi.ftqq.com",
                       **check("https://sctapi.ftqq.com/")},
        "bark": {"host": bark_host, "via_serverchan": bark_via_serverchan(),
                 **check(f"{base}/ping")},
        "proxy": proxy,
    }
