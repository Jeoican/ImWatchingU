"""本地缩略图层：把已归档的原图压成预览图，让内容库能"秒开"。

为什么不用远端缩略图：
微博 CDN 的 wap360 只有 360px 宽，在 1180px 宽的详情页里糊成马赛克；
而原图单张 3–7MB，九图一条就是 40MB+，列表滚动时逐张拉原图必然卡顿。

所以缩略图在**本地生成并落盘**：
  原图 data/archive/weibo_xxx/<post_id>/01.jpg
  缩略 data/archive/_thumbs/weibo_xxx/<post_id>/01.jpg  (长边 900px，~120KB)

长边取 900px 的依据：详情页图片格子最宽约 380px，按 2x/3x 屏（DPR 2~3）
需要 760~1140px，900px 是画质与体积的平衡点；再大体积翻倍但肉眼无差。

为什么要落盘而不是每次现压：
一张 4284×5712 的 JPEG 解码约 250ms、缩放开销 ~80ms，九图一条就是 3 秒。
落盘后第二次访问直接 read_bytes，2ms 返回。缩略图可随时删除重建，不必备份。
"""
from __future__ import annotations

import os
from pathlib import Path

#: 缩略图长边像素。详见模块 docstring 里的取值依据。
THUMB_LONG_EDGE = 900
#: 列表用的小缩略图长边。列表格子只有 56px，按 3x 屏（DPR 3）需要 168px，
#: 取 200px 留一点余量。体积约 10KB，是 900px 版的十分之一：
#: 30 条 × 3 张 = 90 张，900px 版要 9.4MB，小图只要 0.9MB。
THUMB_LIST_EDGE = 200
#: JPEG 质量。82 是肉眼无瑕疵与体积的拐点，再高体积涨但街拍图看不出差别。
THUMB_QUALITY = 82

_THUMB_DIRNAME = "_thumbs"


def thumb_root(media_root: Path) -> Path:
    """缩略图根目录：与原图同级，放在 _thumbs 下，便于整体清空重建。

    放在 media_root 内而不是 DATA 下，是为了 SW_ARCHIVE_ROOT 指向独立磁盘时，
    缩略图跟着原图一起走，不会出现"原图在 NAS、缩略图在系统盘"的割裂。
    """
    p = Path(media_root) / _THUMB_DIRNAME
    p.mkdir(parents=True, exist_ok=True)
    return p


def thumb_path(media_root: Path, local_path: str | Path,
               long_edge: int = THUMB_LONG_EDGE) -> Path:
    """由原图路径推出缩略图路径，保持相同的相对目录结构。

    data/archive/weibo_1/ABC/01.jpg
      → data/archive/_thumbs/900/weibo_1/ABC/01.jpg   （详情页预览）
      → data/archive/_thumbs/200/weibo_1/ABC/01.jpg   （列表小图）

    按长边分一级目录，两档互不覆盖，调参时也能并存对比。
    """
    src = Path(local_path)
    root = Path(media_root)
    try:
        rel = src.resolve().relative_to(root.resolve())
    except (ValueError, OSError):
        # 原图不在 media_root 下（比如手工挪过），退化成只按文件名平铺，
        # 用完整路径哈希避免同名冲突
        import hashlib
        h = hashlib.sha1(str(src).encode("utf-8")).hexdigest()[:10]
        return thumb_root(root) / str(long_edge) / f"{h}_{src.stem}.jpg"
    return thumb_root(root) / str(long_edge) / rel


def ensure_thumb(media_root: Path, local_path: str | Path,
                 long_edge: int = THUMB_LONG_EDGE) -> Path | None:
    """确保缩略图存在并返回其路径；失败返回 None（调用方回落原图）。

    三种情况都算成功：
      1. 缩略图已存在且比原图新  → 直接返回
      2. 原图是 GIF（动图）       → 不压，返回 None 让调用方走原图（压了就不动了）
      3. 是 SVG                   → 同上，矢量图不需要位图缩放
    """
    src = Path(local_path)
    if not src.exists():
        return None
    if src.suffix.lower() in (".gif", ".svg"):
        return None

    dst = thumb_path(media_root, src, long_edge)
    # 原图比缩略图新说明原图被重下过（补图/换档），缩略图需重建
    if dst.exists() and dst.stat().st_mtime >= src.stat().st_mtime and dst.stat().st_size > 0:
        return dst

    try:
        from PIL import Image
    except ImportError:  # 没装 Pillow 时优雅降级，不阻塞整个接口
        return None

    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_suffix(dst.suffix + ".part")
    try:
        with Image.open(src) as im:
            if getattr(im, "is_animated", False):
                return None  # 动图保持原样
            im = im.convert("RGB")
            w, h = im.size
            if max(w, h) <= long_edge:
                # 原图本身就不大，直接转 JPEG 即可（省掉无意义的放大）
                out = im
            else:
                scale = long_edge / float(max(w, h))
                out = im.resize((max(1, int(w * scale)), max(1, int(h * scale)),
                                ), Image.LANCZOS)
            out.save(tmp, "JPEG", quality=THUMB_QUALITY, optimize=True,
                     progressive=True)
        os.replace(tmp, dst)   # 原子替换：避免并发读到写了一半的文件
        return dst
    except Exception:  # noqa: BLE001
        # 单张图损坏不该影响整页：清掉半成品，让调用方回落原图
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        return None


def purge(media_root: Path) -> int:
    """清空缩略图目录，返回删除的文件数。缩略图可重建，不需要备份。"""
    import shutil
    root = Path(media_root) / _THUMB_DIRNAME
    if not root.exists():
        return 0
    n = sum(1 for _ in root.rglob("*.jpg"))
    shutil.rmtree(root, ignore_errors=True)
    return n
