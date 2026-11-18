"""生成单文件 HTML 报表（无外部依赖，双击即开）。"""
from __future__ import annotations

import json
import time
from pathlib import Path

PLAT_NAME = {"netease": "网易云音乐", "weibo": "微博", "douyin": "抖音", "xiaohongshu": "小红书"}

EVENT_STYLE = {
    "track_added":    ("新增歌曲", "add"),
    "track_removed":  ("移除歌曲", "del"),
    "playlist_added": ("新增歌单", "add"),
    "playlist_removed": ("歌单移除", "del"),
    "count_up":       ("数值上升", "add"),
    "count_down":     ("数值下降", "del"),
    "person_follow_added":   ("关注", "add"),
    "person_follow_removed": ("取关", "del"),
    "person_fan_added":      ("新粉丝", "add"),
    "person_fan_removed":    ("掉粉", "del"),
}


def _fmt_time(ts: int) -> str:
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts))


def _https(url):
    """图片地址统一升级为 https，避免 https 页面被混合内容策略拦截。"""
    if not url:
        return None
    return "https://" + url[len("http://"):] if url.startswith("http://") else url


def _playlist_details(store, cfg: dict) -> list[dict]:
    """每个歌单的明细：名称、歌曲数、增删日志。

    歌单集合从 __playlist_set__ 快照拿（含 id → 名称映射），
    歌曲数与日志从各 scope 的快照和事件拿。
    """
    out: list[dict] = []
    for t in (cfg.get("targets") or []):
        if t.get("platform") != "netease":
            continue
        key = f"netease:{t['id']}"
        set_snap = store.last_snapshot(key, "__playlist_set__", "count")
        if not set_snap:
            continue
        detail = set_snap.get("detail") or {}
        ids = detail.get("ids") or []
        names = detail.get("names") or {}

        for pid in ids:
            snap = store.last_snapshot(key, pid, "tracks")
            track_count = snap["value"] if snap else 0
            songs = (snap.get("detail") or {}).get("songs") or {}
            evs = [e for e in store.recent_events(limit=2000, target_key=key)
                   if e.get("scope") == pid]
            snap_detail = snap.get("detail") or {}
            out.append({
                "target_key": key,
                "target": t.get("name") or t["id"],
                "scope": pid,
                "name": names.get(pid) or snap_detail.get("name") or pid,
                "cover": _https(snap_detail.get("cover")),
                "track_count": track_count,
                "added": [e["item_name"] for e in evs if e["event_type"] == "track_added"],
                "removed": [e["item_name"] for e in evs if e["event_type"] == "track_removed"],
                "songs": [{"name": s.get("name"), "artists": s.get("artists"),
                           "album": s.get("album")} for s in songs.values()],
                "events": evs[:40],
            })
    return out


def _playlist_groups(store, cfg: dict, days: int = 30) -> list[dict]:
    """按歌单聚合变更：哪个歌单新增/移除了哪些歌。

    只对网易云目标有意义（其它平台没有歌单概念）。
    """
    import time as _t
    since = int(_t.time()) - days * 86400
    groups: dict[str, dict] = {}
    with store._conn() as c:
        rows = c.execute(
            "SELECT target_key, scope, scope_name, event_type, item_name, item_extra, "
            "       detected_at FROM event "
            "WHERE event_type IN ('track_added','track_removed','playlist_added','playlist_removed') "
            "  AND detected_at>=? ORDER BY detected_at DESC",
            (since,),
        ).fetchall()

    names: dict[str, str] = {}
    for t in (cfg.get("targets") or []):
        if t.get("platform") == "netease":
            names[f"netease:{t['id']}"] = t.get("name") or t["id"]

    for r in rows:
        key = r["target_key"]
        # 目标已被删除/替换时，历史记录不再展示（避免混淆）
        if key not in names:
            continue
        scope = r["scope"] or ""
        gkey = f"{key}||{scope}"
        g = groups.setdefault(gkey, {
            "target_key": key,
            "target": names.get(key, key),
            "scope": scope,
            "name": r["scope_name"] or scope,
            "added": [],
            "removed": [],
            "playlist_added": False,
            "playlist_removed": False,
            "last_at": r["detected_at"],
        })
        if r["event_type"] == "track_added":
            g["added"].append(r["item_name"])
        elif r["event_type"] == "track_removed":
            g["removed"].append(r["item_name"])
        elif r["event_type"] == "playlist_added":
            g["playlist_added"] = True
        elif r["event_type"] == "playlist_removed":
            g["playlist_removed"] = True
        g["last_at"] = max(g["last_at"], r["detected_at"])

    out = list(groups.values())
    out.sort(key=lambda g: -g["last_at"])
    return out


def collect_payload(store, cfg: dict, event_limit: int = 800,
                    per_card_limit: int = 60) -> dict:
    """聚合监控数据。静态报表与 Web API 共用此函数，保证两处口径一致。"""
    targets = cfg.get("targets") or []
    events = store.recent_events(limit=event_limit)
    runs = store.last_runs(limit=40)
    pl_details = _playlist_details(store, cfg)
    pl_by_target: dict[str, list[dict]] = {}
    for d in pl_details:
        pl_by_target.setdefault(d["target_key"], []).append(d)

    cards = []
    for t in targets:
        key = f"{t['platform']}:{t['id']}"
        plat = t["platform"]
        evs = [e for e in events if e["target_key"] == key]
        counts = store.event_counts(key, days=7)
        stats = []
        if plat == "netease":
            # 网易云：歌单增删 + 关注/粉丝数（隐私用户也能读到数字）
            stats = [
                ("新增歌曲", counts.get("track_added", 0), "add"),
                ("移除歌曲", counts.get("track_removed", 0), "del"),
                ("歌单变动", counts.get("playlist_added", 0) + counts.get("playlist_removed", 0), "add"),
            ]
            pf = counts.get("person_follow_added", 0) + counts.get("person_follow_removed", 0)
            pn = counts.get("person_fan_added", 0) + counts.get("person_fan_removed", 0)
            if pf or pn:
                stats.append(("人员变动", pf + pn, "add"))
            # 头部显示歌单数 / 歌曲总数 / 关注数 / 粉丝数
            pls = pl_by_target.get(key, [])
            head = {"歌单": len(pls)} if pls else None
            if head:
                head["歌曲"] = sum(p["track_count"] for p in pls)
            snap_f = store.last_snapshot(key, "__account__", "followers")
            snap_g = store.last_snapshot(key, "__account__", "following")
            if snap_f:
                head["粉丝"] = snap_f["value"]
            if snap_g:
                head["关注"] = snap_g["value"]
            if head and len(head) == 1:
                head = None
        else:
            # 按人数累计而非事件次数：一次变动可以是 +3 也可能是 +1
            ups = sum((e.get("delta") or 0) for e in evs if e["event_type"] == "count_up")
            downs = abs(sum((e.get("delta") or 0) for e in evs if e["event_type"] == "count_down"))
            stats = [("粉丝净增", f"{ups - downs:+d}", "add" if ups >= downs else "del"),
                     ("增加", f"+{ups}", "add"), ("减少", f"-{downs}", "del")]
            snap = store.last_snapshot(key, "__account__", "followers")
            head = {"粉丝": snap["value"]} if snap else None
            snap2 = store.last_snapshot(key, "__account__", "following")
            if snap2:
                head["关注"] = snap2["value"]

        series = []
        for metric in ("followers", "following"):
            s = store.daily_series(key, "__account__", metric, days=30)
            if s:
                series.append({"metric": metric, "points": s})

        # 用户头像：账号快照 detail 里可能带 avatar（网易云/微博/抖音）
        avatar = None
        for m in ("followers_total", "followers", "following_total", "following"):
            snap = store.last_snapshot(key, "__account__", m)
            if snap and (snap.get("detail") or {}).get("avatar"):
                avatar = _https(snap["detail"]["avatar"])
                break

        cards.append({
            "name": t.get("name") or t["id"],
            "platform": PLAT_NAME.get(plat, plat),
            "key": key,
            "enabled": bool(t.get("enabled")),
            "avatar": avatar,
            "stats": stats,
            "head": head,
            "series": series,
            "events": evs[:per_card_limit],
            "playlists": pl_by_target.get(key, []),
        })

    return {"generated_at": _fmt_time(int(time.time())), "cards": cards,
            "runs": [{"time": _fmt_time(r["ran_at"]), "status": r["status"],
                      "target": r["target_key"], "message": r["message"]} for r in runs],
            "playlists": _playlist_groups(store, cfg)}


def build(store, cfg: dict, out_path: Path) -> Path:
    payload = collect_payload(store, cfg)
    html = TEMPLATE.replace("__DATA__", json.dumps(payload, ensure_ascii=False))
    out_path.write_text(html, encoding="utf-8")
    return out_path


TEMPLATE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>社媒监控日报</title>
<style>
:root{
  --bg:#f7f7f5; --card:#ffffff; --line:#e6e6e2; --text:#1c1c1a;
  --muted:#7a7a74; --add:#c0392b; --del:#2e7d4f;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;
  font-size:14px;line-height:1.6;padding:32px 20px 60px}
.wrap{max-width:960px;margin:0 auto}
header{margin-bottom:28px}
h1{font-size:22px;font-weight:500;letter-spacing:-.2px}
.sub{color:var(--muted);font-size:13px;margin-top:6px}
.grid{display:grid;gap:16px;grid-template-columns:repeat(4,minmax(0,1fr))}
@media(max-width:1100px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media(max-width:640px){.grid{grid-template-columns:1fr}}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:20px}
.card h2{font-size:15px;font-weight:500;display:flex;align-items:center;gap:8px}
.avatar{width:34px;height:34px;border-radius:50%;object-fit:cover;flex:0 0 auto;border:1px solid var(--line);background:#f2f2f0}
.avatar.ph{display:inline-flex;align-items:center;justify-content:center;font-size:15px;color:var(--muted)}
.pill{font-size:11px;color:var(--muted);border:1px solid var(--line);border-radius:20px;padding:1px 9px;font-weight:400}
.off{color:#b9b9b3}
.stats{display:flex;gap:22px;margin:14px 0 6px;flex-wrap:wrap}
.stat .n{font-size:20px;font-weight:500;font-variant-numeric:tabular-nums}
.stat .n.add{color:var(--add)} .stat .n.del{color:var(--del)}
.stat .l{font-size:12px;color:var(--muted)}
canvas{margin-top:14px;width:100%;height:110px}
.events{margin-top:14px;border-top:1px solid var(--line);padding-top:12px}
.ev{display:flex;gap:10px;padding:5px 0;font-size:13px;align-items:baseline}
.ev .t{color:var(--muted);font-variant-numeric:tabular-nums;font-size:12px;flex:0 0 74px}
.ev .tag{flex:0 0 auto;font-size:11px;padding:0 6px;border-radius:4px;border:1px solid var(--line)}
.ev .tag.add{color:var(--add);border-color:#f0cfc9}
.ev .tag.del{color:var(--del);border-color:#c9e0d2}
.ev .body{flex:1;min-width:0}
.ev .meta{color:var(--muted);font-size:12px}
.empty{color:var(--muted);font-size:13px;padding:8px 0}
table{width:100%;border-collapse:collapse;font-size:12.5px;margin-top:10px}
th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line)}
th{color:var(--muted);font-weight:400}
td.st.ok{color:var(--del)} td.st.err{color:var(--add)}
h3{font-size:13px;font-weight:500;color:var(--muted);margin:32px 0 10px;letter-spacing:.2px}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>社媒监控日报</h1>
    <div class="sub" id="gen"></div>
  </header>
  <div class="grid" id="cards"></div>
  <h3>最近巡检记录</h3>
  <div class="card" style="padding:12px 16px"><table id="runs"></table></div>
</div>
<script>
const D = __DATA__;
const P = {"followers":"粉丝数","following":"关注数","posts":"微博数","works":"作品数","likes":"获赞数","notes":"笔记数"};
document.getElementById("gen").textContent = "生成时间 " + D.generated_at;

function esc(s){return (s??"").toString().replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]))}
function avatarHTML(url,name){
  const letter=esc((name||"?").slice(0,1));
  if(!url) return '<span class="avatar ph">'+letter+'</span>';
  return '<img class="avatar" referrerpolicy="no-referrer" data-letter="'+letter+'" '+
    'onerror="imgFallback(this)" src="'+esc(url)+'" alt="">';
}
function imgFallback(img){
  const ph=document.createElement("span");ph.className=img.className+" ph";
  ph.textContent=img.dataset.letter||"?";img.replaceWith(ph);
}

function eventHTML(e){
  const tagMap = {track_added:["新增","add"],track_removed:["移除","del"],
    playlist_added:["新歌单","add"],playlist_removed:["歌单移除","del"],
    count_up:["上升","add"],count_down:["下降","del"],
    person_follow_added:["关注","add"],person_follow_removed:["取关","del"],
    person_fan_added:["新粉丝","add"],person_fan_removed:["掉粉","del"]};
  const [tag,cls] = tagMap[e.event_type] || ["变动",""];
  const t = new Date(e.detected_at*1000);
  const ts = String(t.getMonth()+1).padStart(2,"0")+"-"+String(t.getDate()).padStart(2,"0")+" "
    + String(t.getHours()).padStart(2,"0")+":"+String(t.getMinutes()).padStart(2,"0");
  const x = e.item_extra||{};
  let main = "";
  if(e.event_type==="track_added"||e.event_type==="track_removed"){
    const art = x.artists ? '<span class="meta"> — '+esc(x.artists)+'</span>' : "";
    const alb = x.album ? '<span class="meta"> 《'+esc(x.album)+'》</span>' : "";
    main = esc(e.item_name)+art;
    return `<div class="ev"><span class="t">${ts}</span><span class="tag ${cls}">${tag}</span>
      <span class="body">${main}${alb}<span class="meta"> · ${esc(e.scope_name)}</span></span></div>`;
  }
  if(e.event_type.startsWith("count")){
    const sign = e.delta>0?"+":"";
    return `<div class="ev"><span class="t">${ts}</span><span class="tag ${cls}">${tag}</span>
      <span class="body">${esc(e.item_name)} ${x.before} → <b>${x.after}</b>
      <span class="meta"> (${sign}${e.delta})</span></span></div>`;
  }
  if(e.event_type.startsWith("person_")){
    const verb = e.event_type.includes("added") ? "新增" : "移除";
    const dir = e.event_type.includes("follow_") ? "关注" : "粉丝";
    return `<div class="ev"><span class="t">${ts}</span><span class="tag ${cls}">${tag}</span>
      <span class="body">${dir}：${esc(e.item_name)} <span class="meta">(id ${esc(e.item_id)})</span></span></div>`;
  }
  return `<div class="ev"><span class="t">${ts}</span><span class="tag ${cls}">${tag}</span>
    <span class="body">${esc(e.item_name||e.item_id)}</span></div>`;
}

function drawLine(cv, pts){
  const dpr = window.devicePixelRatio||1;
  const w = cv.clientWidth, h = cv.clientHeight;
  cv.width = w*dpr; cv.height = h*dpr;
  const g = cv.getContext("2d"); g.scale(dpr,dpr);
  const vals = pts.map(p=>p.value);
  const min = Math.min(...vals), max = Math.max(...vals);
  const pad = 14, span = (max-min)||1;
  const x = i => pad + i*(w-2*pad)/Math.max(1,pts.length-1);
  const y = v => h-pad - (v-min)*(h-2*pad)/span;
  g.strokeStyle="#e6e6e2"; g.lineWidth=1;
  g.beginPath(); g.moveTo(pad,h-pad); g.lineTo(w-pad,h-pad); g.stroke();
  g.strokeStyle="#c0392b"; g.lineWidth=1.6; g.beginPath();
  pts.forEach((p,i)=> i? g.lineTo(x(i),y(p.value)) : g.moveTo(x(i),y(p.value)));
  g.stroke();
  g.fillStyle="#7a7a74"; g.font="11px -apple-system,sans-serif";
  g.fillText(max, pad, pad-2); g.fillText(min, pad, h-pad+11);
  g.textAlign="right"; g.fillText(pts[pts.length-1].date, w-pad, h-pad+11);
}

const cards = document.getElementById("cards");
if(!D.cards.length){
  cards.innerHTML = '<div class="card"><div class="empty">还没有配置任何监控目标。在 config.yaml 里填好 target 并 enabled: true。</div></div>';
}
D.cards.forEach((c,idx)=>{
  const el = document.createElement("div");
  el.className = "card";
  const off = c.enabled ? "" : ' <span class="pill off">未启用</span>';
  const head = c.head ? `<div class="stats" style="margin-bottom:2px">${Object.entries(c.head).map(
      ([k,v])=>`<div class="stat"><div class="n">${Number(v).toLocaleString()}</div><div class="l">当前${k}</div></div>`).join("")}</div>` : "";
  el.innerHTML = `<h2>${avatarHTML(c.avatar,c.name)}${esc(c.name)}${off}<span class="pill">${esc(c.platform)}</span></h2>
    ${head}
    <div class="stats">${c.stats.map(s=>`<div class="stat"><div class="n ${s[2]}">${s[1]}</div><div class="l">${s[0]} · 近7天</div></div>`).join("")}</div>
    <div class="charts"></div>
    <div class="events">${c.events.length? c.events.map(eventHTML).join("") : '<div class="empty">暂无变更记录（首次采集只建立基线）。</div>'}</div>`;
  cards.appendChild(el);

  const ch = el.querySelector(".charts");
  c.series.forEach(s=>{
    const box = document.createElement("div");
    box.innerHTML = `<div class="meta" style="color:#7a7a74;font-size:12px;margin-top:10px">${P[s.metric]||s.metric}趋势（30天）</div><canvas></canvas>`;
    ch.appendChild(box);
    requestAnimationFrame(()=>drawLine(box.querySelector("canvas"), s.points));
  });
});

const rt = document.getElementById("runs");
rt.innerHTML = `<tr><th>时间</th><th>状态</th><th>目标</th><th>信息</th></tr>` +
 (D.runs.length? D.runs.map(r=>`<tr><td>${esc(r.time)}</td>
   <td class="st ${r.status==="ok"?"ok":"err"}">${r.status}</td>
   <td>${esc(r.target)}</td><td>${esc(r.message)}</td></tr>`).join("")
 : `<tr><td colspan="4" class="empty">尚未运行</td></tr>`);
</script>
</body>
</html>
"""
