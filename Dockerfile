# 官方 Playwright 镜像：已内置 chromium 及全部系统依赖，
# 避免自行 apt install 踩到字体库、libnss 等缺包问题。
# 版本需与 requirements.txt 中的 playwright 版本对应。
FROM mcr.microsoft.com/playwright/python:v1.65.0-noble

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TZ=Asia/Shanghai \
    # 容器内没有 Google Chrome，改用 Playwright 自带的 chromium
    SW_BROWSER_CHANNEL="" \
    # 容器以 root 运行，必须关掉 sandbox，否则 chromium 起不来
    SW_BROWSER_NO_SANDBOX=1 \
    # 容器与宿主机隔离的浏览器 profile 目录
    # （Linux Chromium 不能写 macOS 的 profile，会导致 cookie 被清空）
    SW_PROFILE_ROOT=/app/data/browser_container \
    PORT=8080 \
    HOST=0.0.0.0

WORKDIR /app

# 先装依赖，利用 Docker 层缓存：只有 requirements 变了才重装
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 官方镜像自带 chromium，但显式再确认一次完整浏览器存在：
# headless 模式下 Playwright 默认去找 headless shell，缺了会启动失败
RUN playwright install chromium && \
    ls -d /ms-playwright/chromium-*/ 2>/dev/null || true

COPY . .

# 数据与配置目录：config.yaml 挂载进来，data/ 挂载为卷持久化
VOLUME ["/app/data"]
EXPOSE 8080

HEALTHCHECK --interval=60s --timeout=10s --start-period=40s --retries=3 \
    CMD python -c "import urllib.request,sys; \
        sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/api/health',timeout=8).status==200 else 1)"

ENTRYPOINT ["/app/entrypoint.sh"]
