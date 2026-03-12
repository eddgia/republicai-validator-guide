#!/usr/bin/env bash
set -uo pipefail

WALLET_NAME="my-wallet"
NODE="tcp://127.0.0.1:26657"
CHAIN_ID="raitestnet_77701-1"
JOBS_DIR="/home/akonkat/republic-jobs"
SERVER_BASE="http://127.0.0.1:8080"
EXEC_IMAGE="devtools-llm-inference:latest"
VERIFY_IMAGE="example-verification:latest"
LOG_PREFIX="[auto-compute]"

mkdir -p "$JOBS_DIR"
WALLET_ADDR=$(republicd keys show "$WALLET_NAME" --address --home /home/akonkat/.republicd --keyring-backend test)
VALOPER_ADDR=$(republicd keys show "$WALLET_NAME" --bech val --address --home /home/akonkat/.republicd --keyring-backend test)

echo "$LOG_PREFIX wallet=$WALLET_ADDR"
echo "$LOG_PREFIX validator=$VALOPER_ADDR"

while true; do
  if ! republicd query computevalidation list-job --node "$NODE" --output json --limit 500 2>/dev/null | \
    jq -r --arg v "$VALOPER_ADDR" '.jobs[]? | select(.target_validator==$v and .status=="PendingExecution") | .id' > /tmp/auto_jobs.txt; then
    : > /tmp/auto_jobs.txt
  fi

  while read -r JOB_ID; do
    [ -z "$JOB_ID" ] && continue

    JOB_DIR="$JOBS_DIR/$JOB_ID"
    RESULT_FILE="$JOB_DIR/result.bin"

    if [ -f "$RESULT_FILE" ]; then
      continue
    fi

    echo "$LOG_PREFIX executing job=$JOB_ID"
    mkdir -p "$JOB_DIR"

    if ! docker run --rm --gpus all -v "$JOB_DIR:/output" -v /home/akonkat/inference.py:/app/inference.py "$EXEC_IMAGE" >/tmp/auto_compute_${JOB_ID}.log 2>&1; then
      echo "$LOG_PREFIX docker_failed job=$JOB_ID"
      continue
    fi

    if [ ! -f "$RESULT_FILE" ]; then
      echo "$LOG_PREFIX missing_result job=$JOB_ID"
      continue
    fi

    SHA256=$(python3 -c "import hashlib;print(hashlib.sha256(open('$RESULT_FILE','rb').read()).hexdigest())")
    FETCH_ENDPOINT="$SERVER_BASE/$JOB_ID/result.bin"

    if ! republicd tx computevalidation submit-job-result \
      "$JOB_ID" \
      "$FETCH_ENDPOINT" \
      "$VERIFY_IMAGE" \
      "$SHA256" \
      --from "$WALLET_NAME" \
      --home /home/akonkat/.republicd \
      --keyring-backend test \
      --chain-id "$CHAIN_ID" \
      --node "$NODE" \
      --gas 300000 \
      --gas-prices 2000000000arai \
      --generate-only \
      --output json > "/tmp/tx_unsigned_${JOB_ID}.json" 2>"/tmp/txgen_${JOB_ID}.err"; then
      echo "$LOG_PREFIX tx_generate_failed job=$JOB_ID"
      continue
    fi

    if ! sed -i "s/\"validator\":\"$WALLET_ADDR\"/\"validator\":\"$VALOPER_ADDR\"/" "/tmp/tx_unsigned_${JOB_ID}.json"; then
      echo "$LOG_PREFIX validator_patch_failed job=$JOB_ID"
      continue
    fi

    if ! republicd tx sign "/tmp/tx_unsigned_${JOB_ID}.json" \
      --from "$WALLET_NAME" \
      --home /home/akonkat/.republicd \
      --keyring-backend test \
      --chain-id "$CHAIN_ID" \
      --node "$NODE" \
      --output-document "/tmp/tx_signed_${JOB_ID}.json" >"/tmp/txsign_${JOB_ID}.out" 2>"/tmp/txsign_${JOB_ID}.err"; then
      echo "$LOG_PREFIX tx_sign_failed job=$JOB_ID"
      continue
    fi

    if republicd tx broadcast "/tmp/tx_signed_${JOB_ID}.json" --node "$NODE" --chain-id "$CHAIN_ID" >"/tmp/tx_broadcast_${JOB_ID}.out" 2>"/tmp/tx_broadcast_${JOB_ID}.err"; then
      TXHASH=$(grep -m1 '^txhash:' "/tmp/tx_broadcast_${JOB_ID}.out" | awk '{print $2}' || true)
      echo "$LOG_PREFIX submitted job=$JOB_ID txhash=${TXHASH:-unknown}"
    else
      echo "$LOG_PREFIX tx_broadcast_failed job=$JOB_ID"
    fi
  done < /tmp/auto_jobs.txt

  sleep 30
done
