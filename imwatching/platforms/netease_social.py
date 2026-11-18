"""网易云关注 / 粉丝列表 —— 精确到人。

实测结论：
  * 关注列表：游客可读（weapi/user/getfollows/<uid>），但对方设了隐私会返回 400。
  * 粉丝列表：weapi/user/getfolloweds/<uid> 游客返回 301，必须登录。

加密为网易云 weapi 标准：AES-CBC 双重加密 + RSA pandas 公钥。
粉丝列表走浏览器上下文，自动带上登录 cookie；关注列表纯 HTTP 即可。

注意：粉丝数可能高达千万级，只能拉"最近关注"的前 N 个，配置里用 max_users 限制。
"""
from __future__ import annotations

import base64
import json
import random
import string
import time
import urllib.parse
import urllib.request

from Crypto.Cipher import AES
from Crypto.Util.Padding import pad

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")

_MODULUS = (
    "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876"
    "aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d0"
    "5c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e2"
    "89dc6935b3ece0462db0a22b8e7"
)
_PUBKEY = "010001"


def _aes(text: str, key: str) -> str:
    cipher = AES.new(key.encode(), AES.MODE_CBC, b"0102030405060708")
    return base64.b64encode(cipher.encrypt(pad(text.encode(), 16))).decode()


def _rsa(text: str) -> str:
    rev = text[::-1]
    val = int(rev.encode().hex(), 16)
    return format(pow(val, int(_PUBKEY, 16), int(_MODULUS, 16)), "x").zfill(256)


def _weapi(data: dict) -> dict:
    secret = "".join(random.choices(string.ascii_letters + string.digits, k=16))
    return {
        "params": _aes(_aes(json.dumps(data, separators=(",", ":")), "0CoJUm6Qyw8W8jud"), secret),
        "encSecKey": _rsa(secret),
    }


def _post(ep: str, data: dict) -> dict:
    body = urllib.parse.urlencode(_weapi(data)).encode()
    req = urllib.request.Request(
        "https://music.163.com/" + ep, data=body,
        headers={"User-Agent": UA, "Referer": "https://music.163.com/",
                 "Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def fetch_following(uid: str, max_users: int = 2000,
                    counts: dict | None = None) -> dict:
    """关注列表（游客可读）。返回 {users: [...], note: ...}

    对方设了隐私时列表读不到，但人数仍可从 user/detail 拿到——
    这时用真实人数汇报，而不是显示 0 人。
    """
    users: list[dict] = []
    offset = 0
    privacy = False
    while offset < max_users:
        d = _post(f"weapi/user/getfollows/{uid}",
                  {"uid": uid, "offset": offset, "limit": 100, "csrf_token": ""})
        if d.get("code") == 400 and "隐私" in str(d.get("message", "")):
            privacy = True
            break
        if d.get("code") not in (200, None):
            raise RuntimeError(f"网易云关注列表 code={d.get('code')} {d.get('message')}")
        batch = d.get("follow") or []
        for u in batch:
            users.append({"id": str(u.get("userId")), "name": u.get("nickname")})
        if not d.get("more") or not batch:
            break
        offset += len(batch)
        time.sleep(0.4)

    note = None
    total = None
    if privacy:
        total = (counts or {}).get("following")
        if total is not None:
            note = f"对方设置了隐私，关注列表不可见（关注数 {total} 人）"
        else:
            note = "对方设置了隐私，关注列表不可见"
    elif len(users) >= max_users:
        note = f"只读取最近 {max_users} 个（可能有更多）"
    return {"users": users, "note": note, "complete": not privacy and len(users) < max_users,
            "total": total}


def fetch_followers(browser, uid: str, max_users: int = 500) -> dict:
    """粉丝列表（需登录）。在浏览器页面内发请求，自动带 cookie。"""
    st = browser.cookie_status()
    if not st.get("netease"):
        raise RuntimeError("网易云粉丝列表需要登录。请先运行 login netease。")

    page = browser.new_page()
    try:
        page.goto("https://music.163.com/", wait_until="domcontentloaded", timeout=40000)
        page.wait_for_timeout(1200)
        users: list[dict] = []
        offset = 0
        while offset < max_users:
            # 在页面内生成 weapi 参数并发请求，避免手动搬运 cookie
            raw = page.evaluate(
                """({ep, data, uid}) => {
                  const url = 'https://music.163.com/' + ep;
                  const body = new URLSearchParams(data).toString();
                  return fetch(url, {method:'POST', body, credentials:'include',
                    headers:{'Content-Type':'application/x-www-form-urlencoded',
                             'Referer':'https://music.163.com/'}})
                    .then(r => r.text());
                }""",
                {"ep": f"weapi/user/getfolloweds/{uid}", "data": _weapi({
                    "uid": uid, "offset": offset, "limit": 100, "csrf_token": ""}), "uid": uid},
            )
            d = json.loads(raw)
            if d.get("code") not in (200, None):
                raise RuntimeError(f"网易云粉丝列表 code={d.get('code')} {d.get('message')}")
            batch = d.get("followeds") or []
            for u in batch:
                users.append({"id": str(u.get("userId")), "name": u.get("nickname")})
            if not d.get("more") or not batch:
                break
            offset += len(batch)
            page.wait_for_timeout(400)

        note = f"只读取最近 {max_users} 个粉丝（可能有更多，按关注时间倒序）" if len(users) >= max_users else None
        return {"users": users, "note": note, "complete": len(users) < max_users}
    finally:
        page.close()
