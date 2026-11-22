"""小红书原图回填：把已归档的 CDN 压缩档升级成真原图。

问题背景
----------
小红书详情页给的 `urlDefault` 指向 sns-webpic-qc 的
`!nd_dft_wlteh_webp_3` 处理档 —— CDN 已经按 1080 宽重新编码过：

    压缩档（webpic）→ 1080×1440，约 186KB
    真原图（ci）    → 4284×5712，约 4.4MB

像素差 4 倍、字节差 24 倍。归档时如果原图直链没取到，会**静默**回退到
压缩档，于是用户看到的就是「内容库里的图下载下来不如 App 里清晰」。

本模块把已经落盘成压缩档的历史数据重新抓成原图：

    存量 remote_url → 反推原图 fileId → ci.xiaohongshu.com/{fileId}
                    → 下载 → HEIC 同像素转 JPEG → 落盘 → 改写 DB

fileId 的坑
-----------
原图直链的 fileId **必须带目录前缀**（`notes_pre_post/xxx`、
`notes_uhdr/xxx`、`note_pre_post_uhdr/xxx`）。实测：

    https://ci.xiaohongshu.com/notes_pre_post/1040g3k831v8p5op5ii704a580654utjki6fo060
        → 200  5.1MB  4284×5712
    https://ci.xiaohongshu.com/1040g3k831v8p5op5ii704a580654utjki6fo060
        → 404

而 webpic 地址里的目录段是 `notes_pre_post/1040g3k83...` 这种形式，
第一版实现按「日期/hash 后面的整段」切，恰好能保留前缀；但也有一批地址
是 `.../<日期>/<hash>/1040g2sg31qtpu4pi001g4a580654utjk2qjlv9o`（无目录段，
直接就是 fileId），这种反推同样成立。所以规则统一为：

    从 webpic URL 取「最后一段有效路径」，保留其中的斜杠

两种形态都覆盖，且带前缀的不会被截断。
"""
from __future__ import annotations

import re
import time
import urllib.request
from pathlib import Path

from . import archive as arc

_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")

# 原图通道的 host。主通道 ci.xiaohongshu.com，备用 sns-img-bd.xhscdn.com。
_ORIGIN_HOSTS = ("https://ci.xiaohongshu.com/", "https://sns-img-bd.xhscdn.com/")

# webpic 处理档的 URL 形态：
#   https://sns-webpic-qc.xhscdn.com/<日期>/<hash>/<fileId>!<处理参数>
# <fileId> 里可能带目录前缀（notes_pre_post/xxx），可能不带（1040g2sg31...）。
_WEBPIC_RE = re.compile(
    r"^https?://sns-webpic-[a-z]+\.xhscdn\.com/[^/]+/[^/]+/(.+)$", re.I)

# 已经是原图直链的情况
_ORIGIN_RE = re.compile(
    r"^https?://(?:ci\.xiaohongshu\.com|sns-img-bd\.xhscdn\.com)/(.+)$", re.I)

# CDN 的 imageView2 转码通道：把 HEIC 转成**同像素**的 JPEG。
# /2 = 第二版参数，/w/0 = 不缩放，/format/jpg = 输出 JPEG，/q/95 = 质量。
#
# 只对 HEIC 用：对本来就是 JPEG/PNG 的原图加这个会触发二次有损重编码。
# 实测 HEIC 原图 2.9MB → 转码后 5.1MB，像素完全一致（4284×5712）。
_JPEG_CONVERT_SUFFIX = "imageView2/2/w/0/format/jpg/q/95"

# 单张原图最大下载量。实测最大的一张小红书原图是 22.7MB（PNG），
# 留一倍余量；超过就判定为异常响应，不落盘。
_MAX_BYTES = 64 * 1024 * 1024


def _referer(platform: str) -> str:
    return {"xiaohongshu": "https://www.xiaohongshu.com/",
            "weibo": "https://weibo.com/"}.get(platform, "https://www.xiaohongshu.com/")


def _http_get(url: str, referer: str, timeout: int = 40) -> bytes | None:
    """下载一个 URL，失败返回 None。超过 _MAX_BYTES 视为异常响应丢弃。"""
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": _UA,
            "Referer": referer,
            "Accept": "image/webp,image/jpeg,image/png,image/*,*/*",
        })
        with urllib.request.urlopen(req, timeout=timeout) as r:
            declared = r.headers.get("Content-Length")
            if declared and int(declared) > _MAX_BYTES:
                return None
            data = r.read(_MAX_BYTES + 1)
            if len(data) > _MAX_BYTES:
                return None
            return data or None
    except Exception:  # noqa: BLE001
        return None


def is_heif(data: bytes) -> bool:
    """是不是 HEIF/HEIC 家族（ISOBMFF 容器，Pillow / ImageIO 解不了）。"""
    if len(data) < 12 or data[4:8] != b"ftyp":
        return False
    return data[8:12][:3] in (b"hei", b"hev", b"mif", b"mia", b"msf")


def origin_candidates(remote_url: str) -> list[str]:
    """从一条 webpic 地址反推出原图直链候选（按优先级）。

    返回空列表表示这条地址推不出原图（比如已经是 CDN 压缩档的
    短地址、或地址形态未知），调用方应保持现状不重下。
    """
    u = (remote_url or "").strip()
    if not u:
        return []
    fid = ""
    m = _WEBPIC_RE.match(u)
    if m:
        # 去掉 ! 之后的处理参数，保留目录前缀里的斜杠
        fid = m.group(1).split("!")[0].strip("/")
    else:
        m = _ORIGIN_RE.match(u)
        if m:
            fid = m.group(1).split("?")[0].strip("/")
            # 已经是原图直链，去掉 imageView2 转码参数
            fid = fid.split("!")[0].strip("/")
    if not fid:
        return []
    return [h + fid for h in _ORIGIN_HOSTS]


def fetch_original(remote_url: str, platform: str = "xiaohongshu",
                    timeout: int = 40) -> tuple[bytes | None, str]:
    """取一张图的原图字节，返回 (数据, 实际用到的 URL)。

    HEIC 原图会被 CDN 的 imageView2 通道转成**同像素**的 JPEG
    （Pillow/ImageIO 都解不了 HEIC，落盘成 .jpg 也是骗浏览器）。
    """
    ref = _referer(platform)
    for u in origin_candidates(remote_url):
        data = _http_get(u, ref, timeout=timeout)
        if not data:
            continue
        if is_heif(data):
            sep = "&" if "?" in u else "?"
            conv_url = f"{u}{sep}{_JPEG_CONVERT_SUFFIX}"
            conv = _http_get(conv_url, ref, timeout=timeout)
            if conv and conv[:3] == b"\xff\xd8\xff":
                return conv, conv_url
            # 转码失败就跳过这条通道（HEIC 存下来客户端解不了）
            continue
        return data, u
    return None, ""


def pixel_size(data: bytes) -> tuple[int | None, int | None]:
    """从字节里读出真实像素宽高（不依赖 Pillow）。

    支持 JPEG（SOF 段）、WebP（VP8/VP8L/VP8X）、PNG（IHDR）。
    读不出来返回 (None, None)。
    """
    try:
        if data[:3] == b"\xff\xd8\xff":       # JPEG
            i = 2
            n = len(data)
            while i < n - 9:
                if data[i] != 0xFF:
                    i += 1
                    continue
                m = data[i + 1]
                if m in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                         0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                    h = int.from_bytes(data[i + 5:i + 7], "big")
                    w = int.from_bytes(data[i + 7:i + 9], "big")
                    return w, h
                if m in (0xD8, 0xD9) or 0xD0 <= m <= 0xD7:
                    i += 2
                    continue
                seg = int.from_bytes(data[i + 2:i + 4], "big")
                i += 2 + seg
            return None, None
        if data[:8] == b"\x89PNG\r\n\x1a\n":   # PNG
            return (int.from_bytes(data[16:20], "big"),
                    int.from_bytes(data[20:24], "big"))
        if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
            chunk = data[12:16]
            if chunk == b"VP8 ":
                return (int.from_bytes(data[26:28], "big") & 0x3FFF,
                        int.from_bytes(data[28:30], "big") & 0x3FFF)
            if chunk == b"VP8L":
                bits = int.from_bytes(data[21:25], "little")
                return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
            if chunk == b"VP8X":
                return (int.from_bytes(data[24:27], "little") + 1,
                        int.from_bytes(data[27:30], "little") + 1)
    except Exception:  # noqa: BLE001
        return None, None
    return None, None


def _warn_if_db_claimed_elsewhere(conn, log=print) -> bool:
    """检查这个 DB 文件是不是正被别的进程开着。

    SQLite 的 WAL 模式**不防**跨进程并发写：它靠的是文件锁，而 bind mount
    跨虚拟机边界时锁语义会失效。两个进程同时写 → WAL 损坏（实测截断 2 页）。

    判据：`-wal` 文件存在，说明**有别的连接**（或至少刚有过）在这个库上
    开着事务。自己的连接建 WAL 文件是正常的，但只要容器里的服务进程
    也在用同一个文件，就是危险的。

    返回 True = 检测到疑似并发占用。
    """
    try:
        path = Path(conn.execute("PRAGMA database_list").fetchone()[2] or "")
        if not path:
            return False
        wal = Path(str(path) + "-wal")
        if wal.exists() and wal.stat().st_size > 0:
            log(f"⚠️  检测到 WAL 文件 {wal.name} 存在且非空"
                f"（{wal.stat().st_size} 字节）。")
            log("   若容器里的服务进程正在用同一个库，请勿在宿主机并发写入：")
            log("     docker stop socialwatch   # 或改为在容器内执行本命令")
            log("   继续操作有损坏数据库的风险。")
            return True
    except Exception:  # noqa: BLE001
        pass
    return False


def backfill_xhs_originals(conn, media_root: Path, limit: int = 0,
                            only_compressed: bool = True,
                            log=print) -> dict:
    """把小红书归档里还停在压缩档的图片升级成原图。

    参数
    ----
    conn       已连接的 SQLite 连接
    media_root 归档根目录（archive_root()）
    limit      最多处理多少张，0 = 不限
    only_compressed  True = 只处理 tier='note' 的（压缩档）；False = 全部

    返回统计 dict。

    ⚠️ 不要在容器运行时从宿主机直接写同一个 DB 文件
    ---------------------------------------------------
    docker-compose 把 ./data 挂进容器，容器里的服务进程一直开着这个
    SQLite 文件。宿主机这边再开一个连接写同一个文件，就是**两个进程
    并发写同一个 SQLite**。在 macOS 虚拟化的 bind mount 上这会把 WAL
    写坏（实测：文件短了 2 页，integrity_check 报 malformed，.recover
    才救回来）。Linux 上同样危险。

    正确做法二选一：
      1. 在容器内执行：docker exec socialwatch python -m imwatching.cli \
                        upgrade-media
      2. 宿主机执行前先停容器：docker stop socialwatch
    """
    stats = {"scanned": 0, "upgraded": 0, "already_hq": 0, "failed": 0,
             "bytes_before": 0, "bytes_after": 0, "skipped_no_candidate": 0}

    _warn_if_db_claimed_elsewhere(conn, log)

    sql = ("SELECT m.content_id, m.seq, m.remote_url, m.tier, m.local_path, "
           "       m.width, m.height, c.target_key, c.post_id, c.platform "
           "       FROM content_media m "
           "       JOIN content c ON c.id = m.content_id "
           "       WHERE c.platform='xiaohongshu' ")
    if only_compressed:
        sql += "AND m.tier='note' "
    sql += "ORDER BY m.content_id DESC, m.seq"
    if limit:
        sql += f" LIMIT {int(limit)}"

    rows = conn.execute(sql).fetchall()
    for r in rows:
        stats["scanned"] += 1
        cid = r["content_id"]
        seq = r["seq"]
        target_key = r["target_key"]
        post_id = r["post_id"]

        # 已经有原图档的跳过
        if r["tier"] == "origin":
            stats["already_hq"] += 1
            continue

        cands = origin_candidates(r["remote_url"] or "")
        if not cands:
            stats["skipped_no_candidate"] += 1
            continue

        old_path = Path(r["local_path"]) if r["local_path"] else None
        old_bytes = old_path.stat().st_size if (old_path and old_path.exists()) else 0
        stats["bytes_before"] += old_bytes

        data, used = fetch_original(r["remote_url"] or "", "xiaohongshu")
        if not data:
            stats["failed"] += 1
            log(f"  ✗ cid={cid} seq={seq} 原图下载失败")
            continue

        w, h = pixel_size(data)
        old_w = r["width"] or 0
        old_h = r["height"] or 0
        # 新图的像素不能比旧的小，否则说明反推出的是另一张图，别覆盖
        if (w and h) and (old_w and old_h) and (w * h) < (old_w * old_h) * 0.5:
            stats["failed"] += 1
            log(f"  ✗ cid={cid} seq={seq} 原图像素({w}×{h})反而更小，放弃")
            continue

        saved = arc.save_media(media_root, target_key, post_id, seq, data)
        conn.execute(
            "UPDATE content_media SET remote_url=?, tier='origin', local_path=?, "
            "  bytes=?, width=?, height=?, sha256=?, fetched_at=? "
            "  WHERE content_id=? AND seq=?",
            (used, saved["local_path"], saved["bytes"], w or 0, h or 0,
             saved["sha256"], int(time.time()), cid, seq),
        )
        conn.commit()
        stats["upgraded"] += 1
        stats["bytes_after"] += saved["bytes"]
        log(f"  ✓ cid={cid} seq={seq} {old_w}×{old_h} → {w}×{h}  "
            f"({old_bytes // 1024}KB → {saved['bytes'] // 1024}KB)")
        time.sleep(0.3)

    return stats
