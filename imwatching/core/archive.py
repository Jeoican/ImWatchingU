"""内容归档：把社媒原帖、配图、评论永久留档。

设计要点
--------
1. 只增不删。`content` 表按 (target_key, platform, post_id) 唯一，写入后永不
   物理删除。平台上删帖时只改 `state`，存档正文与评论全部保留。
2. 三态而非两态。`state` 取 alive / deleted / hidden：
     alive   平台仍可见
     deleted 确认已删除（微博 /ajax/statuses/show 返回 error_code=20101）
     hidden  抓取窗口之外，无法判定存活——微博 mymblog 有硬上限
             （实测 statuses_count=90 但只有前 45 条可翻），第 46 条起属此类。
   若不区分 hidden 与 deleted，会把"抓不到"误报成"被删了"。
3. 原图落盘。图片存文件系统而非 SQLite：微博单张原图 4126×5556 达 4.6MB，
   塞进库会让每次查询都被拖慢。库里只存相对路径与体积。
4. 评论按需抓。只保留作者互动过的评论（作者本人回复 / 作者点赞 / 作者回复
   之下的追评），其余不入库——一条热门微博可有 725 条评论，全抓必触发风控。
"""
from __future__ import annotations

import hashlib
import json
import sqlite3
import time
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS content (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    target_key    TEXT NOT NULL,
    platform      TEXT NOT NULL,
    post_id       TEXT NOT NULL,
    url           TEXT,
    author_name   TEXT,
    text          TEXT,
    text_raw      TEXT,                    -- 原始 HTML（含表情），存档保真用
    posted_at     INTEGER,
    first_seen_at INTEGER NOT NULL,
    last_seen_at  INTEGER NOT NULL,
    state         TEXT NOT NULL DEFAULT 'alive',   -- alive / deleted / hidden
    state_at      INTEGER,
    state_note    TEXT,
    likes         INTEGER,
    comments_count INTEGER,
    reposts       INTEGER,
    images_total  INTEGER,
    video         INTEGER DEFAULT 0,
    retweet_text  TEXT,
    UNIQUE(target_key, platform, post_id)
);
CREATE INDEX IF NOT EXISTS idx_content_list
    ON content(target_key, posted_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_content_state ON content(state, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS content_media (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    content_id    INTEGER NOT NULL,
    seq           INTEGER NOT NULL,
    remote_url    TEXT,
    tier          TEXT,                    -- original / large / bmiddle
    local_path    TEXT,                    -- 相对 data/archive 的路径
    bytes         INTEGER,
    width         INTEGER,
    height        INTEGER,
    sha256        TEXT,
    fetched_at    INTEGER,
    UNIQUE(content_id, seq)
);
CREATE INDEX IF NOT EXISTS idx_media_content ON content_media(content_id, seq);

CREATE TABLE IF NOT EXISTS content_comment (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    content_id    INTEGER NOT NULL,
    comment_id    TEXT NOT NULL,
    author_name   TEXT,
    author_id     TEXT,
    text          TEXT,
    text_raw      TEXT,
    likes         INTEGER,
    replied_by_author INTEGER DEFAULT 0,   -- 作者本人回复过这条
    liked_by_author   INTEGER DEFAULT 0,   -- 作者点赞过这条
    posted_at     INTEGER,
    first_seen_at INTEGER NOT NULL,
    state         TEXT NOT NULL DEFAULT 'alive',
    state_at      INTEGER,
    UNIQUE(content_id, comment_id)
);
CREATE INDEX IF NOT EXISTS idx_comment_content ON content_comment(content_id, posted_at);
"""

STATE_ALIVE, STATE_DELETED, STATE_HIDDEN = "alive", "deleted", "hidden"


def connect(db_path: str | Path):
    """打开连接（幂等建表）。与 Store 共用同一个库文件。

    调度器可能正在同一库上写快照，所以这里必须：
      1. WAL 模式 —— 读写不互斥，避免巡检与 Web 请求互相阻塞；
      2. busy_timeout —— 抢不到锁时等待而不是立刻抛 "database is locked"；
      3. isolation_level=None（自动提交）—— 归档采集是长循环，若包在一个
         大事务里，整轮十几分钟都持锁，Web 查询会全部超时。
    """
    conn = sqlite3.connect(db_path, timeout=30, isolation_level=None)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        conn.execute("PRAGMA busy_timeout=30000")
    except sqlite3.Error:
        pass
    conn.executescript(SCHEMA)
    return conn


# ------------------------------------------------------------------ 媒体落盘
def media_path(root: Path, target_key: str, post_id: str, seq: int, ext: str = ".jpg") -> Path:
    """媒体文件路径：data/archive/<target>/<post_id>/<seq><ext>。

    按帖子分目录，便于单帖整体迁移/导出，也避免十万级文件挤在一个目录下。
    """
    safe_target = target_key.replace(":", "_").replace("/", "_")
    safe_post = "".join(ch for ch in str(post_id) if ch.isalnum() or ch in "-_") or "unknown"
    d = root / safe_target / safe_post
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{seq:02d}{ext}"


def sniff_ext(data: bytes) -> str:
    """按魔数判扩展名——微博部分图返回 webp，硬编码 .jpg 会让浏览器不解码。"""
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return ".webp"
    if data[:3] == b"\xff\xd8\xff":
        return ".jpg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return ".png"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return ".gif"
    if data[4:8] == b"ftyp":  # ISOBMFF：HEIC / HEIF / AVIF
        return ".heic"
    return ".jpg"


def save_media(root: Path, target_key: str, post_id: str, seq: int, data: bytes) -> dict:
    """把一张图写盘并返回元信息。同名同内容不重复写。"""
    ext = sniff_ext(data)
    p = media_path(root, target_key, post_id, seq, ext)
    digest = hashlib.sha256(data).hexdigest()
    existed = p.exists() and p.stat().st_size == len(data)
    if not existed:
        tmp = p.with_suffix(p.suffix + ".part")
        tmp.write_bytes(data)
        tmp.replace(p)
    return {
        "local_path": str(p),
        "bytes": len(data),
        "sha256": digest,
        "ext": ext,
        "skipped": existed,
    }


# ------------------------------------------------------------------ 写入
def upsert_content(conn, target_key: str, platform: str, post: dict,
                   state: str = STATE_ALIVE, state_note: str | None = None) -> int:
    """写入或刷新一条内容，返回 content.id。

    已存在的记录只更新互动数、last_seen_at 与 state——正文和 posted_at 一旦
    落库就不再改写，保证存档是"当时看到的样子"。
    """
    now = int(time.time())
    post_id = str(post.get("id") or "")
    if not post_id:
        return 0
    row = conn.execute(
        "SELECT id FROM content WHERE target_key=? AND platform=? AND post_id=?",
        (target_key, platform, post_id),
    ).fetchone()
    if row:
        cid = row["id"]
        # 作者名是元数据，不是"当时看到的样子"：历史数据可能为空（小红书采集器
        # 旧版恒写 None），一旦采集器能拿到昵称就补上，但不覆盖已有的值。
        author_name = post.get("author_name")
        conn.execute(
            "UPDATE content SET last_seen_at=?, state=?, state_at=?, state_note=?, "
            "  likes=COALESCE(?,likes), comments_count=COALESCE(?,comments_count), "
            "  reposts=COALESCE(?,reposts), state=CASE WHEN ?='alive' THEN 'alive' ELSE state END, "
            "  author_name=COALESCE(author_name, ?) "
            "WHERE id=?",
            (now, state if state == STATE_ALIVE else state,
             now if state != STATE_ALIVE else None, state_note,
             post.get("likes"), post.get("comments_count"), post.get("reposts"),
             state, author_name, cid),
        )
        return cid
    conn.execute(
        "INSERT INTO content(target_key, platform, post_id, url, author_name, text, text_raw, "
        "  posted_at, first_seen_at, last_seen_at, state, state_at, state_note, likes, "
        "  comments_count, reposts, images_total, video, retweet_text) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (target_key, platform, post_id, post.get("url"), post.get("author_name"),
         post.get("text"), post.get("text_raw"), post.get("at"),
         now, now, state, now if state != STATE_ALIVE else None, state_note,
         post.get("likes"), post.get("comments_count"), post.get("reposts"),
         post.get("images_total"), 1 if post.get("video") else 0,
         post.get("retweet")),
    )
    return conn.execute("SELECT last_insert_rowid() AS id").fetchone()["id"]


def mark_deleted(conn, target_key: str, platform: str, post_id: str,
                 note: str = "平台已删除") -> bool:
    """把一条内容标记为已删除（存档保留）。返回是否命中记录。"""
    now = int(time.time())
    r = conn.execute(
        "UPDATE content SET state=?, state_at=?, state_note=? "
        "WHERE target_key=? AND platform=? AND post_id=? AND state != ?",
        (STATE_DELETED, now, note, target_key, platform, post_id, STATE_DELETED),
    )
    return bool(r.rowcount)


def mark_hidden(conn, target_key: str, platform: str, post_id: str,
                note: str = "超出可抓范围") -> None:
    """抓取窗口之外（无法判活）：只标记，不当作删除。"""
    conn.execute(
        "UPDATE content SET state=? WHERE target_key=? AND platform=? AND post_id=? AND state=?",
        (STATE_HIDDEN, target_key, platform, post_id, STATE_ALIVE),
    )


def upsert_media(conn, content_id: int, seq: int, remote_url: str, tier: str,
                 saved: dict | None = None) -> None:
    """登记一张配图。saved 为 None 表示"仅登记远程地址，尚未下载"。

    这里刻意不用 COALESCE 保留旧值：调用方的语义就是"用这次的状态覆盖"——
    传 None 是"还没下"（下一轮会补），传 saved 是"下好了"。
    若反过来用 COALESCE，历史遗留的脏宽高会永久覆盖掉新下载的正确值。
    """
    conn.execute(
        "INSERT INTO content_media(content_id, seq, remote_url, tier, local_path, bytes, "
        "  sha256, fetched_at) VALUES(?,?,?,?,?,?,?,?) "
        "ON CONFLICT(content_id, seq) DO UPDATE SET "
        "  remote_url=excluded.remote_url, tier=excluded.tier, "
        "  local_path=excluded.local_path, bytes=excluded.bytes, "
        "  sha256=excluded.sha256, fetched_at=excluded.fetched_at",
        (content_id, seq, remote_url, tier,
         (saved or {}).get("local_path"), (saved or {}).get("bytes"),
         (saved or {}).get("sha256"), int(time.time()) if saved else None),
    )


def upsert_comment(conn, content_id: int, c: dict) -> None:
    now = int(time.time())
    conn.execute(
        "INSERT INTO content_comment(content_id, comment_id, author_name, author_id, text, "
        "  text_raw, likes, replied_by_author, liked_by_author, posted_at, first_seen_at) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?) "
        "ON CONFLICT(content_id, comment_id) DO UPDATE SET "
        "  likes=COALESCE(excluded.likes, content_comment.likes), "
        "  replied_by_author=MAX(excluded.replied_by_author, content_comment.replied_by_author), "
        "  liked_by_author=MAX(excluded.liked_by_author, content_comment.liked_by_author)",
        (content_id, str(c["comment_id"]), c.get("author_name"), c.get("author_id"),
         c.get("text"), c.get("text_raw"), c.get("likes"),
         1 if c.get("replied_by_author") else 0, 1 if c.get("liked_by_author") else 0,
         c.get("posted_at"), now),
    )
