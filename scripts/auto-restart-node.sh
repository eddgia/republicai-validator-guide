#!/bin/bash
# Auto-restart republicd node and resync blocks when it stops
# Usage: Run via cron every 2 minutes: */2 * * * * /home/akonkat/auto-restart-node.sh >> /home/akonkat/auto-restart-node.log 2>&1

export PATH=/usr/local/bin:/usr/bin:/bin:/home/akonkat/.local/bin:/home/akonkat/go/bin:$PATH
export HOME=/home/akonkat

CHAIN_ID="raitestnet_77701-1"
NODE_HOME="/home/akonkat/.republicd"
LOG_FILE="/home/akonkat/auto-restart-node.log"
LOCKFILE="/tmp/auto-restart-node.lock"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Prevent concurrent runs
if [ -f "$LOCKFILE" ]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        exit 0
    fi
    rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap "rm -f $LOCKFILE" EXIT

# Check if republicd is running
if pgrep -x republicd > /dev/null 2>&1; then
    # Node is running, check if it's responsive
    RESPONSE=$(curl -s --max-time 5 http://127.0.0.1:26657/status 2>/dev/null)
    if [ -n "$RESPONSE" ]; then
        HEIGHT=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin)['result']['sync_info']; print(d['latest_block_height'])" 2>/dev/null)
        CATCHING=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin)['result']['sync_info']; print(d['catching_up'])" 2>/dev/null)
        BLOCK_TIME=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin)['result']['sync_info']; print(d['latest_block_time'])" 2>/dev/null)
        log "OK: height=$HEIGHT catching_up=$CATCHING block_time=$BLOCK_TIME"
        
        # Check if node is stuck (same height for too long)
        PREV_HEIGHT_FILE="/tmp/republicd_prev_height"
        PREV_HEIGHT_TIME="/tmp/republicd_prev_height_time"
        
        if [ -f "$PREV_HEIGHT_FILE" ]; then
            OLD_HEIGHT=$(cat "$PREV_HEIGHT_FILE")
            OLD_TIME=$(cat "$PREV_HEIGHT_TIME" 2>/dev/null || echo "0")
            NOW=$(date +%s)
            DIFF=$((NOW - OLD_TIME))
            
            if [ "$HEIGHT" = "$OLD_HEIGHT" ] && [ "$DIFF" -gt 300 ]; then
                log "WARNING: Node stuck at height $HEIGHT for ${DIFF}s. Restarting..."
                pkill -x republicd
                sleep 5
                # Fall through to restart below
            else
                if [ "$HEIGHT" != "$OLD_HEIGHT" ]; then
                    echo "$HEIGHT" > "$PREV_HEIGHT_FILE"
                    date +%s > "$PREV_HEIGHT_TIME"
                fi
                exit 0
            fi
        else
            echo "$HEIGHT" > "$PREV_HEIGHT_FILE"
            date +%s > "$PREV_HEIGHT_TIME"
            exit 0
        fi
    else
        log "WARNING: Node running but RPC unresponsive. Restarting..."
        pkill -x republicd
        sleep 5
    fi
fi

# Node is not running — start it
log "STARTING: republicd not running. Starting node..."

# Start republicd in background
setsid nohup republicd start \
    --home "$NODE_HOME" \
    --chain-id "$CHAIN_ID" \
    >> /home/akonkat/republicd-node.log 2>&1 < /dev/null &

NEW_PID=$!
disown "$NEW_PID" 2>/dev/null

sleep 5

if pgrep -x republicd > /dev/null 2>&1; then
    log "STARTED: republicd running (PID=$(pgrep -x republicd))"
    
    # Wait for RPC to be ready
    for i in $(seq 1 12); do
        RESPONSE=$(curl -s --max-time 3 http://127.0.0.1:26657/status 2>/dev/null)
        if [ -n "$RESPONSE" ]; then
            HEIGHT=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin)['result']['sync_info']; print(d['latest_block_height'])" 2>/dev/null)
            CATCHING=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin)['result']['sync_info']; print(d['catching_up'])" 2>/dev/null)
            log "SYNCING: height=$HEIGHT catching_up=$CATCHING"
            
            # Reset height tracking
            echo "$HEIGHT" > /tmp/republicd_prev_height
            date +%s > /tmp/republicd_prev_height_time
            
            # Also restart auto-compute if not running
            if ! pgrep -f "auto-compute.sh" > /dev/null 2>&1; then
                log "STARTING: auto-compute.sh not running. Starting..."
                setsid nohup bash /home/akonkat/auto-compute.sh >> /home/akonkat/auto-compute.log 2>&1 < /dev/null &
                disown $! 2>/dev/null
                log "STARTED: auto-compute.sh"
            fi
            
            exit 0
        fi
        sleep 5
    done
    log "WARNING: Node started but RPC not ready after 60s"
else
    log "ERROR: Failed to start republicd"
fi
