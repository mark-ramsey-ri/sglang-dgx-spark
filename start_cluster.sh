#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SGLang DGX Spark Cluster - Unified Start Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Starts SGLang on both head and worker nodes from a single command.
# Run this script on the HEAD NODE - it will SSH to workers automatically.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
if [ -f "${SCRIPT_DIR}/config.local.env" ]; then
  source "${SCRIPT_DIR}/config.local.env"
elif [ -f "${SCRIPT_DIR}/config.env" ]; then
  source "${SCRIPT_DIR}/config.env"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Configuration with defaults
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Docker
SGLANG_IMAGE="${SGLANG_IMAGE:-lmsysorg/sglang:spark}"
HEAD_CONTAINER_NAME="${HEAD_CONTAINER_NAME:-sglang-head}"
WORKER_CONTAINER_NAME="${WORKER_CONTAINER_NAME:-sglang-worker}"
SHM_SIZE="${SHM_SIZE:-32g}"

# Model
MODEL="${MODEL:-openai/gpt-oss-120b}"
TENSOR_PARALLEL="${TENSOR_PARALLEL:-2}"
PIPELINE_PARALLEL="${PIPELINE_PARALLEL:-1}"
NUM_NODES="${NUM_NODES:-2}"
MEM_FRACTION="${MEM_FRACTION:-0.80}"

# Ports
SGLANG_PORT="${SGLANG_PORT:-30000}"
DIST_INIT_PORT="${DIST_INIT_PORT:-50000}"

# Storage
HF_CACHE="${HF_CACHE:-/raid/hf-cache}"
TIKTOKEN_DIR="${TIKTOKEN_DIR:-${HOME}/tiktoken_encodings}"

# SGLang options
REASONING_PARSER="${REASONING_PARSER:-gpt-oss}"
TOOL_CALL_PARSER="${TOOL_CALL_PARSER:-gpt-oss}"
DISABLE_CUDA_GRAPH="${DISABLE_CUDA_GRAPH:-true}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

# NCCL
NCCL_DEBUG="${NCCL_DEBUG:-INFO}"
NCCL_IB_DISABLE="${NCCL_IB_DISABLE:-0}"
NCCL_NET_GDR_LEVEL="${NCCL_NET_GDR_LEVEL:-5}"
NCCL_TIMEOUT="${NCCL_TIMEOUT:-1200000}"  # 20 minutes in ms (default is 5 min)

# Worker configuration
# WORKER_HOST: Ethernet IP for SSH access (e.g., 192.168.7.111)
# WORKER_IB_IP: InfiniBand IP for NCCL communication (e.g., 169.254.216.8)
# Legacy WORKER_IPS is supported for backwards compatibility
WORKER_HOST="${WORKER_HOST:-}"
WORKER_IB_IP="${WORKER_IB_IP:-${WORKER_IPS:-}}"  # Fallback to WORKER_IPS for backwards compat
WORKER_USER="${WORKER_USER:-$(whoami)}"
WORKER_SCRIPT_PATH="${WORKER_SCRIPT_PATH:-${SCRIPT_DIR}}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Auto-detect Network Configuration (Head Node)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Auto-detect HEAD_IP from InfiniBand interface
if [ -z "${HEAD_IP:-}" ]; then
  if command -v ibdev2netdev >/dev/null 2>&1; then
    PRIMARY_IB_IF=$(ibdev2netdev 2>/dev/null | grep "(Up)" | awk '{print $5}' | grep "^enp1" | head -1)
    if [ -z "${PRIMARY_IB_IF}" ]; then
      PRIMARY_IB_IF=$(ibdev2netdev 2>/dev/null | grep "(Up)" | awk '{print $5}' | head -1)
    fi
    if [ -n "${PRIMARY_IB_IF}" ]; then
      HEAD_IP=$(ip -o addr show "${PRIMARY_IB_IF}" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -1)
    fi
  fi
  if [ -z "${HEAD_IP:-}" ]; then
    echo "ERROR: Could not auto-detect HEAD_IP. Please set HEAD_IP in config.env"
    exit 1
  fi
fi

# Auto-detect network interfaces
if [ -z "${NCCL_SOCKET_IFNAME:-}" ] || [ -z "${GLOO_SOCKET_IFNAME:-}" ]; then
  if command -v ibdev2netdev >/dev/null 2>&1; then
    PRIMARY_IF=$(ibdev2netdev 2>/dev/null | grep "(Up)" | awk '{print $5}' | grep "^enp1" | head -1)
    if [ -z "${PRIMARY_IF}" ]; then
      PRIMARY_IF=$(ibdev2netdev 2>/dev/null | grep "(Up)" | awk '{print $5}' | head -1)
    fi
    NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-${PRIMARY_IF}}"
    GLOO_SOCKET_IFNAME="${GLOO_SOCKET_IFNAME:-${PRIMARY_IF}}"
  fi
fi

# Auto-detect InfiniBand HCAs
if [ -z "${NCCL_IB_HCA:-}" ]; then
  if command -v ibdev2netdev >/dev/null 2>&1; then
    IB_DEVICES=$(ibdev2netdev 2>/dev/null | grep "(Up)" | awk '{print $1}' | sort | tr '\n' ',' | sed 's/,$//')
    NCCL_IB_HCA="${IB_DEVICES:-}"
  fi
  if [ -z "${NCCL_IB_HCA:-}" ]; then
    IB_DEVICES=$(ls -1 /sys/class/infiniband/ 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    NCCL_IB_HCA="${IB_DEVICES:-}"
  fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Helper Functions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

error() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Parse Arguments
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

HEAD_ONLY=false
SKIP_PULL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --head-only)
      HEAD_ONLY=true
      shift
      ;;
    --skip-pull)
      SKIP_PULL=true
      shift
      ;;
    --worker-ip|--worker-ib-ip)
      WORKER_IB_IP="$2"
      shift 2
      ;;
    --worker-host)
      WORKER_HOST="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --head-only          Only start head node (don't SSH to workers)"
      echo "  --skip-pull          Skip Docker image pull (faster restart)"
      echo "  --worker-host IP     Worker Ethernet IP for SSH (e.g., 192.168.7.111)"
      echo "  --worker-ib-ip IP    Worker InfiniBand IP for NCCL (e.g., 169.254.216.8)"
      echo "  -h, --help           Show this help"
      echo ""
      echo "Environment variables (recommended):"
      echo "  WORKER_HOST          Worker Ethernet IP for SSH"
      echo "  WORKER_IB_IP         Worker InfiniBand IP for NCCL"
      echo ""
      echo "Configuration is read from config.env or config.local.env"
      echo ""
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Validate Worker Configuration
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ "${HEAD_ONLY}" != "true" ] && [ "${NUM_NODES}" -gt 1 ]; then
  if [ -z "${WORKER_IB_IP}" ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Worker Configuration Required"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "This is a ${NUM_NODES}-node cluster but no worker IPs are configured."
    echo ""
    echo "Please set these environment variables:"
    echo "  export WORKER_HOST=\"192.168.x.x\"    # Ethernet IP for SSH"
    echo "  export WORKER_IB_IP=\"169.254.x.x\"   # InfiniBand IP for NCCL"
    echo ""
    echo "Or start head only:"
    echo "  $0 --head-only"
    echo ""
    echo "To find worker IPs, run on the worker node:"
    echo "  hostname -I                          # Shows all IPs"
    echo "  ibdev2netdev && ip addr show <ib_if> # Shows IB interface IP"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
  fi

  # If WORKER_HOST not set, fall back to WORKER_IB_IP for SSH (backwards compat)
  if [ -z "${WORKER_HOST}" ]; then
    log "Warning: WORKER_HOST not set, using WORKER_IB_IP (${WORKER_IB_IP}) for SSH"
    WORKER_HOST="${WORKER_IB_IP}"
  fi
fi

# Convert WORKER_IB_IP to array (supports multiple workers: "ip1 ip2 ip3")
read -ra WORKER_IB_IP_ARRAY <<< "${WORKER_IB_IP}"
read -ra WORKER_HOST_ARRAY <<< "${WORKER_HOST}"
ACTUAL_NUM_WORKERS=${#WORKER_IB_IP_ARRAY[@]}

if [ "${HEAD_ONLY}" != "true" ] && [ "${NUM_NODES}" -gt 1 ]; then
  EXPECTED_WORKERS=$((NUM_NODES - 1))
  if [ "${ACTUAL_NUM_WORKERS}" -ne "${EXPECTED_WORKERS}" ]; then
    log "Warning: NUM_NODES=${NUM_NODES} but only ${ACTUAL_NUM_WORKERS} worker IP(s) provided"
    log "Adjusting NUM_NODES to $((ACTUAL_NUM_WORKERS + 1))"
    NUM_NODES=$((ACTUAL_NUM_WORKERS + 1))
  fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Main Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " SGLang DGX Spark Cluster Startup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log "Configuration:"
log "  Model:             ${MODEL}"
log "  Tensor Parallel:   ${TENSOR_PARALLEL} (per node)"
log "  Pipeline Parallel: ${PIPELINE_PARALLEL} (across nodes)"
log "  Nodes:             ${NUM_NODES}"
log "  Memory Fraction:   ${MEM_FRACTION}"
log ""
log "Network:"
log "  Head IP:         ${HEAD_IP}"
log "  API Port:        ${SGLANG_PORT}"
log "  Dist Init Port:  ${DIST_INIT_PORT}"
if [ "${HEAD_ONLY}" != "true" ] && [ "${ACTUAL_NUM_WORKERS}" -gt 0 ]; then
  log "  Worker Host:     ${WORKER_HOST} (SSH)"
  log "  Worker IB IP:    ${WORKER_IB_IP} (NCCL)"
fi
log ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 1: Setup tiktoken encodings
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 1: Setting up tiktoken encodings"
mkdir -p "${TIKTOKEN_DIR}"

if [ ! -f "${TIKTOKEN_DIR}/o200k_base.tiktoken" ]; then
  log "  Downloading o200k_base.tiktoken..."
  wget -q -O "${TIKTOKEN_DIR}/o200k_base.tiktoken" \
    "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken" || \
    log "  Warning: Failed to download o200k_base.tiktoken"
fi

if [ ! -f "${TIKTOKEN_DIR}/cl100k_base.tiktoken" ]; then
  log "  Downloading cl100k_base.tiktoken..."
  wget -q -O "${TIKTOKEN_DIR}/cl100k_base.tiktoken" \
    "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken" || \
    log "  Warning: Failed to download cl100k_base.tiktoken"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 2: Pull Docker image
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ "${SKIP_PULL}" != "true" ]; then
  log "Step 2: Pulling Docker image on head node"
  docker pull "${SGLANG_IMAGE}" || error "Failed to pull image"
else
  log "Step 2: Skipping Docker pull (--skip-pull)"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 3: Clean up old head container
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 3: Cleaning up old containers"
if docker ps -a --format '{{.Names}}' | grep -qx "${HEAD_CONTAINER_NAME}"; then
  log "  Removing existing head container"
  docker rm -f "${HEAD_CONTAINER_NAME}" >/dev/null
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 4: Start workers via SSH (before head, so they're ready to connect)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ "${HEAD_ONLY}" != "true" ] && [ "${ACTUAL_NUM_WORKERS}" -gt 0 ]; then
  log "Step 4: Starting workers via SSH"

  NODE_RANK=1
  for i in "${!WORKER_IB_IP_ARRAY[@]}"; do
    WORKER_IB="${WORKER_IB_IP_ARRAY[$i]}"
    # Use WORKER_HOST for SSH if available, otherwise fall back to IB IP
    SSH_HOST="${WORKER_HOST_ARRAY[$i]:-${WORKER_IB}}"
    log "  Starting worker at ${SSH_HOST} (IB: ${WORKER_IB}, node-rank ${NODE_RANK})..."

    # Test SSH connectivity
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${WORKER_USER}@${SSH_HOST}" "echo ok" >/dev/null 2>&1; then
      error "Cannot SSH to ${WORKER_USER}@${SSH_HOST}. Check SSH keys and connectivity."
    fi

    # Start worker in background via SSH
    ssh "${WORKER_USER}@${SSH_HOST}" bash -s << WORKER_EOF &
set -e

# Configuration passed from head
export HEAD_IP="${HEAD_IP}"
export NODE_RANK="${NODE_RANK}"
export MODEL="${MODEL}"
export TENSOR_PARALLEL="${TENSOR_PARALLEL}"
export PIPELINE_PARALLEL="${PIPELINE_PARALLEL}"
export NUM_NODES="${NUM_NODES}"
export MEM_FRACTION="${MEM_FRACTION}"
export SGLANG_PORT="${SGLANG_PORT}"
export DIST_INIT_PORT="${DIST_INIT_PORT}"
export HF_CACHE="${HF_CACHE}"
export HF_TOKEN="${HF_TOKEN:-}"
export SGLANG_IMAGE="${SGLANG_IMAGE}"
export SHM_SIZE="${SHM_SIZE}"
export REASONING_PARSER="${REASONING_PARSER}"
export TOOL_CALL_PARSER="${TOOL_CALL_PARSER}"
export DISABLE_CUDA_GRAPH="${DISABLE_CUDA_GRAPH}"
export EXTRA_ARGS="${EXTRA_ARGS}"
export NCCL_DEBUG="${NCCL_DEBUG}"
export NCCL_IB_DISABLE="${NCCL_IB_DISABLE}"
export NCCL_NET_GDR_LEVEL="${NCCL_NET_GDR_LEVEL}"

# Setup tiktoken
TIKTOKEN_DIR="\${HOME}/tiktoken_encodings"
mkdir -p "\${TIKTOKEN_DIR}"
[ ! -f "\${TIKTOKEN_DIR}/o200k_base.tiktoken" ] && wget -q -O "\${TIKTOKEN_DIR}/o200k_base.tiktoken" "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken" || true
[ ! -f "\${TIKTOKEN_DIR}/cl100k_base.tiktoken" ] && wget -q -O "\${TIKTOKEN_DIR}/cl100k_base.tiktoken" "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken" || true

# Pull image if needed
docker pull "${SGLANG_IMAGE}" 2>/dev/null || true

# Auto-detect worker's own network settings
if command -v ibdev2netdev >/dev/null 2>&1; then
  PRIMARY_IF=\$(ibdev2netdev 2>/dev/null | grep "(Up)" | awk '{print \$5}' | grep "^enp1" | head -1)
  [ -z "\${PRIMARY_IF}" ] && PRIMARY_IF=\$(ibdev2netdev 2>/dev/null | grep "(Up)" | awk '{print \$5}' | head -1)
  NCCL_SOCKET_IFNAME="\${PRIMARY_IF}"
  GLOO_SOCKET_IFNAME="\${PRIMARY_IF}"
  IB_DEVICES=\$(ibdev2netdev 2>/dev/null | grep "(Up)" | awk '{print \$1}' | sort | tr '\n' ',' | sed 's/,\$//')
  NCCL_IB_HCA="\${IB_DEVICES}"
fi

# Clean up old container
WORKER_NAME="sglang-worker-\$(hostname -s)"
docker rm -f "\${WORKER_NAME}" 2>/dev/null || true

# Build environment args
ENV_ARGS="-e HF_TOKEN=\${HF_TOKEN:-} -e HF_HOME=/root/.cache/huggingface -e TIKTOKEN_ENCODINGS_BASE=/tiktoken_encodings"
ENV_ARGS="\${ENV_ARGS} -e NCCL_DEBUG=\${NCCL_DEBUG} -e NCCL_IB_DISABLE=\${NCCL_IB_DISABLE} -e NCCL_NET_GDR_LEVEL=\${NCCL_NET_GDR_LEVEL} -e NCCL_TIMEOUT=${NCCL_TIMEOUT}"
[ -n "\${NCCL_SOCKET_IFNAME:-}" ] && ENV_ARGS="\${ENV_ARGS} -e NCCL_SOCKET_IFNAME=\${NCCL_SOCKET_IFNAME}"
[ -n "\${GLOO_SOCKET_IFNAME:-}" ] && ENV_ARGS="\${ENV_ARGS} -e GLOO_SOCKET_IFNAME=\${GLOO_SOCKET_IFNAME}"
[ -n "\${NCCL_IB_HCA:-}" ] && ENV_ARGS="\${ENV_ARGS} -e NCCL_IB_HCA=\${NCCL_IB_HCA}"

# Build SGLang args
SGLANG_ARGS="--model-path \${MODEL} --tp \${TENSOR_PARALLEL} --pp-size \${PIPELINE_PARALLEL}"
SGLANG_ARGS="\${SGLANG_ARGS} --nnodes \${NUM_NODES} --node-rank \${NODE_RANK}"
SGLANG_ARGS="\${SGLANG_ARGS} --dist-init-addr \${HEAD_IP}:\${DIST_INIT_PORT} --host 0.0.0.0 --port \${SGLANG_PORT}"
SGLANG_ARGS="\${SGLANG_ARGS} --mem-fraction-static \${MEM_FRACTION}"

# Add parser args for GPT-OSS
if [[ "\${MODEL}" == *"gpt-oss"* ]]; then
  SGLANG_ARGS="\${SGLANG_ARGS} --reasoning-parser \${REASONING_PARSER} --tool-call-parser \${TOOL_CALL_PARSER}"
fi

[ "\${DISABLE_CUDA_GRAPH}" = "true" ] && SGLANG_ARGS="\${SGLANG_ARGS} --disable-cuda-graph"
[ -n "\${EXTRA_ARGS}" ] && SGLANG_ARGS="\${SGLANG_ARGS} \${EXTRA_ARGS}"

# Check for InfiniBand device
DEVICE_ARGS=""
[ -d "/dev/infiniband" ] && DEVICE_ARGS="--device=/dev/infiniband"

# Start container
docker run -d \
  --restart no \
  --name "\${WORKER_NAME}" \
  --gpus all \
  --network host \
  --shm-size="\${SHM_SIZE}" \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  --ipc=host \
  \${DEVICE_ARGS} \
  -v "\${HF_CACHE}:/root/.cache/huggingface" \
  -v "\${TIKTOKEN_DIR}:/tiktoken_encodings" \
  \${ENV_ARGS} \
  "\${SGLANG_IMAGE}" \
  python3 -m sglang.launch_server \${SGLANG_ARGS}

echo "Worker \${WORKER_NAME} started on \$(hostname)"
WORKER_EOF

    NODE_RANK=$((NODE_RANK + 1))
  done

  # Wait briefly for workers to start
  log "  Waiting for workers to initialize..."
  sleep 5
else
  log "Step 4: Skipping workers (head-only mode or single node)"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 5: Start head node
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 5: Starting head node (node-rank 0)"

# Build environment variable arguments
ENV_ARGS=(
  -e "HF_TOKEN=${HF_TOKEN:-}"
  -e "HF_HOME=/root/.cache/huggingface"
  -e "TIKTOKEN_ENCODINGS_BASE=/tiktoken_encodings"
  -e "NCCL_DEBUG=${NCCL_DEBUG}"
  -e "NCCL_IB_DISABLE=${NCCL_IB_DISABLE}"
  -e "NCCL_NET_GDR_LEVEL=${NCCL_NET_GDR_LEVEL}"
  -e "NCCL_TIMEOUT=${NCCL_TIMEOUT}"
)

[ -n "${NCCL_SOCKET_IFNAME:-}" ] && ENV_ARGS+=(-e "NCCL_SOCKET_IFNAME=${NCCL_SOCKET_IFNAME}")
[ -n "${GLOO_SOCKET_IFNAME:-}" ] && ENV_ARGS+=(-e "GLOO_SOCKET_IFNAME=${GLOO_SOCKET_IFNAME}")
[ -n "${NCCL_IB_HCA:-}" ] && ENV_ARGS+=(-e "NCCL_IB_HCA=${NCCL_IB_HCA}")

# Build SGLang command arguments
SGLANG_ARGS=(
  --model-path "${MODEL}"
  --tp "${TENSOR_PARALLEL}"
  --pp-size "${PIPELINE_PARALLEL}"
  --nnodes "${NUM_NODES}"
  --node-rank 0
  --dist-init-addr "${HEAD_IP}:${DIST_INIT_PORT}"
  --host 0.0.0.0
  --port "${SGLANG_PORT}"
  --mem-fraction-static "${MEM_FRACTION}"
)

# Add parser arguments for GPT-OSS models
if [[ "${MODEL}" == *"gpt-oss"* ]]; then
  SGLANG_ARGS+=(--reasoning-parser "${REASONING_PARSER}")
  SGLANG_ARGS+=(--tool-call-parser "${TOOL_CALL_PARSER}")
fi

[ "${DISABLE_CUDA_GRAPH}" = "true" ] && SGLANG_ARGS+=(--disable-cuda-graph)

if [ -n "${EXTRA_ARGS}" ]; then
  read -ra EXTRA_ARGS_ARRAY <<< "${EXTRA_ARGS}"
  SGLANG_ARGS+=("${EXTRA_ARGS_ARRAY[@]}")
fi

# Volume mounts
VOLUME_ARGS=(
  -v "${HF_CACHE}:/root/.cache/huggingface"
  -v "${TIKTOKEN_DIR}:/tiktoken_encodings"
)

# Device args
DEVICE_ARGS=()
[ -d "/dev/infiniband" ] && DEVICE_ARGS+=(--device=/dev/infiniband)

docker run -d \
  --restart no \
  --name "${HEAD_CONTAINER_NAME}" \
  --gpus all \
  --network host \
  --shm-size="${SHM_SIZE}" \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  --ipc=host \
  "${DEVICE_ARGS[@]}" \
  "${VOLUME_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  "${SGLANG_IMAGE}" \
  python3 -m sglang.launch_server "${SGLANG_ARGS[@]}"

if ! docker ps | grep -q "${HEAD_CONTAINER_NAME}"; then
  error "Head container failed to start. Check: docker logs ${HEAD_CONTAINER_NAME}"
fi

log "  Head container started"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 6: Wait for cluster to be ready
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 6: Waiting for cluster to be ready"

if [ "${NUM_NODES}" -gt 1 ]; then
  MAX_WAIT=600
  log "  Multi-node cluster - waiting up to 10 minutes..."
else
  MAX_WAIT=300
  log "  Single-node - waiting up to 5 minutes..."
fi

READY=false
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=10

for i in $(seq 1 ${MAX_WAIT}); do
  if curl -sf "http://127.0.0.1:${SGLANG_PORT}/health" >/dev/null 2>&1; then
    log "  Cluster is ready! (${i}s)"
    READY=true
    break
  fi

  # Check if head container is still running using docker inspect (more reliable than docker ps | grep)
  CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' "${HEAD_CONTAINER_NAME}" 2>/dev/null || echo "not_found")

  if [ "${CONTAINER_STATUS}" = "exited" ] || [ "${CONTAINER_STATUS}" = "dead" ]; then
    # Container has definitively exited - check if it was an error
    EXIT_CODE=$(docker inspect -f '{{.State.ExitCode}}' "${HEAD_CONTAINER_NAME}" 2>/dev/null || echo "unknown")
    if [ "${EXIT_CODE}" != "0" ]; then
      error "Head container exited with code ${EXIT_CODE}. Check: docker logs ${HEAD_CONTAINER_NAME}"
    fi
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
  elif [ "${CONTAINER_STATUS}" = "not_found" ]; then
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
  else
    # Container is running/starting - reset failure counter
    CONSECUTIVE_FAILURES=0
  fi

  # Only error out if we've had multiple consecutive failures (handles transient states)
  if [ ${CONSECUTIVE_FAILURES} -ge ${MAX_CONSECUTIVE_FAILURES} ]; then
    error "Head container not running after ${MAX_CONSECUTIVE_FAILURES} checks. Check: docker logs ${HEAD_CONTAINER_NAME}"
  fi

  # Progress every 30 seconds
  if [ $((i % 30)) -eq 0 ]; then
    log "  Still initializing... (${i}s)"
    docker logs --tail 2 "${HEAD_CONTAINER_NAME}" 2>&1 | grep -v "^$" | head -1 || true
  fi

  sleep 1
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Output Summary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Detect public-facing IP
PUBLIC_IP=$(ip -o addr show | grep "inet " | grep -v "127.0.0.1" | grep -v "169.254" | grep -v "172.17" | awk '{print $4}' | cut -d'/' -f1 | head -1)
[ -z "${PUBLIC_IP}" ] && PUBLIC_IP="${HEAD_IP}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "${READY}" = "true" ]; then
  echo " SGLang Cluster is READY!"
else
  echo " SGLang Cluster Started (still initializing)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Cluster Info:"
echo "  Nodes:         ${NUM_NODES} (1 head + $((NUM_NODES - 1)) workers)"
echo "  Model:         ${MODEL}"
echo "  TP:            ${TENSOR_PARALLEL}"
echo ""
echo "API Endpoints:"
echo "  API:           http://${PUBLIC_IP}:${SGLANG_PORT}/v1"
echo "  Health:        http://${PUBLIC_IP}:${SGLANG_PORT}/health"
echo ""
echo "Quick Test:"
echo "  curl http://${PUBLIC_IP}:${SGLANG_PORT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
echo ""
echo "Benchmark:"
echo "  ./benchmark_current.sh --quick"
echo ""
echo "Logs:"
echo "  docker logs -f ${HEAD_CONTAINER_NAME}"
for i in "${!WORKER_IB_IP_ARRAY[@]}"; do
  SSH_HOST="${WORKER_HOST_ARRAY[$i]:-${WORKER_IB_IP_ARRAY[$i]}}"
  echo "  ssh ${WORKER_USER}@${SSH_HOST} docker logs -f sglang-worker-*"
done
echo ""
echo "Stop Cluster:"
echo "  ./stop_cluster.sh"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
