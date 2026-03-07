#!/bin/bash
# Watchdog for full-auto.sh — restarts if it stops

echo "[watchdog] 👀 Watchdog started..."

while true; do
  if ! pgrep -f "full-auto.sh" > /dev/null; then
    echo "[watchdog] ⚠️  full-auto.sh stopped! Restarting..."
    nohup bash /home/akonkat/full-auto.sh >> /home/akonkat/full-auto.log 2>&1 &
    echo "[watchdog] ✅ Restarted! PID: $!"
  fi
  sleep 30
done
