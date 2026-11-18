#!/bin/zsh
# 定时巡检 + 刷新报表 + 失败告警 + 日志轮转
cd "$(dirname "$0")"

LOG="data/run.log"
ALERT="data/alert.log"
mkdir -p data

echo "===== $(date '+%Y-%m-%d %H:%M:%S') =====" >> "$LOG"

# 巡检：即使部分目标失败也要继续生成报表
.venv/bin/python -m imwatching.cli check >> "$LOG" 2>&1
.venv/bin/python -m imwatching.cli report >> "$LOG" 2>&1

# 检测本轮是否有失败目标，记录到告警日志
FAILS=$(tail -30 "$LOG" | grep "^❌" || true)
if [ -n "$FAILS" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 巡检出现失败：" >> "$ALERT"
  echo "$FAILS" >> "$ALERT"
fi

# 日志轮转：超过 5MB 保留最后 2000 行
for f in "$LOG" "$ALERT"; do
  if [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 5242880 ]; then
    tail -2000 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  fi
done

# 只保留最近 5000 条运行记录，避免数据库无限增长
.venv/bin/python - <<'PY' >> "$LOG" 2>&1
from imwatching.core.store import Store
s = Store("data/watch.db")
with s._conn() as c:
    c.execute("DELETE FROM run_log WHERE id NOT IN (SELECT id FROM run_log ORDER BY ran_at DESC LIMIT 5000)")
PY

echo "" >> "$LOG"
