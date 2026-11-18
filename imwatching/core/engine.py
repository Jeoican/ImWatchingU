"""监控引擎：比对快照 → 生成变更事件。"""
from __future__ import annotations

import time
from typing import Any


def _diff_sets(old: set[str], new: set[str]) -> tuple[list[str], list[str], list[str]]:
    added = [x for x in new if x not in old]
    removed = [x for x in old if x not in new]
    kept = [x for x in new if x in old]
    return added, removed, kept


def watch_netease(store, target: dict, data: dict) -> list[dict]:
    """歌单增删比对 + 关注/粉丝数比对。返回事件列表。"""
    target_key = f"netease:{target['id']}"
    opts = target.get("options") or {}
    watch = opts.get("watch_playlists", "all")
    ignore_empty = opts.get("ignore_empty", True)

    events: list[dict] = []
    seen_playlist_ids = {p["id"] for p in data["playlists"]}

    # 关注数 / 粉丝数：对方设隐私时列表读不到，但数字仍然可读，
    # 所以走数值型比对，和微博/抖音一致。
    events.extend(watch_counts(store, target, data,
                               metrics=["followers", "following"]))
    # 记录真实人数，报告里展示（隐私用户也能看到正确数字）
    account_detail = {"nickname": data.get("nickname")}
    if data.get("avatar"):
        account_detail["avatar"] = data["avatar"]
    store.add_snapshot(target_key, "netease", "__account__", "following_total",
                       int(data.get("following") or 0), account_detail)
    store.add_snapshot(target_key, "netease", "__account__", "followers_total",
                       int(data.get("followers") or 0), account_detail)

    # 歌单本身的增删
    known = store.last_snapshot(target_key, "__playlist_set__", "count")
    old_set = set((known or {}).get("detail", {}).get("ids", [])) if known else None

    for p in data["playlists"]:
        pid = p["id"]
        if watch != "all" and pid not in watch:
            continue
        ids = p["track_ids"]
        if ignore_empty and not ids:
            # 仍然记录数量，避免歌单被清空却看不到
            pass

        prev = store.last_snapshot(target_key, pid, "tracks")
        prev_ids = set(prev["detail"].get("track_ids", [])) if prev else None

        track_detail = {"name": p["name"], "track_ids": ids, "songs": p["songs"]}
        if p.get("cover"):
            track_detail["cover"] = p["cover"]

        if prev_ids is None:
            # 首次采集，只建基线，不产生事件
            store.add_snapshot(target_key, "netease", pid, "tracks", len(ids), track_detail)
            continue

        if prev_ids != set(ids):
            added, removed, _ = _diff_sets(prev_ids, set(ids))
            for sid in added:
                s = p["songs"].get(sid, {})
                events.append({
                    "target_key": target_key, "platform": "netease", "scope": pid,
                    "scope_name": p["name"], "event_type": "track_added",
                    "item_type": "song", "item_id": sid, "item_name": s.get("name"),
                    "item_extra": {"artists": s.get("artists"), "album": s.get("album")},
                })
            for sid in removed:
                s = p["songs"].get(sid) or (prev["detail"].get("songs") or {}).get(sid) or {}
                events.append({
                    "target_key": target_key, "platform": "netease", "scope": pid,
                    "scope_name": p["name"], "event_type": "track_removed",
                    "item_type": "song", "item_id": sid, "item_name": s.get("name"),
                    "item_extra": {"artists": s.get("artists"), "album": s.get("album")},
                })
            store.add_snapshot(target_key, "netease", pid, "tracks", len(ids), track_detail)
        else:
            # 歌曲没变也更新快照，这样歌单里的歌曲列表始终是最新的
            store.add_snapshot(target_key, "netease", pid, "tracks", len(ids), track_detail)

    # 歌单集合增删
    if old_set is not None:
        new_set = seen_playlist_ids
        names = {p["id"]: p["name"] for p in data["playlists"]}
        for pid in [x for x in new_set if x not in old_set]:
            events.append({
                "target_key": target_key, "platform": "netease", "scope": "__playlist_set__",
                "event_type": "playlist_added", "item_type": "playlist",
                "item_id": pid, "item_name": names.get(pid),
            })
        for pid in [x for x in old_set if x not in new_set]:
            events.append({
                "target_key": target_key, "platform": "netease", "scope": "__playlist_set__",
                "event_type": "playlist_removed", "item_type": "playlist",
                "item_id": pid, "item_name": None,
            })
    store.add_snapshot(target_key, "netease", "__playlist_set__", "count",
                       len(seen_playlist_ids), {"ids": sorted(seen_playlist_ids),
                                                "names": {p["id"]: p["name"] for p in data["playlists"]}})
    return events


def watch_counts(store, target: dict, data: dict, metrics: list[str] | None = None) -> list[dict]:
    """粉丝/关注等数值型指标比对，适用于微博/抖音/小红书。"""
    platform = data["kind"]
    target_key = f"{platform}:{target['id']}"
    metrics = metrics or (target.get("options") or {}).get("metrics") or ["followers", "following"]

    events: list[dict] = []
    account_detail = {"nickname": data.get("nickname")}
    if data.get("avatar"):
        account_detail["avatar"] = data["avatar"]
    for metric in metrics:
        val = data.get(metric)
        if val is None:
            continue
        prev = store.last_snapshot(target_key, "__account__", metric)
        store.add_snapshot(target_key, platform, "__account__", metric, int(val),
                           account_detail)
        if prev is None:
            continue
        delta = int(val) - int(prev["value"])
        if delta == 0:
            continue
        events.append({
            "target_key": target_key, "platform": platform, "scope": "__account__",
            "scope_name": data.get("nickname"),
            "event_type": "count_up" if delta > 0 else "count_down",
            "item_type": "count", "item_id": metric, "item_name": _metric_label(metric),
            "item_extra": {"before": prev["value"], "after": int(val)},
            "delta": delta,
        })
    return events


def watch_people(store, target: dict, kind: str, data: dict) -> list[dict]:
    """关注/粉丝列表比对 —— 精确到人。

    kind: "following"（该账号关注了谁）或 "followers"（谁关注了该账号）
    data: {"users": [{"id":..., "name":...}], "note":..., "complete":...}
    """
    platform = target["platform"]
    target_key = f"{platform}:{target['id']}"
    scope = "__following__" if kind == "following" else "__followers__"
    events: list[dict] = []

    prev = store.last_snapshot(target_key, scope, "people")
    old = {u["id"]: u.get("name") for u in (prev or {}).get("detail", {}).get("users", [])}
    new = {u["id"]: u.get("name") for u in data["users"]}

    added = [uid for uid in new if uid not in old]
    removed = [uid for uid in old if uid not in new]

    if prev is None:
        # 首次只建基线
        store.add_snapshot(target_key, platform, scope, "people", len(new),
                           {"users": data["users"], "note": data.get("note"),
                            "complete": data.get("complete")})
        return []

    for uid in added:
        events.append({
            "target_key": target_key, "platform": platform, "scope": scope,
            "scope_name": data.get("nickname"),
            "event_type": "person_follow_added" if kind == "following" else "person_fan_added",
            "item_type": "person", "item_id": uid, "item_name": new[uid],
            "item_extra": {"direction": kind, "note": data.get("note")},
        })
    for uid in removed:
        events.append({
            "target_key": target_key, "platform": platform, "scope": scope,
            "scope_name": data.get("nickname"),
            "event_type": "person_follow_removed" if kind == "following" else "person_fan_removed",
            "item_type": "person", "item_id": uid, "item_name": old[uid],
            "item_extra": {"direction": kind, "note": data.get("note")},
        })

    store.add_snapshot(target_key, platform, scope, "people", len(new),
                       {"users": data["users"], "note": data.get("note"),
                        "complete": data.get("complete")})
    return events


_METRIC_LABELS = {
    "followers": "粉丝数", "following": "关注数",
    "posts": "微博数", "works": "作品数", "likes": "获赞数", "notes": "笔记数",
}


def _metric_label(m: str) -> str:
    return _METRIC_LABELS.get(m, m)
