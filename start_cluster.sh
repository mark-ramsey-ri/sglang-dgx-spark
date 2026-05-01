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
SGLANG_IMAGE="${SGLANG_IMAGE:-lmsysorg/sglang:v0.5.10.post1-cu130}"
HEAD_CONTAINER_NAME="${HEAD_CONTAINER_NAME:-sglang-head}"
WORKER_CONTAINER_NAME="${WORKER_CONTAINER_NAME:-sglang-worker}"
SHM_SIZE="${SHM_SIZE:-32g}"

# Model
MODEL="${MODEL:-openai/gpt-oss-120b}"
PIPELINE_PARALLEL="${PIPELINE_PARALLEL:-1}"
MEM_FRACTION="${MEM_FRACTION:-0.80}"
# TENSOR_PARALLEL and NUM_NODES default to (1 head + N workers); resolved
# below once WORKER_HOST_ARRAY is parsed.

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

# Worker configuration. WORKER_HOST and WORKER_IB_IP are space-separated lists
# with 1:1 positional correspondence (a single value is just N=1).
#   WORKER_HOST:  Ethernet IP(s) for SSH (e.g., "192.168.7.111 192.168.7.112")
#   WORKER_IB_IP: InfiniBand IP(s) for NCCL (e.g., "169.254.216.8 169.254.216.9")
# Legacy WORKER_IPS is supported for backwards compatibility (treated as
# WORKER_IB_IP when WORKER_IB_IP is unset).
# Arrays are split AFTER CLI args are parsed (CLI may override these strings).
WORKER_HOST="${WORKER_HOST:-}"
WORKER_IB_IP="${WORKER_IB_IP:-${WORKER_IPS:-}}"
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
      echo "  --worker-host IP[s]  Worker Ethernet IP(s) for SSH, space-separated for >1"
      echo "  --worker-ib-ip IP[s] Worker InfiniBand IP(s) for NCCL, 1:1 with --worker-host"
      echo "  -h, --help           Show this help"
      echo ""
      echo "Environment variables (recommended):"
      echo "  WORKER_HOST          Ethernet IP(s), space-separated for 1-N workers"
      echo "                         single:  WORKER_HOST=\"192.168.7.111\""
      echo "                         3-Spark: WORKER_HOST=\"192.168.7.111 192.168.7.112 192.168.7.113\""
      echo "  WORKER_IB_IP         InfiniBand IP(s), 1:1 positional with WORKER_HOST"
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
# Parse worker arrays (after CLI args; CLI may override the strings)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Split into arrays. read -ra on an empty string yields an empty array.
read -ra WORKER_HOST_ARRAY <<< "${WORKER_HOST}"
read -ra WORKER_IB_IP_ARRAY <<< "${WORKER_IB_IP}"
WORKER_COUNT="${#WORKER_HOST_ARRAY[@]}"

# Backwards-compat path: legacy single-worker setups sometimes only set
# WORKER_IB_IP (via WORKER_IPS) and rely on it for SSH too. Mirror it back
# into WORKER_HOST so the rest of the script doesn't need a special case.
# Must run BEFORE the cardinality check below.
if [ "${WORKER_COUNT}" -eq 0 ] && [ "${#WORKER_IB_IP_ARRAY[@]}" -gt 0 ]; then
  WORKER_HOST_ARRAY=("${WORKER_IB_IP_ARRAY[@]}")
  WORKER_HOST="${WORKER_IB_IP}"
  WORKER_COUNT="${#WORKER_HOST_ARRAY[@]}"
fi

# Validate WORKER_IB_IP cardinality: must match WORKER_HOST when given.
if [ "${#WORKER_IB_IP_ARRAY[@]}" -gt 0 ] && [ "${#WORKER_IB_IP_ARRAY[@]}" -ne "${WORKER_COUNT}" ]; then
  echo "ERROR: WORKER_IB_IP has ${#WORKER_IB_IP_ARRAY[@]} entries but WORKER_HOST has ${WORKER_COUNT}."
  echo "       They must be 1:1 positional: WORKER_HOST=\"a b c\" needs WORKER_IB_IP=\"x y z\"."
  exit 1
fi

# When WORKER_IB_IP is unset, mirror WORKER_HOST so per-worker NCCL IPs are
# always available downstream (NCCL just talks over the SSH path).
if [ "${#WORKER_IB_IP_ARRAY[@]}" -eq 0 ] && [ "${WORKER_COUNT}" -gt 0 ]; then
  WORKER_IB_IP_ARRAY=("${WORKER_HOST_ARRAY[@]}")
  WORKER_IB_IP="${WORKER_HOST}"
fi

# Defaults that scale with cluster size: 1 head + N workers, 1 GPU per Spark.
NUM_NODES="${NUM_NODES:-$((WORKER_COUNT + 1))}"
TENSOR_PARALLEL="${TENSOR_PARALLEL:-${NUM_NODES}}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Validate Worker Configuration
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ "${WORKER_COUNT}" -eq 0 ] && [ "${NUM_NODES}" -gt 1 ] && [ "${HEAD_ONLY}" != "true" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Worker Configuration Required"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "NUM_NODES=${NUM_NODES} but no workers configured. Pick one:"
  echo ""
  echo "  A) Configure workers (space-separated for >1):"
  echo "       export WORKER_HOST=\"192.168.x.x [192.168.x.y ...]\"    # Ethernet IPs (SSH)"
  echo "       export WORKER_IB_IP=\"169.254.x.x [169.254.x.y ...]\"   # InfiniBand IPs (NCCL)"
  echo ""
  echo "  B) Single-Spark mode: re-run with NUM_NODES=1 TENSOR_PARALLEL=1"
  echo ""
  echo "  C) Head-only test: $0 --head-only (will hang waiting for ${NUM_NODES} workers)"
  echo ""
  echo "To find worker IPs, run on the worker node:"
  echo "  hostname -I                          # Shows all IPs"
  echo "  ibdev2netdev && ip addr show <ib_if> # Shows IB interface IP"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi

# Implicit head-only when no workers are configured (and NUM_NODES is sane).
if [ "${WORKER_COUNT}" -eq 0 ]; then
  HEAD_ONLY=true
fi

# Reconcile NUM_NODES with what WORKER_HOST actually provides when both are set.
if [ "${HEAD_ONLY}" != "true" ] && [ "${WORKER_COUNT}" -gt 0 ]; then
  EXPECTED_WORKERS=$((NUM_NODES - 1))
  if [ "${WORKER_COUNT}" -ne "${EXPECTED_WORKERS}" ]; then
    log "Note: NUM_NODES=${NUM_NODES} but ${WORKER_COUNT} worker(s) configured; using $((WORKER_COUNT + 1))."
    NUM_NODES=$((WORKER_COUNT + 1))
  fi
fi

# Pre-flight SSH connectivity check (one round trip per worker beats a partial
# launch where worker N hangs SSH and we have to chase it down).
if [ "${HEAD_ONLY}" != "true" ] && [ "${WORKER_COUNT}" -gt 0 ]; then
  for ip in "${WORKER_HOST_ARRAY[@]}"; do
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "${WORKER_USER}@${ip}" "echo ok" >/dev/null 2>&1; then
      error "Cannot SSH to ${WORKER_USER}@${ip}. Check SSH keys and connectivity (try: ssh-copy-id ${WORKER_USER}@${ip})."
    fi
  done
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
log "  Tensor Parallel:   ${TENSOR_PARALLEL} (across all nodes)"
log "  Pipeline Parallel: ${PIPELINE_PARALLEL} (across nodes)"
log "  Nodes:             ${NUM_NODES} (1 head + ${WORKER_COUNT} worker(s))"
log "  Memory Fraction:   ${MEM_FRACTION}"
log ""
log "Network:"
log "  Head IP:         ${HEAD_IP}"
log "  API Port:        ${SGLANG_PORT}"
log "  Dist Init Port:  ${DIST_INIT_PORT}"
if [ "${HEAD_ONLY}" != "true" ] && [ "${WORKER_COUNT}" -gt 0 ]; then
  for i in "${!WORKER_HOST_ARRAY[@]}"; do
    if [ "${WORKER_IB_IP_ARRAY[i]}" != "${WORKER_HOST_ARRAY[i]}" ]; then
      log "  Worker $((i+1)):        ${WORKER_HOST_ARRAY[i]} (SSH) / ${WORKER_IB_IP_ARRAY[i]} (NCCL)"
    else
      log "  Worker $((i+1)):        ${WORKER_HOST_ARRAY[i]}"
    fi
  done
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

if [ "${HEAD_ONLY}" != "true" ] && [ "${WORKER_COUNT}" -gt 0 ]; then
  log "Step 4: Starting ${WORKER_COUNT} worker(s) via SSH"

  for i in "${!WORKER_HOST_ARRAY[@]}"; do
    SSH_HOST="${WORKER_HOST_ARRAY[$i]}"
    WORKER_IB="${WORKER_IB_IP_ARRAY[$i]}"
    NODE_RANK=$((i + 1))
    log "  Starting worker at ${SSH_HOST} (IB: ${WORKER_IB}, node-rank ${NODE_RANK})..."

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
  done

  # Wait briefly for workers to start
  log "  Waiting for workers to initialize..."
  sleep 5
else
  log "Step 4: Skipping workers (head-only mode or single Spark)"
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
  # 10 min base + 2 min per worker; large clusters take longer to bootstrap.
  MAX_WAIT=$((600 + 120 * WORKER_COUNT))
  log "  Multi-Spark cluster (${NUM_NODES} nodes) - waiting up to $((MAX_WAIT / 60)) minutes..."
else
  MAX_WAIT=300
  log "  Single Spark - waiting up to 5 minutes..."
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
echo "  Nodes:         ${NUM_NODES} (1 head + ${WORKER_COUNT} worker(s))"
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
if [ "${HEAD_ONLY}" != "true" ]; then
  for i in "${!WORKER_HOST_ARRAY[@]}"; do
    echo "  ssh ${WORKER_USER}@${WORKER_HOST_ARRAY[i]} 'docker logs -f \$(docker ps --format \"{{.Names}}\" | grep ^sglang-worker-)'"
  done
fi
echo ""
echo "Stop Cluster:"
echo "  ./stop_cluster.sh"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
