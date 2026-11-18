#!/bin/bash
# 容器启动入口：准备配置 → 启动 Web 服务（内含调度器）
set -e

cd /app

# 容器内首次启动时，如果配置不存在则用示例配置创建一份
if [ ! -f /app/config.yaml ]; then
  if [ -f /app/config.example.yaml ]; then
    cp /app/config.example.yaml /app/config.yaml
    echo "[entrypoint] 未找到 config.yaml，已从示例创建"
  else
    printf 'poll_interval_minutes: 60\nbrowser_headless: true\ntargets: []\n' > /app/config.yaml
    echo "[entrypoint] 已创建空配置"
  fi
fi

mkdir -p /app/data

echo "[entrypoint] 数据目录：/app/data"
echo "[entrypoint] 配置文件：/app/config.yaml"

# 预先拉起 Xvfb 虚拟显示：网页扫码登录需要一个可显示的浏览器。
# 提前启动比等到登录时再拉更稳（避免残留 socket 误判）。
if command -v Xvfb >/dev/null 2>&1; then
  if ! pgrep -f "Xvfb :99" >/dev/null 2>&1; then
    rm -f /tmp/.X11-unix/X99 /tmp/.X99-lock 2>/dev/null || true
    Xvfb :99 -screen 0 1280x900x24 -nolisten tcp >/dev/null 2>&1 &
    sleep 1
    echo "[entrypoint] Xvfb 虚拟显示已启动 (:99)"
  fi
fi

# 调试模式：exec "$@"
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

exec python -m imwatching.webapp
