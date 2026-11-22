"""归档采集：把平台上的原帖 + 原图 + 作者互动评论落库。

存活判定（用户确认的口径）
--------------------------
微博 `mymblog` 有硬上限（实测 statuses_count=90，但只有前 45 条能翻到）。
因此采取"以可见窗口为基线"的策略：

  * 窗口内的内容            → 归档，state=alive
  * 出了窗口的旧内容        → 不管，不动它的存档记录
  * 存档过但这次没出现      → 不判死，标 hidden（可能只是滑出窗口）
  * 主动探测确认已删        → 标 deleted（微博 /ajax/statuses/show 返回 20101）
  * 曾 hidden 又出现        → 立刻回写 alive 并抓图补档

这样一个"曾可见、后消失"的内容会保留在列表里、带标记，而从未见过的内容
不会被误报成"已删除"。
"""
from __future__ import annotations

import json
import time
import urllib.request
from pathlib import Path

from ..platforms.browser import _weibo_clean, _weibo_ts
from . import archive as arc

# 原图档位：微博 pic_infos 里 `largest` 的 url 实际指向 /large/ 路径，
# 即 4126×5556 真原图（单张实测 4.6MB）。`large`(960) / `mw2000`(2000) 是缩水版。
_WEIBO_TIERS = ("largest", "mw2000", "large")

# 小红书归档档位名。DB 里 tier 只是给人看的元信息（App 不按它分支），
# 但要能区分"真原图"和"CDN 压缩档"。
#  - origin：ci.xiaohongshu.com/{fileId} 的原始 JPEG（实测 4284×5712 / 4.4MB）
#  - note  ：sns-webpic-qc 的 !nd_dft_wlteh_webp_3 压缩档（实测 1080×1440 / 186KB）
_XHS_TIER_ORIGIN = "origin"
_XHS_TIER_FALLBACK = "note"

# 小红书原图通道有一部分图**直接交付 HEIC**（ISOBMFF 容器）。HEIC 落盘有三个后果：
#   1) Pillow 不认 → 缩略图生成失败，列表页回落成 1.4–3MB 的原图；
#   2) HTTP 头写 image/jpeg 但内容是 HEIC → 浏览器不解码；
#   3) _px_size 解析不出像素 → DB 尺寸退回不可信的接口元数据。
# CDN 自带 imageView2 转码通道：?imageView2/2/w/0/format/jpg/q/95 能把同一张
# HEIC 转成**同像素**的 JPEG（实测像素完全一致，逐像素 MAE 0.40–0.63，肉眼不可分辨）。
# 注意这个参数只能用在 HEIC 上：对本来就是 JPEG 的原图加会触发二次有损重编码
# （实测 4.4MB → 2.2MB）。
_XHS_JPEG_CONVERT_Q = "q/95"

_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")

# 单轮最多下多少张图。首次归档 45 条 × 9 图 = 405 张、约 1.8GB，
# 一小时一轮的巡检里跑完会拖很久，所以分批：每轮补一批，直到补满。
MEDIA_BUDGET_PER_RUN = 60


def _http_get(url: str, referer: str = "https://weibo.com/", timeout: int = 20) -> bytes | None:
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": _UA, "Referer": referer,
            "Accept": "image/webp,image/jpeg,image/png,*/*",
        })
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()
    except Exception:  # noqa: BLE001
        return None


def _http_get_first(urls: list[str], referer: str = "https://weibo.com/",
                    timeout: int = 20) -> tuple[bytes | None, str]:
    """依次尝试多个 URL，返回第一个下载成功的 (数据, 实际用到的 URL)。

    小红书有两条通道：原图（ci.xiaohongshu.com/{fileId}）和 CDN 压缩档
    （sns-webpic-qc 的 !nd_dft_wlteh_webp_3）。原图优先，失败退回压缩档，
    宁可存小图也别丢图。
    """
    for u in urls:
        if not u:
            continue
        data = _http_get(u, referer=referer, timeout=timeout)
        if data:
            return data, u
    return None, ""


def _is_heif(data: bytes) -> bool:
    """判断字节是不是 HEIF/HEIC 家族（ISOBMFF 容器，Pillow 解不了）。

    小红书原图通道有一部分图直接交付 HEIC，落盘会带来三个问题：
    Pillow 解不出缩略图、Content-Type 说谎、_px_size 解析不出像素。
    """
    if len(data) < 12 or data[4:8] != b"ftyp":
        return False
    return data[8:12][:3] in (b"hei", b"hev", b"mif", b"mia", b"msf")


def _heif_size(data: bytes) -> tuple[int | None, int | None]:
    """从 HEIF/HEIC 字节里读出**显示方向**的像素宽高。

    一个 HEIC 里通常有多张图：主图 + 缩略图 + 派生图，每张都有自己的 ispe
    （Image Spatial Extents）。实测一个文件里能出现 5 个 ispe：
    640×896 / 4284×5712 / 896×960 / 2142×2856 / 512×512。
    主图的那张在 ipco 里紧挨着第一个 irot（旋转属性）之前；
    irot 值为奇数（1/3）表示要转 90°，宽高要互换。
    """
    props: list[tuple[bytes, bytes]] = []   # (box type, payload)
    found = {"ipco": False}

    def walk(buf: bytes) -> None:
        i = 0
        n = len(buf)
        while i + 8 <= n:
            size = int.from_bytes(buf[i:i + 4], "big")
            btype = buf[i + 4:i + 8]
            hdr = 8
            if size == 1:  # 64 位长度
                if i + 16 > n:
                    return
                size = int.from_bytes(buf[i + 8:i + 16], "big")
                hdr = 16
            elif size == 0:  # 一直延伸到文件尾
                size = n - i
            if size < hdr or i + size > n:
                return
            payload = buf[i + hdr:i + size]
            if btype == b"ipco":
                found["ipco"] = True
                j = 0
                while j + 8 <= len(payload):
                    psz = int.from_bytes(payload[j:j + 4], "big")
                    ptype = payload[j + 4:j + 8]
                    phdr = 8
                    if psz == 1:
                        if j + 16 > len(payload):
                            break
                        psz = int.from_bytes(payload[j + 8:j + 16], "big")
                        phdr = 16
                    if psz < phdr or j + psz > len(payload):
                        break
                    props.append((ptype, payload[j + phdr:j + psz]))
                    j += psz
            elif btype == b"meta":  # fullbox：多 4 字节 version/flags
                walk(payload[4:])
            elif btype == b"iprp":
                walk(payload)
            i += size

    try:
        walk(data)
    except Exception:  # noqa: BLE001
        return None, None
    if not found["ipco"]:
        return None, None

    def ispe_wh(payload: bytes) -> tuple[int, int] | None:
        if len(payload) < 12:
            return None
        return (int.from_bytes(payload[4:8], "big"),
                int.from_bytes(payload[8:12], "big"))

    # 主图 ispe：第一个 irot 之前的那一个 ispe
    wh = None
    rot = 0
    for ptype, payload in props:
        if ptype == b"irot":
            rot = payload[0] & 3 if payload else 0
            break
        if ptype == b"ispe":
            wh = ispe_wh(payload)
    if wh is None:  # 没有 irot：取面积最大的 ispe
        cands = [ispe_wh(p) for t, p in props if t == b"ispe"]
        cands = [c for c in cands if c]
        if not cands:
            return None, None
        wh = max(cands, key=lambda c: c[0] * c[1])
    if rot in (1, 3):  # 转 90°，宽高互换
        wh = (wh[1], wh[0])
    return wh


def _xhs_jpeg_convert_url(url: str) -> str:
    """给小红书原图直链拼上 CDN 的 JPEG 转码参数。

    imageView2 是 CDN 的服务端图像处理管线：/2/ 表示第二版参数、
    /w/0 表示不缩放、/format/jpg 指定输出格式、/q/95 指定 JPEG 质量。
    对 HEIC 原图用它可以拿到**同像素**的 JPEG（实测像素完全一致）。
    注意：只对 HEIC 用——给本来就是 JPEG 的原图加会二次有损重编码。
    """
    if not url:
        return ""
    sep = "&" if "?" in url else "?"
    return f"{url}{sep}imageView2/2/w/0/format/jpg/{_XHS_JPEG_CONVERT_Q}"


def _xhs_fetch(urls: list[str], referer: str = "https://www.xiaohongshu.com/",
               timeout: int = 30) -> tuple[bytes | None, str]:
    """依次尝试多个 URL 下载小红书图，返回 (数据, 实际用到的 URL)。

    小红书原图通道（ci.xiaohongshu.com/{fileId}）有一部分图**直接交付 HEIC**：
    Pillow 解不出缩略图、HTTP 头写 image/jpeg 但内容是 HEIC（浏览器不解码）、
    _px_size 也解析不出像素。落盘前统一转成同像素 JPEG——CDN 的 imageView2
    转码通道能做到（实测像素完全一致，q/95 逐像素 MAE 0.4–0.6，肉眼不可分辨）。
    转码失败就跳过这条 URL，退到下一个候选（宁可存压缩档也别存解不开的 HEIC）。

    返回的第二个元素是"字节真正来自哪个 URL"：HEIC 转码后是带 imageView2
    参数的地址，DB 里记它，App 在本地文件丢失时回落到远端也能拿到可解码的图。
    """
    for u in urls:
        if not u:
            continue
        data = _http_get(u, referer=referer, timeout=timeout)
        if not data:
            continue
        if _is_heif(data):
            conv_url = _xhs_jpeg_convert_url(u)
            conv = _http_get(conv_url, referer=referer, timeout=timeout)
            if conv and conv[:3] == b"\xff\xd8\xff":
                return conv, conv_url
            continue
        return data, u
    return None, ""


def _file_is_heif(path: str) -> bool:
    """已落盘的文件是不是 HEIC（早前把 HEIC 当 .jpg 存了，浏览器解不了）。"""
    try:
        with open(path, "rb") as fh:
            return _is_heif(fh.read(16))
    except OSError:
        return False


def _preserve_heif(local_path: str) -> str:
    """把早前误存成 .jpg 的 HEIC 改名成 .heic 保留原文件，返回新路径。

    不删既有文件：HEIC 是源站给的原始字节，改名保留，新下载的同像素 JPEG
    另存到 .jpg 路径。改名后原路径空出来，save_media 才能写进去。
    """
    src = Path(local_path)
    if not src.exists() or not _file_is_heif(local_path):
        return local_path
    dst = src.with_suffix(".heic")
    if dst.exists():
        return local_path
    try:
        src.rename(dst)
        return str(dst)
    except OSError:
        return local_path


def _weibo_hq_url(info: dict) -> tuple[str | None, str]:
    """从 pic_infos 的单个条目里取最高画质 URL，返回 (url, tier)。"""
    for tier in _WEIBO_TIERS:
        v = info.get(tier) or {}
        u = v.get("url") if isinstance(v, dict) else None
        if u:
            return (u if u.startswith("http") else "https:" + u), tier
    return None, ""


def _px_size(data: bytes) -> tuple[int | None, int | None]:
    """从图片字节里读出像素宽高，不依赖 Pillow。

    支持 JPEG（SOF 段）、WebP（VP8/VP8L/VP8X）、PNG、HEIF（ispe box）。
    读不出来就返回 (None, None)，由前端按实际文件尺寸显示——绝不用接口
    返回的元数据，它会骗人。
    """
    try:
        if data[:3] == b"\xff\xd8\xff":  # JPEG：扫 SOF0/1/2 段
            i = 2
            n = len(data)
            while i < n - 9:
                if data[i] != 0xFF:
                    i += 1
                    continue
                marker = data[i + 1]
                if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                              0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                    h = int.from_bytes(data[i + 5:i + 7], "big")
                    w = int.from_bytes(data[i + 7:i + 9], "big")
                    return w, h
                if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
                    i += 2
                    continue
                seg_len = int.from_bytes(data[i + 2:i + 4], "big")
                i += 2 + seg_len
            return None, None
        if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
            kind = data[12:16]
            if kind == b"VP8X":  # 扩展格式：画布宽高在 24 位小端里
                w = int.from_bytes(data[24:27], "little") + 1
                h = int.from_bytes(data[27:30], "little") + 1
                return w, h
            if kind == b"VP8 ":  # 有损：帧头 14 位宽高
                w = int.from_bytes(data[26:28], "little") & 0x3FFF
                h = int.from_bytes(data[28:30], "little") & 0x3FFF
                return w, h
            if kind == b"VP8L":  # 无损：位打包
                b = data[21:25]
                w = ((b[1] & 0x3F) << 8 | b[0]) + 1
                h = ((b[3] & 0x0F) << 10 | b[2] << 2 | (b[1] & 0xC0) >> 6) + 1
                return w, h
            return None, None
        if data[:8] == b"\x89PNG\r\n\x1a\n":
            return (int.from_bytes(data[16:20], "big"),
                    int.from_bytes(data[20:24], "big"))
        if data[4:8] == b"ftyp":  # HEIF/HEIC：图像空间尺寸在 ispe box
            return _heif_size(data)
    except Exception:  # noqa: BLE001
        return None, None
    return None, None


# ---------------------------------------------------------------- 微博
def collect_weibo(page, target_key: str, uid: str, conn,
                  media_root: Path, budget: dict | None = None,
                  max_pages: int = 8) -> dict:
    """翻页抓微博正文与原图，写进归档库。返回本轮统计。"""
    budget = budget if budget is not None else {"media": MEDIA_BUDGET_PER_RUN}
    stats = {"posts": 0, "new": 0, "media_saved": 0, "media_bytes": 0,
             "comments": 0, "hidden": 0, "deleted": 0, "pages": 0}

    seen_ids: set[str] = set()
    page_no = 1
    while page_no <= max_pages:
        try:
            raw = page.evaluate(
                """async ([uid, p]) => {
                  const r = await fetch('/ajax/statuses/mymblog?uid=' + uid
                    + '&page=' + p + '&feature=0',
                    {headers:{'accept':'application/json'}, credentials:'include'});
                  return [r.status, await r.text()];
                }""",
                [uid, page_no],
            )
        except Exception:  # noqa: BLE001
            break
        if not raw or raw[0] != 200:
            break
        d = json.loads(raw[1])
        lst = (d.get("data") or {}).get("list") or []
        if not lst:
            break
        stats["pages"] = page_no
        for s in lst:
            pid = s.get("mblogid") or s.get("mid")
            if not pid:
                continue
            pid = str(pid)
            if pid in seen_ids:
                continue
            seen_ids.add(pid)
            _ingest_one(page, conn, media_root, budget, stats,
                        target_key, uid, s, pid)
        # 最后一页返回的条数少于常规页容量就说明到底了
        if len(lst) < 15:
            break
        page_no += 1
        time.sleep(0.6)  # 翻页间隔，避免风控

    # 存档里活着、但这轮没出现在列表里的 → 标 hidden（不判死）
    hidden = _mark_vanished(conn, target_key, "weibo", seen_ids)
    stats["hidden"] = hidden
    return stats


def _ingest_one(page, conn, media_root: Path, budget: dict, stats: dict,
                target_key: str, uid: str, s: dict, pid: str) -> None:
    """处理单条微博：正文 → 原图 → 评论。"""
    text_raw = s.get("text_raw") or s.get("text") or ""
    text = _weibo_clean(text_raw)
    rt = s.get("retweeted_status") or {}
    rt_txt = _weibo_clean(rt.get("text_raw") or rt.get("text") or "") if rt else None

    existed = conn.execute(
        "SELECT id FROM content WHERE target_key=? AND platform='weibo' AND post_id=?",
        (target_key, pid),
    ).fetchone()

    post = {
        "id": pid,
        "text": text,
        "text_raw": text_raw,
        "at": _weibo_ts(s.get("created_at")),
        "url": f"https://weibo.com/{uid}/{pid}",
        "author_name": (s.get("user") or {}).get("screen_name"),
        "likes": int(s.get("attitudes_count") or 0),
        "comments_count": int(s.get("comments_count") or 0),
        "reposts": int(s.get("reposts_count") or 0),
        "images_total": int(s.get("pic_num") or len(s.get("pic_ids") or [])),
        "retweet": (rt_txt[:200] if rt_txt else None),
    }
    cid = arc.upsert_content(conn, target_key, "weibo", post)
    if not cid:
        return
    stats["posts"] += 1
    if not existed:
        stats["new"] += 1

    # ---- 配图：优先原图，落盘到 data/archive
    pic_ids = s.get("pic_ids") or []
    pic_infos = s.get("pic_infos") or {}
    for seq, p_id in enumerate(pic_ids, start=1):
        info = pic_infos.get(p_id) or {}
        hq_url, tier = _weibo_hq_url(info)
        if not hq_url:
            continue
        already = conn.execute(
            "SELECT local_path, remote_url FROM content_media WHERE content_id=? AND seq=?",
            (cid, seq),
        ).fetchone()
        # 已经下好且文件还在：只刷新远程地址（微博图链带时效签名，会过期）
        if already and already["local_path"] and Path(already["local_path"]).exists():
            conn.execute("UPDATE content_media SET remote_url=?, tier=? "
                         "WHERE content_id=? AND seq=?", (hq_url, tier, cid, seq))
            continue
        # 预算耗尽 / 下载失败：只登记地址，不写 NULL 覆盖已有成功记录
        if budget["media"] <= 0:
            if not already:
                arc.upsert_media(conn, cid, seq, hq_url, tier)
            continue
        data = _http_get(hq_url)
        if not data:
            if not already:
                arc.upsert_media(conn, cid, seq, hq_url, tier)
            continue
        saved = arc.save_media(media_root, target_key, pid, seq, data)
        # 像素尺寸以实际下载到的文件字节为准：pic_infos 里 largest 声明的是
        # 2048×2757，但 /large/ 实际返回 3213×5712，元数据不可信。
        # 只有从字节里也解析不出来时，才拿接口元数据兜底。
        w, h = _px_size(data)
        if not (w and h):
            meta = info.get(tier) or {}
            w, h = int(meta.get("width") or 0), int(meta.get("height") or 0)
        conn.execute(
            "INSERT INTO content_media(content_id, seq, remote_url, tier, local_path, bytes, "
            "  width, height, sha256, fetched_at) VALUES(?,?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(content_id, seq) DO UPDATE SET "
            "  remote_url=excluded.remote_url, tier=excluded.tier, "
            "  local_path=excluded.local_path, bytes=excluded.bytes, "
            "  width=excluded.width, height=excluded.height, "
            "  sha256=excluded.sha256, fetched_at=excluded.fetched_at",
            (cid, seq, hq_url, tier, saved["local_path"], saved["bytes"],
             w, h, saved["sha256"], int(time.time())),
        )
        budget["media"] -= 1
        stats["media_saved"] += 1
        stats["media_bytes"] += saved["bytes"]
        time.sleep(0.25)

    # ---- 评论：只留作者互动过的
    if int(s.get("comments_count") or 0) > 0:
        got = _weibo_author_comments(page, conn, cid, pid, uid,
                                     int(s.get("comments_count") or 0))
        stats["comments"] += got


def _weibo_author_comments(page, conn, cid: int, mid: str, author_uid: str,
                           total: int, max_pages: int = 4) -> int:
    """抓评论，只保留作者互动过的。

    判定「作者互动」的三种情形（均已实测可识别）：
      1. isLikedByMblogAuthor == true     作者点赞了这条评论
      2. 嵌套 comments 里 user.id == 作者   作者本人回复了这条评论
      3. 上述作者回复之下的追评            算作围绕作者互动的对话

    其余评论一律不落库——热门微博动辄 725 条评论，全抓必然触发风控，
    且存档价值低。作者互动才是用户真正关心的。
    """
    kept = 0
    max_id = ""
    for _ in range(max_pages):
        try:
            raw = page.evaluate(
                """async ([mid, mx]) => {
                  const r = await fetch('/ajax/statuses/buildComments?flow=0&is_reload=1&id='
                    + mid + '&is_show_bulletin=2&is_mix=0&count=20'
                    + (mx ? '&max_id=' + mx : ''),
                    {headers:{'accept':'application/json'}, credentials:'include'});
                  return [r.status, await r.text()];
                }""",
                [mid, max_id],
            )
        except Exception:  # noqa: BLE001
            break
        if not raw or raw[0] != 200:
            break
        d = json.loads(raw[1])
        items = d.get("data") or []
        if not items:
            break
        for c in items:
            if not _is_author_interaction(c, author_uid):
                continue
            arc.upsert_comment(conn, cid, {
                "comment_id": str(c.get("id") or c.get("idstr") or ""),
                "author_name": (c.get("user") or {}).get("screen_name"),
                "author_id": str((c.get("user") or {}).get("id") or ""),
                "text": _cm_text(c),
                "text_raw": c.get("text_raw") or c.get("text"),
                "likes": int(c.get("like_counts") or 0),
                "liked_by_author": bool(c.get("isLikedByMblogAuthor")),
                "replied_by_author": _author_replied(c, author_uid),
                "posted_at": _cm_ts(c),
            })
            kept += 1
        max_id = str(d.get("max_id") or "")
        if not max_id or max_id == "0":
            break
        time.sleep(0.5)
    return kept


def _cm_text(c: dict) -> str:
    return _weibo_clean(c.get("text_raw") or c.get("text") or "")


def _cm_ts(c: dict):
    return _weibo_ts(c.get("created_at"))


def _author_replied(c: dict, author_uid: str) -> bool:
    """嵌套回复里是否出现作者本人。"""
    for r in (c.get("comments") or []):
        uid = str((r.get("user") or {}).get("id") or "")
        if uid and uid == str(author_uid):
            return True
    return False


def _is_author_interaction(c: dict, author_uid: str) -> bool:
    """这条评论是否与作者产生过互动。"""
    if c.get("isLikedByMblogAuthor"):
        return True
    if _author_replied(c, author_uid):
        return True
    # 评论者本人就是作者（作者自己在别人楼下回复，出现在楼中楼时）
    if str((c.get("user") or {}).get("id") or "") == str(author_uid):
        return True
    return False


# ---------------------------------------------------------------- 存活判定
def _mark_vanished(conn, target_key: str, platform: str, seen_ids: set[str]) -> int:
    """这轮没出现的存档内容标 hidden。

    不标 deleted：微博只给前 45 条，第 46 条起"看不到"不等于"已删除"。
    真正的删除判定走 probe_deleted() 主动查证。
    """
    if not seen_ids:
        return 0
    rows = conn.execute(
        "SELECT post_id FROM content WHERE target_key=? AND platform=? AND state='alive'",
        (target_key, platform),
    ).fetchall()
    checked = 0
    for r in rows:
        if r["post_id"] not in seen_ids:
            conn.execute(
                "UPDATE content SET state='hidden' WHERE target_key=? AND platform=? "
                "AND post_id=? AND state='alive'",
                (target_key, platform, r["post_id"]),
            )
            checked += 1
    return checked


def probe_deleted(page, conn, target_key: str, platform: str = "weibo",
                  limit: int = 20) -> int:
    """主动查证：对 hidden 的内容调 show 接口，确认是真删还是滑出窗口。

    微博 /ajax/statuses/show?id=<mblogid> 在微博被删时仍返回 HTTP 200，
    但正文是 {"ok":0,"error_code":20101,"message":"该微博不存在"}。
    """
    if platform != "weibo":
        return 0
    rows = conn.execute(
        "SELECT id, post_id FROM content WHERE target_key=? AND platform=? "
        "AND state='hidden' ORDER BY last_seen_at DESC LIMIT ?",
        (target_key, platform, limit),
    ).fetchall()
    confirmed = 0
    for r in rows:
        try:
            raw = page.evaluate(
                """async (mid) => {
                  const r = await fetch('/ajax/statuses/show?id=' + mid,
                    {headers:{'accept':'application/json'}, credentials:'include'});
                  return [r.status, await r.text()];
                }""",
                r["post_id"],
            )
            if not raw:
                continue
            body = raw[1] or ""
            if '"error_code":20101' in body.replace(" ", "") or "该微博不存在" in body:
                conn.execute(
                    "UPDATE content SET state='deleted', state_at=?, state_note=? WHERE id=?",
                    (int(time.time()), "平台已删除（show 接口返回 20101）", r["id"]),
                )
                confirmed += 1
        except Exception:  # noqa: BLE001
            continue
        time.sleep(0.4)
    return confirmed


# ---------------------------------------------------------------- 小红书
def collect_xiaohongshu(page, target_key: str, uid: str, conn,
                        media_root: Path, budget: dict | None = None,
                        max_notes: int = 12) -> dict:
    """采集小红书：主页列表 → 逐条详情页取全图 → 落盘。

    为什么必须逐条开详情页：
    用户主页 SSR 的 noteCard 只有封面 1 张（cover.urlDefault），
    9 张图的笔记在主页也显示成 1 张。详情页 SSR 的 note.imageList 才是
    完整列表。实测：主页 1 张 / 详情页 9 张。
    详情页还必须带 xsecToken，无 token 时 SSR 里 noteDetailMap 的 key
    是 "undefined"、note 是空对象——这就是"只有一张图"的根因。

    预算比微博宽松：小红书一条最多 18 图，但单图通常 300–800KB
    （原图 1920×2560 而非微博 4000+），所以 12 条 × 9 图 ≈ 80MB。
    """
    from ..platforms import browser as plat
    stats = {"posts": 0, "new": 0, "media_saved": 0, "media_bytes": 0,
             "hidden": 0, "notes_visited": 0, "detail_fail": 0,
             # 原图通道没命中而落到 1080 宽压缩档的计数。这两个值不为 0
             # 就说明这批图的画质被降级了，是「保存的图不如 App 清晰」的直接来源。
             "media_fallback": 0, "media_origin_failed": 0}
    if budget is None:
        budget = {"media": MEDIA_BUDGET_PER_RUN * 2}

    # 1) 主页 SSR 取 noteCard 列表（含 xsecToken）
    try:
        page.goto(f"https://www.xiaohongshu.com/user/profile/{uid}",
                  wait_until="domcontentloaded", timeout=45000)
        page.wait_for_timeout(4500)
    except Exception:  # noqa: BLE001
        return stats
    # 注意：绝不能 JSON.stringify(window.__INITIAL_STATE__) —— 它含 Vue 响应式
    # 循环引用，序列化会直接抛 "Converting circular structure to JSON"。
    # 只能从 HTML 源码里用正则截取（原有的 profile 抓取也是这么做的）。
    html = page.content()
    import re as _re
    m = _re.search(r"window\.__INITIAL_STATE__\s*=\s*(\{.+?\})</script>", html, _re.S)
    seg = m.group(1) if m else ""
    npos = seg.find('"notes"')
    notes_seg = seg[npos:] if npos >= 0 else seg
    cards = plat._xhs_post_items(notes_seg, uid)
    if not cards:
        return stats

    # 被访问账号的昵称：SSR 的 userPageData 里就有，零额外请求。
    # 历史数据 author_name 恒为 None，新采集的条目带上它，详情页就能显示作者。
    profile = plat._xhs_from_initial_state(html, uid) or {}
    author_name = profile.get("nickname")

    seen_ids: set[str] = set()
    for i, c in enumerate(cards[:max_notes]):
        nid = c.get("id") or ""
        if not nid:
            continue
        seen_ids.add(nid)

        # 2) 详情页取全图（主页只有封面）
        imgs: list[dict] = []
        if not c.get("video"):
            imgs = plat.xhs_note_images(page, nid, c.get("xsec_token") or "")
            if not imgs:
                # 详情页拿不到就用主页封面，至少别丢图。
                # 封面地址同样能反推出原图（fileId 规则一致），优先存原图。
                stats["detail_fail"] += 1
                if c.get("images"):
                    cover = c["images"][0]
                    origin = plat.xhs_origin_url(cover)
                    imgs = [{"url": origin or cover,
                             "fallback_url": cover,
                             "origin_url": origin,
                             "width": c.get("cover_w") or 0,
                             "height": c.get("cover_h") or 0, "seq": 1}]
            else:
                stats["notes_visited"] += 1

        post = {
            "id": nid,
            "text": c.get("text") or "",
            "text_raw": c.get("text") or "",
            "at": c.get("at"),
            "url": c.get("url") or f"https://www.xiaohongshu.com/explore/{nid}",
            "author_name": author_name,
            "likes": c.get("likes") or 0,
            "comments_count": 0,
            "reposts": 0,
            "images_total": len(imgs),
            "video": bool(c.get("video")),
            "retweet": None,
        }
        existed = conn.execute(
            "SELECT id FROM content WHERE target_key=? AND platform='xiaohongshu' "
            "AND post_id=?", (target_key, nid),
        ).fetchone()
        cid = arc.upsert_content(conn, target_key, "xiaohongshu", post)
        if not cid:
            continue
        stats["posts"] += 1
        if not existed:
            stats["new"] += 1

        # 3) 图片落盘（复用微博那套预算 + 增量逻辑）
        for seq, im in enumerate(imgs, start=1):
            u = im.get("url") or ""
            if not u:
                continue
            origin = im.get("origin_url") or ""
            # 原图候选全集：SSR fileId 与 webpic 反推的都得试。
            # 哪个带对目录前缀只有发一次请求才知道，所以不猜，全带上。
            origin_cands = [c for c in (im.get("origin_candidates") or []) if c]
            if not origin_cands:
                origin_cands = [c for c in (origin, im.get("origin_alt") or "") if c]
            cands = origin_cands + [im.get("fallback_url") or ""] if origin_cands \
                else [u]
            already = conn.execute(
                "SELECT local_path, tier, remote_url FROM content_media "
                "WHERE content_id=? AND seq=?", (cid, seq),
            ).fetchone()
            has_file = bool(already and already["local_path"]
                            and Path(already["local_path"]).exists())
            # 已经下过原图就不重下；只下过压缩档的（老数据）要重新下原图升级。
            # 例外：早前落盘的 HEIC 冒充 .jpg——浏览器解不了、缩略图也生不出，
            # 必须重下并转成同像素 JPEG。
            if has_file and _file_is_heif(already["local_path"]):
                has_file = False
            if has_file and (not origin or already["tier"] == _XHS_TIER_ORIGIN):
                # 已经是原图档：remote_url 保持原样（HEIC 转码过的记录的是带
                # imageView2 参数的地址，回落到远端时拿到的才是可解码的 JPEG）
                prev = already["remote_url"] or ""
                if not (origin and prev.startswith(origin)):
                    conn.execute("UPDATE content_media SET remote_url=? "
                                 "WHERE content_id=? AND seq=?", (u, cid, seq))
                continue
            if budget["media"] <= 0:
                if not already:
                    arc.upsert_media(conn, cid, seq, u, _XHS_TIER_FALLBACK)
                continue
            data, used = _xhs_fetch(
                cands, referer="https://www.xiaohongshu.com/", timeout=30)
            if not data:
                # 全候选都失败。落压缩档兜底，但**记下原因**——
                # 静默降级会让「保存的图不如 App 清晰」变成查不出原因的问题。
                if not already:
                    arc.upsert_media(conn, cid, seq, u, _XHS_TIER_FALLBACK)
                stats["media_origin_failed"] += 1
                continue
            # 判定档位：命中的 URL 是不是原图直链。
            # 注意 imageView2 转码过的地址也以 origin 开头，仍算原图档。
            tier = (_XHS_TIER_ORIGIN
                    if origin_cands and any(used.startswith(o) for o in origin_cands)
                    else _XHS_TIER_FALLBACK)
            if tier == _XHS_TIER_FALLBACK:
                # 落到压缩档 = 1080 宽的 webp。记一笔，运维能看出哪批图降级了。
                stats["media_fallback"] += 1
            # 老文件是 HEIC（早前被当 .jpg 存）→ 改名保留原字节，新 JPEG
            # 写到 .jpg 路径。不删既有文件。
            if already and already["local_path"]:
                _preserve_heif(already["local_path"])
            saved = arc.save_media(media_root, target_key, nid, seq, data)
            # 尺寸一律以实际下载到的文件字节为准：接口给的 width/height 是
            # 「展示尺寸」（小红书报 1920×2560，实际只有 1080×1440），不可信。
            # 只有从字节里也解析不出来时，才拿接口元数据兜底。
            w, h = _px_size(data)
            if not (w and h):
                w, h = im.get("width") or 0, im.get("height") or 0
            conn.execute(
                "INSERT INTO content_media(content_id, seq, remote_url, tier, local_path, "
                "  bytes, width, height, sha256, fetched_at) VALUES(?,?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(content_id, seq) DO UPDATE SET "
                "  remote_url=excluded.remote_url, tier=excluded.tier, "
                "  local_path=excluded.local_path, bytes=excluded.bytes, "
                "  width=excluded.width, height=excluded.height, "
                "  sha256=excluded.sha256, fetched_at=excluded.fetched_at",
                (cid, seq, used or u, tier, saved["local_path"], saved["bytes"],
                 w, h, saved["sha256"], int(time.time())),
            )
            budget["media"] -= 1
            stats["media_saved"] += 1
            stats["media_bytes"] += saved["bytes"]
            time.sleep(0.2)

        # 4) 小红书的评论作者互动：暂不采集（用户口径"仅作者互动过的"，
        #    小红书作者点赞字段在详情页 comments 里，需额外接口，后续再补）
        time.sleep(0.6)

    stats["hidden"] = _mark_vanished(conn, target_key, "xiaohongshu", seen_ids)
    return stats
