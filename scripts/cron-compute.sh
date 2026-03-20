#!/usr/bin/env bash
set -uo pipefail

WALLET="my-wallet"
HOME_DIR="/home/akonkat/.republicd"
CHAIN_ID="raitestnet_77701-1"
NODE="tcp://127.0.0.1:26657"
JOBS_DIR="/home/akonkat/republic-jobs"
LOG="/home/akonkat/cron-compute.log"
EXEC_IMAGE="devtools-llm-inference:latest"
VERIFY_IMAGE="example-verification:latest"

# Get fresh cloudflared URL
SERVER_BASE=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' /home/akonkat/cloudflared.log | tail -1)
if [ -z "$SERVER_BASE" ]; then
  echo "ERROR: No cloudflared tunnel URL found" >> "$LOG"
  exit 1
fi

echo "" >> "$LOG"
echo "======== $(date) ========" >> "$LOG"
echo "Tunnel URL: $SERVER_BASE" >> "$LOG"
echo "Creating + computing job..." >> "$LOG"

WALLET_ADDR=$(republicd keys show "$WALLET" --address --home "$HOME_DIR" --keyring-backend test 2>/dev/null)
VALOPER_ADDR=$(republicd keys show "$WALLET" --bech val --address --home "$HOME_DIR" --keyring-backend test 2>/dev/null)

# 1. Create job
CREATE_OUT=$(republicd tx computevalidation submit-job \
  "$VALOPER_ADDR" "$EXEC_IMAGE" "$SERVER_BASE/upload" "$SERVER_BASE/result" "$VERIFY_IMAGE" \
  1000000000000000000arai \
  --from "$WALLET" --home "$HOME_DIR" --keyring-backend test \
  --chain-id "$CHAIN_ID" --gas auto --gas-adjustment 1.5 --gas-prices 2000000000arai \
  --node "$NODE" -y 2>&1) || true

TXHASH=$(echo "$CREATE_OUT" | grep -m1 'txhash:' | awk '{print $2}')
echo "Create TX: ${TXHASH:-failed}" >> "$LOG"

sleep 12

# Get job ID - FIXED: parse from events directly AND from text output
JOB_ID=$(republicd query tx "$TXHASH" --node "$NODE" --output json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for e in d.get('events', []):
        if e.get('type') == 'job_submitted':
            for a in e.get('attributes', []):
                if a.get('key') == 'job_id':
                    print(a['value'])
                    sys.exit(0)
    for l in d.get('logs', []):
        for e in l.get('events', []):
            if e.get('type') == 'job_submitted':
                for a in e.get('attributes', []):
                    if a.get('key') == 'job_id':
                        print(a['value'])
                        sys.exit(0)
except:
    pass
" 2>/dev/null)

if [ -z "$JOB_ID" ]; then
  # Fallback: parse from text output
  JOB_ID=$(republicd query tx "$TXHASH" --node "$NODE" 2>/dev/null | grep -A1 'key: job_id' | grep 'value:' | awk '{print $2}' | tr -d '"')
fi

if [ -z "$JOB_ID" ]; then
  # Fallback 2: find latest pending job
  JOB_ID=$(republicd query computevalidation list-job --node "$NODE" --output json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
val = '$VALOPER_ADDR'
pending = [j for j in d.get('jobs', []) if j.get('target_validator') == val and j.get('status') == 'PendingExecution']
if pending:
    print(pending[-1]['id'])
" 2>/dev/null)
fi

if [ -z "$JOB_ID" ]; then
  echo "ERROR: No job ID found" >> "$LOG"
  exit 1
fi
echo "Job ID: $JOB_ID" >> "$LOG"

# 2. Compute (docker GPU inference)
JOB_DIR="$JOBS_DIR/$JOB_ID"
mkdir -p "$JOB_DIR"
docker run --rm --gpus all -v "$JOB_DIR:/output" "$EXEC_IMAGE" >> "$LOG" 2>&1 || true

RESULT_FILE="$JOB_DIR/result.bin"
if [ ! -f "$RESULT_FILE" ]; then
  echo "ERROR: No result.bin" >> "$LOG"
  exit 1
fi

SHA256=$(python3 -c "import hashlib; print(hashlib.sha256(open('$RESULT_FILE','rb').read()).hexdigest())")
echo "SHA256: $SHA256" >> "$LOG"

# 3. Submit result (with bech32 fix)
republicd tx computevalidation submit-job-result \
  "$JOB_ID" "$SERVER_BASE/$JOB_ID/result.bin" "$VERIFY_IMAGE" "$SHA256" \
  --from "$WALLET" --home "$HOME_DIR" --keyring-backend test \
  --chain-id "$CHAIN_ID" --node "$NODE" --gas 300000 --gas-prices 2000000000arai \
  --generate-only --output json > /tmp/tx_unsigned_${JOB_ID}.json 2>/dev/null

python3 << PYFIX
import bech32, json
tx = json.load(open('/tmp/tx_unsigned_${JOB_ID}.json'))
_, data = bech32.bech32_decode('$WALLET_ADDR')
valoper = bech32.bech32_encode('raivaloper', data)
tx['body']['messages'][0]['validator'] = valoper
json.dump(tx, open('/tmp/tx_unsigned_${JOB_ID}.json', 'w'))
PYFIX

republicd tx sign /tmp/tx_unsigned_${JOB_ID}.json \
  --from "$WALLET" --home "$HOME_DIR" --keyring-backend test \
  --chain-id "$CHAIN_ID" --node "$NODE" \
  --output-document /tmp/tx_signed_${JOB_ID}.json 2>/dev/null

SUBMIT_OUT=$(republicd tx broadcast /tmp/tx_signed_${JOB_ID}.json --node "$NODE" --chain-id "$CHAIN_ID" 2>&1)
SUBMIT_TX=$(echo "$SUBMIT_OUT" | grep -m1 'txhash:' | awk '{print $2}')
echo "Submit TX: ${SUBMIT_TX:-failed}" >> "$LOG"
echo "DONE Job $JOB_ID ✅" >> "$LOG"
