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

    支持 JPEG（SOF 段）与 WebP（VP8/VP8L/VP8X）。读不出来就返回 (None, None)，
    由前端按实际文件尺寸显示——绝不用接口返回的元数据，它会骗人。
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
        # 像素尺寸取实际文件而非接口元数据：pic_infos 里 largest 声明的是
        # 2048×2757，但 /large/ 实际返回 3213×5712，元数据不可信。
        w, h = _px_size(data)
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
             "hidden": 0, "notes_visited": 0, "detail_fail": 0}
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
                # 详情页拿不到就用主页封面，至少别丢图
                stats["detail_fail"] += 1
                if c.get("images"):
                    imgs = [{"url": c["images"][0],
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
            already = conn.execute(
                "SELECT local_path FROM content_media WHERE content_id=? AND seq=?",
                (cid, seq),
            ).fetchone()
            if already and already["local_path"] and Path(already["local_path"]).exists():
                conn.execute("UPDATE content_media SET remote_url=? WHERE content_id=? AND seq=?",
                             (u, cid, seq))
                continue
            if budget["media"] <= 0:
                if not already:
                    arc.upsert_media(conn, cid, seq, u, "note")
                continue
            data = _http_get(u, referer="https://www.xiaohongshu.com/")
            if not data:
                if not already:
                    arc.upsert_media(conn, cid, seq, u, "note")
                continue
            saved = arc.save_media(media_root, target_key, nid, seq, data)
            # 尺寸优先用接口给的（详情页 imageList 的 width/height 是准的），
            # 缺失时再从文件字节解析
            w, h = im.get("width") or 0, im.get("height") or 0
            if not (w and h):
                w, h = _px_size(data)
            conn.execute(
                "INSERT INTO content_media(content_id, seq, remote_url, tier, local_path, "
                "  bytes, width, height, sha256, fetched_at) VALUES(?,?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(content_id, seq) DO UPDATE SET "
                "  remote_url=excluded.remote_url, tier=excluded.tier, "
                "  local_path=excluded.local_path, bytes=excluded.bytes, "
                "  width=excluded.width, height=excluded.height, "
                "  sha256=excluded.sha256, fetched_at=excluded.fetched_at",
                (cid, seq, u, "note", saved["local_path"], saved["bytes"],
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
