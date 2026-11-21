"""巡检执行器：CLI、Web、调度器共用同一套逻辑。

把原来 cli.cmd_check 里的流程抽出来，返回结构化结果，
便于 Web 端渲染成 JSON，而不是解析终端输出。
"""
from __future__ import annotations

import threading
import time
from pathlib import Path

from .core.store import Store
from . import notify
from .platforms import browser as platforms

# 全局锁：调度器与手动触发可能同时到来，浏览器 profile 不能并发使用
_check_lock = threading.Lock()


def need_browser(targets: list[dict]) -> bool:
    for t in targets:
        if t["platform"] != "netease":
            return True
        if "followers" in ((t.get("options") or {}).get("people") or []):
            return True
    return False


def run_check(cfg: dict, store: Store, target_filter: str | None = None,
              browser_factory=None) -> dict:
    """跑一轮巡检。

    target_filter: 只跑名字或 id 匹配的目标
    browser_factory: 返回 Browser 上下文的工厂，默认用 cli.make_browser
    """
    if browser_factory is None:
        from . import cli
        browser_factory = cli.make_browser

    targets = [t for t in (cfg.get("targets") or []) if t.get("enabled")]
    if target_filter:
        # 支持按 name / id / 精确 key（platform:id）过滤
        def _match(t):
            key = f"{t.get('platform')}:{t.get('id')}"
            return target_filter in (t.get("name"), t.get("id"), key)
        targets = [t for t in targets if _match(t)]

    results: list[dict] = []
    total_events = 0
    started = time.time()

    with _check_lock:
        box: dict = {}
        try:
            if need_browser(targets):
                box["browser"] = browser_factory(
                    headless=cfg.get("browser_headless", True)).__enter__()
            for t in targets:
                from .cli import check_one
                status, msg, events = check_one(store, t, box)
                total_events += len(events)
                results.append({
                    "target": t.get("name") or t["id"],
                    "platform": t["platform"],
                    "id": t["id"],
                    "status": status,
                    "message": msg,
                    "events": events,
                })
        finally:
            if "browser" in box:
                try:
                    box["browser"].__exit__(None, None, None)
                except Exception:  # noqa: BLE001
                    pass

    result = {
        "ok": True,
        "finished_at": int(time.time()),
        "duration_ms": int((time.time() - started) * 1000),
        "total_events": total_events,
        "results": results,
    }
    # 通知失败不能影响巡检结果，dispatch 内部已吞掉所有异常。
    # 放在这里而不是调度器里，定时巡检、网页手动巡检都会自动推送。
    result["notify"] = notify.dispatch(cfg, results)
    return result


def check_is_running() -> bool:
    return _check_lock.locked()
