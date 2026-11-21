"""容器内调度器：按 poll_interval_minutes 周期性巡检。

容器里没有 launchd/cron，所以由本模块承担定时任务。
与 Web 服务跑在同一个进程（entrypoint.sh 启动 webapp.py，
webapp 启动时拉起本调度器），也可以独立运行：

    python scheduler.py
"""
from __future__ import annotations

import signal
import threading
import time
from pathlib import Path

import yaml

from . import config
from . import runner
from .core.store import Store
from .platforms import browser as platforms

ROOT = config.ROOT
CFG = config.CFG
DB = config.DB
PROFILE = platforms.profile_root()
STATE_FILE = config.STATE_FILE

_stop = threading.Event()

# 供 Web 端读取：最近一次调度巡检的结果与时间
_status: dict = {"running": False, "started_at": None, "finished_at": None,
                 "last_result": None, "runs": 0, "errors": 0}


def status() -> dict:
    """最近一次调度巡检的状态快照。"""
    with _status_lock:
        return dict(_status)


_status_lock = threading.Lock()


def _load_cfg() -> dict:
    try:
        with open(CFG, encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except Exception:  # noqa: BLE001
        return {}


def _interval() -> int:
    v = _load_cfg().get("poll_interval_minutes", 60)
    try:
        v = int(v)
    except (TypeError, ValueError):
        v = 60
    return max(5, v)  # 平台对高频访问敏感，下限 5 分钟


def _make_browser(headless: bool = True):
    from .platforms import browser as platforms
    return platforms.Browser(PROFILE, headless=headless, state_file=STATE_FILE)


def tick() -> None:
    cfg = _load_cfg()
    store = Store(DB)
    with _status_lock:
        _status["running"] = True
        _status["started_at"] = int(time.time())
    try:
        res = runner.run_check(cfg, store, browser_factory=_make_browser)
        with _status_lock:
            _status["last_result"] = res
            _status["runs"] += 1
        print(f"[scheduler] 巡检完成：{res['total_events']} 条变更，"
              f"耗时 {res['duration_ms']}ms", flush=True)
        for r in res["results"]:
            icon = "✅" if r["status"] == "ok" else "❌"
            print(f"   {icon} [{r['platform']}] {r['target']} — {r['message']}", flush=True)
        for ch, st in ((res.get("notify") or {}).get("channels") or {}).items():
            if not st.get("ok") and not st.get("skipped"):
                print(f"   ⚠️ 通知[{ch}]发送失败：{st.get('error') or '未知错误'}", flush=True)
    except Exception as e:  # noqa: BLE001
        with _status_lock:
            _status["last_result"] = {"ok": False, "error": f"{type(e).__name__}: {e}"}
            _status["errors"] += 1
        print(f"[scheduler] 巡检异常：{type(e).__name__}: {e}", flush=True)
    finally:
        with _status_lock:
            _status["running"] = False
            _status["finished_at"] = int(time.time())


def loop(run_immediately: bool = True) -> None:
    if run_immediately:
        tick()
    while not _stop.is_set():
        mins = _interval()
        print(f"[scheduler] 下次巡检将在 {mins} 分钟后", flush=True)
        if _stop.wait(mins * 60):
            break
        tick()


def start_background(run_immediately: bool = True) -> threading.Thread:
    t = threading.Thread(target=loop, args=(run_immediately,), daemon=True, name="scheduler")
    t.start()
    return t


def stop() -> None:
    _stop.set()


if __name__ == "__main__":
    def _sig(signum, frame):  # noqa: ARG001
        print("[scheduler] 收到停止信号", flush=True)
        stop()

    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)
    print("[scheduler] 调度器已启动", flush=True)
    loop(run_immediately=True)
