#!/bin/bash
# Republic AI - Full Auto Compute Script
# Based on: https://github.com/M4D2510/republic-ai-node/blob/master/compute/FULL-AUTO.md
# Customized for this node

VALOPER="raivaloper1yqz02uvdthefkvn2prsn73wf7geveqcj3jphpk"
WALLET="rai1yqz02uvdthefkvn2prsn73wf7geveqcjk8p22q"
NODE="tcp://localhost:26657"
CHAIN_ID="raitestnet_77701-1"
SERVER_IP="172.31.79.17"
JOBS_DIR="/home/akonkat/republic-jobs"
PASSWORD="gia01656"
JOB_FEE="5000000000000000arai"
LOG_PREFIX="[full-auto]"
WALLET_NAME="my-wallet"

# Ensure jobs dir exists
mkdir -p "$JOBS_DIR"

# Start HTTP server if not running
if ! pgrep -f "python3 -m http.server 8080" > /dev/null; then
  echo "$LOG_PREFIX Starting HTTP server on port 8080..."
  cd "$JOBS_DIR" && python3 -m http.server 8080 &
  cd /home/akonkat
  sleep 2
fi

echo "$LOG_PREFIX 🚀 Full Auto started..."
echo "$LOG_PREFIX Validator: $VALOPER"
echo "$LOG_PREFIX Wallet: $WALLET"

while true; do
  # Step 1: Submit new job
  echo "$LOG_PREFIX 📤 Submitting new job..."
  TX=$(echo "$PASSWORD" | republicd tx computevalidation submit-job \
    $VALOPER \
    republic-llm-inference:latest \
    http://$SERVER_IP:8080/upload \
    http://$SERVER_IP:8080/result \
    example-verification:latest \
    $JOB_FEE \
    --from $WALLET_NAME \
    --home /home/akonkat/.republicd \
    --chain-id $CHAIN_ID \
    --gas auto \
    --gas-adjustment 1.5 \
    --gas-prices 1000000000arai \
    --node $NODE \
    --keyring-backend test \
    -y 2>/dev/null | grep txhash | awk '{print $2}')

  if [ -z "$TX" ]; then
    echo "$LOG_PREFIX ❌ TX submission failed, retrying in 60s..."
    sleep 60
    continue
  fi
  echo "$LOG_PREFIX ✅ TX: $TX"

  # Step 2: Wait and get Job ID
  sleep 15
  JOB_ID=$(republicd query tx $TX --node $NODE -o json 2>/dev/null | \
    jq -r '.events[] | select(.type=="job_submitted") | .attributes[] | select(.key=="job_id") | .value')

  if [ -z "$JOB_ID" ] || [ "$JOB_ID" = "null" ]; then
    echo "$LOG_PREFIX ❌ Job ID not found for TX $TX, skipping..."
    sleep 30
    continue
  fi
  echo "$LOG_PREFIX 📋 Job ID: $JOB_ID"

  # Step 3: Run GPU inference
  RESULT_FILE="$JOBS_DIR/$JOB_ID/result.bin"
  echo "$LOG_PREFIX ⚙️  Processing job $JOB_ID..."
  mkdir -p "$JOBS_DIR/$JOB_ID"

  timeout 120 docker run --rm --gpus all \
    -v "$JOBS_DIR/$JOB_ID":/output \
    -v /home/akonkat/inference.py:/app/inference.py \
    devtools-llm-inference:latest 2>/dev/null

  if [ $? -ne 0 ]; then
    echo "$LOG_PREFIX ❌ Docker timeout/error for job $JOB_ID, skipping..."
    docker ps -q --filter ancestor=devtools-llm-inference:latest | xargs -r docker kill 2>/dev/null
    sleep 30
    continue
  fi
  echo "$LOG_PREFIX ✅ Inference done for job $JOB_ID"

  # Step 4: Submit result
  if [ -f "$RESULT_FILE" ]; then
    echo "$LOG_PREFIX 📤 Submitting result for job $JOB_ID..."
    SHA256=$(sha256sum "$RESULT_FILE" | awk '{print $1}')

    # Generate unsigned TX
    echo "$PASSWORD" | republicd tx computevalidation submit-job-result \
      $JOB_ID \
      http://$SERVER_IP:8080/$JOB_ID/result.bin \
      example-verification:latest \
      $SHA256 \
      --from $WALLET_NAME \
      --home /home/akonkat/.republicd \
      --chain-id $CHAIN_ID \
      --gas 300000 \
      --gas-prices 1000000000arai \
      --node $NODE \
      --keyring-backend test \
      --generate-only 2>/dev/null > /tmp/tx_unsigned.json

    # Fix bech32 address bug
    python3 -c "
import bech32, json
tx = json.load(open('/tmp/tx_unsigned.json'))
_, data = bech32.bech32_decode('$WALLET')
valoper = bech32.bech32_encode('raivaloper', data)
tx['body']['messages'][0]['validator'] = valoper
json.dump(tx, open('/tmp/tx_unsigned.json', 'w'))
"

    # Sign TX
    echo "$PASSWORD" | republicd tx sign /tmp/tx_unsigned.json \
      --from $WALLET_NAME \
      --home /home/akonkat/.republicd \
      --chain-id $CHAIN_ID \
      --node $NODE \
      --keyring-backend test \
      --output-document /tmp/tx_signed.json 2>/dev/null

    # Broadcast
    RESULT_TX=$(republicd tx broadcast /tmp/tx_signed.json \
      --node $NODE \
      --chain-id $CHAIN_ID 2>/dev/null | grep txhash | awk '{print $2}')

    echo "$LOG_PREFIX 🎉 Job $JOB_ID result submitted! TX: $RESULT_TX"
    sleep 15
  else
    echo "$LOG_PREFIX ❌ No result file for job $JOB_ID"
  fi

  echo "$LOG_PREFIX ⏳ Waiting 30 seconds..."
  sleep 30
done
