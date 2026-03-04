#!/bin/bash
# Launcher script that starts auto-compute in background properly
export PATH=/usr/local/bin:/usr/bin:/bin:/home/akonkat/.local/bin:/home/akonkat/go/bin:$PATH
export HOME=/home/akonkat

# Kill any existing auto-compute
OLD_PID=$(cat /home/akonkat/auto-compute.pid 2>/dev/null)
if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Killing old auto-compute PID=$OLD_PID"
    kill "$OLD_PID" 2>/dev/null
    sleep 1
fi

# Start in background with setsid
setsid bash /home/akonkat/auto-compute.sh >> /home/akonkat/auto-compute.log 2>&1 < /dev/null &
NEW_PID=$!
echo "$NEW_PID" > /home/akonkat/auto-compute.pid
disown "$NEW_PID"

echo "Auto-compute started with PID=$NEW_PID"
sleep 3

# Verify it's still alive
if kill -0 "$NEW_PID" 2>/dev/null; then
    echo "VERIFIED: Process $NEW_PID is running"
    echo "=== Last 5 lines of log ==="
    tail -5 /home/akonkat/auto-compute.log
else
    echo "ERROR: Process $NEW_PID died!"
    echo "=== Last 10 lines of log ==="
    tail -10 /home/akonkat/auto-compute.log
fi
