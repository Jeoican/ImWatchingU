"""微博关注 / 粉丝列表 —— 精确到人。

实测结论（m.weibo.cn 容器内接口，游客可读）：
  /api/container/getIndex?containerid=231051_-_followers_-_<uid>&page=N
  返回 card_group，card_type=10 的项带 user{id, screen_name}。
  total 字段 = 1642（雷军关注数），分页拉取。

粉丝列表容器 231051_-_fans_-_<uid> 游客态 total 缺失、内容异常；
需登录 cookie（SUB）才能稳定拿到，登录态下走同一套代码。
"""
from __future__ import annotations

import json
import time


API = "https://m.weibo.cn/api/container/getIndex"


def _fetch_page(page_obj, uid: str, kind: str, page: int, retries: int = 3) -> tuple[list[dict], int | None]:
    """kind: followers(关注) / fans(粉丝)。

    直接导航到 API 地址读取 JSON（已实测稳定），避免页面内 fetch 在复用浏览器
    会话时偶发 "Failed to fetch" 的问题。
    """
    from urllib.parse import quote

    cid = f"231051_-_{kind}_-_{uid}"
    url = API + "?containerid=" + quote(cid) + "&page=" + str(page)
    last = None
    for attempt in range(retries):
        try:
            resp = page_obj.goto(url, wait_until="domcontentloaded", timeout=30000)
            if resp and resp.status == 200:
                text = page_obj.evaluate("() => document.body.innerText || document.body.textContent || ''")
                text = text.strip()
                try:
                    d = json.loads(text)
                    break
                except json.JSONDecodeError:
                    if "登录" in text[:100]:
                        raise RuntimeError("微博列表需要登录。请先运行 login weibo 扫码登录。") from None
                    last = f"非JSON响应: {text[:120]!r}"
            else:
                last = f"HTTP {resp.status if resp else 'None'}"
        except RuntimeError:
            raise
        except Exception as e:  # noqa: BLE001
            last = str(e)
        time.sleep(1.0 * (attempt + 1))
    else:
        raise RuntimeError(f"微博列表请求重试 {retries} 次仍失败：{last}")

    info = (d.get("data") or {}).get("cardlistInfo") or {}
    users = []
    for card in (d.get("data") or {}).get("cards") or []:
        for item in (card.get("card_group") or []):
            u = item.get("user") or {}
            if u.get("id") and u.get("screen_name"):
                users.append({"id": str(u["id"]), "name": u["screen_name"]})
    total = info.get("total")
    return users, int(total) if total else None


def _open_page(browser, uid: str):
    pg = browser.new_page()
    pg.goto("https://m.weibo.cn/u/" + uid, wait_until="domcontentloaded", timeout=40000)
    pg.wait_for_timeout(1500)
    # 预热：先发一次真实请求，确保页面上下文的 fetch 可用
    pg.evaluate(
        """async () => {
          try { await fetch('/api/container/getIndex?containerid=100505', {credentials:'include'}); }
          catch (e) {}
        }"""
    )
    pg.wait_for_timeout(300)
    return pg


def fetch_following(browser, uid: str, max_users: int = 600) -> dict:
    pg = _open_page(browser, uid)
    try:
        users: list[dict] = []
        total = None
        page = 1
        while len(users) < max_users:
            batch, t = _fetch_page(pg, uid, "followers", page)
            if t:
                total = t
            if not batch:
                break
            users.extend(batch)
            page += 1
            time.sleep(0.5)

        note = None
        if total and len(users) < total:
            note = f"只读取最近 {len(users)} 个（共 {total} 个）"
        return {"users": dedup(users), "total": total, "note": note,
                "complete": bool(total and len(users) >= total)}
    finally:
        pg.close()


def fetch_followers(browser, uid: str, max_users: int = 600) -> dict:
    if not browser.cookie_status().get("weibo"):
        raise RuntimeError("微博粉丝列表需要登录。请先运行 login weibo。")
    pg = _open_page(browser, uid)
    try:
        users: list[dict] = []
        total = None
        page = 1
        while len(users) < max_users:
            batch, t = _fetch_page(pg, uid, "fans", page)
            if t:
                total = t
            if not batch:
                break
            users.extend(batch)
            page += 1
            time.sleep(0.5)

        note = f"只读取最近 {len(users)} 个粉丝（可能有更多）" if len(users) >= max_users else None
        return {"users": dedup(users), "total": total, "note": note,
                "complete": len(users) < max_users}
    finally:
        pg.close()


def dedup(users: list[dict]) -> list[dict]:
    seen = set()
    out = []
    for u in users:
        if u["id"] not in seen:
            seen.add(u["id"])
            out.append(u)
    return out
