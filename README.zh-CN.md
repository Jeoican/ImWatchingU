<div align="center">

# ImWatchingU

**谁取关了谁，谁悄悄把歌单里的歌删掉了。**

一个自托管的社媒账号变更监控工具。它定期轮询各平台的公开主页，把每次结果和上一次的快照做比对，只报告真正发生的变化——歌单里增删了哪首歌、粉丝数动了多少、谁关注了 TA、谁取关了 TA。

[English](README.md) | 简体中文

[![Python](https://img.shields.io/badge/python-3.11%2B-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![Playwright](https://img.shields.io/badge/Playwright-1.65-2EAD33?logo=playwright&logoColor=white)](https://playwright.dev/)
[![Docker](https://img.shields.io/badge/Docker-ready-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![Dependencies](https://img.shields.io/badge/web%20framework-none-lightgrey)](#为什么不用-web-框架)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

---

## 它能监控什么

| | 网易云音乐 | 微博 | 抖音 | 小红书 |
|---|---|---|---|---|
| 粉丝数 / 关注数 | ✅ | ✅ | ✅ | ⚠️ 需登录 |
| 歌单歌曲增删 | ✅ | — | — | — |
| 精确到人（谁关注了 TA / 谁取关了 TA） | ⚠️ 粉丝列表需登录 | ⚠️ 需登录 | ⚠️ 需登录 | ⚠️ 需登录 |
| 不登录能否使用 | ✅ | ✅ | ✅ | ❌ |

两条设计原则贯穿整个项目：

**不编造历史。** 第一次采集只建立基线，不会凭空生成任何"变更"事件。数据库里的每一条记录，都对应一次真实观测到的差异。

**失败要说出来。** 遇到私密主页、登录态过期这类情况，会在运行日志里明确报错，而不是悄悄写个 0 糊弄过去。

## 界面

看板为每个监控目标展示一张卡片：当前数值、近 7 天增减、30 天趋势曲线，以及按时间倒序排列的变更流水。可以点一下立刻巡检、增删改监控目标，也能在网页上直接完成扫码登录，全程不用碰终端。

> _截图位置：仓库不含 `data/`（已 gitignore），所以没有附带实际运行截图。_

## 快速开始

### 方式一：Docker（推荐）

一个容器同时跑定时巡检和 Web 看板。

```bash
git clone https://github.com/Jeoican/ImWatchingU.git
cd ImWatchingU

cp config.example.yaml config.yaml
# 编辑 config.yaml，填入要监控的账号，把 enabled 改成 true

docker compose up -d --build
open http://localhost:8080
```

8080 被占用的话，改 `docker-compose.yml` 里的端口映射（`"8899:8080"`）。

### 方式二：本机运行（不用 Docker）

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/playwright install chromium

cp config.example.yaml config.yaml

# 把主页链接解析成配置里需要的 id
.venv/bin/python -m imwatching.cli resolve netease "https://music.163.com/#/user/home?id=xxxxx"
.venv/bin/python -m imwatching.cli resolve weibo   "https://weibo.com/u/xxxxx"
.venv/bin/python -m imwatching.cli resolve douyin  "https://v.douyin.com/xxxxx"

.venv/bin/python -m imwatching.cli check     # 立刻巡检一次
.venv/bin/python -m imwatching.cli report    # 生成 report.html
.venv/bin/python -m imwatching.webapp        # 打开看板（:8080）
```

> macOS 上默认用本机安装的 Google Chrome（`SW_BROWSER_CHANNEL=chrome`）。
> 其他系统把它设为空字符串即可改用 Playwright 自带的 Chromium。

## 配置说明

```yaml
poll_interval_minutes: 60      # 巡检间隔（分钟）。下限 30，平台对高频访问敏感
browser_headless: true

targets:
- name: netease-someone
  platform: netease
  id: "1234567890"             # 数字 uid
  enabled: false
  options:
    watch_playlists: all       # all = 所有歌单；或写 ["歌单id", ...] 只盯几个
    metrics: [followers, following]
    people: [following, followers]   # 精确到人；粉丝列表需登录
    max_users: 500             # 列表最多读多少人（大号粉丝可能千万级）

- name: weibo-someone
  platform: weibo
  id: "1234567890"
  enabled: false
  options:
    metrics: [followers, following]

- name: douyin-someone
  platform: douyin
  id: "MS4wLjABAAAA..."        # sec_uid，不是抖音号，用 resolve 解析
  enabled: false
  options:
    metrics: [followers, following]

- name: xhs-someone
  platform: xiaohongshu
  id: "000000000000000000000000"   # 24 位 user_id
  enabled: false
  options:
    metrics: [followers, following]
```

`config.yaml` 本身是 gitignore 的——里面是你的真实账号 id。仓库里只跟踪 `config.example.yaml`。

### 配置项速查

| 字段 | 取值 | 含义 |
|---|---|---|
| `watch_playlists` | `all` 或 `["<id>", ...]` | 盯哪些歌单，逐首歌曲比对 |
| `metrics` | `followers`、`following`、`posts`、`works`、`likes`、`notes` | 数值型指标。可用项因平台而异——微博有 `posts`，抖音有 `works`/`likes`，小红书有 `notes` |
| `people` | `following`、`followers` | 精确到人，产生"某某关注了 TA""某某取关了 TA"这类事件 |
| `max_users` | 整数，默认 500 | 列表最多读多少人。日志会明确标注实际读取数量 |
| `ignore_empty` | 布尔，默认 true | 跳过空歌单，避免新建歌单时刷屏 |

## 登录

四个平台里，有三个要拿到会话才能读超出公开计数以外的数据。两种方式：

**在网页上完成** —— 点顶部的平台徽章，选「开始登录」。容器内部会通过 Xvfb 起一个真实浏览器，二维码直接显示在网页里，用手机 App 扫一下即可。Cookie 会写进 `data/state.json`，**立即生效，不用重启容器**。

**用命令行** —— 在本机弹出 Chrome：

```bash
.venv/bin/python -m imwatching.cli login xiaohongshu
.venv/bin/python -m imwatching.cli export-state     # 给容器用：写入 data/state.json
docker compose restart                              # 容器自动注入
```

### 会话有效性判定

"有 cookie" 不等于"已登录"。微博（`SUB`）、小红书（`web_session`）、抖音（`ttwid`）这三个平台，未登录访客也会拿到对应的追踪 cookie。

所以程序改为探测"只有登录后才会出现"的特征——微博查接口返回的 `isLogin` 字段、小红书是否被重定向到 `/login`、抖音有没有 `sessionid`。游客态实测都能被正确识别为未登录。

会话会过期（通常几周，抖音更短）。`cli.py status` 会显示各平台的登录状态，以及连续失败的目标。

## 命令一览

| 命令 | 说明 |
|---|---|
| `cli.py check [--target 名称]` | 立即巡检一次 |
| `cli.py report` | 重新生成自包含的 `report.html` |
| `cli.py log [--limit N]` | 查看变更日志 |
| `cli.py status` | 登录状态与连续失败告警 |
| `cli.py resolve 平台 链接` | 把主页链接解析成配置里的 id |
| `cli.py login 平台` | 交互式登录，保存 cookie |
| `cli.py export-state` | 汇总会话到 `state.json` |

完整写法是 `python -m imwatching.cli <子命令>`。安装成包之后也可以直接用 `imwatching <子命令>`。

## HTTP API

看板本身就是靠这套接口驱动的，全部返回 JSON，你也可以直接拿来脚本调用。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/` | 看板页面 |
| GET | `/api/state` | 全量状态：卡片、事件、运行记录、登录态 |
| GET | `/api/events` | 变更事件，支持 `?limit=` `?target=` `?platform=` 过滤 |
| GET | `/api/health` | 健康检查：连续失败 ≥3 次的目标会列出 |
| POST | `/api/check` | 手动触发巡检，body 可传 `{"target": "平台:id"}` 只跑某个 |
| POST | `/api/login/start` | 启动扫码登录会话 |
| GET | `/api/login/status` | 查询登录会话状态 |
| GET | `/api/login/shot` | 取登录画面截图（base64 JPEG） |
| POST | `/api/login/cancel` | 取消登录会话 |
| POST | `/api/targets` | 新增目标 |
| PUT | `/api/targets/{idx}` | 修改目标（启停、选项） |
| DELETE | `/api/targets/{idx}` | 删除目标（历史记录保留） |

配置变更采用**原子写入**——先写临时文件、校验、再原地替换，写到一半崩溃也不会损坏 `config.yaml`。

## 数据存储

`data/watch.db`，SQLite，WAL 模式 + 30 秒 busy timeout：

- `snapshot` —— 每次采集的原始数值与歌曲 id 列表，用于比对和画趋势线
- `event` —— 一条真实变更一行，例如 `2026-11-17 09:12 · 歌单「深夜」· 移除「某首歌」— 歌手（专辑）`，或 `粉丝数 1000 → 1012（+12）`
- `run_log` —— 每轮巡检的成功/失败与耗时，方便排查

把 `config.yaml` 和 `data/` 一起拷到另一台机器，就能接着跑。

## 项目结构

```
ImWatchingU/
├── imwatching/                # 核心包
│   ├── config.py              # 统一的路径解析（配置/数据/前端都在这里定位）
│   ├── cli.py                 # 命令行入口
│   ├── webapp.py              # Web 服务（纯标准库 HTTP）+ JSON API
│   ├── loginsession.py        # 网页扫码登录：Xvfb + 有界面浏览器 + 实时截图
│   ├── scheduler.py           # 容器内定时调度器
│   ├── runner.py              # 巡检执行器，CLI / Web / 调度器共用
│   ├── core/                  # 与平台无关的领域逻辑
│   │   ├── engine.py          #   变更比对与事件生成
│   │   ├── store.py           #   SQLite 存储层（WAL 模式）
│   │   └── report.py          #   报表数据聚合
│   └── platforms/             # 平台采集适配
│       ├── browser.py         #   浏览器会话层（抖音/微博/小红书）
│       ├── netease.py         #   网易云歌单与歌曲采集
│       ├── netease_social.py  #   网易云关注 / 粉丝列表（AES-CBC + RSA）
│       └── weibo_social.py    #   微博关注 / 粉丝列表
├── web/index.html             # 看板前端（无构建步骤，改完刷新即生效）
├── scripts/verify_docker.py   # Docker 配置静态校验
├── config.example.yaml        # 配置样例
├── Dockerfile / docker-compose.yml
├── entrypoint.sh / run.sh
└── pyproject.toml
```

分层思路：`core/` 不依赖任何具体平台，`platforms/` 只管"怎么把数据抓回来"，比对、存储、报表这些逻辑与平台无关的部分都放在 `core/`。新增一个平台时，只需要在 `platforms/` 下加一个采集模块。

### 为什么不用 Web 框架

整个看板就是 `http.server` 加 `sqlite3`——没有 Flask，没有 FastAPI，没有 npm。镜像更小、启动更快，也少了一层依赖版本冲突的坑（这个项目在容器里踩过不少）。`web/index.html` 是单文件，打开就能改，刷新即生效。

### 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SW_PROFILE_ROOT` | `data/browser` | 浏览器 profile 根目录。**容器与宿主机必须不同** |
| `SW_BROWSER_CHANNEL` | `chrome` | 设为空字符串则用 Playwright 自带的 Chromium（容器内用） |
| `SW_BROWSER_NO_SANDBOX` | 未设置 | 设为 `1` 加 `--no-sandbox`（以 root 运行时需要） |
| `SW_STATE_FILE` | `data/state.json` | 注入的登录态 |
| `PORT` / `HOST` | `8080` / `0.0.0.0` | 看板监听地址 |

## 容器化的几个坑

这些是实际踩过、然后修掉的问题，留在这里省得你再踩一遍。

| 现象 | 原因与解决 |
|---|---|
| 容器内 chromium 起不来 | 以 root 运行需要加 `--no-sandbox --disable-dev-shm-usage`（`SW_BROWSER_NO_SANDBOX=1`） |
| headless 启动失败，找不到浏览器 | Playwright 默认去找单独的 headless shell，要显式指定完整的 chromium |
| **跑完容器，宿主机登录态没了** | Linux Chromium 会覆写 macOS 的 profile（cookie 加密格式不同）。容器用 `data/browser_container`，宿主机用 `data/browser` |
| bind mount 上的文件不能 rename | 改成"写临时文件 → 校验 → 原地覆盖" |
| SQLite 报 database is locked | 开启 WAL 模式 + `busy_timeout=30000` |
| 浏览器 profile 被占用 | 巡检、登录检测、账号解析、失败重试各用独立 profile 目录 |
| 镜像和 Playwright 版本对不上 | `playwright==1.65.0` 与 `mcr.microsoft.com/playwright/python:v1.65.0-noble` 严格对应 |

profile 隔离这条尤其值得重复一遍：宿主机和容器共用 `data/browser` 会让**两边**的登录态同时失效，因为两套 Chromium 的 cookie 加密方式不一样。

实测数据（Mac mini）：镜像 3.8GB 磁盘占用 / 1.1GB 实际内容，首次构建约 10 分钟，之后有层缓存约 3 秒；容器空闲时 34MB 内存、0.02% CPU；三个平台跑一轮巡检约 35–40 秒。

## 定时运行

Docker 里内置调度器会自己管。裸机运行时，可以用 cron，或者用附带的 launchd 模板（macOS，默认每小时一次，改 `StartInterval` 即可调整）：

```bash
# 复制模板，把里面的 /path/to/ImWatchingU 换成你的项目绝对路径
cp com.socialwatch.plist.example ~/Library/LaunchAgents/com.socialwatch.plist
launchctl load ~/Library/LaunchAgents/com.socialwatch.plist
launchctl list | grep socialwatch

# 停用
launchctl unload ~/Library/LaunchAgents/com.socialwatch.plist
```

`run.sh` 负责跑一轮巡检 + 刷新报表，把失败追加到 `data/alert.log`，日志超过 5MB 自动轮转。

## 注意事项

- **巡检间隔别低于 30 分钟。** 这四个平台都对高频访问敏感，请求太密会触发风控，整轮直接失败。
- **小红书必须登录**，而且会话通常几周就过期。
- **抖音的 sec_uid 不是抖音号。** 用 `cli.py resolve` 从主页链接解析。
- **网易云偶尔拿不到歌曲名。** 未登录时少数歌曲会显示为 `歌曲(id 12345)`，id 本身是准确的。
- **大号粉丝列表是限量读取，不是全量。** 千万粉的账号不可能完整枚举，日志里始终会写明实际读了多少条。
- **私密主页会被标注，不会瞎猜。** 对方隐藏了关注列表，程序照常记录数字，并明确说明列表本身不可见。
- **仅供个人观察公开数据**，别拿去做批量采集或商用。

## License

MIT，详见 [LICENSE](LICENSE)。

<div align="center">
<sub>与网易云、微博、字节跳动、小红书均无隶属关系。请合理使用。</sub>
</div>
