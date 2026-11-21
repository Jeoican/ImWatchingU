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

#: 访问鉴权的 token 清单（只存 sha256，明文仅在签发时出现一次）。
#: 放在 data/ 下因为它属于运行状态而非配置；data/ 已 gitignore。
#: 用 SW_AUTH_FILE 可指向别处（比如挂到宿主机便于用 CLI 管理）。
AUTH_FILE = DATA / "auth.json"

#: 内容归档的图片根目录。原图单张可达 4.6MB，必须落在文件系统而非 SQLite，
#: 否则每次查询都会被大 BLOB 拖慢。按 <target>/<post_id>/<seq>.jpg 分目录存放。
ARCHIVE = DATA / "archive"


def archive_root() -> Path:
    """归档媒体根目录，可用 SW_ARCHIVE_ROOT 覆盖（便于把图片放独立磁盘）。"""
    root = os.environ.get("SW_ARCHIVE_ROOT", "").strip()
    p = Path(root) if root else ARCHIVE
    p.mkdir(parents=True, exist_ok=True)
    return p

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


def auth_file() -> Path:
    """鉴权 token 清单路径，可用 SW_AUTH_FILE 覆盖。"""
    p = os.environ.get("SW_AUTH_FILE", "").strip()
    return Path(p) if p else AUTH_FILE


def public_base_url() -> str:
    """对外可访问的基址（如 https://sw.example.com），用于生成分享链接。

    留空则返回空串，调用方自行回落到请求头推断。
    """
    return os.environ.get("SW_PUBLIC_BASE_URL", "").strip().rstrip("/")
