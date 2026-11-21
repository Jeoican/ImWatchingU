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
import re
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
    """某歌单的完整歌曲列表（本地快照，name/artists/album/duration/cover）。

    时长与封面为什么要单独补
    ------------------------
    老快照里 songs 只有 name/artists/album —— 采集器当时没存 dt 与 picUrl。
    而 iOS 端要显示「3:47」和专辑图，缺了就只能是干巴巴一行文字。
    策略是：快照里有就直接用（零成本）；缺的批量回打一次 /api/v3/song/detail
    补齐，并顺手写回快照 —— 补一次就永久解决，不会每次都打上游。
    """
    found: dict | None = None
    found_key = ""
    for t in (cfg.get("targets") or []):
        if t.get("platform") != "netease":
            continue
        key = f"netease:{t['id']}"
        if target_key and key != target_key:
            continue
        snap = store.last_snapshot(key, playlist_id, "tracks")
        if snap and (snap.get("detail") or {}).get("track_ids"):
            found = snap
            found_key = key
            break
    if not found:
        return []
    detail = found["detail"]
    meta = detail.get("songs") or {}
    raw_ids = detail.get("track_ids") or []

    # 找出元数据缺失的歌曲，一次性批量补齐
    missing = [sid for sid in raw_ids
               if not (meta.get(sid) or {}).get("cover")
               or not (meta.get(sid) or {}).get("duration")]
    patched: dict[str, dict] = {}
    if missing:
        try:
            from ..platforms.netease import song_details
            # song_details 一次最多吃 50 个，分批
            for start in range(0, len(missing), 50):
                chunk = missing[start:start + 50]
                got = song_details([str(c) for c in chunk])
                for sid, m in got.items():
                    if m.get("name") and not str(m["name"]).startswith("歌曲(id "):
                        patched[sid] = m
        except Exception:  # noqa: BLE001
            # 上游不可达不影响列表可用性：宁可不显示封面，也不要整页报错
            patched = {}

    result = []
    for sid in raw_ids:
        m = dict(meta.get(sid) or {})
        p = patched.get(sid) or {}
        for f in ("name", "artists", "album", "duration", "cover"):
            if not m.get(f) and p.get(f):
                m[f] = p[f]
        name = m.get("name")
        if not name or name.startswith("歌曲(id "):
            # 采集时未登录拿不到元数据的占位项：保留 id，前端显示为「未知歌曲」
            name = None
        dur = m.get("duration") or 0
        result.append({
            "id": sid,
            "name": name,
            "artists": m.get("artists"),
            "album": m.get("album"),
            # 毫秒 → 秒，前端按秒做格式化，语义更直观
            "duration": int(round(int(dur) / 1000)) if dur else None,
            "cover": m.get("cover") or None,
        })

    # 把补齐到的元数据写回快照，下次直接命中，不再打上游。
    # 失败就跳过 —— 这是纯优化，不能因为它让整个请求失败。
    if patched and found_key:
        try:
            merged = dict(meta)
            for sid, p in patched.items():
                old = dict(merged.get(sid) or {})
                for f in ("name", "artists", "album", "duration", "cover"):
                    if not old.get(f) and p.get(f):
                        old[f] = p[f]
                merged[sid] = old
            new_detail = dict(detail)
            new_detail["songs"] = merged
            store.add_snapshot(found_key, "netease", playlist_id, "tracks",
                               found.get("value") or 0, new_detail)
        except Exception:  # noqa: BLE001
            pass
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


# ---------------- 歌词 ----------------

# LRC 行格式：[mm:ss.xxx]文本，一行可能挂多个时间戳（副歌复用同一句时网易云会这么写）
_LRC_TAG = re.compile(r"\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\]")
# 这些是纯元信息，不是要跟着唱的词，滚动列表里显示出来会打断节奏
_LRC_META = ("作词", "作曲", "编曲", "制作人", "吉他", "贝斯", "鼓", "混音",
             "母带", "和声", "录音", "监制", "出品", "发行", "统筹", "OP", "SP")

# 制作人员行有两种写法，都要滤掉：
#   顶部   "[00:00.00] 作词 : 陶喆"        —— 以角色名开头
#   尾部   "[04:38.20] 电吉他 : Bruce Watson" ——「乐器/角色 + 冒号 + 人名」
# 后者开头不是常见角色词，靠「A : B」这个形态判定更稳。
# 正常歌词极少出现「空格冒号空格」，误伤风险很低。
_LRC_CREDIT = re.compile(r"^[\w\u4e00-\u9fa5\.&/\-]{1,12}\s*[:：]\s*[\w\u4e00-\u9fa5\.&/\- ]{1,40}$")

_lyric_cache: dict[str, tuple[float, list[dict]]] = {}
_LYRIC_TTL = 3600.0


def _is_credit(text: str) -> bool:
    if any(text.startswith(k) for k in _LRC_META):
        return True
    return bool(_LRC_CREDIT.match(text))


def _parse_lrc(raw: str) -> list[dict]:
    """LRC → [{t: 秒, text: 文本}]，按时间升序。

    LRC 是最省事的格式：每行自带起始时间，播放器只要「找最后一个 t <= 当前进度」
    即可定位到当前行，滚动的稳定性和精度都比逐字 KRC 好处理，
    而网易云给的 lrc.lyric 正是它。
    """
    lines: list[dict] = []
    for line in (raw or "").splitlines():
        tags = _LRC_TAG.findall(line)
        if not tags:
            continue
        text = _LRC_TAG.sub("", line).strip()
        # 空行保留为间隔（滚动时视觉上分段），但过滤元信息行
        if text and _is_credit(text):
            continue
        for mm, ss, ms in tags:
            frac = (ms or "0")
            # .5 表示 5/10 秒，.50 表示 50/100，.500 表示 500/1000 —— 按位数算权重
            sec = int(mm) * 60 + int(ss) + (int(frac) / (10 ** len(frac)) if frac else 0)
            lines.append({"t": round(sec, 2), "text": text})
    lines.sort(key=lambda x: x["t"])
    return lines


def lyric(song_id: str) -> dict:
    """取一首歌的逐行歌词。

    返回 {"lines": [{t, text, tr}], "none": bool}。
    没有歌词是常态（纯音乐、下架曲），这时返回空列表而不是报错 ——
    前端据此把歌词区换成「暂无歌词」，而不是整页失败。
    """
    sid = str(song_id)
    now = time.time()
    hit = _lyric_cache.get(sid)
    if hit and now - hit[0] < _LYRIC_TTL:
        return {"lines": hit[1], "none": not hit[1]}

    url = ("https://music.163.com/api/song/lyric"
           f"?id={urllib.parse.quote(sid)}&lv=-1&kv=-1&tv=-1")
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Referer": "https://music.163.com/",
        "Accept-Encoding": "identity",
    })
    cookie, _ = _login_cookie()
    if cookie:
        req.add_header("Cookie", cookie)

    lines: list[dict] = []
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            j = json.loads(r.read().decode("utf-8", "replace"))
        lrc = (j.get("lrc") or {}).get("lyric") or ""
        # 翻译是可选的：有就跟原文按时间对齐贴上去，没有就留空
        tr_map: dict[float, str] = {}
        tr_raw = (j.get("tlyric") or {}).get("lyric") or ""
        for row in _parse_lrc(tr_raw):
            tr_map.setdefault(row["t"], row["text"])
        for row in _parse_lrc(lrc):
            lines.append({
                "t": row["t"],
                "text": row["text"],
                "tr": tr_map.get(row["t"]),
            })
    except Exception:  # noqa: BLE001
        lines = []

    _lyric_cache[sid] = (now, lines)
    return {"lines": lines, "none": not lines}
