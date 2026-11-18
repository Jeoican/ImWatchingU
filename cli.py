"""命令行入口：login / check / run / log / status / daemon"""
from __future__ import annotations

import argparse
import json
import sys
import time
import traceback
from pathlib import Path

import yaml

import engine
import netease
import netease_social
import platforms
import weibo_social
from store import Store

ROOT = Path(__file__).resolve().parent
CFG = ROOT / "config.yaml"
DB = ROOT / "data" / "watch.db"
# 浏览器 profile 根目录。容器与宿主机通过 SW_PROFILE_ROOT 隔离，
# 否则两边的 Chromium 会互相覆写 profile（cookie 加密格式不同）。
PROFILE = platforms.profile_root()
STATE_FILE = ROOT / "data" / "state.json"


def load_cfg() -> dict:
    with open(CFG, encoding="utf-8") as f:
        return yaml.safe_load(f)


def make_browser(headless: bool = True, profile: Path | None = None) -> platforms.Browser:
    """创建浏览器；若存在导出的登录态则自动注入。

    profile 指定独立目录时用于并行实例——同一 profile 目录不能被两个
    浏览器进程同时使用。
    """
    prof = profile or PROFILE
    return platforms.Browser(prof, headless=headless, state_file=STATE_FILE)


def enabled_targets(cfg: dict) -> list[dict]:
    return [t for t in (cfg.get("targets") or []) if t.get("enabled")]


# ---------------------------------------------------------------- 采集
def collect_netease(target: dict) -> dict:
    return netease.fetch(target["id"])


def collect_browser(browser: platforms.Browser, target: dict) -> dict:
    plat = target["platform"]
    if plat == "douyin":
        return platforms.douyin_profile(browser, target["id"])
    if plat == "weibo":
        return platforms.weibo_profile(browser, target["id"])
    if plat == "xiaohongshu":
        return platforms.xhs_profile(browser, target["id"])
    raise RuntimeError(f"未支持的平台：{plat}")


def _collect_people(store, target, data, browser, opts, browser_box=None):
    """采集关注/粉丝列表，返回 (events, 说明文字)。失败不影响主流程。"""
    events: list[dict] = []
    notes = []
    max_u = opts.get("max_users", 500)
    for kind in ("following", "followers"):
        if kind not in (opts.get("people") or []):
            continue

        def do_collect(br):
            if target["platform"] == "netease":
                if kind == "following":
                    # 传人数进去：对方设隐私时列表读不到，但数字可读
                    return netease_social.fetch_following(
                        target["id"], max_users=max_u,
                        counts={"following": data.get("following"),
                                "followers": data.get("followers")})
                return netease_social.fetch_followers(br, target["id"], max_users=min(max_u, 500))
            if target["platform"] == "weibo":
                if kind == "following":
                    return weibo_social.fetch_following(br, target["id"], max_users=max_u)
                return weibo_social.fetch_followers(br, target["id"], max_users=max_u)
            raise RuntimeError("该平台暂不支持列表采集")

        try:
            r = do_collect(browser)
        except Exception as first_err:  # noqa: BLE001
            # 失败后用独立 profile 的浏览器重试一次，排除会话污染。
            # 必须用不同目录：主浏览器还开着，同目录会被 profile 锁挡住。
            try:
                with make_browser(headless=True,
                                  profile=platforms.profile_path("retry")) as fresh:
                    r = do_collect(fresh)
            except Exception:  # noqa: BLE001
                label = "关注" if kind == "following" else "粉丝"
                notes.append(f"{label}列表失败: {first_err}")
                continue

        r["nickname"] = data.get("nickname")
        events.extend(engine.watch_people(store, target, kind, r))
        label = "关注" if kind == "following" else "粉丝"
        s = f"{label}列表 {len(r['users'])} 人"
        if r.get("note"):
            s += f"（{r['note']}）"
        notes.append(s)
    return events, notes


def check_one(store: Store, target: dict, browser_box: dict) -> tuple[str, str, list[dict]]:
    """返回 (status, message, events)"""
    t0 = time.time()
    plat = target["platform"]
    name = target.get("name") or target["id"]
    try:
        opts = target.get("options") or {}
        if plat == "netease":
            data = collect_netease(target)
            events = engine.watch_netease(store, target, data)
            msg = f"{data['nickname']}：{len(data['playlists'])} 个歌单"
        else:
            br = browser_box.get("browser")
            data = collect_browser(br, target)
            events = engine.watch_counts(store, target, data)
            msg = f"{data.get('nickname')}：采集成功"

        # 列表采集放在账号数据之后；失败时记录但不中断主流程
        if opts.get("people"):
            pe, notes = _collect_people(store, target, data, browser_box.get("browser"), opts)
            events.extend(pe)
            if notes:
                msg += " | " + "; ".join(notes)

        store.add_events(events)
        store.log_run(f"{plat}:{target['id']}", plat, "ok", msg, int((time.time() - t0) * 1000))
        return "ok", msg, events
    except Exception as e:  # noqa: BLE001
        err = f"{type(e).__name__}: {e}"
        store.log_run(f"{plat}:{target['id']}", plat, "error", err, int((time.time() - t0) * 1000))
        return "error", err, []


# ---------------------------------------------------------------- 命令
LOGIN_HELP = {
    "netease": "手机号验证码登录，或点右上角「登录」后扫码",
    "douyin": "点右上角「登录」，抖音 App 扫码确认",
    "weibo": "点右上角「登录」，手机号验证码或扫码",
    "xiaohongshu": "点右上角「登录」，小红书 App 扫码或手机号验证码",
}


def cmd_login(args):
    """扫码/手动登录，把 cookie 存进 state.json（宿主机与容器共用）。"""
    plat = args.platform
    urls = {
        "netease": "https://music.163.com/",
        "douyin": "https://www.douyin.com/",
        "weibo": "https://weibo.com/",
        "xiaohongshu": "https://www.xiaohongshu.com/explore",
    }
    print(f"即将打开浏览器，请在窗口中登录 {plat}。")
    print(f"登录方式：{LOGIN_HELP.get(plat, '按页面提示登录')}")
    print("登录成功后回到这里按回车（会保存 cookie 并同步给容器）。\n")

    # 用独立的登录 profile：容器里的调度器可能正占用主 profile，
    # 同目录并发会报 "Failed to create a ProcessSingleton"。
    login_profile = platforms.profile_path("login")
    with platforms.Browser(login_profile, headless=False) as br:
        page = br.new_page()
        page.goto(urls[plat], wait_until="domcontentloaded")
        print(f"浏览器已打开：{urls[plat]}")
        print("提示：扫码或输入手机号完成登录，看到已登录主页后回到终端按 Enter。")
        input("按 Enter 继续...")
        st = br.cookie_status()
        cookies = br._ctx.cookies()
        print("\n当前 Cookie 状态：", st)

    # 合并进 state.json：容器启动时会自动注入这个文件
    existing = {"cookies": [], "origins": []}
    if STATE_FILE.exists():
        try:
            existing = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            existing = {"cookies": [], "origins": []}
    merged = {(c.get("domain"), c.get("name"), c.get("path")): c
              for c in (existing.get("cookies") or [])}
    for c in cookies:
        merged[(c.get("domain"), c.get("name"), c.get("path"))] = c
    STATE_FILE.write_text(
        json.dumps({"cookies": list(merged.values()), "origins": []},
                   ensure_ascii=False, indent=2),
        encoding="utf-8")
    print(f"\n✅ 已保存 {len(cookies)} 条 cookie 到 {STATE_FILE}")

    if st.get(plat):
        print(f"✅ {plat} 登录成功，容器会自动注入该凭证")
        print("   下一步： docker compose restart")
    else:
        print(f"⚠️ 未检测到 {plat} 的登录态，可能没有登录成功。")
        print("   常见原因：没等到登录完成就按了回车；或该平台需要额外验证。")
        print("   可以重跑本命令再试一次。")


def cmd_export_state(args):
    """把各 profile 里的登录态汇总导出为 state.json，用于注入容器。"""
    merged: dict = {}
    profiles = [platforms.profile_root(), platforms.profile_path("login")]
    for prof in profiles:
        if not prof.exists():
            continue
        try:
            with platforms.Browser(prof, headless=True) as br:
                for c in br._ctx.cookies():
                    merged[(c.get("domain"), c.get("name"), c.get("path"))] = c
        except Exception as e:  # noqa: BLE001
            print(f"  ⚠️  跳过 {prof.name}：{str(e)[:80]}")

    STATE_FILE.write_text(
        json.dumps({"cookies": list(merged.values()), "origins": []},
                   ensure_ascii=False, indent=2),
        encoding="utf-8")
    by_domain: dict[str, int] = {}
    for c in merged.values():
        d = c.get("domain", "?")
        by_domain[d] = by_domain.get(d, 0) + 1
    print(f"✅ 已导出 {len(merged)} 条 cookie 到 {STATE_FILE}")
    for d, n in sorted(by_domain.items(), key=lambda kv: -kv[1])[:12]:
        print(f"   {d:<34} {n}")
    print("\n提示：把 data/ 目录挂载进容器即可自动注入登录态。")


def cmd_check(args):
    cfg = load_cfg()
    store = Store(DB)
    targets = enabled_targets(cfg)
    if args.target:
        targets = [t for t in targets if args.target in (t.get("name"), t.get("id"))]

    need_browser = any(
        t["platform"] != "netease" or
        ("followers" in ((t.get("options") or {}).get("people") or []))
        for t in targets
    )
    box: dict = {}
    total_events = 0
    try:
        if need_browser:
            box["browser"] = make_browser(headless=cfg.get("browser_headless", True)).__enter__()
        for t in targets:
            status, msg, events = check_one(store, t, box)
            icon = "✅" if status == "ok" else "❌"
            print(f"{icon} [{t['platform']}] {t.get('name') or t['id']} — {msg}")
            for e in events:
                print("    " + format_event(e))
            total_events += len(events)
    finally:
        if "browser" in box:
            box["browser"].__exit__()

    print(f"\n本次共记录 {total_events} 条变更。")


def format_event(e: dict) -> str:
    t = e["event_type"]
    name = e.get("item_name") or e.get("item_id")
    extra = e.get("item_extra") or {}
    if t == "track_added":
        art = f" — {extra['artists']}" if extra.get("artists") else ""
        return f"+ 新增《{name}》{art}  (歌单：{e.get('scope_name')})"
    if t == "track_removed":
        art = f" — {extra['artists']}" if extra.get("artists") else ""
        return f"- 移除《{name}》{art}  (歌单：{e.get('scope_name')})"
    if t == "playlist_added":
        return f"+ 新建/收藏歌单「{name}」"
    if t == "playlist_removed":
        return f"- 歌单消失「{name or e.get('item_id')}」"
    if t in ("count_up", "count_down"):
        sign = "+" if t == "count_up" else ""
        return f"{name}：{extra.get('before')} → {extra.get('after')}  ({sign}{e.get('delta')})"
    if t == "person_follow_added":
        return f"关注了 @{name}  (id {e.get('item_id')})"
    if t == "person_follow_removed":
        return f"取消关注 @{name}  (id {e.get('item_id')})"
    if t == "person_fan_added":
        return f"新粉丝 @{name}  (id {e.get('item_id')})"
    if t == "person_fan_removed":
        return f"取关了 @{name}  (id {e.get('item_id')})"
    return str(e)


def cmd_log(args):
    store = Store(DB)
    rows = store.recent_events(limit=args.limit)
    if not rows:
        print("暂无变更记录。")
        return
    cur_day = None
    for r in rows:
        day = time.strftime("%Y-%m-%d", time.localtime(r["detected_at"]))
        if day != cur_day:
            print(f"\n{'=' * 12} {day} {'=' * 12}")
            cur_day = day
        ts = time.strftime("%H:%M:%S", time.localtime(r["detected_at"]))
        print(f"[{ts}] {format_event(r)}")


def cmd_report(args):
    """生成 HTML 报表。"""
    import report
    store = Store(DB)
    cfg = load_cfg()
    out = report.build(store, cfg, ROOT / "report.html")
    print(f"报表已生成：{out}")


def cmd_status(args):
    store = Store(DB)
    cfg = load_cfg()
    print("=== 监控目标 ===")
    for t in cfg.get("targets") or []:
        flag = "启用" if t.get("enabled") else "停用"
        extra = ""
        people = (t.get("options") or {}).get("people") or []
        if people:
            extra = "  精确到人: " + "/".join(people)
        print(f"  [{flag}] {t['platform']:<12} {t.get('name') or t['id']}{extra}")

    print("\n=== 登录凭证状态 ===")
    try:
        # 用独立 profile 目录：主 profile 可能正被容器内的巡检占用，
        # 同一目录不能被两个浏览器进程同时打开。
        with make_browser(headless=True,
                          profile=platforms.profile_path("status")) as br:
            st = br.cookie_status()
        for k, v in st.items():
            print(f"  {k:<14} {'已登录' if v else '未登录'}")
    except Exception as e:  # noqa: BLE001
        print(f"  无法检查：{str(e)[:120]}")

    print("\n=== 连续失败检测 ===")
    targets = enabled_targets(cfg)
    problems = 0
    for t in targets:
        key = f"{t['platform']}:{t['id']}"
        with store._conn() as c:
            rows = c.execute(
                "SELECT status FROM run_log WHERE target_key=? ORDER BY ran_at DESC LIMIT 5", (key,)
            ).fetchall()
        fails = sum(1 for r in rows if r["status"] == "error")
        oks = sum(1 for r in rows if r["status"] == "ok")
        # 最近几次里有成功就不算故障
        if fails >= 3 and oks == 0:
            problems += 1
            print(f"  ⚠️  {t.get('name') or t['id']}: 最近 {len(rows)} 次中 {fails} 次失败")
    if not problems:
        print("  正常")

    print("\n=== 最近运行 ===")
    for r in store.last_runs(limit=15):
        ts = time.strftime("%m-%d %H:%M:%S", time.localtime(r["ran_at"]))
        print(f"  {ts}  {r['status']:<6} {r['target_key']:<28} {r['message'][:60]}")


def cmd_resolve(args):
    """把用户给的链接/账号解析成配置需要的 id。"""
    raw = args.value
    plat = args.platform
    if plat == "netease":
        print("uid:", netease.resolve_uid(raw))
    elif plat == "xiaohongshu":
        print("user_id:", platforms.xhs_resolve(raw))
    else:
        # 解析是独立的一次性操作，用独立 profile 避免与巡检抢锁
        with make_browser(headless=True,
                          profile=platforms.profile_path("resolve")) as br:
            if plat == "douyin":
                print("sec_uid:", platforms.douyin_resolve(br, raw))
            else:
                uid, dom = platforms.weibo_resolve(br, raw)
                print("uid:", uid, "domain:", dom)


def main():
    p = argparse.ArgumentParser(description="社媒账号监控")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("login", help="登录某平台，保存 cookie")
    sp.add_argument("platform", choices=["netease", "douyin", "weibo", "xiaohongshu"])
    sp.set_defaults(func=cmd_login)

    sp = sub.add_parser("export-state", help="导出登录态为 state.json（供容器注入）")
    sp.set_defaults(func=cmd_export_state)

    sp = sub.add_parser("check", help="立即巡检一次")
    sp.add_argument("--target", help="只跑某个目标（name 或 id）")
    sp.set_defaults(func=cmd_check)

    sp = sub.add_parser("log", help="查看变更日志")
    sp.add_argument("--limit", type=int, default=60)
    sp.set_defaults(func=cmd_log)

    sp = sub.add_parser("report", help="生成 HTML 报表")
    sp.set_defaults(func=cmd_report)

    sp = sub.add_parser("status", help="查看目标与最近运行")
    sp.set_defaults(func=cmd_status)

    sp = sub.add_parser("resolve", help="解析账号链接为 id")
    sp.add_argument("platform", choices=["netease", "weibo", "douyin", "xiaohongshu"])
    sp.add_argument("value")
    sp.set_defaults(func=cmd_resolve)

    args = p.parse_args()
    try:
        args.func(args)
    except KeyboardInterrupt:
        print("\n已中断。")
    except Exception:  # noqa: BLE001
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
