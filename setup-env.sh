#!/usr/bin/env bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SGLang DGX Spark Environment Configuration Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# This script sets up environment variables for SGLang cluster deployment.
# Network configuration (IPs, interfaces, HCAs) is auto-detected by scripts.
#
# Required configuration:
#   - WORKER_HOST: Worker Ethernet IP(s) for SSH access (space-separated for >1)
#   - WORKER_IB_IP: Worker InfiniBand IP(s) for NCCL (1:1 with WORKER_HOST)
#   - HF_TOKEN: HuggingFace token (for gated models like Llama)
#
# Usage:
#   source ./setup-env.sh           # Interactive mode (recommended)
#   source ./setup-env.sh --head    # Head node mode
#   ./setup-env.sh --discover       # Run NVIDIA's mDNS Spark discovery and
#                                   # bidir SSH key push (no shell vars set)
#
# NOTE: This script must be SOURCED (not executed) to set environment variables
#       — except for --discover which is a one-shot.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# --discover is a one-shot wrapper that runs without sourcing. It downloads
# and runs NVIDIA's discover-sparks helper (mDNS scan + bidir SSH key push).
if [[ "${1:-}" == "--discover" ]]; then
    NVIDIA_DISCOVER_URL="https://raw.githubusercontent.com/NVIDIA/dgx-spark-playbooks/refs/heads/main/nvidia/connect-two-sparks/assets/discover-sparks"
    TMP_SCRIPT="$(mktemp -t discover-sparks.XXXXXX.sh)"
    trap 'rm -f "${TMP_SCRIPT}"' EXIT
    echo ""
    echo "Fetching NVIDIA's discover-sparks helper..."
    echo "  Source: ${NVIDIA_DISCOVER_URL}"
    if ! curl -fsSL "${NVIDIA_DISCOVER_URL}" -o "${TMP_SCRIPT}"; then
        echo "ERROR: Could not download ${NVIDIA_DISCOVER_URL}"
        echo "       Check your network, or run the steps manually (see README)."
        exit 1
    fi
    chmod +x "${TMP_SCRIPT}"
    echo "Running discover-sparks (will mDNS-scan and prompt for per-Spark passwords)..."
    echo ""
    "${TMP_SCRIPT}" || true
    echo ""
    echo "Done. Re-run interactively to capture WORKER_HOST / WORKER_IB_IP:"
    echo "    source ./setup-env.sh"
    exit 0
fi

# Check if script is being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This script must be sourced, not executed"
    echo "Usage: source ./setup-env.sh"
    echo "       (or: ./setup-env.sh --discover)"
    exit 1
fi

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Helper function to prompt for input
prompt_input() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local is_secret="${4:-false}"
    local current_value="${!var_name:-}"

    # If variable is already set, use it
    if [ -n "$current_value" ]; then
        if [ "$is_secret" = true ]; then
            echo -e "${GREEN}[ok]${NC} $var_name already set (hidden)"
        else
            echo -e "${GREEN}[ok]${NC} $var_name=$current_value"
        fi
        return
    fi

    # Show prompt
    if [ -n "$default_value" ]; then
        echo -ne "${BLUE}[?]${NC} $prompt_text [${default_value}]: "
    else
        echo -ne "${YELLOW}[!]${NC} $prompt_text: "
    fi

    # Read input (with or without echo for secrets)
    if [ "$is_secret" = true ]; then
        read -s user_input
        echo ""  # New line after secret input
    else
        read user_input
    fi

    # Use default if no input provided
    if [ -z "$user_input" ] && [ -n "$default_value" ]; then
        user_input="$default_value"
    fi

    # Export the variable
    if [ -n "$user_input" ]; then
        export "$var_name=$user_input"
        if [ "$is_secret" = true ]; then
            echo -e "${GREEN}[ok]${NC} $var_name set (hidden)"
        else
            echo -e "${GREEN}[ok]${NC} $var_name=$user_input"
        fi
    else
        if [ -n "$default_value" ]; then
            echo -e "${YELLOW}[-]${NC} $var_name not set (will use default: $default_value)"
        else
            echo -e "${YELLOW}[-]${NC} $var_name not set (optional)"
        fi
    fi
}

# Detect node type from arguments
NODE_TYPE="interactive"
if [[ "$1" == "--head" ]]; then
    NODE_TYPE="head"
fi

echo ""
echo -e "${GREEN}=============================================================${NC}"
echo -e "${GREEN}     SGLang DGX Spark - Environment Setup${NC}"
echo -e "${GREEN}=============================================================${NC}"
echo ""
echo "Note: Network configuration (IPs, interfaces, HCAs) is auto-detected!"
echo "      You only need to provide the essential settings below."
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Check HuggingFace Cache Permissions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

HF_CACHE="${HF_CACHE:-/raid/hf-cache}"
echo -e "${YELLOW}Checking HuggingFace cache...${NC}"

if [ -d "$HF_CACHE" ]; then
    if [ ! -w "$HF_CACHE" ]; then
        echo -e "${RED}[!]${NC} HF cache at $HF_CACHE is not writable"
        echo "    Docker containers run as root and may have created files owned by root."
        echo ""
        echo -e "${YELLOW}To fix, run:${NC}"
        echo "    sudo chown -R \$USER $HF_CACHE"
        echo ""
        read -p "Fix permissions now? (requires sudo) [y/N]: " fix_perms
        if [[ "$fix_perms" =~ ^[Yy]$ ]]; then
            if sudo chown -R "$USER" "$HF_CACHE"; then
                echo -e "${GREEN}[ok]${NC} Permissions fixed"
            else
                echo -e "${RED}[!]${NC} Failed. Please run manually: sudo chown -R \$USER $HF_CACHE"
            fi
        fi
    else
        echo -e "${GREEN}[ok]${NC} HF cache OK ($HF_CACHE)"
    fi
else
    echo -e "${BLUE}[i]${NC} HF cache will be created at $HF_CACHE"
fi
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Required Configuration
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo -e "${GREEN}--- Required Settings ---${NC}"
echo ""

# Worker host(s) for SSH — space-separated for >1 worker.
echo "Worker Node Ethernet IP(s) (for SSH access):"
echo "  Space-separated for multiple workers (1-to-N Spark support)."
echo "  First-time setup tip: ./setup-env.sh --discover (NVIDIA mDNS scan)"
echo "  1 worker:  192.168.7.111"
echo "  3 workers: 192.168.7.111 192.168.7.112 192.168.7.113"
prompt_input "WORKER_HOST" "Enter worker Ethernet IP(s)" ""
echo ""

# Worker InfiniBand IP(s) for NCCL — 1:1 positional with WORKER_HOST.
echo "Worker Node InfiniBand IP(s) (for NCCL communication):"
echo "  Space-separated, must be 1:1 positional with WORKER_HOST above."
echo "  Find on each worker: ibdev2netdev && ip addr show <interface>"
echo "  1 worker:  169.254.216.8"
echo "  3 workers: 169.254.216.8 169.254.216.9 169.254.216.10"
prompt_input "WORKER_IB_IP" "Enter worker InfiniBand IP(s)" ""
echo ""

# Worker SSH username
echo "Worker Node Username (for SSH):"
prompt_input "WORKER_USER" "Enter worker username" "$(whoami)"
echo ""

# HuggingFace Token
echo "HuggingFace Token (required for gated models like Llama):"
echo "  Get yours at: https://huggingface.co/settings/tokens"
echo "  Leave blank if using public models only"
prompt_input "HF_TOKEN" "Enter HuggingFace token" "" true
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Model Configuration
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo -e "${BLUE}--- Model Settings (press Enter for defaults) ---${NC}"
echo ""

echo "Model to serve:"
echo "  Recommended: openai/gpt-oss-120b (requires 2 nodes)"
echo "  Alternatives: openai/gpt-oss-20b, nvidia/Llama-3.3-70B-Instruct-FP4"
prompt_input "MODEL" "Model name" "openai/gpt-oss-120b"
echo ""

# Default TP/NUM_NODES from worker count; user can still override.
read -ra _WORKER_HOST_ARRAY <<< "${WORKER_HOST:-}"
_DEFAULT_NODES=$(( ${#_WORKER_HOST_ARRAY[@]} + 1 ))
unset _WORKER_HOST_ARRAY
prompt_input "TENSOR_PARALLEL" "Tensor parallel size (total GPUs across all Sparks)" "${_DEFAULT_NODES}"
prompt_input "NUM_NODES" "Number of nodes (1 head + N workers)" "${_DEFAULT_NODES}"
prompt_input "MEM_FRACTION" "Memory fraction for KV cache (0.0-1.0)" "0.90"
unset _DEFAULT_NODES
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Advanced Configuration
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo -e "${BLUE}--- Advanced Settings (press Enter for defaults) ---${NC}"
echo ""

prompt_input "SGLANG_IMAGE" "Docker image" "lmsysorg/sglang:v0.5.10.post1-cu130"
prompt_input "SGLANG_PORT" "API port" "30000"
prompt_input "DISABLE_CUDA_GRAPH" "Disable CUDA graph (true/false)" "false"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Summary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo -e "${GREEN}=============================================================${NC}"
echo -e "${GREEN}     Configuration Complete!${NC}"
echo -e "${GREEN}=============================================================${NC}"
echo ""
echo "Environment variables set:"
echo ""
[ -n "${WORKER_HOST:-}" ] && echo "  WORKER_HOST=$WORKER_HOST"
[ -n "${WORKER_IB_IP:-}" ] && echo "  WORKER_IB_IP=$WORKER_IB_IP"
[ -n "${WORKER_USER:-}" ] && echo "  WORKER_USER=$WORKER_USER"
[ -n "${HF_TOKEN:-}" ] && echo "  HF_TOKEN=(hidden)"
[ -n "${MODEL:-}" ] && echo "  MODEL=$MODEL"
[ -n "${TENSOR_PARALLEL:-}" ] && echo "  TENSOR_PARALLEL=$TENSOR_PARALLEL"
[ -n "${NUM_NODES:-}" ] && echo "  NUM_NODES=$NUM_NODES"
[ -n "${MEM_FRACTION:-}" ] && echo "  MEM_FRACTION=$MEM_FRACTION"
[ -n "${SGLANG_IMAGE:-}" ] && echo "  SGLANG_IMAGE=$SGLANG_IMAGE"
[ -n "${SGLANG_PORT:-}" ] && echo "  SGLANG_PORT=$SGLANG_PORT"
[ -n "${DISABLE_CUDA_GRAPH:-}" ] && echo "  DISABLE_CUDA_GRAPH=$DISABLE_CUDA_GRAPH"
echo ""
echo "Auto-detected by scripts (no configuration needed):"
echo "  - HEAD_IP (from InfiniBand interface)"
echo "  - Network interfaces (NCCL_SOCKET_IFNAME, GLOO_SOCKET_IFNAME)"
echo "  - InfiniBand HCAs (NCCL_IB_HCA)"
echo ""
echo -e "${GREEN}Next step:${NC}"
echo "  ./start_cluster.sh"
echo ""
echo "Or to save this configuration for future use:"
echo "  Create config.local.env with these exports"
echo ""
