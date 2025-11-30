#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SGLang Benchmark All Models Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Iterates through all supported models, benchmarks each one, and creates
# a summary comparison matrix of performance metrics.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Model Definitions (same as switch_model.sh)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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
)

MODEL_SHORT_NAMES=(
  "GPT-OSS-120B"
  "GPT-OSS-20B"
  "Qwen2.5-7B"
  "Qwen2.5-14B"
  "Qwen2.5-32B"
  "Qwen2.5-72B"
  "Mistral-7B"
  "Mistral-Nemo-12B"
  "Mixtral-8x7B"
  "Llama-3.1-8B"
  "Llama-3.1-70B"
  "Phi-4"
  "Gemma2-27B"
)

MODEL_NODES=(
  2 2 2 2 2 2 2 2 2 2 2 2 2
)

MODEL_NEEDS_TOKEN=(
  false false false false false false false false false true true false true
)

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Configuration
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${SCRIPT_DIR}/benchmark_results/all_models_${TIMESTAMP}"
SUMMARY_FILE="${OUTPUT_DIR}/summary.txt"
CSV_FILE="${OUTPUT_DIR}/results.csv"
JSON_FILE="${OUTPUT_DIR}/results.json"

# Benchmark settings
BENCHMARK_PROFILE="${BENCHMARK_PROFILE:-short}"
NUM_PROMPTS="${NUM_PROMPTS:-50}"
INPUT_LEN="${INPUT_LEN:-256}"
OUTPUT_LEN="${OUTPUT_LEN:-256}"

# Timing (increased to accommodate NCCL timeout of 20 min for problematic models)
STARTUP_TIMEOUT=900
BENCHMARK_TIMEOUT=600

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Parse Arguments
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SINGLE_NODE_ONLY=false
MULTI_NODE_ONLY=false
SKIP_TOKEN_MODELS=false
MODELS_TO_RUN=""
DRY_RUN=false

usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Benchmark all supported models and create a comparison matrix.

Options:
  --single-node       Only benchmark single-node models (TP=1)
  --multi-node        Only benchmark multi-node models (TP=2)
  --skip-token        Skip models that require HuggingFace token
  --models "1,3,5"    Only benchmark specific models (by number)
  --profile PROFILE   Benchmark profile: quick, short, medium (default: short)
  --prompts N         Number of prompts (default: 50)
  --input-len N       Input token length (default: 256)
  --output-len N      Output token length (default: 256)
  --dry-run           Show what would be benchmarked without running
  -h, --help          Show this help

Profiles:
  quick   - 10 prompts, 128 tokens (fast sanity check)
  short   - 50 prompts, 256 tokens (default, ~5 min/model)
  medium  - 100 prompts, 512 tokens (~10 min/model)

Examples:
  $0                           # Benchmark all models with default settings
  $0 --single-node             # Only single-node models
  $0 --models "1,2,3"          # Only models 1, 2, 3
  $0 --profile quick           # Quick benchmark of all models
  $0 --skip-token --single-node  # Single-node, no HF token required

EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --single-node)
      SINGLE_NODE_ONLY=true
      shift
      ;;
    --multi-node)
      MULTI_NODE_ONLY=true
      shift
      ;;
    --skip-token)
      SKIP_TOKEN_MODELS=true
      shift
      ;;
    --models)
      MODELS_TO_RUN="$2"
      shift 2
      ;;
    --profile)
      BENCHMARK_PROFILE="$2"
      shift 2
      ;;
    --prompts)
      NUM_PROMPTS="$2"
      shift 2
      ;;
    --input-len)
      INPUT_LEN="$2"
      shift 2
      ;;
    --output-len)
      OUTPUT_LEN="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Apply profile settings
case ${BENCHMARK_PROFILE} in
  quick)
    NUM_PROMPTS=10
    INPUT_LEN=128
    OUTPUT_LEN=128
    ;;
  short)
    NUM_PROMPTS=50
    INPUT_LEN=256
    OUTPUT_LEN=256
    ;;
  medium)
    NUM_PROMPTS=100
    INPUT_LEN=512
    OUTPUT_LEN=512
    ;;
esac

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Helper Functions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "${OUTPUT_DIR}/benchmark_all.log" 2>/dev/null || true
}

check_hf_token() {
  [ -n "${HF_TOKEN:-}" ] && return 0
  [ -f "${SCRIPT_DIR}/config.local.env" ] && grep -q '^HF_TOKEN=' "${SCRIPT_DIR}/config.local.env" && return 0
  return 1
}

wait_for_api() {
  local timeout=$1
  local elapsed=0
  local last_log=""

  echo "  Waiting for API (timeout: ${timeout}s)..."

  while [ $elapsed -lt $timeout ]; do
    if curl -sf "http://127.0.0.1:30000/health" >/dev/null 2>&1; then
      echo "  API ready after ${elapsed}s"
      return 0
    fi

    # Show progress every 30 seconds with latest container log
    if [ $((elapsed % 30)) -eq 0 ] && [ $elapsed -gt 0 ]; then
      # Get latest meaningful log line from container
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "sglang-head"; then
        last_log=$(docker logs --tail 5 sglang-head 2>&1 | grep -v "^$" | grep -v "HTTP/1.1" | tail -1 || echo "Loading...")
        echo "  [${elapsed}s] ${last_log:0:80}"
      else
        echo "  [${elapsed}s] Waiting for container..."
      fi
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "  Timeout after ${timeout}s"
  return 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Determine which models to benchmark
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

declare -a BENCHMARK_INDICES=()

if [ -n "${MODELS_TO_RUN}" ]; then
  # Parse comma-separated list
  IFS=',' read -ra SPECIFIED <<< "${MODELS_TO_RUN}"
  for num in "${SPECIFIED[@]}"; do
    idx=$((num - 1))
    if [ $idx -ge 0 ] && [ $idx -lt ${#MODELS[@]} ]; then
      BENCHMARK_INDICES+=($idx)
    fi
  done
else
  # Build list based on filters
  for i in "${!MODELS[@]}"; do
    # Check single-node filter
    if [ "${SINGLE_NODE_ONLY}" = "true" ] && [ "${MODEL_NODES[$i]}" -ne 1 ]; then
      continue
    fi
    # Check multi-node filter
    if [ "${MULTI_NODE_ONLY}" = "true" ] && [ "${MODEL_NODES[$i]}" -ne 2 ]; then
      continue
    fi
    # Check token filter
    if [ "${SKIP_TOKEN_MODELS}" = "true" ] && [ "${MODEL_NEEDS_TOKEN[$i]}" = "true" ]; then
      continue
    fi
    # Check if we have HF token for models that need it
    if [ "${MODEL_NEEDS_TOKEN[$i]}" = "true" ] && ! check_hf_token; then
      log "Skipping ${MODEL_SHORT_NAMES[$i]} (requires HF token)"
      continue
    fi
    BENCHMARK_INDICES+=($i)
  done
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Main Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " SGLang Benchmark All Models"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Configuration:"
echo "  Profile:        ${BENCHMARK_PROFILE}"
echo "  Num Prompts:    ${NUM_PROMPTS}"
echo "  Input Length:   ${INPUT_LEN} tokens"
echo "  Output Length:  ${OUTPUT_LEN} tokens"
echo "  Output Dir:     ${OUTPUT_DIR}"
echo ""
echo "Models to benchmark (${#BENCHMARK_INDICES[@]} total):"
for idx in "${BENCHMARK_INDICES[@]}"; do
  nodes_str="TP=${MODEL_NODES[$idx]}"
  [ "${MODEL_NODES[$idx]}" -eq 2 ] && nodes_str="${nodes_str} (2 nodes)"
  echo "  $((idx+1)). ${MODEL_SHORT_NAMES[$idx]} - ${nodes_str}"
done
echo ""

if [ "${DRY_RUN}" = "true" ]; then
  echo "Dry run - exiting without benchmarking."
  exit 0
fi

if [ ${#BENCHMARK_INDICES[@]} -eq 0 ]; then
  echo "ERROR: No models to benchmark. Check filters and HF token."
  exit 1
fi

# Confirm
read -p "Start benchmarking ${#BENCHMARK_INDICES[@]} models? This may take a while. (y/N): " CONFIRM
if [ "${CONFIRM}" != "y" ] && [ "${CONFIRM}" != "Y" ]; then
  echo "Cancelled."
  exit 0
fi

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Initialize results tracking
declare -A RESULTS_THROUGHPUT
declare -A RESULTS_TTFT
declare -A RESULTS_ITL
declare -A RESULTS_E2E
declare -A RESULTS_STATUS

# Initialize CSV
echo "model,model_short,nodes,tp,output_throughput,total_throughput,ttft_ms,itl_ms,e2e_ms,status" > "${CSV_FILE}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Benchmark Loop
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

TOTAL_MODELS=${#BENCHMARK_INDICES[@]}
CURRENT_MODEL=0
START_TIME=$(date +%s)

for idx in "${BENCHMARK_INDICES[@]}"; do
  CURRENT_MODEL=$((CURRENT_MODEL + 1))
  MODEL="${MODELS[$idx]}"
  MODEL_SHORT="${MODEL_SHORT_NAMES[$idx]}"
  NODES="${MODEL_NODES[$idx]}"
  MODEL_NUM=$((idx + 1))

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Model ${CURRENT_MODEL}/${TOTAL_MODELS}: ${MODEL_SHORT}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Starting benchmark for ${MODEL_SHORT} (${MODEL})"

  # Step 1: Switch to model
  log "  Switching to model..."
  if ! "${SCRIPT_DIR}/switch_model.sh" -s "${MODEL_NUM}" > "${OUTPUT_DIR}/${MODEL_SHORT}_switch.log" 2>&1; then
    log "  ERROR: Failed to switch model config"
    RESULTS_STATUS[$idx]="CONFIG_FAILED"
    echo "${MODEL},${MODEL_SHORT},${NODES},${NODES},,,,,,CONFIG_FAILED" >> "${CSV_FILE}"
    continue
  fi

  # Step 2: Start cluster (start_cluster.sh handles stopping existing containers)
  log "  Switching to model..."
  log "  Starting cluster (this may take several minutes)..."
  if [ "${NODES}" -eq 1 ]; then
    "${SCRIPT_DIR}/start_cluster.sh" --head-only --skip-pull > "${OUTPUT_DIR}/${MODEL_SHORT}_startup.log" 2>&1 &
  else
    "${SCRIPT_DIR}/start_cluster.sh" --skip-pull > "${OUTPUT_DIR}/${MODEL_SHORT}_startup.log" 2>&1 &
  fi
  STARTUP_PID=$!

  # Step 4: Wait for API
  log "  Waiting for API to become ready..."
  if ! wait_for_api ${STARTUP_TIMEOUT}; then
    log "  ERROR: API not ready after ${STARTUP_TIMEOUT}s"
    RESULTS_STATUS[$idx]="STARTUP_FAILED"
    echo "${MODEL},${MODEL_SHORT},${NODES},${NODES},,,,,,STARTUP_FAILED" >> "${CSV_FILE}"
    kill $STARTUP_PID 2>/dev/null || true
    continue
  fi
  log "  API is ready"

  # Step 5: Run benchmark
  log "  Running benchmark..."
  BENCH_OUTPUT="${OUTPUT_DIR}/${MODEL_SHORT}_benchmark.json"

  if timeout ${BENCHMARK_TIMEOUT} "${SCRIPT_DIR}/benchmark_current.sh" \
    -n "${NUM_PROMPTS}" \
    -i "${INPUT_LEN}" \
    -o "${OUTPUT_LEN}" \
    --output-dir "${OUTPUT_DIR}" \
    > "${OUTPUT_DIR}/${MODEL_SHORT}_bench.log" 2>&1; then

    # Find the benchmark output file
    LATEST_BENCH=$(ls -t "${OUTPUT_DIR}"/bench_*.json 2>/dev/null | head -1)
    if [ -n "${LATEST_BENCH}" ] && [ -f "${LATEST_BENCH}" ]; then
      mv "${LATEST_BENCH}" "${BENCH_OUTPUT}"

      # Parse results (handle JSONL format - take last line which is the main benchmark)
      METRICS=$(python3 << PARSE_SCRIPT
import json
import sys

try:
    with open("${BENCH_OUTPUT}", "r") as f:
        lines = f.readlines()
    # Take last non-empty line (main benchmark result, skip warmup if present)
    data = json.loads(lines[-1].strip())

    output_tput = data.get('output_throughput', 0)
    total_tput = data.get('total_throughput', output_tput)

    ttft = data.get('ttft_ms', data.get('mean_ttft_ms', 0))
    if isinstance(ttft, dict):
        ttft = ttft.get('mean', 0)

    itl = data.get('itl_ms', data.get('mean_itl_ms', 0))
    if isinstance(itl, dict):
        itl = itl.get('mean', 0)

    e2e = data.get('e2e_latency_ms', data.get('mean_e2e_latency_ms', 0))
    if isinstance(e2e, dict):
        e2e = e2e.get('mean', 0)

    print(f"{output_tput:.2f},{total_tput:.2f},{ttft:.2f},{itl:.2f},{e2e:.2f}")
except Exception as e:
    print("0,0,0,0,0")
    sys.exit(1)
PARSE_SCRIPT
)

      IFS=',' read -r OUT_TPUT TOT_TPUT TTFT ITL E2E <<< "${METRICS}"

      RESULTS_THROUGHPUT[$idx]="${OUT_TPUT}"
      RESULTS_TTFT[$idx]="${TTFT}"
      RESULTS_ITL[$idx]="${ITL}"
      RESULTS_E2E[$idx]="${E2E}"
      RESULTS_STATUS[$idx]="OK"

      log "  Results: ${OUT_TPUT} tok/s output, ${TTFT}ms TTFT, ${ITL}ms ITL"
      echo "${MODEL},${MODEL_SHORT},${NODES},${NODES},${OUT_TPUT},${TOT_TPUT},${TTFT},${ITL},${E2E},OK" >> "${CSV_FILE}"
    else
      log "  ERROR: Benchmark output file not found"
      RESULTS_STATUS[$idx]="NO_OUTPUT"
      echo "${MODEL},${MODEL_SHORT},${NODES},${NODES},,,,,,NO_OUTPUT" >> "${CSV_FILE}"
    fi
  else
    log "  ERROR: Benchmark failed or timed out"
    RESULTS_STATUS[$idx]="BENCH_FAILED"
    echo "${MODEL},${MODEL_SHORT},${NODES},${NODES},,,,,,BENCH_FAILED" >> "${CSV_FILE}"
  fi

  # Brief pause between models
  sleep 5
done

# Stop cluster after all benchmarks
log "Stopping cluster..."
"${SCRIPT_DIR}/stop_cluster.sh" -f > /dev/null 2>&1 || true

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Generate Summary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " SGLang Model Benchmark Summary"
  echo " Date: $(date)"
  echo " Total Time: $((TOTAL_TIME / 60))m $((TOTAL_TIME % 60))s"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Benchmark Configuration:"
  echo "  Profile:      ${BENCHMARK_PROFILE}"
  echo "  Prompts:      ${NUM_PROMPTS}"
  echo "  Input Len:    ${INPUT_LEN} tokens"
  echo "  Output Len:   ${OUTPUT_LEN} tokens"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " PERFORMANCE MATRIX"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  printf "%-20s %6s %12s %10s %10s %10s %10s\n" "Model" "Nodes" "Output tok/s" "TTFT (ms)" "ITL (ms)" "E2E (ms)" "Status"
  printf "%-20s %6s %12s %10s %10s %10s %10s\n" "--------------------" "------" "------------" "----------" "----------" "----------" "----------"

  for idx in "${BENCHMARK_INDICES[@]}"; do
    MODEL_SHORT="${MODEL_SHORT_NAMES[$idx]}"
    NODES="${MODEL_NODES[$idx]}"
    STATUS="${RESULTS_STATUS[$idx]:-SKIPPED}"

    if [ "${STATUS}" = "OK" ]; then
      printf "%-20s %6s %12s %10s %10s %10s %10s\n" \
        "${MODEL_SHORT}" \
        "${NODES}" \
        "${RESULTS_THROUGHPUT[$idx]:-N/A}" \
        "${RESULTS_TTFT[$idx]:-N/A}" \
        "${RESULTS_ITL[$idx]:-N/A}" \
        "${RESULTS_E2E[$idx]:-N/A}" \
        "${STATUS}"
    else
      printf "%-20s %6s %12s %10s %10s %10s %10s\n" \
        "${MODEL_SHORT}" \
        "${NODES}" \
        "-" \
        "-" \
        "-" \
        "-" \
        "${STATUS}"
    fi
  done

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " THROUGHPUT RANKING (Output Tokens/Second)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Sort by throughput (descending)
  declare -a SORTED_BY_THROUGHPUT=()
  for idx in "${BENCHMARK_INDICES[@]}"; do
    if [ "${RESULTS_STATUS[$idx]:-}" = "OK" ]; then
      SORTED_BY_THROUGHPUT+=("${RESULTS_THROUGHPUT[$idx]}:${idx}")
    fi
  done

  # Sort and display
  RANK=1
  for entry in $(printf '%s\n' "${SORTED_BY_THROUGHPUT[@]}" | sort -t: -k1 -rn); do
    TPUT="${entry%%:*}"
    idx="${entry##*:}"
    MODEL_SHORT="${MODEL_SHORT_NAMES[$idx]}"
    NODES="${MODEL_NODES[$idx]}"
    printf "%2d. %-20s %8s tok/s  (TP=%d)\n" "${RANK}" "${MODEL_SHORT}" "${TPUT}" "${NODES}"
    RANK=$((RANK + 1))
  done

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " LATENCY RANKING (Time to First Token)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Sort by TTFT (ascending - lower is better)
  declare -a SORTED_BY_TTFT=()
  for idx in "${BENCHMARK_INDICES[@]}"; do
    if [ "${RESULTS_STATUS[$idx]:-}" = "OK" ]; then
      SORTED_BY_TTFT+=("${RESULTS_TTFT[$idx]}:${idx}")
    fi
  done

  RANK=1
  for entry in $(printf '%s\n' "${SORTED_BY_TTFT[@]}" | sort -t: -k1 -n); do
    TTFT="${entry%%:*}"
    idx="${entry##*:}"
    MODEL_SHORT="${MODEL_SHORT_NAMES[$idx]}"
    NODES="${MODEL_NODES[$idx]}"
    printf "%2d. %-20s %8s ms  (TP=%d)\n" "${RANK}" "${MODEL_SHORT}" "${TTFT}" "${NODES}"
    RANK=$((RANK + 1))
  done

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Output files:"
  echo "  Summary:     ${SUMMARY_FILE}"
  echo "  CSV:         ${CSV_FILE}"
  echo "  Per-model:   ${OUTPUT_DIR}/<model>_benchmark.json"
  echo ""

} | tee "${SUMMARY_FILE}"

# Generate JSON summary
python3 << JSON_SCRIPT
import json
import csv

results = []
with open("${CSV_FILE}", "r") as f:
    reader = csv.DictReader(f)
    for row in reader:
        results.append(row)

summary = {
    "timestamp": "${TIMESTAMP}",
    "config": {
        "profile": "${BENCHMARK_PROFILE}",
        "num_prompts": ${NUM_PROMPTS},
        "input_len": ${INPUT_LEN},
        "output_len": ${OUTPUT_LEN}
    },
    "total_time_seconds": ${TOTAL_TIME},
    "models_tested": len(results),
    "results": results
}

with open("${JSON_FILE}", "w") as f:
    json.dump(summary, f, indent=2)

print(f"JSON summary saved to: ${JSON_FILE}")
JSON_SCRIPT

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Benchmark Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
