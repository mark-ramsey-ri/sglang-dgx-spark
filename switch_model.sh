#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SGLang Model Switching Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Allows switching between different models with proper configuration.
# Handles tensor parallelism, node count, memory, and model-specific settings.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Model Definitions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Model HuggingFace IDs
MODELS=(
  "openai/gpt-oss-120b"
  "openai/gpt-oss-20b"
  "Qwen/Qwen2.5-7B-Instruct"
  "Qwen/Qwen2.5-14B-Instruct"
  "Qwen/Qwen2.5-32B-Instruct"
  "Qwen/Qwen2.5-72B-Instruct"
  "mistralai/Mistral-7B-Instruct-v0.3"
  "mistralai/Mistral-Nemo-Instruct-2407"
  "mistralai/Mixtral-8x7B-Instruct-v0.1"
  "meta-llama/Llama-3.1-8B-Instruct"
  "meta-llama/Llama-3.1-70B-Instruct"
  "microsoft/phi-4"
  "google/gemma-2-27b-it"
  "deepseek-ai/DeepSeek-V2-Lite-Chat"
)

# Human-readable model descriptions
MODEL_NAMES=(
  "GPT-OSS-120B (120B params, MoE, ~80GB+, heavy, high quality)"
  "GPT-OSS-20B (21B params, MoE, ~16-20GB, fast)"
  "Qwen2.5-7B (7B params, ~7GB, very fast)"
  "Qwen2.5-14B (14B params, ~14GB, fast)"
  "Qwen2.5-32B (32B params, ~30GB, strong mid-size)"
  "Qwen2.5-72B (72B params, ~70GB, slow, high quality)"
  "Mistral-7B v0.3 (7B params, ~7GB, very fast)"
  "Mistral-Nemo-12B (12B params, ~12GB, 128k context)"
  "Mixtral-8x7B (47B total, 12B active, ~45GB, MoE, fast)"
  "Llama-3.1-8B (8B params, ~8GB, very fast)"
  "Llama-3.1-70B (70B params, ~65GB, high quality)"
  "Phi-4 (15B params, ~14-16GB, small but smart)"
  "Gemma2-27B (27B params, ~24-28GB, strong mid-size)"
  "DeepSeek-V2-Lite (16B MoE, ~12-16GB, very fast, reasoning tuned)"
)

# Tensor Parallelism (number of GPUs needed)
# All models use TP=2 to run across both nodes
MODEL_TP=(
  2    # gpt-oss-120b
  2    # gpt-oss-20b
  2    # Qwen2.5-7B
  2    # Qwen2.5-14B
  2    # Qwen2.5-32B
  2    # Qwen2.5-72B
  2    # Mistral-7B
  2    # Mistral-Nemo-12B
  2    # Mixtral-8x7B
  2    # Llama-3.1-8B
  2    # Llama-3.1-70B
  2    # Phi-4
  2    # Gemma2-27B
  2    # DeepSeek-V2-Lite
)

# Number of nodes required (all models use 2 nodes)
MODEL_NODES=(
  2    # gpt-oss-120b
  2    # gpt-oss-20b
  2    # Qwen2.5-7B
  2    # Qwen2.5-14B
  2    # Qwen2.5-32B
  2    # Qwen2.5-72B
  2    # Mistral-7B
  2    # Mistral-Nemo-12B
  2    # Mixtral-8x7B
  2    # Llama-3.1-8B
  2    # Llama-3.1-70B
  2    # Phi-4
  2    # Gemma2-27B
  2    # DeepSeek-V2-Lite
)

# Memory fraction (0.90 default, lower for larger models)
MODEL_MEM=(
  0.90  # gpt-oss-120b
  0.90  # gpt-oss-20b
  0.90  # Qwen2.5-7B
  0.90  # Qwen2.5-14B
  0.90  # Qwen2.5-32B
  0.90  # Qwen2.5-72B
  0.90  # Mistral-7B
  0.90  # Mistral-Nemo-12B
  0.90  # Mixtral-8x7B
  0.90  # Llama-3.1-8B
  0.90  # Llama-3.1-70B
  0.90  # Phi-4
  0.90  # Gemma2-27B
  0.90  # DeepSeek-V2-Lite
)

# Reasoning parser (gpt-oss for GPT-OSS models, empty for others)
MODEL_REASONING_PARSER=(
  "gpt-oss"  # gpt-oss-120b
  "gpt-oss"  # gpt-oss-20b
  ""         # Qwen2.5-7B
  ""         # Qwen2.5-14B
  ""         # Qwen2.5-32B
  ""         # Qwen2.5-72B
  ""         # Mistral-7B
  ""         # Mistral-Nemo-12B
  ""         # Mixtral-8x7B
  ""         # Llama-3.1-8B
  ""         # Llama-3.1-70B
  ""         # Phi-4
  ""         # Gemma2-27B
  "deepseek" # DeepSeek-V2-Lite
)

# Tool call parser
MODEL_TOOL_PARSER=(
  "gpt-oss"  # gpt-oss-120b
  "gpt-oss"  # gpt-oss-20b
  ""         # Qwen2.5-7B
  ""         # Qwen2.5-14B
  ""         # Qwen2.5-32B
  ""         # Qwen2.5-72B
  ""         # Mistral-7B
  ""         # Mistral-Nemo-12B
  ""         # Mixtral-8x7B
  "llama3"   # Llama-3.1-8B
  "llama3"   # Llama-3.1-70B
  ""         # Phi-4
  ""         # Gemma2-27B
  ""         # DeepSeek-V2-Lite
)

# Trust remote code flag
MODEL_TRUST_REMOTE=(
  false  # gpt-oss-120b
  false  # gpt-oss-20b
  false  # Qwen2.5-7B
  false  # Qwen2.5-14B
  false  # Qwen2.5-32B
  false  # Qwen2.5-72B
  false  # Mistral-7B
  false  # Mistral-Nemo-12B
  false  # Mixtral-8x7B
  false  # Llama-3.1-8B
  false  # Llama-3.1-70B
  true   # Phi-4 - requires trust_remote_code
  false  # Gemma2-27B
  true   # DeepSeek-V2-Lite - requires trust_remote_code
)

# Requires HF token (gated models)
MODEL_NEEDS_TOKEN=(
  false  # gpt-oss-120b
  false  # gpt-oss-20b
  false  # Qwen2.5-7B
  false  # Qwen2.5-14B
  false  # Qwen2.5-32B
  false  # Qwen2.5-72B
  false  # Mistral-7B
  false  # Mistral-Nemo-12B
  false  # Mixtral-8x7B
  true   # Llama-3.1-8B - gated
  true   # Llama-3.1-70B - gated
  false  # Phi-4
  true   # Gemma2-27B - gated
  false  # DeepSeek-V2-Lite
)

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Helper Functions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

get_current_model() {
  if [ -f "${SCRIPT_DIR}/config.local.env" ]; then
    grep '^MODEL=' "${SCRIPT_DIR}/config.local.env" 2>/dev/null | head -1 | sed 's/MODEL="//' | sed 's/"$//' || echo ""
  elif [ -f "${SCRIPT_DIR}/config.env" ]; then
    grep '^MODEL=' "${SCRIPT_DIR}/config.env" 2>/dev/null | head -1 | sed 's/MODEL="\${MODEL:-//' | sed 's/}"$//' || echo ""
  else
    echo ""
  fi
}

check_hf_token() {
  if [ -n "${HF_TOKEN:-}" ]; then
    return 0
  fi
  if [ -f "${SCRIPT_DIR}/config.local.env" ]; then
    grep -q '^HF_TOKEN=' "${SCRIPT_DIR}/config.local.env" && return 0
  fi
  return 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Parse Arguments
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SKIP_RESTART=false
LIST_ONLY=false
MODEL_NUMBER=""

usage() {
  cat << EOF
Usage: $0 [OPTIONS] [MODEL_NUMBER]

Switch between different models on the SGLang cluster.

Options:
  -l, --list          List available models without switching
  -s, --skip-restart  Update config only, don't restart cluster
  -h, --help          Show this help

Examples:
  $0                  # Interactive model selection
  $0 1                # Switch to model #1 (GPT-OSS-120B)
  $0 --list           # List all available models
  $0 -s 3             # Update config for model #3 without restarting

EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -l|--list)
      LIST_ONLY=true
      shift
      ;;
    -s|--skip-restart)
      SKIP_RESTART=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    [0-9]*)
      MODEL_NUMBER="$1"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Main Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " SGLang Model Switcher"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Show current model
CURRENT_MODEL=$(get_current_model)
if [ -n "${CURRENT_MODEL}" ]; then
  echo "Current model: ${CURRENT_MODEL}"
else
  echo "Current model: (not configured)"
fi
echo ""

# Display available models
echo "Available models:"
echo ""
echo "  Single-Node Models (TP=1):"
for i in "${!MODELS[@]}"; do
  if [ "${MODEL_NODES[$i]}" -eq 1 ]; then
    MARKER=""
    if [ "${MODELS[$i]}" = "${CURRENT_MODEL}" ]; then
      MARKER=" [CURRENT]"
    fi
    if [ "${MODEL_NEEDS_TOKEN[$i]}" = "true" ]; then
      MARKER="${MARKER} [HF TOKEN]"
    fi
    printf "    %2d. %s%s\n" "$((i+1))" "${MODEL_NAMES[$i]}" "${MARKER}"
  fi
done

echo ""
echo "  Multi-Node Models (TP=2, requires 2 DGX Spark nodes):"
for i in "${!MODELS[@]}"; do
  if [ "${MODEL_NODES[$i]}" -eq 2 ]; then
    MARKER=""
    if [ "${MODELS[$i]}" = "${CURRENT_MODEL}" ]; then
      MARKER=" [CURRENT]"
    fi
    if [ "${MODEL_NEEDS_TOKEN[$i]}" = "true" ]; then
      MARKER="${MARKER} [HF TOKEN]"
    fi
    printf "    %2d. %s%s\n" "$((i+1))" "${MODEL_NAMES[$i]}" "${MARKER}"
  fi
done
echo ""

# Exit if list only
if [ "${LIST_ONLY}" = "true" ]; then
  exit 0
fi

# Get model selection
if [ -z "${MODEL_NUMBER}" ]; then
  read -p "Select model (1-${#MODELS[@]}), or 'q' to quit: " MODEL_NUMBER
fi

if [ "${MODEL_NUMBER}" = "q" ] || [ "${MODEL_NUMBER}" = "Q" ]; then
  echo "Cancelled."
  exit 0
fi

# Validate selection
if ! [[ "${MODEL_NUMBER}" =~ ^[0-9]+$ ]] || [ "${MODEL_NUMBER}" -lt 1 ] || [ "${MODEL_NUMBER}" -gt "${#MODELS[@]}" ]; then
  echo "ERROR: Invalid selection. Please enter a number between 1 and ${#MODELS[@]}."
  exit 1
fi

# Get model configuration
IDX=$((MODEL_NUMBER - 1))
NEW_MODEL="${MODELS[$IDX]}"
NEW_MODEL_NAME="${MODEL_NAMES[$IDX]}"
NEW_TP="${MODEL_TP[$IDX]}"
NEW_NODES="${MODEL_NODES[$IDX]}"
NEW_MEM="${MODEL_MEM[$IDX]}"
NEW_REASONING="${MODEL_REASONING_PARSER[$IDX]}"
NEW_TOOL="${MODEL_TOOL_PARSER[$IDX]}"
NEW_TRUST="${MODEL_TRUST_REMOTE[$IDX]}"
NEEDS_TOKEN="${MODEL_NEEDS_TOKEN[$IDX]}"

# Check if model needs HF token
if [ "${NEEDS_TOKEN}" = "true" ]; then
  if ! check_hf_token; then
    echo ""
    echo "WARNING: ${NEW_MODEL} requires a HuggingFace token."
    echo ""
    echo "Please set HF_TOKEN before starting the cluster:"
    echo "  export HF_TOKEN=hf_your_token_here"
    echo ""
    echo "Or add to config.local.env:"
    echo "  HF_TOKEN=\"hf_your_token_here\""
    echo ""
    read -p "Continue anyway? (y/N): " CONTINUE
    if [ "${CONTINUE}" != "y" ] && [ "${CONTINUE}" != "Y" ]; then
      echo "Cancelled."
      exit 1
    fi
  fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Switching to: ${NEW_MODEL_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Configuration:"
echo "  Model:             ${NEW_MODEL}"
echo "  Tensor Parallel:   ${NEW_TP}"
echo "  Nodes Required:    ${NEW_NODES}"
echo "  Memory Fraction:   ${NEW_MEM}"
[ -n "${NEW_REASONING}" ] && echo "  Reasoning Parser:  ${NEW_REASONING}"
[ -n "${NEW_TOOL}" ] && echo "  Tool Parser:       ${NEW_TOOL}"
[ "${NEW_TRUST}" = "true" ] && echo "  Trust Remote Code: yes"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Update Configuration
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 1/4: Updating configuration..."

# Create or update config.local.env
CONFIG_FILE="${SCRIPT_DIR}/config.local.env"

# Start with existing config or empty
if [ -f "${CONFIG_FILE}" ]; then
  # Remove old model-related settings
  grep -v '^MODEL=\|^TENSOR_PARALLEL=\|^NUM_NODES=\|^MEM_FRACTION=\|^REASONING_PARSER=\|^TOOL_CALL_PARSER=\|^TRUST_REMOTE_CODE=\|^EXTRA_ARGS=' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" || true
  mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
else
  # Copy from config.env template
  if [ -f "${SCRIPT_DIR}/config.env" ]; then
    cp "${SCRIPT_DIR}/config.env" "${CONFIG_FILE}"
    # Remove default values to override
    grep -v '^MODEL=\|^TENSOR_PARALLEL=\|^NUM_NODES=\|^MEM_FRACTION=\|^REASONING_PARSER=\|^TOOL_CALL_PARSER=\|^EXTRA_ARGS=' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" || true
    mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
  else
    touch "${CONFIG_FILE}"
  fi
fi

# Add model configuration
{
  echo ""
  echo "# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "# Model Configuration (set by switch_model.sh)"
  echo "# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "MODEL=\"${NEW_MODEL}\""
  echo "TENSOR_PARALLEL=\"${NEW_TP}\""
  echo "NUM_NODES=\"${NEW_NODES}\""
  echo "MEM_FRACTION=\"${NEW_MEM}\""

  if [ -n "${NEW_REASONING}" ]; then
    echo "REASONING_PARSER=\"${NEW_REASONING}\""
  else
    echo "REASONING_PARSER=\"\""
  fi

  if [ -n "${NEW_TOOL}" ]; then
    echo "TOOL_CALL_PARSER=\"${NEW_TOOL}\""
  else
    echo "TOOL_CALL_PARSER=\"\""
  fi

  # Build EXTRA_ARGS
  EXTRA_ARGS_VALUE=""
  if [ "${NEW_NODES}" -gt 1 ]; then
    EXTRA_ARGS_VALUE="--enable-dp-attention"
  fi
  if [ "${NEW_TRUST}" = "true" ]; then
    EXTRA_ARGS_VALUE="${EXTRA_ARGS_VALUE} --trust-remote-code"
  fi
  EXTRA_ARGS_VALUE=$(echo "${EXTRA_ARGS_VALUE}" | xargs)  # trim whitespace
  echo "EXTRA_ARGS=\"${EXTRA_ARGS_VALUE}\""

} >> "${CONFIG_FILE}"

echo "  Configuration saved to: ${CONFIG_FILE}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Restart Cluster (if not skipped)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ "${SKIP_RESTART}" = "true" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Configuration Updated (restart skipped)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "To start the cluster with the new model:"
  if [ "${NEW_NODES}" -gt 1 ]; then
    echo "  ./start_cluster.sh"
  else
    echo "  ./start_cluster.sh --head-only"
  fi
  echo ""
  exit 0
fi

# Stop existing cluster
echo ""
log "Step 2/4: Stopping existing cluster..."
if [ -x "${SCRIPT_DIR}/stop_cluster.sh" ]; then
  "${SCRIPT_DIR}/stop_cluster.sh" 2>/dev/null || true
else
  docker rm -f sglang-head 2>/dev/null || true
fi
echo "  Cluster stopped"

# Start new cluster
echo ""
log "Step 3/4: Starting cluster with new model..."
echo ""

if [ "${NEW_NODES}" -gt 1 ]; then
  echo "  Starting multi-node cluster (this may take 3-5 minutes)..."
  "${SCRIPT_DIR}/start_cluster.sh" --skip-pull 2>&1 | tee /tmp/model_switch.log &
else
  echo "  Starting single-node cluster (this may take 2-3 minutes)..."
  "${SCRIPT_DIR}/start_cluster.sh" --head-only --skip-pull 2>&1 | tee /tmp/model_switch.log &
fi
STARTUP_PID=$!

# Wait for API
echo ""
log "Step 4/4: Waiting for API to become ready..."

MAX_WAIT=600
ELAPSED=0
API_URL="http://127.0.0.1:30000"

while [ $ELAPSED -lt $MAX_WAIT ]; do
  if curl -sf "${API_URL}/health" >/dev/null 2>&1; then
    echo ""
    echo "  API is ready!"
    break
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
  if [ $((ELAPSED % 30)) -eq 0 ]; then
    # Check if startup process is still running
    if ! kill -0 $STARTUP_PID 2>/dev/null; then
      # Check if it succeeded
      if curl -sf "${API_URL}/health" >/dev/null 2>&1; then
        echo ""
        echo "  API is ready!"
        break
      fi
    fi
    echo "  Still waiting... ${ELAPSED}s elapsed"
  fi
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
  echo ""
  echo "  WARNING: API not ready after ${MAX_WAIT}s"
  echo "  Check logs: docker logs sglang-head"
  echo "  Or: cat /tmp/model_switch.log"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Verify and Display Results
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Model Switch Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get loaded model info
LOADED_MODEL=$(curl -sf "${API_URL}/v1/models" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null || echo "unknown")

echo "  Model:        ${LOADED_MODEL}"
echo "  API:          ${API_URL}"
echo "  Health:       ${API_URL}/health"
echo "  Time:         ${ELAPSED}s"
echo ""

# Quick test
echo "Testing inference..."
TEST_RESPONSE=$(curl -sf "${API_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"'"${NEW_MODEL}"'","messages":[{"role":"user","content":"Say OK"}],"max_tokens":5}' 2>/dev/null || echo "{}")

if echo "${TEST_RESPONSE}" | grep -q '"choices"'; then
  echo "  Inference test: PASSED"
else
  echo "  Inference test: FAILED (check logs)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
