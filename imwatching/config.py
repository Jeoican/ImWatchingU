"""统一的项目路径解析。

原先各模块各自用 ``Path(__file__).resolve().parent`` 定位配置与数据目录，
但包化之后模块分散在不同子目录里，各自的 parent 并不指向项目根目录。
这里集中定义一次，所有模块都从这里取路径。

项目根目录 = 本文件所在包的上一级（即包含 imwatching/ 的那一层）。
"""
from __future__ import annotations

import os
from pathlib import Path

# imwatching/config.py -> imwatching/ -> 项目根目录
ROOT = Path(__file__).resolve().parent.parent

#: 配置文件：容器内挂载到 /app/config.yaml
CFG = ROOT / "config.yaml"

#: 数据目录：数据库、登录态、浏览器 profile 都在这里
DATA = ROOT / "data"

#: SQLite 数据库
DB = DATA / "watch.db"

#: 登录态（storage state），供浏览器会话注入
STATE_FILE = DATA / "state.json"

#: 看板前端页面
PAGE = ROOT / "web" / "index.html"

#: 静态报表输出位置
REPORT_HTML = ROOT / "report.html"


def profile_root() -> Path:
    """浏览器 profile 的根目录。

    容器与宿主机必须使用不同的根目录：两边共用同一个目录时，
    Linux Chromium 会覆写 macOS 的 profile（cookie 加密格式不同），
    结果是登录态被清空、两边互相破坏。
    通过 SW_PROFILE_ROOT 环境变量切换即可。
    """
    root = os.environ.get("SW_PROFILE_ROOT", "").strip()
    return Path(root) if root else DATA / "browser"


def profile_path(name: str) -> Path:
    """取某个用途独立的 profile 目录（status / resolve / login / retry）。

    同一个浏览器 profile 不能被两个进程同时打开，所以每种用途各用一份。
    """
    return profile_root() / name if name else profile_root()


def ensure_data_dir() -> Path:
    """确保数据目录存在并返回它。"""
    DATA.mkdir(parents=True, exist_ok=True)
    return DATA
