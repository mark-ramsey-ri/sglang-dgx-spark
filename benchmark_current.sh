#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SGLang Comprehensive Benchmark Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Similar to vLLM's bench_serving, uses SGLang's built-in benchmark tool
# with various workload patterns for comprehensive performance testing.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
if [ -f "${SCRIPT_DIR}/config.local.env" ]; then
  source "${SCRIPT_DIR}/config.local.env"
elif [ -f "${SCRIPT_DIR}/config.env" ]; then
  source "${SCRIPT_DIR}/config.env"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Configuration
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SGLANG_HOST="${SGLANG_HOST:-127.0.0.1}"
SGLANG_PORT="${SGLANG_PORT:-30000}"
MODEL="${MODEL:-openai/gpt-oss-120b}"
SGLANG_IMAGE="${SGLANG_IMAGE:-lmsysorg/sglang:spark}"

# Output directory for results
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/benchmark_results}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Benchmark Profiles
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Default: Quick sanity test
PROFILE="quick"
NUM_PROMPTS=10
INPUT_LEN=128
OUTPUT_LEN=128
REQUEST_RATE="inf"
MAX_CONCURRENCY=""

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

check_server() {
  curl -sf "http://${SGLANG_HOST}:${SGLANG_PORT}/health" >/dev/null 2>&1
}

usage() {
  cat << EOF
Usage: $0 [OPTIONS] [PROFILE]

Profiles:
  quick       Quick sanity test (10 prompts, 128 in/out)
  short       Short benchmark (50 prompts, 256 in/out)
  medium      Medium benchmark (100 prompts, 512 in/out)
  long        Long benchmark (200 prompts, 1024 in/out)
  throughput  Max throughput test (500 prompts, concurrent)
  latency     Latency-focused test (100 prompts, rate-limited)
  stress      Stress test (1000 prompts, high concurrency)
  custom      Use custom settings from options

Options:
  -h, --host HOST          Server host (default: ${SGLANG_HOST})
  -p, --port PORT          Server port (default: ${SGLANG_PORT})
  -n, --num-prompts N      Number of prompts (default: ${NUM_PROMPTS})
  -i, --input-len N        Input token length (default: ${INPUT_LEN})
  -o, --output-len N       Output token length (default: ${OUTPUT_LEN})
  -r, --request-rate R     Request rate (default: inf)
  -c, --concurrency N      Max concurrent requests
  --output-dir DIR         Output directory for results
  --no-docker              Run bench_serving natively (requires sglang installed)
  --help                   Show this help

Examples:
  $0 quick                 # Quick 10-request test
  $0 throughput            # Max throughput benchmark
  $0 -n 50 -i 256 -o 512   # Custom settings
  $0 latency -r 1          # 1 request/second latency test

EOF
  exit 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Parse Arguments
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

USE_DOCKER=true
CUSTOM_SETTINGS=false

while [[ $# -gt 0 ]]; do
  case $1 in
    quick|short|medium|long|throughput|latency|stress|custom)
      PROFILE="$1"
      shift
      ;;
    -h|--host)
      SGLANG_HOST="$2"
      shift 2
      ;;
    -p|--port)
      SGLANG_PORT="$2"
      shift 2
      ;;
    -n|--num-prompts)
      NUM_PROMPTS="$2"
      CUSTOM_SETTINGS=true
      shift 2
      ;;
    -i|--input-len)
      INPUT_LEN="$2"
      CUSTOM_SETTINGS=true
      shift 2
      ;;
    -o|--output-len)
      OUTPUT_LEN="$2"
      CUSTOM_SETTINGS=true
      shift 2
      ;;
    -r|--request-rate)
      REQUEST_RATE="$2"
      CUSTOM_SETTINGS=true
      shift 2
      ;;
    -c|--concurrency)
      MAX_CONCURRENCY="$2"
      CUSTOM_SETTINGS=true
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --no-docker)
      USE_DOCKER=false
      shift
      ;;
    --help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Apply profile settings (unless custom settings were provided)
if [ "${CUSTOM_SETTINGS}" != "true" ]; then
  case ${PROFILE} in
    quick)
      NUM_PROMPTS=10
      INPUT_LEN=128
      OUTPUT_LEN=128
      REQUEST_RATE="inf"
      ;;
    short)
      NUM_PROMPTS=50
      INPUT_LEN=256
      OUTPUT_LEN=256
      REQUEST_RATE="inf"
      ;;
    medium)
      NUM_PROMPTS=100
      INPUT_LEN=512
      OUTPUT_LEN=512
      REQUEST_RATE="inf"
      ;;
    long)
      NUM_PROMPTS=200
      INPUT_LEN=1024
      OUTPUT_LEN=1024
      REQUEST_RATE="inf"
      ;;
    throughput)
      NUM_PROMPTS=500
      INPUT_LEN=256
      OUTPUT_LEN=256
      REQUEST_RATE="inf"
      MAX_CONCURRENCY=64
      ;;
    latency)
      NUM_PROMPTS=100
      INPUT_LEN=128
      OUTPUT_LEN=128
      REQUEST_RATE=2
      ;;
    stress)
      NUM_PROMPTS=1000
      INPUT_LEN=512
      OUTPUT_LEN=512
      REQUEST_RATE="inf"
      MAX_CONCURRENCY=128
      ;;
  esac
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Setup Output Directory
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

mkdir -p "${OUTPUT_DIR}"
OUTPUT_FILE="${OUTPUT_DIR}/bench_${PROFILE}_${TIMESTAMP}.json"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Main Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " SGLang Benchmark - ${PROFILE^^} Profile"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log "Configuration:"
log "  Server:         http://${SGLANG_HOST}:${SGLANG_PORT}"
log "  Model:          ${MODEL}"
log "  Profile:        ${PROFILE}"
log "  Num Prompts:    ${NUM_PROMPTS}"
log "  Input Length:   ${INPUT_LEN} tokens"
log "  Output Length:  ${OUTPUT_LEN} tokens"
log "  Request Rate:   ${REQUEST_RATE} req/s"
[ -n "${MAX_CONCURRENCY}" ] && log "  Max Concurrency: ${MAX_CONCURRENCY}"
log "  Output File:    ${OUTPUT_FILE}"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 1: Health Check
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 1/3: Checking server health..."

if ! check_server; then
  error "Server is not responding at http://${SGLANG_HOST}:${SGLANG_PORT}

  Make sure the SGLang cluster is running:
    ./start_cluster.sh

  Then check health:
    curl http://${SGLANG_HOST}:${SGLANG_PORT}/health"
fi

log "  Server is healthy"

# Get model info
MODEL_INFO=$(curl -sf "http://${SGLANG_HOST}:${SGLANG_PORT}/v1/models" 2>/dev/null || echo "{}")
if [ -n "${MODEL_INFO}" ] && [ "${MODEL_INFO}" != "{}" ]; then
  SERVED_MODEL=$(echo "${MODEL_INFO}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',[{}])[0].get('id','unknown'))" 2>/dev/null || echo "unknown")
  log "  Serving model: ${SERVED_MODEL}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 2: Warmup
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 2/3: Warming up..."

cat > /tmp/warmup_request.json << EOF
{"model":"${MODEL}","messages":[{"role":"user","content":"Hello, please respond with OK."}],"max_tokens":10}
EOF

WARMUP_START=$(date +%s.%N)
curl -sf "http://${SGLANG_HOST}:${SGLANG_PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d @/tmp/warmup_request.json > /dev/null 2>&1 || true
WARMUP_END=$(date +%s.%N)
WARMUP_TIME=$(echo "${WARMUP_END} - ${WARMUP_START}" | bc)
log "  Warmup completed in ${WARMUP_TIME}s"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 3: Run Benchmark
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 3/3: Running benchmark..."
echo ""

# Build benchmark command arguments
BENCH_ARGS=(
  --backend sglang-oai
  --host "${SGLANG_HOST}"
  --port "${SGLANG_PORT}"
  --model "${MODEL}"
  --dataset-name random
  --num-prompts "${NUM_PROMPTS}"
  --random-input-len "${INPUT_LEN}"
  --random-output-len "${OUTPUT_LEN}"
  --request-rate "${REQUEST_RATE}"
  --output-file "/tmp/benchmark_output.json"
)

# Add optional arguments
[ -n "${MAX_CONCURRENCY}" ] && BENCH_ARGS+=(--max-concurrency "${MAX_CONCURRENCY}")

# Clear any existing output file to prevent appending
# Use docker to remove in case it was created by a container (root ownership)
if [ "${USE_DOCKER}" = "true" ]; then
  docker run --rm -v /tmp:/tmp "${SGLANG_IMAGE}" rm -f /tmp/benchmark_output.json 2>/dev/null || true
fi
rm -f /tmp/benchmark_output.json 2>/dev/null || true

# Run benchmark
BENCH_START=$(date +%s.%N)

if [ "${USE_DOCKER}" = "true" ]; then
  docker run --rm --network host \
    -v /tmp:/tmp \
    -e "HF_TOKEN=${HF_TOKEN:-}" \
    -e "HF_HOME=/root/.cache/huggingface" \
    "${SGLANG_IMAGE}" \
    python3 -m sglang.bench_serving "${BENCH_ARGS[@]}"
else
  python3 -m sglang.bench_serving "${BENCH_ARGS[@]}"
fi

BENCH_END=$(date +%s.%N)
BENCH_DURATION=$(echo "${BENCH_END} - ${BENCH_START}" | bc)

# Copy output file
if [ -f /tmp/benchmark_output.json ]; then
  cp /tmp/benchmark_output.json "${OUTPUT_FILE}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Parse and Display Results
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Benchmark Results"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -f "${OUTPUT_FILE}" ]; then
  # Parse results from JSON
  python3 << PARSE_SCRIPT
import json
import sys

try:
    with open("${OUTPUT_FILE}", "r") as f:
        data = json.load(f)

    print("  Test Configuration:")
    print(f"    Profile:              ${PROFILE}")
    print(f"    Num Prompts:          {data.get('num_prompts', 'N/A')}")
    print(f"    Request Rate:         {data.get('request_rate', 'N/A')} req/s")
    print(f"    Input Length:         ${INPUT_LEN} tokens")
    print(f"    Output Length:        ${OUTPUT_LEN} tokens")
    print()
    print("  Throughput Metrics:")
    print(f"    Total Duration:       {data.get('total_time', 0):.2f}s")
    print(f"    Requests/sec:         {data.get('request_throughput', 0):.2f}")
    print(f"    Input tok/s:          {data.get('input_throughput', 0):.2f}")
    print(f"    Output tok/s:         {data.get('output_throughput', 0):.2f}")
    print(f"    Total tok/s:          {data.get('total_throughput', data.get('output_throughput', 0)):.2f}")
    print()
    print("  Latency Metrics (seconds):")

    # TTFT (Time to First Token)
    ttft = data.get('ttft_ms', data.get('mean_ttft_ms', 0))
    if isinstance(ttft, dict):
        print(f"    TTFT Mean:            {ttft.get('mean', 0)/1000:.3f}s")
        print(f"    TTFT Median:          {ttft.get('median', ttft.get('p50', 0))/1000:.3f}s")
        print(f"    TTFT P99:             {ttft.get('p99', 0)/1000:.3f}s")
    else:
        print(f"    TTFT Mean:            {ttft/1000:.3f}s")

    # TPOT (Time Per Output Token)
    tpot = data.get('tpot_ms', data.get('mean_tpot_ms', 0))
    if isinstance(tpot, dict):
        print(f"    TPOT Mean:            {tpot.get('mean', 0)/1000:.4f}s")
        print(f"    TPOT Median:          {tpot.get('median', tpot.get('p50', 0))/1000:.4f}s")
        print(f"    TPOT P99:             {tpot.get('p99', 0)/1000:.4f}s")
    else:
        print(f"    TPOT Mean:            {tpot/1000:.4f}s")

    # ITL (Inter-Token Latency) if available
    itl = data.get('itl_ms', data.get('mean_itl_ms', None))
    if itl:
        if isinstance(itl, dict):
            print(f"    ITL Mean:             {itl.get('mean', 0)/1000:.4f}s")
        else:
            print(f"    ITL Mean:             {itl/1000:.4f}s")

    # E2E Latency
    e2e = data.get('e2e_latency_ms', data.get('mean_e2e_latency_ms', 0))
    if isinstance(e2e, dict):
        print(f"    E2E Mean:             {e2e.get('mean', 0)/1000:.3f}s")
        print(f"    E2E Median:           {e2e.get('median', e2e.get('p50', 0))/1000:.3f}s")
        print(f"    E2E P99:              {e2e.get('p99', 0)/1000:.3f}s")
    else:
        print(f"    E2E Mean:             {e2e/1000:.3f}s")

    print()
    print("  Request Statistics:")
    print(f"    Completed:            {data.get('completed', data.get('num_prompts', 'N/A'))}")
    print(f"    Failed:               {data.get('failed', 0)}")

except Exception as e:
    print(f"  Error parsing results: {e}")
    print(f"  Raw output saved to: ${OUTPUT_FILE}")
PARSE_SCRIPT

else
  echo "  WARNING: No output file generated"
  echo "  Check if benchmark completed successfully"
fi

echo ""
log "Benchmark completed in ${BENCH_DURATION}s"
log "Results saved to: ${OUTPUT_FILE}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Quick Reference"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Run other profiles:"
echo "    $0 short       # 50 prompts, 256 tokens"
echo "    $0 medium      # 100 prompts, 512 tokens"
echo "    $0 throughput  # Max throughput test"
echo "    $0 latency     # Rate-limited latency test"
echo ""
echo "  Custom benchmark:"
echo "    $0 -n 100 -i 512 -o 1024 -c 32"
echo ""
echo "  View saved results:"
echo "    cat ${OUTPUT_FILE} | python3 -m json.tool"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
