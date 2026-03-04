#!/bin/bash
echo "=== Node Status Check ==="
STATUS=$(curl -s http://127.0.0.1:26657/status)
HEIGHT=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['sync_info']['latest_block_height'])")
TIME=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['sync_info']['latest_block_time'])")
CATCHING=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['sync_info']['catching_up'])")
echo "Latest block height: $HEIGHT"
echo "Latest block time:   $TIME"
echo "Catching up:         $CATCHING"
echo ""
echo "=== Peer Count ==="
PEERS=$(curl -s http://127.0.0.1:26657/net_info | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['n_peers'])")
echo "Connected peers: $PEERS"
echo ""
echo "=== Current Time ==="
date -u
echo ""

# Wait 5 seconds and check again to see if height is moving
sleep 5
STATUS2=$(curl -s http://127.0.0.1:26657/status)
HEIGHT2=$(echo "$STATUS2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['sync_info']['latest_block_height'])")
TIME2=$(echo "$STATUS2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['sync_info']['latest_block_time'])")
echo "=== After 5 seconds ==="
echo "Block height: $HEIGHT -> $HEIGHT2"
echo "Block time:   $TIME -> $TIME2"

if [ "$HEIGHT" = "$HEIGHT2" ]; then
    echo "WARNING: Block height not moving! Node may be stuck."
else
    echo "OK: Node is syncing (height increased by $((HEIGHT2 - HEIGHT)))"
fi
