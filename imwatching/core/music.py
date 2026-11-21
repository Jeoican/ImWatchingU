"""网易云歌单读取 + 播放地址解析，供 App 内嵌播放器使用。

设计要点：
  * 歌单列表、歌曲元数据全部从本地采集快照读取 —— 不打上游、零延迟，
    也不把 1033 首的歌曲表塞进 /api/state（那儿刻意不返回 songs）。
  * 只有「点开某首歌要播放」时才实时打网易云 weapi 换临时地址：
    该地址带时效签名（URL 里的时间戳 + authSecret），必须现用现取，不能缓存。
  * 音频 CDN 给的是 http://，这里统一升级成 https://，
    这样 iOS ATS 无需放行明文域名，App 里 AVPlayer 可直接播。
"""
from __future__ import annotations

import json
import time
import urllib.parse
import urllib.request

from .. import config
from ..platforms.netease_social import _weapi

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")

# cookie 缓存：读一次磁盘即可，避免每首歌都解析 state.json
_cookie_cache: tuple[float, str, str] = (0.0, "", "")
_COOKIE_TTL = 30.0


def _login_cookie() -> tuple[str, str]:
    """返回 (完整 Cookie 头, csrf token)。登录态来自浏览器 storage state。"""
    global _cookie_cache
    now = time.time()
    if now - _cookie_cache[0] < _COOKIE_TTL and _cookie_cache[1]:
        return _cookie_cache[1], _cookie_cache[2]
    try:
        with open(config.STATE_FILE, encoding="utf-8") as f:
            state = json.load(f)
        seen: dict[str, str] = {}
        for c in state.get("cookies", []):
            dom = c.get("domain", "")
            if "music.163.com" in dom or dom == "163.com":
                seen[c["name"]] = c["value"]
        cookie = "; ".join(f"{k}={v}" for k, v in seen.items())
        csrf = seen.get("__csrf", "")
        _cookie_cache = (now, cookie, csrf)
        return cookie, csrf
    except Exception:  # noqa: BLE001
        return "", ""


def _https(url: str | None) -> str | None:
    if not url:
        return None
    return "https://" + url[len("http://"):] if url.startswith("http://") else url


def playlists(store, cfg: dict) -> list[dict]:
    """所有网易云目标下的歌单。数据取自 __playlist_set__ 与各歌单 tracks 快照。"""
    out: list[dict] = []
    for t in (cfg.get("targets") or []):
        if t.get("platform") != "netease":
            continue
        key = f"netease:{t['id']}"
        set_snap = store.last_snapshot(key, "__playlist_set__", "count")
        if not set_snap:
            continue
        detail = set_snap.get("detail") or {}
        names = detail.get("names") or {}
        target_name = t.get("name") or t["id"]
        for pid in detail.get("ids") or []:
            snap = store.last_snapshot(key, pid, "tracks")
            sd = (snap or {}).get("detail") or {}
            out.append({
                "target_key": key,
                "target_name": target_name,
                "id": pid,
                "name": names.get(pid) or sd.get("name") or pid,
                "cover": _https(sd.get("cover")),
                "track_count": (snap or {}).get("value", 0) or 0,
            })
    # 歌单多的排前面，和 web 端展示顺序一致
    out.sort(key=lambda x: -x["track_count"])
    return out


def songs(store, cfg: dict, playlist_id: str, target_key: str | None = None) -> list[dict]:
    """某歌单的完整歌曲列表（本地快照，name/artists/album）。"""
    found: dict | None = None
    for t in (cfg.get("targets") or []):
        if t.get("platform") != "netease":
            continue
        key = f"netease:{t['id']}"
        if target_key and key != target_key:
            continue
        snap = store.last_snapshot(key, playlist_id, "tracks")
        if snap and (snap.get("detail") or {}).get("track_ids"):
            found = snap
            break
    if not found:
        return []
    detail = found["detail"]
    meta = detail.get("songs") or {}
    result = []
    for sid in detail.get("track_ids") or []:
        m = meta.get(sid) or {}
        name = m.get("name")
        if not name or name.startswith("歌曲(id "):
            # 采集时未登录拿不到元数据的占位项：保留 id，前端显示为「未知歌曲」
            name = None
        result.append({
            "id": sid,
            "name": name,
            "artists": m.get("artists"),
            "album": m.get("album"),
        })
    return result


def play_urls(ids: list[str]) -> dict[str, dict]:
    """批量换取临时播放地址。

    返回 {song_id: {"url": https地址或None, "br": 码率, "code": 业务码}}。
    URL 带时效签名，调用方拿去应立即播放，不要长期缓存。
    """
    if not ids:
        return {}
    clean = [str(i) for i in ids if str(i).isdigit()][:100]
    if not clean:
        return {}
    cookie, csrf = _login_cookie()
    if not cookie:
        return {i: {"url": None, "br": 0, "code": 401, "message": "无网易云登录态"} for i in clean}

    out: dict[str, dict] = {}
    # 分批，避免单请求过大
    for start in range(0, len(clean), 30):
        chunk = clean[start:start + 30]
        data = {
            "ids": "[" + ",".join(chunk) + "]",
            "level": "standard",
            "encodeType": "aac",
            "csrf_token": csrf,
        }
        body = urllib.parse.urlencode(_weapi(data)).encode()
        req = urllib.request.Request(
            "https://music.163.com/weapi/song/enhance/player/url/v1",
            data=body,
            headers={
                "User-Agent": UA,
                "Referer": "https://music.163.com/",
                "Content-Type": "application/x-www-form-urlencoded",
                "Cookie": cookie,
                "Accept-Encoding": "identity",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                j = json.loads(r.read().decode("utf-8", "replace"))
            for s in j.get("data") or []:
                sid = str(s.get("id"))
                out[sid] = {
                    "url": _https(s.get("url")),
                    "br": s.get("br") or 0,
                    "code": s.get("code"),
                }
        except Exception as e:  # noqa: BLE001
            for sid in chunk:
                out.setdefault(sid, {"url": None, "br": 0, "code": 0, "message": str(e)[:120]})
        for sid in chunk:
            out.setdefault(sid, {"url": None, "br": 0, "code": 404})
    return out
