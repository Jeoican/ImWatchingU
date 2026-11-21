"""网易云音乐采集器 —— 无需登录，走公开 web api。

核心事实（已实测）：
  * /api/user/playlist?uid=  可列出该用户全部歌单（含"我喜欢的音乐"）
  * /api/v6/playlist/detail?id=  返回完整 trackIds（tracks 字段只给 10 首，不可靠）
  * /api/v3/song/detail (POST c=[...])  批量换歌曲名/歌手/专辑
    未登录时部分歌曲可能拿不到元数据，此时退回 trackIds 只比 id 差异。
"""
from __future__ import annotations

import json
import re
import time
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")
HEADERS = {"User-Agent": UA, "Referer": "https://music.163.com/", "Accept": "*/*"}


def _get(url: str, retries: int = 3) -> dict:
    last: Exception | None = None
    for i in range(retries):
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=25) as r:
                return json.loads(r.read().decode("utf-8", "replace"))
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(1.2 * (i + 1))
    raise RuntimeError(f"GET 失败 {url}: {last}")


def _post_form(url: str, data: dict, retries: int = 3) -> dict:
    body = urllib.parse.urlencode(data).encode()
    last: Exception | None = None
    for i in range(retries):
        try:
            req = urllib.request.Request(url, data=body, headers={
                **HEADERS,
                "Content-Type": "application/x-www-form-urlencoded",
            })
            with urllib.request.urlopen(req, timeout=25) as r:
                return json.loads(r.read().decode("utf-8", "replace"))
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(1.2 * (i + 1))
    raise RuntimeError(f"POST 失败 {url}: {last}")


def resolve_uid(raw: str) -> str:
    """支持 用户主页链接 / 纯数字 uid。"""
    raw = raw.strip()
    m = re.search(r"(?:id=|/user/home\?id=)(\d+)", raw)
    if m:
        return m.group(1)
    if re.fullmatch(r"\d{1,}", raw):
        return raw
    raise ValueError(f"无法识别网易云用户标识：{raw}（请填数字 uid 或用户主页链接）")


def _https(url):
    """网易云接口给的是 http:// 图片地址，统一升级为 https 以便 https 页面直连。"""
    if not url:
        return None
    return "https://" + url[len("http://"):] if url.startswith("http://") else url


def user_info(uid: str) -> dict:
    d = _get(f"https://music.163.com/api/v1/user/detail/{uid}")
    p = d.get("profile") or {}
    return {
        "uid": uid,
        "nickname": p.get("nickname") or uid,
        "avatar": _https(p.get("avatarUrl")),
        # 关注数 / 粉丝数。这两个字段不受"隐私设置"影响——
        # 即使对方隐藏了关注列表，数字依然可读。
        "follows": p.get("follows"),
        "followeds": p.get("followeds"),
        "playlist_count": p.get("playlistCount"),
    }


def list_playlists(uid: str) -> list[dict]:
    """返回该用户创建/收藏的全部歌单。"""
    out: list[dict] = []
    offset = 0
    while True:
        d = _get(f"https://music.163.com/api/user/playlist?uid={uid}&limit=100&offset={offset}")
        if d.get("code") != 200:
            raise RuntimeError(f"歌单列表返回 code={d.get('code')}")
        batch = d.get("playlist") or []
        for p in batch:
            out.append({
                "id": str(p["id"]),
                "name": p.get("name") or str(p["id"]),
                "track_count": p.get("trackCount") or 0,
                "special_type": p.get("specialType") or 0,
                "update_time": p.get("updateTime") or 0,
                "cover": _https(p.get("coverImgUrl") or p.get("coverUrl")),
            })
        if not d.get("more") or not batch:
            break
        offset += len(batch)
        time.sleep(0.4)
    return out


def playlist_track_ids(playlist_id: str) -> tuple[list[str], dict]:
    d = _get(f"https://music.163.com/api/v6/playlist/detail?id={playlist_id}")
    p = d.get("playlist") or {}
    ids = [str(t["id"]) for t in (p.get("trackIds") or []) if t.get("id")]
    meta = {
        "name": p.get("name"),
        "track_count": p.get("trackCount"),
        "update_time": p.get("updateTime"),
        "creator_id": (p.get("creator") or {}).get("userId") if p.get("creator") else p.get("userId"),
    }
    # 若 trackIds 缺失但 tracks 有内容，退化处理
    if not ids and p.get("tracks"):
        ids = [str(t["id"]) for t in p["tracks"]]
    return ids, meta


_song_cache: dict[str, dict] = {}


def song_details(ids: list[str]) -> dict[str, dict]:
    """批量换取歌曲元数据，带内存缓存。拿不到的 id 返回占位信息。"""
    need = [i for i in ids if i not in _song_cache]
    for i in range(0, len(need), 50):
        chunk = need[i:i + 50]
        payload = "[" + ",".join('{"id":%s}' % c for c in chunk) + "]"
        try:
            d = _post_form("https://music.163.com/api/v3/song/detail", {"c": payload})
        except Exception:  # noqa: BLE001
            continue
        for s in d.get("songs") or []:
            sid = str(s["id"])
            al = s.get("al") or {}
            _song_cache[sid] = {
                "name": s.get("name"),
                "artists": "/".join(a.get("name", "") for a in (s.get("ar") or [])),
                "album": al.get("name"),
                # 时长（毫秒）与专辑封面：App 的歌曲列表要显示时长、
                # 全屏播放器要显示大封面，这两个字段必须有。
                # picUrl 是 http:// 开头，走 _https 升级，否则 https 页面会拦成混合内容。
                "duration": s.get("dt"),
                "cover": _https(al.get("picUrl")),
            }
        for c in chunk:
            _song_cache.setdefault(c, {"name": None, "artists": None, "album": None,
                                       "duration": None, "cover": None})
        time.sleep(0.35)

    out = {}
    for i in ids:
        m = _song_cache.get(i) or {}
        if m.get("name"):
            out[i] = m
        else:
            out[i] = {"name": f"歌曲(id {i})", "artists": None, "album": None,
                      "duration": None, "cover": None}
    return out


def fetch(uid: str) -> dict:
    """采集一个网易云用户的全量歌单状态。"""
    uid = resolve_uid(uid)
    info = user_info(uid)
    playlists = list_playlists(uid)

    result = {
        "kind": "netease", "uid": uid, "nickname": info["nickname"],
        "avatar": info.get("avatar"),
        # 关注数 / 粉丝数：不受隐私设置影响，对方隐藏列表也能读到数字
        "followers": info.get("followeds"),
        "following": info.get("follows"),
        "playlists": [],
    }
    # 只对真正有歌的歌单拉明细，避免空歌单浪费请求
    for p in playlists:
        ids, meta = playlist_track_ids(p["id"])
        names = song_details(ids) if ids else {}
        result["playlists"].append({
            "id": p["id"],
            "name": meta.get("name") or p["name"],
            "cover": p.get("cover"),
            "track_ids": ids,
            "songs": {
                sid: {
                    "name": names[sid]["name"],
                    "artists": names[sid].get("artists"),
                    "album": names[sid].get("album"),
                    # 时长与封面一并落进快照：iOS 端歌曲列表要显示 mm:ss，
                    # 播放器要显示专辑图，不能每次都回打上游。
                    "duration": names[sid].get("duration"),
                    "cover": names[sid].get("cover"),
                }
                for sid in ids
            },
        })
        time.sleep(0.5)
    return result
