"""存储层：SQLite 快照 + 变更日志。"""
from __future__ import annotations

import json
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS snapshot (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    target_key    TEXT NOT NULL,           -- 例如 netease:1738363959
    platform      TEXT NOT NULL,
    scope         TEXT NOT NULL,           -- 歌单 id / 账号标识，歌单类用 playlist id
    metric        TEXT NOT NULL,           -- followers / following / tracks
    value         INTEGER NOT NULL,
    detail        TEXT,                    -- JSON：歌单名、昵称等
    captured_at   INTEGER NOT NULL         -- unix 秒
);
CREATE INDEX IF NOT EXISTS idx_snap_lookup ON snapshot(target_key, scope, metric, captured_at);

CREATE TABLE IF NOT EXISTS event (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    target_key    TEXT NOT NULL,
    platform      TEXT NOT NULL,
    scope         TEXT NOT NULL,
    scope_name    TEXT,
    event_type    TEXT NOT NULL,           -- track_added / track_removed / count_up / count_down / playlist_added / playlist_removed
    item_type     TEXT NOT NULL,           -- song / count / playlist
    item_id       TEXT,
    item_name     TEXT,
    item_extra    TEXT,                    -- JSON：歌手、专辑、数字变化前后
    delta         INTEGER,
    detected_at   INTEGER NOT NULL,
    UNIQUE(target_key, scope, event_type, item_id, detected_at)
);
CREATE INDEX IF NOT EXISTS idx_event_time ON event(detected_at DESC);

CREATE TABLE IF NOT EXISTS run_log (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    target_key    TEXT NOT NULL,
    platform      TEXT NOT NULL,
    status        TEXT NOT NULL,           -- ok / error / skipped
    message       TEXT,
    duration_ms   INTEGER,
    ran_at        INTEGER NOT NULL
);
"""


class Store:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._conn() as c:
            c.executescript(SCHEMA)

    @contextmanager
    def _conn(self):
        conn = sqlite3.connect(self.path, timeout=30)
        conn.row_factory = sqlite3.Row
        # WAL 模式：读写不互斥。容器里数据目录常挂在 bind mount 上，
        # 默认的 rollback journal 模式在并发读写时容易报 "database is locked"。
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=NORMAL")
            conn.execute("PRAGMA busy_timeout=30000")
        except sqlite3.Error:
            pass
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    # ---------- 快照 ----------
    def last_snapshot(self, target_key: str, scope: str, metric: str) -> dict | None:
        """取最新快照。

        detail 可能因为去重（见 add_snapshot）而存成 NULL，此时回溯最近一条
        带 detail 的记录——内容相同，语义等价。
        """
        with self._conn() as c:
            row = c.execute(
                "SELECT id, value, detail, captured_at FROM snapshot "
                "WHERE target_key=? AND scope=? AND metric=? "
                "ORDER BY captured_at DESC, id DESC LIMIT 1",
                (target_key, scope, metric),
            ).fetchone()
            if not row:
                return None
            detail = row["detail"]
            if detail is None:
                detail_row = c.execute(
                    "SELECT detail FROM snapshot "
                    "WHERE target_key=? AND scope=? AND metric=? AND detail IS NOT NULL "
                    "ORDER BY captured_at DESC, id DESC LIMIT 1",
                    (target_key, scope, metric),
                ).fetchone()
                detail = detail_row["detail"] if detail_row else None
        return {
            "value": row["value"],
            "detail": json.loads(detail) if detail else {},
            "captured_at": row["captured_at"],
        }

    def add_snapshot(self, target_key: str, platform: str, scope: str, metric: str,
                     value: int, detail: dict | None = None) -> None:
        """写快照。

        detail 与上一次完全相同时只写 value、detail 存 NULL —— 歌单歌曲表
        这类 detail 单份可达 90KB，而内容往往几十轮都不变，每轮重写会让
        库里绝大部分体积都是同一份数据的副本（实测冗余占 96%）。
        读取侧 last_snapshot 会自动回溯最近的非空 detail，语义不变。
        """
        payload = json.dumps(detail, ensure_ascii=False, sort_keys=True) if detail else None
        with self._conn() as c:
            if payload is not None:
                prev = c.execute(
                    "SELECT detail FROM snapshot "
                    "WHERE target_key=? AND scope=? AND metric=? AND detail IS NOT NULL "
                    "ORDER BY captured_at DESC, id DESC LIMIT 1",
                    (target_key, scope, metric),
                ).fetchone()
                if prev and prev["detail"] == payload:
                    payload = None
            c.execute(
                "INSERT INTO snapshot(target_key, platform, scope, metric, value, detail, captured_at) "
                "VALUES(?,?,?,?,?,?,?)",
                (target_key, platform, scope, metric, int(value), payload, int(time.time())),
            )

    # ---------- 事件 ----------
    def add_events(self, events: list[dict]) -> int:
        """批量写入事件，detected_at 相同则去重。返回实际新增条数。"""
        if not events:
            return 0
        now = int(time.time())
        inserted = 0
        with self._conn() as c:
            for e in events:
                try:
                    c.execute(
                        "INSERT INTO event(target_key, platform, scope, scope_name, event_type, "
                        "item_type, item_id, item_name, item_extra, delta, detected_at) "
                        "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                        (e["target_key"], e["platform"], e["scope"], e.get("scope_name"),
                         e["event_type"], e["item_type"], e.get("item_id"), e.get("item_name"),
                         json.dumps(e.get("item_extra") or {}, ensure_ascii=False),
                         e.get("delta"), e.get("detected_at", now)),
                    )
                    inserted += 1
                except sqlite3.IntegrityError:
                    pass
        return inserted

    def recent_events(self, limit: int = 50, target_key: str | None = None) -> list[dict]:
        q = "SELECT * FROM event"
        args: list = []
        if target_key:
            q += " WHERE target_key=?"
            args.append(target_key)
        q += " ORDER BY detected_at DESC, id DESC LIMIT ?"
        args.append(limit)
        with self._conn() as c:
            rows = c.execute(q, args).fetchall()
        out = []
        for r in rows:
            d = dict(r)
            d["item_extra"] = json.loads(d["item_extra"]) if d["item_extra"] else {}
            out.append(d)
        return out

    def event_counts(self, target_key: str, days: int = 7) -> dict[str, int]:
        since = int(time.time()) - days * 86400
        with self._conn() as c:
            rows = c.execute(
                "SELECT event_type, COUNT(*) n FROM event "
                "WHERE target_key=? AND detected_at>=? GROUP BY event_type",
                (target_key, since),
            ).fetchall()
        return {r["event_type"]: r["n"] for r in rows}

    def daily_series(self, target_key: str, scope: str, metric: str, days: int = 30) -> list[dict]:
        """每天取该指标最后一次快照，用于折线图。"""
        since = int(time.time()) - days * 86400
        with self._conn() as c:
            rows = c.execute(
                "SELECT value, captured_at FROM snapshot "
                "WHERE target_key=? AND scope=? AND metric=? AND captured_at>=? "
                "ORDER BY captured_at ASC",
                (target_key, scope, metric, since),
            ).fetchall()
        daily: dict[str, int] = {}
        for r in rows:
            day = time.strftime("%Y-%m-%d", time.localtime(r["captured_at"]))
            daily[day] = r["value"]
        return [{"date": k, "value": v} for k, v in daily.items()]

    def latest_scopes(self, target_key: str, metric: str) -> list[dict]:
        """取该目标下每个 scope 的最新快照（用于统计歌单数、歌曲总数等）。

        detail 可能因为去重而存成 NULL，这里用一条 SQL 关联出「每 scope
        最新一条带 detail 的记录」，避免逐行二次查询。
        """
        with self._conn() as c:
            rows = c.execute(
                "WITH latest AS ("
                "  SELECT scope, MAX(captured_at) mx FROM snapshot"
                "  WHERE target_key=? AND metric=? GROUP BY scope"
                "), top AS ("
                "  SELECT s.scope, s.value, s.captured_at, s.detail, s.id,"
                "         ROW_NUMBER() OVER (PARTITION BY s.scope ORDER BY s.id DESC) rn"
                "  FROM snapshot s JOIN latest m"
                "    ON s.scope=m.scope AND s.captured_at=m.mx"
                "  WHERE s.target_key=? AND s.metric=?"
                "), det AS ("
                "  SELECT scope, detail FROM ("
                "    SELECT scope, detail, ROW_NUMBER() OVER (PARTITION BY scope ORDER BY id DESC) rn"
                "    FROM snapshot WHERE target_key=? AND metric=? AND detail IS NOT NULL"
                "  ) WHERE rn=1"
                ") "
                "SELECT t.scope, t.value, t.captured_at, COALESCE(t.detail, d.detail) detail"
                " FROM (SELECT * FROM top WHERE rn=1) t"
                " LEFT JOIN det d ON d.scope = t.scope",
                (target_key, metric, target_key, metric, target_key, metric),
            ).fetchall()
        out = []
        for r in rows:
            out.append({
                "scope": r["scope"],
                "value": r["value"],
                "detail": json.loads(r["detail"]) if r["detail"] else {},
                "captured_at": r["captured_at"],
            })
        return out

    # ---------- 运行日志 ----------
    def log_run(self, target_key: str, platform: str, status: str,
                message: str = "", duration_ms: int = 0) -> None:
        with self._conn() as c:
            c.execute(
                "INSERT INTO run_log(target_key, platform, status, message, duration_ms, ran_at) "
                "VALUES(?,?,?,?,?,?)",
                (target_key, platform, status, message[:2000], duration_ms, int(time.time())),
            )

    def last_runs(self, limit: int = 20) -> list[dict]:
        with self._conn() as c:
            rows = c.execute(
                "SELECT * FROM run_log ORDER BY ran_at DESC LIMIT ?", (limit,)
            ).fetchall()
        return [dict(r) for r in rows]
