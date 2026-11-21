# 部署到公网（NAS + Caddy）

目标是：手机 App 和网页都能在任何网络下访问，同时不把私人存档敞开。

## 拓扑

```
手机/电脑 ──HTTPS──> Caddy(NAS:443) ──HTTP(内网)──> socialwatch:8080
                        │
                        └─ 自动签发/续期 Let's Encrypt 证书
```

Caddy 负责三件事：TLS 终结、反代、HTTP→HTTPS 跳转。
SocialWatch 本身仍然是明文 HTTP，**只在内网/回环可达**，不直接暴露。

## 一、让 SocialWatch 只监听内网

`docker-compose.yml` 里的端口映射改成只绑回环：

```yaml
ports:
  - "127.0.0.1:8080:8080"   # 而不是 "8080:8080"
```

`"8080:8080"` 会让 Docker 把端口发布到 `0.0.0.0`，等于绕过 Caddy
直接对公网开放一个明文 HTTP 入口 —— 那么前面所有鉴权配置都会被降级，
因为凭证会在公网上明文传输。

如果 Caddy 也在 Docker 里且和 socialwatch 共享网络，甚至可以完全去掉
`ports:`，只靠容器名互联（最安全，宿主机上根本没有监听的 8080）。

## 二、环境变量

在 NAS 的项目目录建 `.env`（已被 gitignore）：

```bash
# 公网地址，用于变更通知里的「打开看板」链接
SW_DASHBOARD_URL=https://sw.example.com

# 变更通知（可选）
SW_NOTIFY_SERVERCHAN_KEY=
SW_NOTIFY_BARK_KEY=
```

`SW_AUTH_FILE` 一般不用设。设了是为了把 `auth.json` 放到别处，
比如宿主机上想直接 `cat` 而不用进容器：

```bash
SW_AUTH_FILE=/app/data/auth.json   # 默认就是这个，写出来只是明示
```

## 三、签发访问 Token

**必须在容器内执行**（token 清单写在容器的数据卷里）：

```bash
docker exec socialwatch python -m imwatching.cli token issue \
  -n iphone-14pro --note "主力机 App"
```

会打印一串 `sw_...`，**只显示这一次**，立刻存到手机/密码管理器里。
之后再想拿明文只能重新签发一枚。

多设备就多签几枚，各自命名。丢了哪台就吊销哪个：

```bash
# 列出（只看得到名称和时间，看不到 token 本身）
docker exec socialwatch python -m imwatching.cli token list

# 吊销。立即生效，不需要重启容器，网页 Cookie 也会立刻失效
docker exec socialwatch python -m imwatching.cli token revoke -n iphone-14pro
```

吊销是即时生效的：Cookie 里存的就是同一串 token，每次请求都重新校验，
不存在「登出了但 30 天内还能用」的窗口。

## 四、Caddy 配置

把 `deploy/Caddyfile.example` 复制到 NAS 的 Caddy 配置位置，
改掉域名和上游地址，然后 `caddy reload`。

上游地址二选一：

| Caddy 安装方式 | 上游写法 |
|---|---|
| Docker（与 socialwatch 同网络） | `socialwatch:8080` |
| 宿主机 apt / brew 安装 | `127.0.0.1:8080` |

## 五、验证上线是否真的安全

依次跑这四条，全部符合预期才算配好：

```bash
# 1) 公网直连 8080 应该连不上（说明没有绕过 Caddy 暴露明文端口）
curl -sS -m 5 http://<你的公网IP>:8080/api/state ; echo "退出码 $?"   # 期望连接失败

# 2) HTTPS 域名可访问首页
curl -sS -o /dev/null -w "%{http_code}\n" https://sw.example.com/       # 期望 200

# 3) 无凭证访问 API 应该 401
curl -sS -o /dev/null -w "%{http_code}\n" https://sw.example.com/api/state   # 期望 401

# 4) 带 Token 应该 200
curl -sS -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer sw_xxxxxxxx" https://sw.example.com/api/state    # 期望 200
```

第 1 条最关键。很多人只做了 2–4，却忘了 8080 还发布在 0.0.0.0 上，
攻击者直接走明文端口就绕过了 TLS 和反代。

## 六、备份什么

| 路径 | 内容 | 是否必须备份 |
|---|---|---|
| `data/watch.db` | 变更记录、目标配置 | **必须** |
| `data/archive/` | 原始图片存档（约 800MB 起） | 按需，可重抓但费时 |
| `data/auth.json` | Token 哈希清单 | 建议（丢了重新签发即可） |
| `data/archive/_thumbs/` | 缩略图 | **不必**，删掉会自动重建 |
| `data/browser_container/` | Chromium profile（3.1GB） | 不必，但要重新扫码登录平台 |

`_thumbs` 之外都能用 SQLite 在线备份：

```bash
docker exec socialwatch python -c "
import sqlite3
src = sqlite3.connect('/app/data/watch.db')
dst = sqlite3.connect('/app/data/backup.db')
src.backup(dst)
"
```
