"""访问鉴权：多 Token + HttpOnly Cookie + 登录接口。

为什么需要它
------------
在此之前 /api/* 完全敞开：站在容器外 curl 就能拉走全部存档（实测 200）。
一旦端口映射到公网，等于把私人存档公开，所以这是上线前的第一道必做项。

两种凭证，按客户端自动选择
--------------------------
1. `Authorization: Bearer <token>` —— App / 脚本用。TTL 长（默认 90 天），
   存客户端自己的安全存储里。
2. `sw_session` HttpOnly Cookie —— 网页用。因为 `<img src="/api/archive/media">`
   是浏览器原生加载，发不出自定义 header；靠 Cookie 才能让图片正常显示。
   Cookie 用 HttpOnly + SameSite=Lax，前端 JS 读不到，防 XSS 窃取。

Token 的存储与比对
-----------------
只存 sha256 哈希，**不存明文**：备份泄漏、误传仓库都不会直接让人拿到钥匙。
比对用 hmac.compare_digest（防时序攻击）。
Token 本身是 32 字节随机（secrets.token_urlsafe），人手抄不下来也用不猜。

多 Token 是为了区分设备 / 可单独吊销：
每个 token 有 name（如 "iphone-14pro"、"macbook-web"）、created_at、
last_used_at。丢了哪台就 revoke 哪个，不影响其他设备。

未配置时的行为
-------------
`data/auth.json` 不存在 → 鉴权关闭，保持现状可访问。
这样升级过程不会把自己锁在门外；配好第一枚 token 后自动启用。
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import threading
import time
from pathlib import Path

#: Cookie 名。改名前先考虑已有客户端会掉线。
COOKIE_NAME = "sw_session"
#: Token 前缀，便于在日志/配置里肉眼区分和搜索。
TOKEN_PREFIX = "sw_"
#: 网页 Cookie 有效期（秒）。30 天：够久，又不用天天重登。
COOKIE_MAX_AGE = 30 * 86400


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


class AuthStore:
    """Token 清单的读写。文件格式：

        {"enabled": true,
         "tokens": [{"name": "iphone", "sha256": "...", "created_at": 123,
                     "last_used_at": 456, "note": ""}]}

    用文件而非数据库：token 数量个位数，且需要在容器外（宿主机上）
    也能方便地查看/吊销；文件比开 SQLite 直观。
    """

    def __init__(self, path: Path):
        self.path = Path(path)
        # RLock：_save 内部会调 _load，普通 Lock 会自锁死
        self._lock = threading.RLock()
        self._data: dict | None = None
        #: 上次读盘时文件的 (mtime_ns, size, inode)，用于判断是否需要重读
        self._stamp: tuple | None = None

    # ---- 读写 ----
    def _stat_stamp(self) -> tuple | None:
        """文件的变更指纹。取 inode 是因为 os.replace 换的是新 inode，
        单看 mtime+size 在「同一纳秒内改到同样大小」时会漏判。"""
        try:
            st = os.stat(self.path)
        except OSError:
            return None
        return (st.st_mtime_ns, st.st_size, st.st_ino)

    def _load(self) -> dict:
        """读 token 清单。

        缓存必须按文件指纹失效，不能只读一次就永久持有：
        CLI 在宿主机签发/吊销 token 时改的是挂载进容器的同一个文件，
        而 webapp 进程里的 AuthStore 是长驻单例。若只读一次，
        就会出现「宿主机上 token 已经生效、容器里 auth_enabled 仍是 false」
        ——请求继续放行，等于鉴权形同虚设（本项目实测踩过这个坑）。
        """
        stamp = self._stat_stamp()
        if self._data is not None and stamp == self._stamp:
            return self._data
        try:
            with open(self.path, encoding="utf-8") as f:
                d = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            d = {"enabled": False, "tokens": []}
        d.setdefault("enabled", bool(d.get("tokens")))
        d.setdefault("tokens", [])
        self._data = d
        self._stamp = stamp
        return d

    def _save(self, d: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".json.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=2)
        os.replace(tmp, self.path)
        # 只有属主可读写：里面虽是哈希，但没必要让同机其他用户读到 token 清单
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass
        self._data = d
        # 同步指纹，避免刚写完就被改判为「外部变更」而白读一次磁盘
        self._stamp = self._stat_stamp()

    def invalidate(self) -> None:
        with self._lock:
            self._data = None
            self._stamp = None

    # ---- 查询 ----
    def enabled(self) -> bool:
        d = self._load()
        return bool(d.get("enabled")) and bool(d.get("tokens"))

    def public_list(self) -> list[dict]:
        """给前端/接口看的清单，绝不含 sha256（那是可直接使用的凭证等价物）。"""
        d = self._load()
        return [{
            "name": t.get("name"),
            "created_at": t.get("created_at"),
            "last_used_at": t.get("last_used_at"),
            "note": t.get("note") or "",
        } for t in d.get("tokens") or []]

    def verify(self, token: str) -> dict | None:
        """校验一枚 token，成功返回对应条目（并刷新 last_used_at）。"""
        token = (token or "").strip()
        if not token:
            return None
        want = _hash(token)
        d = self._load()
        hit = None
        for t in d.get("tokens") or []:
            # compare_digest：逐字节定长比较，避免靠响应时间猜前缀
            if hmac.compare_digest(str(t.get("sha256") or ""), want):
                hit = t
                break
        if not hit:
            return None
        # 更新最近使用时间，但节流到 1 小时，避免每个请求都写盘
        now = int(time.time())
        if now - int(hit.get("last_used_at") or 0) > 3600:
            with self._lock:
                d2 = self._load()
                for t in d2.get("tokens") or []:
                    if t.get("name") == hit.get("name"):
                        t["last_used_at"] = now
                self._save(d2)
        return hit

    # ---- 变更 ----
    def issue(self, name: str, note: str = "") -> str:
        """签发一枚新 token，返回明文（**只此一次**，之后只存哈希）。"""
        name = (name or "").strip() or f"token-{int(time.time())}"
        token = TOKEN_PREFIX + secrets.token_urlsafe(32)
        with self._lock:
            d = self._load()
            if any(t.get("name") == name for t in d.get("tokens") or []):
                raise ValueError(f"名称已存在：{name}")
            d.setdefault("tokens", []).append({
                "name": name,
                "sha256": _hash(token),
                "created_at": int(time.time()),
                "last_used_at": 0,
                "note": note or "",
            })
            d["enabled"] = True
            self._save(d)
        return token

    def revoke(self, name: str) -> bool:
        with self._lock:
            d = self._load()
            before = len(d.get("tokens") or [])
            d["tokens"] = [t for t in d.get("tokens") or [] if t.get("name") != name]
            if len(d["tokens"]) == before:
                return False
            # 全部吊销后不自动关鉴权：enabled 保持，避免"删掉最后一枚"
            # 就意外把服务敞开。要关得显式调用 disable()。
            self._save(d)
        return True

    def disable(self) -> None:
        with self._lock:
            d = self._load()
            d["enabled"] = False
            self._save(d)

    def enable(self) -> bool:
        with self._lock:
            d = self._load()
            if not d.get("tokens"):
                return False
            d["enabled"] = True
            self._save(d)
        return True


def cookie_header(token: str, max_age: int = COOKIE_MAX_AGE) -> str:
    """构造 Set-Cookie。HttpOnly 让 JS 读不到；SameSite=Lax 兼容普通导航。"""
    return (f"{COOKIE_NAME}={token}; Path=/; Max-Age={max_age}; "
            "HttpOnly; SameSite=Lax")


def cookie_clear_header() -> str:
    return f"{COOKIE_NAME}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"


def parse_cookies(header: str | None) -> dict[str, str]:
    out: dict[str, str] = {}
    for part in (header or "").split(";"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        k, _, v = part.partition("=")
        out[k.strip()] = v.strip()
    return out
