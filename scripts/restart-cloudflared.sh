#!/bin/bash
# Restart Cloudflare Tunnel and log new URL
# Usage: bash restart-cloudflared.sh

LOGFILE="/home/akonkat/cloudflared.log"

echo "Stopping old cloudflared..."
pkill -f cloudflared 2>/dev/null
sleep 2

echo "Starting new tunnel..."
nohup /home/akonkat/cloudflared tunnel --url http://localhost:8080 > "$LOGFILE" 2>&1 &
sleep 8

NEW_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOGFILE" | tail -1)
if [ -z "$NEW_URL" ]; then
  echo "ERROR: Failed to get tunnel URL"
  cat "$LOGFILE"
  exit 1
fi

echo "New tunnel URL: $NEW_URL"
echo "Cloudflared PID: $(pgrep -f cloudflared)"
