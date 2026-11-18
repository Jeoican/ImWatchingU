<div align="center">

# ImWatchingU

**Who unfollowed whom, and which song quietly disappeared from the playlist.**

A self-hosted social-media watcher. It polls public profile pages, diffs every result against the last snapshot, and tells you exactly what changed — which track was added or removed from a playlist, whose follower count moved, and who followed or unfollowed an account.

[![Python](https://img.shields.io/badge/python-3.11%2B-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![Playwright](https://img.shields.io/badge/Playwright-1.65-2EAD33?logo=playwright&logoColor=white)](https://playwright.dev/)
[![Docker](https://img.shields.io/badge/Docker-ready-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![Dependencies](https://img.shields.io/badge/web%20framework-none-lightgrey)](#why-no-framework)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

English | [简体中文](README.zh-CN.md)

</div>

---

## What it does

| | NetEase Cloud Music | Weibo | Douyin | Xiaohongshu |
|---|---|---|---|---|
| Follower / following counts | ✅ | ✅ | ✅ | ⚠️ login required |
| Playlist track add / remove | ✅ | — | — | — |
| Who follows / who unfollowed (per-user) | ⚠️ followers need login | ⚠️ login required | ⚠️ login required | ⚠️ login required |
| Works without any login | ✅ | ✅ | ✅ | ❌ |

Two principles shape the design:

**No fabricated history.** The first run only establishes a baseline. Nothing is ever reported as "changed" until there are two snapshots to compare. Every event in the database corresponds to a real, observed difference.

**Fail loudly, never silently.** A `check` that cannot read a private profile or an expired session raises a visible error in the run log instead of quietly writing a zero.

## Screenshots

The dashboard shows a card per target with current values, 7-day deltas, a 30-day trend line, and a reverse-chronological change feed. Run a scan, add or remove targets, and complete QR-code logins — all from the browser, no terminal needed.

> _Add your own screenshots here — `data/` is gitignored, so the repo ships without them._

## Quick start

### Docker (recommended)

One container runs both the scheduled scans and the web dashboard.

```bash
git clone https://github.com/Jeoican/ImWatchingU.git
cd ImWatchingU

cp config.example.yaml config.yaml
# edit config.yaml — set the accounts you want to watch, flip enabled: true

docker compose up -d --build
open http://localhost:8080
```

Change the host port in `docker-compose.yml` (`"8899:8080"`) if 8080 is taken.

### Local (no Docker)

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/playwright install chromium

cp config.example.yaml config.yaml

# resolve a profile link into the id the config expects
.venv/bin/python -m imwatching.cli resolve netease "https://music.163.com/#/user/home?id=xxxxx"
.venv/bin/python -m imwatching.cli resolve weibo   "https://weibo.com/u/xxxxx"
.venv/bin/python -m imwatching.cli resolve douyin  "https://v.douyin.com/xxxxx"

.venv/bin/python -m imwatching.cli check     # one scan now
.venv/bin/python -m imwatching.cli report    # writes report.html
.venv/bin/python -m imwatching.webapp        # dashboard on :8080
```

> On macOS, `SW_BROWSER_CHANNEL` defaults to `chrome` and uses your installed Google Chrome. Elsewhere, set it to an empty string to use Playwright's bundled Chromium.

## Configuration

```yaml
poll_interval_minutes: 60      # scheduler interval; keep >= 30, these platforms rate-limit
browser_headless: true

targets:
- name: netease-someone
  platform: netease
  id: "1234567890"             # numeric user uid
  enabled: false
  options:
    watch_playlists: all       # all, or a list of specific playlist ids
    metrics: [followers, following]
    people: [following, followers]   # per-user diffs; followers need login
    max_users: 500             # cap on list reads — big accounts have millions

- name: weibo-someone
  platform: weibo
  id: "1234567890"
  enabled: false
  options:
    metrics: [followers, following]

- name: douyin-someone
  platform: douyin
  id: "MS4wLjABAAAA..."        # sec_uid — not the @handle, use `resolve`
  enabled: false
  options:
    metrics: [followers, following]

- name: xhs-someone
  platform: xiaohongshu
  id: "000000000000000000000000"   # 24-char user id
  enabled: false
  options:
    metrics: [followers, following]
```

`config.yaml` itself is gitignored — it holds real account ids. Only `config.example.yaml` is tracked.

### Option reference

| Key | Values | Meaning |
|---|---|---|
| `watch_playlists` | `all` or `["<id>", ...]` | Which playlists to diff, track by track |
| `metrics` | `followers`, `following`, `posts`, `works`, `likes`, `notes` | Numeric counters to diff. Availability varies by platform — Weibo has `posts`, Douyin `works`/`likes`, Xiaohongshu `notes` |
| `people` | `following`, `followers` | Per-user diffs — produces "A followed B", "C unfollowed D" |
| `max_users` | integer, default 500 | Read at most N entries from a list. The log states the cap explicitly |
| `ignore_empty` | bool, default true | Skip empty playlists so a newly created one doesn't flood the feed |

## Login

Three of the four platforms need a session for anything beyond public counters. Two ways to get one.

**From the dashboard** — click a platform badge, then `Start login`. A real browser launches behind Xvfb inside the container, the QR code renders straight in the web page, and you scan it with the app. Cookies land in `data/state.json` and take effect immediately; no restart.

**From the CLI** — opens Chrome on your machine:

```bash
.venv/bin/python -m imwatching.cli login xiaohongshu
.venv/bin/python -m imwatching.cli export-state     # for containers: writes data/state.json
docker compose restart                   # picks up the new state
```

### Session detection

Presence of a cookie is not proof of login. All three platforms hand out tracking cookies (`SUB` on Weibo, `web_session` on Xiaohongshu, `ttwid` on Douyin) to visitors who never signed in. The watcher therefore probes for signals that only exist after authentication — Weibo's `isLogin` field, whether Xiaohongshu redirects to `/login`, Douyin's `sessionid` — and reports guest sessions correctly as signed out.

Sessions expire (typically weeks; Douyin sooner). `imwatching status` reports per-platform validity and flags targets that have failed three runs in a row.

## Commands

| Command | Purpose |
|---|---|
| `imwatching check [--target NAME]` | Run one scan |
| `imwatching report` | Rebuild the self-contained `report.html` |
| `imwatching log [--limit N]` | Print the change feed |
| `imwatching status` | Session health and recent failures |
| `imwatching resolve PLATFORM URL` | Turn a profile link into a config id |
| `imwatching login PLATFORM` | Interactive login, saves cookies |
| `imwatching export-state` | Consolidate sessions into `state.json` |

## HTTP API

The dashboard talks to these; they're plain JSON, so you can script against them too.

| Method | Path | Description |
|---|---|---|
| GET | `/` | Dashboard |
| GET | `/api/state` | Everything: cards, events, runs, sessions |
| GET | `/api/events` | Change feed; `?limit= ?target= ?platform=` |
| GET | `/api/health` | Targets failing three or more consecutive runs |
| POST | `/api/check` | Trigger a scan; body `{"target": "platform:id"}` to narrow |
| POST | `/api/login/start` | Begin a QR login session |
| GET | `/api/login/status` | Poll session state |
| GET | `/api/login/shot` | Base64 JPEG of the login screen |
| POST | `/api/login/cancel` | Abort a session |
| POST | `/api/targets` | Add a target |
| PUT | `/api/targets/{idx}` | Enable/disable or change options |
| DELETE | `/api/targets/{idx}` | Remove a target (history is kept) |

Config edits are written atomically — temp file, validate, in-place replace — so a crash mid-write can't corrupt `config.yaml`.

## Storage

`data/watch.db`, SQLite in WAL mode with a 30-second busy timeout:

- `snapshot` — raw observed values and track id lists, for diffing and trend lines
- `event` — one row per real change, e.g. `2026-11-17 09:12 · playlist "Late night" · removed "Song" — Artist (Album)` or `followers 1000 → 1012 (+12)`
- `run_log` — pass/fail and duration per scan, for debugging

Drop `config.yaml` and `data/` onto another machine and it picks up exactly where it left off.

## Architecture

```
ImWatchingU/
├── imwatching/                # the package
│   ├── config.py              # single source of truth for all paths
│   ├── cli.py                 # Command-line entry point
│   ├── webapp.py              # HTTP server (stdlib only) + JSON API
│   ├── loginsession.py        # QR login: Xvfb + headful browser + frame capture
│   ├── scheduler.py           # In-container polling loop
│   ├── runner.py              # Scan executor shared by CLI, web, and scheduler
│   ├── core/                  # Platform-agnostic domain logic
│   │   ├── engine.py          #   Diffing and event generation
│   │   ├── store.py           #   SQLite layer (WAL)
│   │   └── report.py          #   Report aggregation, shared by page and API
│   └── platforms/             # Platform collection adapters
│       ├── browser.py         #   Browser session layer (Douyin/Weibo/XHS)
│       ├── netease.py         #   Playlist and track collection
│       ├── netease_social.py  #   NetEase following / follower lists (AES-CBC + RSA)
│       └── weibo_social.py    #   Weibo following / follower lists
├── web/index.html             # Dashboard; no build step, edits apply on refresh
├── scripts/verify_docker.py   # Static validation of the Docker setup
├── config.example.yaml        # Configuration sample
├── Dockerfile / docker-compose.yml
├── entrypoint.sh / run.sh
└── pyproject.toml
```

The layering is deliberate: `core/` knows nothing about any specific platform, `platforms/` only handles fetching data, and the diffing, storage, and reporting logic stays platform-independent. Adding a platform means adding one module under `platforms/`.

Every path — config file, database, login state, dashboard page — resolves through `imwatching/config.py`, so the package can live in a subdirectory without anything else needing to know where it is.

### Why no framework

The whole dashboard is `http.server` and `sqlite3`. No Flask, no FastAPI, no npm. The image stays small, startup is instant, and there is no dependency-resolution surface to break during a long deployment. `web/index.html` is a single file — open it, edit it, refresh.

### Environment variables

| Variable | Default | Notes |
|---|---|---|
| `SW_PROFILE_ROOT` | `data/browser` | Browser profile root. **Must differ between host and container** |
| `SW_BROWSER_CHANNEL` | `chrome` | Empty string → Playwright's bundled Chromium (use in containers) |
| `SW_BROWSER_NO_SANDBOX` | unset | `1` adds `--no-sandbox`; required when running as root |
| `SW_STATE_FILE` | `data/state.json` | Injected storage state |
| `PORT` / `HOST` | `8080` / `0.0.0.0` | Dashboard binding |

## Containerization notes

These are all things that broke first and were fixed afterwards, kept here so you don't rediscover them.

| Symptom | Cause and fix |
|---|---|
| Chromium won't start as root | Add `--no-sandbox --disable-dev-shm-usage` (`SW_BROWSER_NO_SANDBOX=1`) |
| Headless launch fails, no browser found | Playwright looks for a separate headless shell; pin the full Chromium binary |
| **Host login lost after running the container** | Linux Chromium rewrites the macOS profile — cookie encryption differs. Container uses `data/browser_container`, host uses `data/browser` |
| Config write fails on a bind mount | Files on bind mounts can't be renamed over. Write temp → validate → in-place overwrite |
| SQLite "database is locked" | WAL mode plus `busy_timeout=30000` |
| Browser profile already in use | Scanning, login polling, account resolution, and retries each get a separate profile directory |
| Image and Playwright version drift | `playwright==1.65.0` pinned to match `mcr.microsoft.com/playwright/python:v1.65.0-noble` |

The profile-isolation one is worth repeating: sharing `data/browser` between host and container destroys the login state on **both** sides, because the two Chromium builds encrypt cookies differently.

Measured on a Mac mini: image 3.8 GB on disk / 1.1 GB content, first build ~10 min then ~3 s cached; container idle at 34 MB RAM and 0.02 % CPU; one scan across three platforms takes 35–40 s.

## Scheduling

In Docker the built-in scheduler handles it. On a bare machine, either use cron or the bundled launchd template (macOS, hourly — edit `StartInterval` to taste):

```bash
# 复制模板并把里面的 /path/to/ImWatchingU 换成你的项目绝对路径
cp com.socialwatch.plist.example ~/Library/LaunchAgents/com.socialwatch.plist
launchctl load ~/Library/LaunchAgents/com.socialwatch.plist
launchctl list | grep socialwatch

# 停用
launchctl unload ~/Library/LaunchAgents/com.socialwatch.plist
```

`run.sh` wraps a scan plus a report rebuild, appends failures to `data/alert.log`, and rotates logs past 5 MB.

## Caveats

- **Poll no faster than every 30 minutes.** All four platforms rate-limit aggressively; frequent requests trigger risk controls that fail the entire run.
- **Xiaohongshu always requires login**, and its session expires every few weeks.
- **Douyin's `sec_uid` is not the @handle.** Use `imwatching resolve` on a profile URL.
- **NetEase occasionally withholds a track name** for signed-out visitors; the entry then shows `歌曲(id 12345)` with the id still correct.
- **Big follower lists are capped, not fully read.** A ten-million-follower account cannot be enumerated; the log always states how many entries were actually read.
- **Private profiles are marked, not guessed.** If someone hides their following list, the watcher records the count and says the list itself is inaccessible.
- **Built for personal observation of public data.** Don't point it at bulk harvesting or commercial redistribution.

## License

MIT — see [LICENSE](LICENSE).

<div align="center">
<sub>Not affiliated with NetEase, Weibo, ByteDance, or Xiaohongshu. Use responsibly.</sub>
</div>
