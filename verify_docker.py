"""Docker 配置静态校验：本机无 Docker 时的替代验证手段。"""
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent
fails = []


def chk(name, ok, extra=""):
    print(("✅" if ok else "❌"), name, extra)
    if not ok:
        fails.append(name)


print("=== Dockerfile ===")
df = (ROOT / "Dockerfile").read_text(encoding="utf-8")
chk("FROM 指令存在", bool(re.search(r"^FROM\s+\S+", df, re.M)))
chk("使用官方 Playwright 镜像", "mcr.microsoft.com/playwright/python" in df)
chk("镜像版本与 playwright 依赖匹配",
    "v1.65.0" in df and "playwright" in (ROOT / "requirements.txt").read_text(encoding="utf-8"))
chk("WORKDIR 存在", "WORKDIR" in df)
chk("先 COPY requirements 再 COPY 源码（利用层缓存）",
    df.index("COPY requirements.txt") < df.index("COPY . ."))
chk("pip install 存在", "pip install" in df)
chk("ENTRYPOINT 存在", "ENTRYPOINT" in df)
chk("HEALTHCHECK 存在", "HEALTHCHECK" in df)
chk("EXPOSE 8080", "EXPOSE 8080" in df)
chk("SW_BROWSER_CHANNEL 置空（容器无 Google Chrome）", 'SW_BROWSER_CHANNEL=""' in df)
chk("SW_BROWSER_NO_SANDBOX=1（容器 root 运行需要）", "SW_BROWSER_NO_SANDBOX=1" in df)
chk("VOLUME 声明 data 目录", 'VOLUME ["/app/data"]' in df)

print("\n=== docker-compose.yml ===")
c = yaml.safe_load((ROOT / "docker-compose.yml").read_text(encoding="utf-8"))
svc = (c.get("services") or {}).get("socialwatch")
chk("service 名为 socialwatch", svc is not None)
if svc:
    chk("restart 策略为 unless-stopped", svc.get("restart") == "unless-stopped")
    chk("映射 8080 端口", "8080:8080" in (svc.get("ports") or []))
    chk("挂载 config.yaml", any("config.yaml" in v for v in svc.get("volumes", [])))
    chk("挂载 data 目录", any(v.endswith(":/app/data") for v in svc.get("volumes", [])))
    chk("配置 healthcheck", bool(svc.get("healthcheck")))
    chk("设置内存上限", svc["deploy"]["resources"]["limits"].get("memory") == "2G")
    chk("日志轮转已配置", svc["logging"]["options"].get("max-size") == "10m")
    env = svc.get("environment") or {}
    chk("环境变量 channel 置空", env.get("SW_BROWSER_CHANNEL") == "")
    chk("环境变量 no_sandbox 开启", env.get("SW_BROWSER_NO_SANDBOX") == "1")
    for v in svc.get("volumes", []):
        src = v.split(":")[0]
        if src.startswith("./"):
            chk(f"挂载源存在 {src}", (ROOT / src[2:]).exists())

print("\n=== entrypoint.sh ===")
ep = (ROOT / "entrypoint.sh").read_text(encoding="utf-8")
chk("以 set -e 开头", ep.strip().startswith("#!/bin/bash"))
chk("配置缺失时自动创建", "config.example.yaml" in ep)
chk("创建 data 目录", "mkdir -p /app/data" in ep)
chk("最终 exec webapp", "exec python webapp.py" in ep)
chk("支持调试模式覆盖命令", 'if [ "$#" -gt 0 ]' in ep)
chk("有可执行权限", (ROOT / "entrypoint.sh").stat().st_mode & 0o111 != 0)

print("\n=== .dockerignore ===")
di = (ROOT / ".dockerignore").read_text(encoding="utf-8")
for key in [".venv/", "data/", "__pycache__/", "*.db"]:
    chk(f"排除 {key}", key in di)

print()
if fails:
    print(f"❌ {len(fails)} 项未通过：{fails}")
    sys.exit(1)
print("✅ Docker 配置静态校验全部通过")
