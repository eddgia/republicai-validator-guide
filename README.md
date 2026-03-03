# RepublicAI Validator & Compute Guide — CPU & GPU

> **Complete guide to run a RepublicAI validator with compute jobs on testnet**  
> Supports both **CPU-only** and **GPU (NVIDIA CUDA)** setups  
> Network: `raitestnet_77701-1` | Last updated: 2026-03-03

---

## Table of Contents

1. [Overview](#1-overview)
2. [Hardware Requirements](#2-hardware-requirements)
3. [Install Node & Sync](#3-install-node--sync)
4. [Create Wallet & Validator](#4-create-wallet--validator)
5. [Setup Docker & Inference Image](#5-setup-docker--inference-image)
6. [Patch inference.py (Required)](#6-patch-inferencepy-required)
7. [Setup Result HTTP Endpoint](#7-setup-result-http-endpoint)
8. [Deploy Auto-Compute Service](#8-deploy-auto-compute-service)
9. [Deploy Job Sidecar (Committee Verification)](#9-deploy-job-sidecar-committee-verification)
10. [Submit Your First Job](#10-submit-your-first-job)
11. [Monitoring & Queries](#11-monitoring--queries)
12. [Health Check Script](#12-health-check-script)
13. [Troubleshooting](#13-troubleshooting)
14. [Architecture](#14-architecture)

---

## 1. Overview

RepublicAI is a decentralized compute network. Validators can earn rewards by:

- **Mining**: Running GPU/CPU inference jobs assigned to your validator
- **Committee Verification**: Verifying other validators' job results and voting

### How It Works

```
Submit Job → Assigned to Validator → Run Inference → Submit Result → Committee Verifies → Settlement
(On-Chain)     (PendingExecution)     (Off-Chain)     (On-Chain)       (Off-Chain)         (On-Chain)
```

### Key Info

| Property | Value |
|----------|-------|
| Chain ID | `raitestnet_77701-1` |
| Denom | `arai` (base), `RAI` (display) |
| Decimals | 18 (1 RAI = 10^18 arai) |
| Min Gas Price | `250000000arai` |
| Job Fee | 1 RAI per job |
| RPC | `https://rpc.republicai.io` (public) or `tcp://localhost:26657` (local) |
| REST | `https://rest.republicai.io` |

---

## 2. Hardware Requirements

### CPU-Only Setup (Budget / VPS)

| Component | Minimum |
|-----------|---------|
| **CPU** | 4+ cores (x86_64 or ARM64) |
| **RAM** | 16 GB |
| **Storage** | 500 GB SSD |
| **OS** | Ubuntu 22.04 / 24.04 LTS |
| **Network** | 100 Mbps |

> ⚠️ CPU inference is **~10x slower** than GPU (~77s vs ~8s per job). Fine for testnet.

### GPU Setup (Recommended)

| Component | Consumer Grade | Enterprise |
|-----------|---------------|------------|
| **CPU** | AMD Ryzen 9 / Intel i9 (12+ cores) | AMD EPYC / Intel Xeon (32+ cores) |
| **GPU** | NVIDIA RTX 3090/4090 (24GB VRAM) | 1-4x NVIDIA A100/H100 (80GB VRAM) |
| **RAM** | 64 GB DDR5 | 256 GB+ ECC |
| **Storage** | 1 TB NVMe Gen4 | 4 TB+ NVMe RAID |
| **CUDA** | 11.8+ | 12.x |

---

## 3. Install Node & Sync

### 3.1 Install republicd binary

```bash
# Auto-detect latest release and architecture
VERSION=$(curl -s https://api.github.com/repos/RepublicAI/networks/releases/latest | jq -r .tag_name)
ARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')

curl -L "https://github.com/RepublicAI/networks/releases/download/${VERSION}/republicd-linux-${ARCH}" -o /tmp/republicd
chmod +x /tmp/republicd
sudo mv /tmp/republicd /usr/local/bin/republicd

# Verify
republicd version --long
```

### 3.2 Initialize node

```bash
REPUBLIC_HOME="$HOME/.republicd"

republicd init <your-moniker> \
  --chain-id raitestnet_77701-1 \
  --home "$REPUBLIC_HOME"

# Download genesis
curl -s https://raw.githubusercontent.com/RepublicAI/networks/main/testnet/genesis.json \
  > "$REPUBLIC_HOME/config/genesis.json"
```

### 3.3 Sync (choose one)

#### Option A: State Sync (Recommended — fast)

```bash
SNAP_RPC="https://statesync.republicai.io"
LATEST_HEIGHT=$(curl -s $SNAP_RPC/block | jq -r .result.block.header.height)
BLOCK_HEIGHT=$((LATEST_HEIGHT - 1000))
TRUST_HASH=$(curl -s "$SNAP_RPC/block?height=$BLOCK_HEIGHT" | jq -r .result.block_id.hash)

sed -i.bak -E "s|^(enable[[:space:]]+=[[:space:]]+).*$|\1true| ; \
s|^(rpc_servers[[:space:]]+=[[:space:]]+).*$|\1\"$SNAP_RPC,$SNAP_RPC\"| ; \
s|^(trust_height[[:space:]]+=[[:space:]]+).*$|\1$BLOCK_HEIGHT| ; \
s|^(trust_hash[[:space:]]+=[[:space:]]+).*$|\1\"$TRUST_HASH\"|" \
  "$REPUBLIC_HOME/config/config.toml"
```

#### Option B: Full Sync from Genesis (slower but complete history)

No additional config needed, just start the node.

### 3.4 Configure peers

```bash
PEERS="cd10f1a4162e3a4fadd6993a24fd5a32b27b8974@52.201.231.127:26656,f13fec7efb7538f517c74435e082c7ee54b4a0ff@3.208.19.30:26656"
sed -i.bak -e "s/^persistent_peers *=.*/persistent_peers = \"$PEERS\"/" \
  "$REPUBLIC_HOME/config/config.toml"
```

### 3.5 Create systemd service

```bash
sudo tee /etc/systemd/system/republicd.service > /dev/null << EOF
[Unit]
Description=Republic Protocol Node
After=network-online.target

[Service]
User=$USER
ExecStart=/usr/local/bin/republicd start --home $HOME/.republicd --chain-id raitestnet_77701-1
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now republicd
```

### 3.6 Wait for sync

```bash
# Check sync status (wait until catching_up=false)
watch -n 5 'curl -s http://localhost:26657/status | jq .result.sync_info'
```

---

## 4. Create Wallet & Validator

### 4.1 Create wallet

```bash
# Create new key
republicd keys add my-wallet --home ~/.republicd --keyring-backend test

# ⚠️ SAVE YOUR MNEMONIC! It cannot be recovered if lost.

# Or import existing mnemonic
republicd keys add my-wallet --recover --home ~/.republicd --keyring-backend test
```

### 4.2 Get testnet tokens

Contact the RepublicAI team on [Discord](https://discord.com/invite/republicai) for testnet RAI tokens.

### 4.3 Create validator

```bash
republicd tx staking create-validator \
  --amount=1000000000000000000000arai \
  --pubkey=$(republicd comet show-validator --home ~/.republicd) \
  --moniker="<your-moniker>" \
  --chain-id=raitestnet_77701-1 \
  --commission-rate="0.10" \
  --commission-max-rate="0.20" \
  --commission-max-change-rate="0.01" \
  --min-self-delegation="1" \
  --gas=auto --gas-adjustment=1.5 \
  --gas-prices="250000000arai" \
  --from=my-wallet \
  --home ~/.republicd \
  --keyring-backend test -y
```

### 4.4 Check addresses

```bash
# Wallet address (rai1...)
WALLET=$(republicd keys show my-wallet -a --home ~/.republicd --keyring-backend test)
echo "Wallet: $WALLET"

# Validator operator address (raivaloper1...)
VALOPER=$(republicd keys show my-wallet --bech val -a --home ~/.republicd --keyring-backend test)
echo "Valoper: $VALOPER"
```

### Validator Bond Status

| Status | Submit Jobs | Run Compute | Submit Results On-Chain |
|--------|:-----------:|:-----------:|:----------------------:|
| **BONDED** (top 100) | ✅ | ✅ | ✅ |
| **UNBONDED** | ✅ | ✅ | ❌ |

> Even if unbonded, you can still submit jobs and run compute. Only on-chain result submission requires bonded status.

---

## 5. Setup Docker & Inference Image

### 5.1 Install Docker

```bash
# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

### 5.2 GPU Only: Install NVIDIA Container Toolkit

Skip this section if you are running **CPU-only**.

```bash
# Install NVIDIA drivers (if not already installed)
sudo apt-get install -y nvidia-driver-535

# Install NVIDIA Container Toolkit
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L "https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list" \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Verify GPU access in Docker
docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi
```

### 5.3 Install dependencies

```bash
sudo apt-get install -y jq
pip install bech32 republic-core-utils
```

### 5.4 Build inference Docker image

```bash
# Clone devtools
git clone https://github.com/RepublicAI/devtools.git ~/devtools
cd ~/devtools && pip install -e .

# Build image (downloads LLM model, ~10-30 min first time)
cd ~/devtools/containers/llm-inference
docker build -t republic-llm-inference:latest .

# Verify
docker images | grep republic-llm-inference
```

---

## 6. Patch inference.py (Required)

> **Known Bug**: The official `inference.py` only writes to stdout. It does NOT write `/output/result.bin` as the protocol requires.

### 6.1 Extract and patch

```bash
# Extract official file from Docker image
docker run --rm --entrypoint cat republic-llm-inference:latest /app/inference.py > ~/inference.py

# Apply patch
python3 << 'PATCH'
with open('inference.py', 'r') as f:
    content = f.read()

old = '    print(json.dumps(result, indent=2))'
new = '''    result_json = json.dumps(result, indent=2)
    print(result_json)

    # Write to /output/result.bin (Republic protocol requirement)
    output_path = os.getenv("OUTPUT_PATH", "/output/result.bin")
    try:
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        with open(output_path, "w") as f:
            f.write(result_json)
        print(f"\\n✓ Result written to {output_path}")
    except Exception as e:
        import sys
        print(f"\\n⚠ Could not write to {output_path}: {e}", file=sys.stderr)'''

content = content.replace(old, new)

with open('inference.py', 'w') as f:
    f.write(content)

print("✓ Patch applied")
PATCH
```

### 6.2 Test inference

```bash
mkdir -p /tmp/test-inference

# GPU mode
docker run --rm --gpus all \
  -v /tmp/test-inference:/output \
  -v ~/inference.py:/app/inference.py \
  republic-llm-inference:latest

# CPU mode (no --gpus flag)
# docker run --rm \
#   -v /tmp/test-inference:/output \
#   -v ~/inference.py:/app/inference.py \
#   republic-llm-inference:latest

# Verify
test -f /tmp/test-inference/result.bin && echo "✅ PASS" || echo "❌ FAIL"
cat /tmp/test-inference/result.bin | python3 -m json.tool

# Cleanup
rm -rf /tmp/test-inference
```

> ⏱ **Performance**: GPU ~8s | CPU ~77s per inference

---

## 7. Setup Result HTTP Endpoint

The protocol needs your `result.bin` files accessible via HTTP for committee verification.

### 7.1 Create jobs directory and HTTP service

```bash
JOBS_DIR="/var/lib/republic/jobs"  # or ~/republic-jobs for non-root
sudo mkdir -p $JOBS_DIR

sudo tee /etc/systemd/system/republic-http.service > /dev/null << 'EOF'
[Unit]
Description=Republic Jobs HTTP Server (port 8080)
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/republic/jobs
ExecStart=/usr/bin/python3 -m http.server 8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now republic-http
```

### 7.2 Get your public IP

```bash
PUBLIC_IP=$(curl -s ifconfig.me)
echo "Your result URL: http://$PUBLIC_IP:8080"
```

### 7.3 Open firewall port

```bash
sudo ufw allow 8080/tcp
```

### 7.4 Verify endpoint

```bash
curl -s -o /dev/null -w "HTTP %{http_code}" http://localhost:8080/
# Expected: HTTP 200
```

> **Optional**: For HTTPS without port forwarding, use [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) to expose port 8080 behind your domain.

---

## 8. Deploy Auto-Compute Service

Auto-compute polls the chain for new jobs targeting your validator, runs inference, and submits results on-chain.

> **Why auto-compute?** The official sidecar has two known testnet bugs:
> 1. `inference.py` doesn't write `result.bin`
> 2. `submit-job-result` crashes on bech32 conversion (`rai1...` → `raivaloper1...`)
>
> Auto-compute works around both.

### 8.1 Set your variables

```bash
# Replace these with YOUR values
WALLET_ADDR="rai1..."           # republicd keys show my-wallet -a
VALOPER_ADDR="raivaloper1..."   # republicd keys show my-wallet --bech val -a
KEY_NAME="my-wallet"
RESULT_BASE_URL="http://YOUR_PUBLIC_IP:8080"
DOCKER_GPU_FLAG="--gpus all"    # GPU mode
# DOCKER_GPU_FLAG=""            # CPU mode (remove --gpus all)
```

### 8.2 Create the auto-compute script

```bash
cat > ~/auto-compute.sh << 'SCRIPT_EOF'
#!/usr/bin/env bash
set -uo pipefail

# ========== CONFIGURATION ==========
WALLET_NAME="my-wallet"
NODE="tcp://127.0.0.1:26657"
CHAIN_ID="raitestnet_77701-1"
JOBS_DIR="/var/lib/republic/jobs"       # Match your HTTP server WorkingDirectory
SERVER_BASE="http://YOUR_PUBLIC_IP:8080" # Your public result URL
EXEC_IMAGE="republic-llm-inference:latest"
VERIFY_IMAGE="example-verification:latest"
DOCKER_GPU="--gpus all"                 # Remove for CPU-only
LOG_PREFIX="[auto-compute]"
# ====================================

mkdir -p "$JOBS_DIR"
WALLET_ADDR=$(republicd keys show "$WALLET_NAME" --address --home ~/.republicd --keyring-backend test)
VALOPER_ADDR=$(republicd keys show "$WALLET_NAME" --bech val --address --home ~/.republicd --keyring-backend test)

echo "$LOG_PREFIX wallet=$WALLET_ADDR"
echo "$LOG_PREFIX validator=$VALOPER_ADDR"

while true; do
  # Query all pending jobs targeting our validator
  jobs_json=$(republicd query computevalidation list-job --node "$NODE" --output json 2>/dev/null || echo '{"jobs":[]}')

  python3 - "$jobs_json" "$VALOPER_ADDR" > /tmp/auto_jobs.txt <<'PY'
import json,sys
raw=sys.argv[1]; val=sys.argv[2]
try: data=json.loads(raw)
except: data={"jobs":[]}
for j in data.get("jobs", []):
    if j.get("target_validator") == val and j.get("status") == "PendingExecution":
        print(j.get("id", ""))
PY

  while read -r JOB_ID; do
    [ -z "$JOB_ID" ] && continue
    RESULT_FILE="$JOBS_DIR/$JOB_ID/result.bin"

    # Skip if already computed
    if [ -f "$RESULT_FILE" ]; then continue; fi

    echo "$LOG_PREFIX executing job=$JOB_ID"
    mkdir -p "$JOBS_DIR/$JOB_ID"

    # Run inference (GPU or CPU)
    if ! docker run --rm $DOCKER_GPU \
      -v "$JOBS_DIR/$JOB_ID:/output" \
      -v ~/inference.py:/app/inference.py \
      "$EXEC_IMAGE" >/tmp/auto_compute_${JOB_ID}.log 2>&1; then
      echo "$LOG_PREFIX docker_failed job=$JOB_ID"
      continue
    fi

    if [ ! -f "$RESULT_FILE" ]; then
      echo "$LOG_PREFIX missing_result job=$JOB_ID"
      continue
    fi

    # Calculate hash
    SHA256=$(python3 -c "import hashlib;print(hashlib.sha256(open('$RESULT_FILE','rb').read()).hexdigest())")
    FETCH_ENDPOINT="$SERVER_BASE/$JOB_ID/result.bin"

    # Generate unsigned TX
    if ! republicd tx computevalidation submit-job-result \
      "$JOB_ID" "$FETCH_ENDPOINT" "$VERIFY_IMAGE" "$SHA256" \
      --from "$WALLET_NAME" --home ~/.republicd --keyring-backend test \
      --chain-id "$CHAIN_ID" --node "$NODE" \
      --gas 300000 --gas-prices 2000000000arai \
      --generate-only --output json > "/tmp/tx_unsigned_${JOB_ID}.json" 2>/dev/null; then
      echo "$LOG_PREFIX tx_generate_failed job=$JOB_ID"
      continue
    fi

    # Patch bech32 validator address (rai1... → raivaloper1...)
    python3 - "$WALLET_ADDR" "/tmp/tx_unsigned_${JOB_ID}.json" <<'PY'
import bech32, json, sys
wallet = sys.argv[1]; path = sys.argv[2]
hrp, data = bech32.bech32_decode(wallet)
if data is None: raise SystemExit("invalid_wallet_bech32")
valoper = bech32.bech32_encode("raivaloper", data)
tx = json.load(open(path))
tx["body"]["messages"][0]["validator"] = valoper
json.dump(tx, open(path, "w"))
PY

    # Sign TX
    if ! republicd tx sign "/tmp/tx_unsigned_${JOB_ID}.json" \
      --from "$WALLET_NAME" --home ~/.republicd --keyring-backend test \
      --chain-id "$CHAIN_ID" --node "$NODE" \
      --output-document "/tmp/tx_signed_${JOB_ID}.json" 2>/dev/null; then
      echo "$LOG_PREFIX tx_sign_failed job=$JOB_ID"
      continue
    fi

    # Broadcast
    if republicd tx broadcast "/tmp/tx_signed_${JOB_ID}.json" \
      --node "$NODE" --chain-id "$CHAIN_ID" > "/tmp/tx_broadcast_${JOB_ID}.out" 2>&1; then
      TXHASH=$(grep -m1 '^txhash:' "/tmp/tx_broadcast_${JOB_ID}.out" | awk '{print $2}' || true)
      echo "$LOG_PREFIX submitted job=$JOB_ID txhash=${TXHASH:-unknown}"
    else
      echo "$LOG_PREFIX tx_broadcast_failed job=$JOB_ID"
    fi
  done < /tmp/auto_jobs.txt

  sleep 30
done
SCRIPT_EOF

chmod +x ~/auto-compute.sh
```

### 8.3 CPU vs GPU modes

Edit the `DOCKER_GPU` variable in the script:

```bash
# GPU mode (default)
DOCKER_GPU="--gpus all"

# CPU mode (remove GPU flag)
DOCKER_GPU=""
```

### 8.4 Create systemd service

```bash
sudo tee /etc/systemd/system/republic-autocompute.service > /dev/null << EOF
[Unit]
Description=Republic Auto-Compute Job Processor
After=network-online.target republicd.service

[Service]
Type=simple
User=$USER
ExecStart=$HOME/auto-compute.sh
Restart=always
RestartSec=10
StandardOutput=append:$HOME/auto-compute.log
StandardError=append:$HOME/auto-compute.log

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now republic-autocompute
```

---

## 9. Deploy Job Sidecar (Committee Verification)

The sidecar handles **committee verification** — downloading and verifying other validators' job results.

```bash
sudo tee /etc/systemd/system/republic-sidecar.service > /dev/null << EOF
[Unit]
Description=Republic Compute Job Sidecar
After=network-online.target republicd.service

[Service]
Type=simple
User=$USER
ExecStart=/usr/local/bin/republicd tx computevalidation job-sidecar \
  --from my-wallet \
  --work-dir /var/lib/republic/jobs \
  --poll-interval 10s \
  --home $HOME/.republicd \
  --node tcp://localhost:26657 \
  --chain-id raitestnet_77701-1 \
  --gas auto --gas-adjustment 1.5 \
  --keyring-backend test
Restart=always
RestartSec=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now republic-sidecar
```

### Role of each service

| Service | Role | What it does |
|---------|------|-------------|
| **republic-autocompute** | Mining | YOUR jobs → inference → submit result |
| **republic-sidecar** | Committee | OTHER validators' jobs → download → verify → vote |
| **republic-http** | File Server | Serve result files for committee access |
| **republicd** | Node | Sync chain, sign transactions |

---

## 10. Submit Your First Job

### 10.1 Submit a job targeting your own validator

```bash
VALOPER=$(republicd keys show my-wallet --bech val -a --home ~/.republicd --keyring-backend test)
RESULT_URL="http://YOUR_PUBLIC_IP:8080"

republicd tx computevalidation submit-job \
  $VALOPER \
  republic-llm-inference:latest \
  $RESULT_URL/upload \
  $RESULT_URL \
  example-verification:latest \
  1000000000000000000arai \
  --from my-wallet \
  --home ~/.republicd \
  --chain-id raitestnet_77701-1 \
  --gas 300000 --gas-prices 1000000000arai \
  --node tcp://localhost:26657 \
  --keyring-backend test -y
```

> 💰 Cost: **1 RAI** per job (escrowed, returned if job fails)

### 10.2 Get job ID from TX

```bash
TX_HASH="<from output>"
republicd query tx $TX_HASH --node tcp://localhost:26657 -o json | \
  jq -r '.events[] | select(.type=="job_submitted") | .attributes[] | select(.key=="job_id") | .value'
```

### 10.3 Wait for auto-compute or force-compute

```bash
# Watch auto-compute log
tail -f ~/auto-compute.log

# Or manually force a specific job
# (create ~/force-compute.sh with job-specific commands)
```

---

## 11. Monitoring & Queries

### Check specific job status

```bash
republicd query computevalidation job <JOB_ID> --node tcp://localhost:26657 -o json | \
  jq '{id: .job.id, status: .job.status, result_hash: .job.result_hash}'
```

### List all jobs targeting your validator

```bash
VALOPER=$(republicd keys show my-wallet --bech val -a --home ~/.republicd --keyring-backend test)

republicd query computevalidation list-job --node tcp://localhost:26657 -o json | \
  jq ".jobs[] | select(.target_validator==\"$VALOPER\") | {id, status}"
```

### Find unprocessed jobs

```bash
republicd query computevalidation list-job --node tcp://localhost:26657 -o json | \
  jq '.jobs[] | select(.status=="PendingExecution") | {id, target_validator, status}'
```

### Check wallet balance

```bash
WALLET=$(republicd keys show my-wallet -a --home ~/.republicd --keyring-backend test)
republicd query bank balances $WALLET --node tcp://localhost:26657 -o json | \
  jq '.balances'
```

### Check validator status

```bash
VALOPER=$(republicd keys show my-wallet --bech val -a --home ~/.republicd --keyring-backend test)
republicd query staking validator $VALOPER --node tcp://localhost:26657 -o json | \
  jq '{status, tokens, delegator_shares}'
```

---

## 12. Health Check Script

Save as `~/health-check.sh`:

```bash
#!/bin/bash
echo "=== RepublicAI Health Check ==="

# 1. Node sync
SYNC=$(curl -s http://localhost:26657/status | jq -r '.result.sync_info.catching_up')
echo "Node synced:        $([ "$SYNC" = "false" ] && echo "✅ YES" || echo "❌ NO")"

# 2. Validator
VALOPER=$(republicd keys show my-wallet --bech val -a --home ~/.republicd --keyring-backend test 2>/dev/null)
BOND=$(republicd query staking validator $VALOPER --node tcp://localhost:26657 -o json 2>/dev/null | jq -r '.status')
echo "Validator bonded:   $([ "$BOND" = "BOND_STATUS_BONDED" ] && echo "✅ YES" || echo "⚠️  $BOND")"

# 3. Balance
WALLET=$(republicd keys show my-wallet -a --home ~/.republicd --keyring-backend test 2>/dev/null)
BAL=$(republicd query bank balances $WALLET --node tcp://localhost:26657 -o json 2>/dev/null | jq -r '.balances[] | select(.denom=="arai") | .amount')
BAL_RAI=$(python3 -c "print(f'{int(\"${BAL:-0}\") / 10**18:.2f}')" 2>/dev/null)
echo "Balance:            ${BAL_RAI:-0} RAI"

# 4. Services
for svc in republicd republic-autocompute republic-http republic-sidecar; do
  STATUS=$(systemctl is-active $svc 2>/dev/null || echo "not-found")
  echo "Service $svc: $([ "$STATUS" = "active" ] && echo "✅" || echo "❌ $STATUS")"
done

# 5. HTTP endpoint
HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/ 2>/dev/null)
echo "HTTP server:        $([ "$HTTP" = "200" ] && echo "✅ OK" || echo "❌ HTTP $HTTP")"

# 6. Docker image
IMG=$(docker images -q republic-llm-inference:latest 2>/dev/null)
echo "Docker image:       $([ -n "$IMG" ] && echo "✅ exists" || echo "❌ missing")"

# 7. Patched inference.py
PATCH=$(grep -c "result.bin" ~/inference.py 2>/dev/null || echo "0")
echo "inference.py patch: $([ "$PATCH" -ge 2 ] && echo "✅ YES" || echo "❌ NO")"

# 8. GPU
if command -v nvidia-smi &>/dev/null; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  echo "GPU:                ✅ $GPU_NAME"
else
  echo "GPU:                ⚠️  None (CPU-only mode)"
fi

echo "=== End Health Check ==="
```

```bash
chmod +x ~/health-check.sh
bash ~/health-check.sh
```

---

## 13. Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| Docker GPU fails | NVIDIA Container Toolkit missing | Install nvidia-container-toolkit, restart docker |
| No `result.bin` after inference | Original inference.py bug | Mount patched version (Step 6) |
| `submit-job-result` bech32 error | Known testnet bug | Auto-compute handles this with generate→patch→sign→broadcast |
| Job stuck at `PendingValidation` | Not enough committee members | Normal on testnet, no action needed |
| `Out of Gas` | Gas too low | Use `--gas auto --gas-adjustment 1.5` |
| HTTP 404 on result URL | result.bin doesn't exist | Run inference for that job first |
| `ModuleNotFoundError: bech32` | Python module missing | `pip install bech32` |
| Service keeps restarting | Wrong KEY_NAME/CHAIN_ID/node not synced | Check `journalctl -u <service> -n 50` |
| CPU inference too slow | No GPU | Normal (~77s vs ~8s). Consider GPU upgrade |

### Useful commands

```bash
# Restart a service
sudo systemctl restart republic-autocompute

# View service logs
journalctl -u republic-autocompute --no-pager -n 50

# View auto-compute log
tail -f ~/auto-compute.log

# Unjail validator
republicd tx slashing unjail \
  --from my-wallet --chain-id raitestnet_77701-1 \
  --gas auto --gas-adjustment 1.5 --gas-prices 250000000arai \
  --home ~/.republicd --keyring-backend test -y
```

---

## 14. Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   RepublicAI Node                       │
│                                                         │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │republicd │    │ auto-compute │    │  job-sidecar  │  │
│  │ (chain)  │◄──▶│  (mining)    │    │ (committee)   │  │
│  └──────────┘    └──────┬───────┘    └──────────────┘  │
│                         │                               │
│                   ┌─────▼─────┐                        │
│                   │  Docker   │                        │
│                   │ GPU / CPU │                        │
│                   │ inference │                        │
│                   └─────┬─────┘                        │
│                         │                               │
│                   ┌─────▼─────┐    ┌──────────────┐    │
│                   │ /var/lib/ │    │ HTTP Server  │    │
│                   │ republic/ │───▶│   :8080      │    │
│                   │ jobs/     │    └──────┬───────┘    │
│                   └───────────┘           │            │
│                                    ┌─────▼─────┐      │
│                                    │  Internet │      │
│                                    │ (public)  │      │
│                                    └───────────┘      │
└─────────────────────────────────────────────────────────┘
```

### Job Lifecycle

```
Phase 1: Submission       → Requester submits MsgSubmitJob → Status: PendingExecution
Phase 2: Execution        → Auto-compute runs Docker inference → Produces result.bin
Phase 3: Result Submit    → Hash + upload → MsgSubmitJobResult → Status: PendingValidation
Phase 4: Verification     → Committee downloads & verifies result → Votes true/false
Phase 5: Settlement       → Majority true → Fee to miner | Majority false → Fee refunded
```

---

## References

- [Official Networks Repo](https://github.com/RepublicAI/networks)
- [Compute Provisioning Guide](https://github.com/RepublicAI/networks/blob/main/docs/compute-provisioning-guide.md)
- [DevTools & Docker Images](https://github.com/RepublicAI/devtools)
- [Community Node Guide](https://github.com/M4D2510/republic-ai-node)
- [Miner Guide (Agent)](https://github.com/billythekidz/republicai-miner-guide)
- [Discord](https://discord.com/invite/republicai)

---

## License

MIT — Feel free to use, modify, and share.
