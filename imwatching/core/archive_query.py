"""归档查询：给 Web 层提供分页列表与单条详情。

与 core/store.py 的区别：store 面向"指标快照与变更事件"（小而密），
archive 面向"原文与评论"（大而疏）。两者共用同一个 SQLite 文件，
但查询路径完全分开——列表只取元数据，图片按需回源，避免一次拉全量。
"""
from __future__ import annotations

import json
import sqlite3
from pathlib import Path


def _row_content(r: sqlite3.Row) -> dict:
    return {
        "id": r["id"],
        "post_id": r["post_id"],
        "url": r["url"],
        "platform": r["platform"] if "platform" in r.keys() else None,
        "target_key": r["target_key"] if "target_key" in r.keys() else None,
        "text": r["text"],
        "posted_at": r["posted_at"],
        "first_seen_at": r["first_seen_at"],
        "last_seen_at": r["last_seen_at"],
        "state": r["state"],
        "state_at": r["state_at"],
        "state_note": r["state_note"],
        "likes": r["likes"],
        "comments_count": r["comments_count"],
        "reposts": r["reposts"],
        "images_total": r["images_total"],
        "video": bool(r["video"]),
        "retweet": r["retweet_text"],
        "media_count": r["media_count"] if "media_count" in r.keys() else 0,
        "saved_comment_count": r["saved_comment_count"] if "saved_comment_count" in r.keys() else 0,
    }


LIST_COLS = """
  c.id, c.post_id, c.url, c.platform, c.target_key,
  c.text, c.posted_at, c.first_seen_at, c.last_seen_at,
  c.state, c.state_at, c.state_note, c.likes, c.comments_count, c.reposts,
  c.images_total, c.video, c.retweet_text,
  (SELECT COUNT(*) FROM content_media m WHERE m.content_id=c.id AND m.local_path IS NOT NULL) media_count,
  (SELECT COUNT(*) FROM content_comment k WHERE k.content_id=c.id) saved_comment_count
"""


def list_content(conn, target_key: str | None = None, platform: str | None = None,
                 state: str | None = None, before_key: str | None = None,
                 limit: int = 30) -> dict:
    """游标分页：按 (posted_at DESC, id DESC) 排序。

    游标必须是「posted_at + id」复合键，不能只用 id：
    排序主键是 posted_at，一条记录的 id 大小与它的时间先后无关
    （补抓旧帖时 id 很大但时间很早）。只用 id 做游标会退化成
    "取所有更小 id"，导致翻页重复或漏条。
    """
    limit = max(1, min(int(limit or 30), 100))
    q = f"SELECT {LIST_COLS} FROM content c WHERE 1=1"
    args: list = []
    if target_key:
        q += " AND c.target_key=?"
        args.append(target_key)
    if platform:
        q += " AND c.platform=?"
        args.append(platform)
    if state:
        q += " AND c.state=?"
        args.append(state)
    if before_key:
        # 游标格式 "posted_at:id"
        try:
            pts_s, id_s = str(before_key).split(":", 1)
            pts, cid = int(pts_s), int(id_s)
        except (ValueError, TypeError):
            pts = cid = None
        if pts is not None:
            # 严格小于 (posted_at, id) 的字典序下一批
            q += " AND (c.posted_at < ? OR (c.posted_at = ? AND c.id < ?))"
            args.extend([pts, pts, cid])
    q += " ORDER BY c.posted_at DESC, c.id DESC LIMIT ?"
    args.append(limit + 1)
    rows = conn.execute(q, args).fetchall()
    has_more = len(rows) > limit
    rows = rows[:limit]
    items = [_row_content(r) for r in rows]
    next_cursor = None
    if has_more and items:
        last = items[-1]
        next_cursor = f"{last['posted_at']}:{last['id']}"
    return {"items": items, "next_cursor": next_cursor, "has_more": has_more}


def get_content(conn, content_id: int) -> dict | None:
    r = conn.execute(
        f"SELECT {LIST_COLS}, c.text_raw, c.author_name "
        "FROM content c WHERE c.id=?", (content_id,)
    ).fetchone()
    if not r:
        return None
    d = _row_content(r)
    d["text_raw"] = r["text_raw"]
    d["author_name"] = r["author_name"]
    d["target_key"] = r["target_key"]
    d["platform"] = r["platform"]

    # 作者头像：账号快照 detail 里的 avatar（scope=__account__）。
    # 内容与账号是固定对应关系，头像取自该目标最近一条带 avatar 的快照。
    d["author_avatar"] = None
    try:
        snaps = conn.execute(
            "SELECT detail FROM snapshot WHERE target_key=? AND scope='__account__' "
            "AND detail LIKE '%avatar%' ORDER BY captured_at DESC", (r["target_key"],)
        ).fetchall()
        for s in snaps:
            av = (json.loads(s["detail"] or "{}") or {}).get("avatar")
            if av:
                d["author_avatar"] = av.replace("http://", "https://", 1) if av.startswith("http://") else av
                break
    except Exception:
        pass
    media = conn.execute(
        "SELECT seq, remote_url, tier, local_path, bytes, width, height "
        "FROM content_media WHERE content_id=? ORDER BY seq", (content_id,)
    ).fetchall()
    d["media"] = [{
        "seq": m["seq"], "remote_url": m["remote_url"], "tier": m["tier"],
        "local_path": m["local_path"], "bytes": m["bytes"],
        "width": m["width"], "height": m["height"],
        "cached": bool(m["local_path"]),
    } for m in media]
    cms = conn.execute(
        "SELECT comment_id, author_name, author_id, text, likes, replied_by_author, "
        "  liked_by_author, posted_at, state FROM content_comment "
        "WHERE content_id=? ORDER BY "
        "  (replied_by_author OR liked_by_author) DESC, posted_at ASC", (content_id,)
    ).fetchall()
    d["comments"] = [{
        "comment_id": c["comment_id"], "author_name": c["author_name"],
        "author_id": c["author_id"], "text": c["text"], "likes": c["likes"],
        "by_author": bool(c["replied_by_author"]),
        "liked_by_author": bool(c["liked_by_author"]),
        "posted_at": c["posted_at"], "state": c["state"],
    } for c in cms]
    return d


def stats(conn) -> dict:
    """每个目标的归档概况：总数 / 存活 / 已删 / 隐藏 / 图片数 / 字节数。"""
    rows = conn.execute(
        "SELECT target_key, platform, "
        "  COUNT(*) total, "
        "  SUM(CASE WHEN state='alive' THEN 1 ELSE 0 END) alive, "
        "  SUM(CASE WHEN state='deleted' THEN 1 ELSE 0 END) deleted, "
        "  SUM(CASE WHEN state='hidden' THEN 1 ELSE 0 END) hidden "
        "FROM content GROUP BY target_key, platform"
    ).fetchall()
    out = {}
    for r in rows:
        media = conn.execute(
            "SELECT COUNT(*) n, COALESCE(SUM(bytes),0) b FROM content_media m "
            "JOIN content c ON c.id=m.content_id WHERE c.target_key=?", (r["target_key"],)
        ).fetchone()
        out[r["target_key"]] = {
            "platform": r["platform"],
            "total": r["total"], "alive": r["alive"] or 0,
            "deleted": r["deleted"] or 0, "hidden": r["hidden"] or 0,
            "media": media["n"], "media_bytes": media["b"],
        }
    return out
