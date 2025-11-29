# SGLang on DGX Spark Cluster

Deploy [SGLang](https://github.com/sgl-project/sglang) on a dual-node NVIDIA DGX Spark cluster with InfiniBand RDMA for serving large language models like GPT-OSS 120B.

## Features

- **Single-command deployment** - Start entire cluster from head node via SSH
- **Auto-detection** of InfiniBand IPs, network interfaces, and HCA devices
- **Generic scripts** that work on any DGX Spark pair
- **GPT-OSS 120B** support with reasoning/tool parsers
- **Blackwell (sm100) GPU support** with multi-node workarounds
- **InfiniBand RDMA** for high-speed inter-node communication
- **Comprehensive benchmarking** with multiple test profiles

## Cluster Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    DGX Spark 2-Node Cluster                     │
│                                                                 │
│  ┌──────────────────────┐      ┌──────────────────────┐        │
│  │     HEAD NODE        │      │    WORKER NODE       │        │
│  │    (node-rank 0)     │ SSH  │    (node-rank 1)     │        │
│  │                      │─────►│                      │        │
│  │  GPU: 1x GB10        │◄────►│  GPU: 1x GB10        │        │
│  │  (Blackwell, sm100)  │ IB   │  (Blackwell, sm100)  │        │
│  │                      │200Gb │                      │        │
│  │  /raid/hf-cache      │      │  /raid/hf-cache      │        │
│  │  Port: 30000 (API)   │      │                      │        │
│  └──────────────────────┘      └──────────────────────┘        │
│                                                                 │
│  Tensor Parallel (TP=2): Model split across both GPUs          │
└─────────────────────────────────────────────────────────────────┘
```

## Hardware Requirements

- **Nodes:** 2x DGX Spark systems
- **GPUs:** 1x NVIDIA GB10 (Grace Blackwell, sm100) per node, ~120GB VRAM each
- **Network:** 200Gb/s InfiniBand RoCE between nodes
- **Storage:** Shared model cache at `/raid/hf-cache` (or configure in `config.env`)
- **SSH:** Passwordless SSH from head to worker node(s)

## Prerequisites

Complete these steps on **BOTH** servers before running `start_cluster.sh`:

### 1. NVIDIA GPU Drivers

Ensure NVIDIA drivers are installed and working:
```bash
nvidia-smi
```
You should see your GPU listed with driver version.

### 2. Docker with NVIDIA Container Runtime

Docker must be installed with NVIDIA Container Runtime configured:
```bash
# Verify Docker works with GPU access
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu20.04 nvidia-smi
```
If this fails, install/configure the NVIDIA Container Toolkit.

### 3. InfiniBand Network Configuration

**CRITICAL:** InfiniBand (QSFP) interfaces must be configured and operational for multi-node performance.

```bash
# Check InfiniBand status
ibstatus

# Find InfiniBand interfaces (typically enp1s0f1np1, enP2p1s0f1np1 on DGX Spark)
ip addr show | grep 169.254

# Verify both nodes can reach each other via InfiniBand
ping <infiniband-ip-of-other-node>
```

InfiniBand IPs are typically in the `169.254.x.x` range.

**Performance Warning:** Using standard Ethernet IPs instead of InfiniBand will result in **10-20x slower performance**.

Need help with InfiniBand setup? See NVIDIA's guide: https://build.nvidia.com/spark/nccl/stacked-sparks

### 4. Firewall Configuration

Ensure the following ports are open between both nodes:
- **6379** - Ray GCS (used by SGLang for coordination)
- **30000** - SGLang API

### 5. Hugging Face Authentication (for gated models)

Some models (Llama, Gemma, etc.) require Hugging Face authorization:

```bash
# Install the Hugging Face CLI (run on both nodes)
pip install huggingface_hub

# Login to Hugging Face (run on both nodes)
huggingface-cli login
# Enter your token when prompted

# Accept model licenses
# Visit the model page on huggingface.co and accept the license agreement
# Example: https://huggingface.co/meta-llama/Llama-3.1-70B-Instruct
```

Alternatively, set `HF_TOKEN` in your `config.local.env`:
```bash
HF_TOKEN="hf_your_token_here"
```

## Quick Start

### 1. Clone and Setup

```bash
git clone <this-repo>
cd sglang-dgx-spark
```

### 2. Setup SSH (one-time)

Ensure passwordless SSH from head to worker:
```bash
# On head node, generate key if needed:
ssh-keygen -t ed25519  # Press enter for defaults

# Copy to worker (replace with your worker's InfiniBand IP):
ssh-copy-id <username>@<worker-ib-ip>

# Test connection:
ssh <username>@<worker-ib-ip> "hostname"
```

### 3. Configure Environment

**Option A: Interactive setup (recommended)**
```bash
source ./setup-env.sh
```

**Option B: Edit config file**
```bash
cp config.env config.local.env
vim config.local.env

# Set at minimum:
# WORKER_IPS="<worker-infiniband-ip>"
# WORKER_USER="<ssh-username>"
```

### 4. Start the Cluster

From the **head node**, run:
```bash
./start_cluster.sh
```

This single command will:
1. Setup tiktoken encodings (for GPT-OSS models)
2. Pull the Docker image on both nodes
3. SSH to worker(s) and start SGLang containers
4. Start SGLang on the head node
5. Wait for the cluster to become ready (~2-5 minutes)

### 5. Verify the Cluster

```bash
# Check health
curl http://localhost:30000/health

# List models
curl http://localhost:30000/v1/models

# Test inference
curl http://localhost:30000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-oss-120b","messages":[{"role":"user","content":"Hello!"}],"max_tokens":50}'
```

### 6. Run Benchmarks

```bash
# Quick sanity test (10 requests)
./benchmark_current.sh quick

# Throughput test
./benchmark_current.sh throughput

# Custom benchmark
./benchmark_current.sh -n 100 -i 512 -o 256
```

### 7. Stop the Cluster

```bash
./stop_cluster.sh
```

## Scripts Overview

| Script | Description |
|--------|-------------|
| `setup-env.sh` | Interactive environment setup (source this!) |
| `config.env` | Configuration template |
| `start_cluster.sh` | **Main script** - starts head + workers via SSH |
| `stop_cluster.sh` | Stops containers on head + workers |
| `switch_model.sh` | Switch between different models |
| `benchmark_current.sh` | Benchmark current model |
| `benchmark_all.sh` | Benchmark all models and create comparison matrix |

## Configuration

Key settings in `config.env` or `config.local.env`:

```bash
# ┌─────────────────────────────────────────────────────────────────┐
# │ Required for Multi-Node                                         │
# └─────────────────────────────────────────────────────────────────┘
WORKER_IPS="<worker-ib-ip>"        # Worker InfiniBand IP(s), space-separated
WORKER_USER="<username>"           # SSH username for workers

# ┌─────────────────────────────────────────────────────────────────┐
# │ Model Settings                                                  │
# └─────────────────────────────────────────────────────────────────┘
MODEL="openai/gpt-oss-120b"        # Model to serve
TENSOR_PARALLEL="2"                # Total GPUs (1 per node × 2 nodes)
MEM_FRACTION="0.90"                # GPU memory fraction for KV cache

# ┌─────────────────────────────────────────────────────────────────┐
# │ Multi-Node Workarounds (Important!)                             │
# └─────────────────────────────────────────────────────────────────┘
DISABLE_CUDA_GRAPH="true"          # Required for multi-node TP
EXTRA_ARGS="--enable-dp-attention" # Bypasses FlashInfer IPC issue

# ┌─────────────────────────────────────────────────────────────────┐
# │ Optional                                                        │
# └─────────────────────────────────────────────────────────────────┘
HF_TOKEN="hf_xxx"                  # For gated models (Llama, etc.)
SGLANG_IMAGE="lmsysorg/sglang:spark"  # Docker image
```

### Finding Worker InfiniBand IP

On the **worker node**, run:
```bash
# Find InfiniBand interface name
ibdev2netdev

# Example output: mlx5_0 port 1 ==> enp1s0f1np1 (Up)

# Get IP address for that interface
ip addr show enp1s0f1np1 | grep "inet "

# Example output: inet 169.254.x.x/16 ...
```

## Benchmark Profiles

The `benchmark_current.sh` script supports multiple profiles:

| Profile | Prompts | Input | Output | Use Case |
|---------|---------|-------|--------|----------|
| `quick` | 10 | 128 | 128 | Sanity test |
| `short` | 50 | 256 | 256 | Quick benchmark |
| `medium` | 100 | 512 | 512 | Standard benchmark |
| `long` | 200 | 1024 | 1024 | Extended test |
| `throughput` | 500 | 256 | 256 | Max throughput |
| `latency` | 100 | 128 | 128 | Rate-limited latency |
| `stress` | 1000 | 512 | 512 | Stress test |

```bash
# Run specific profile
./benchmark_current.sh throughput

# Custom settings
./benchmark_current.sh -n 200 -i 512 -o 1024 -c 32

# View results
cat benchmark_results/bench_*.json | python3 -m json.tool
```

### Benchmark All Models

Use `benchmark_all.sh` to automatically benchmark multiple models and create a comparison matrix:

```bash
# Benchmark all models (takes several hours)
./benchmark_all.sh

# Only single-node models (faster)
./benchmark_all.sh --single-node

# Skip models requiring HF token
./benchmark_all.sh --skip-token

# Quick benchmark of specific models
./benchmark_all.sh --models "1,2,3" --profile quick

# Dry run - see what would be benchmarked
./benchmark_all.sh --dry-run --single-node
```

The script generates:
- **Summary matrix** with throughput and latency for all models
- **CSV file** for spreadsheet analysis
- **JSON file** for programmatic access
- **Per-model benchmark files** with detailed metrics

## Switching Models

Use `switch_model.sh` to easily switch between models:

```bash
# List available models
./switch_model.sh --list

# Interactive selection
./switch_model.sh

# Direct selection (by number)
./switch_model.sh 3  # Switch to Qwen2.5-7B

# Update config only (don't restart)
./switch_model.sh -s 5
```

## Supported Models

All models run across both DGX Spark nodes (TP=2) for maximum performance.

| # | Model | Size | Notes |
|---|-------|------|-------|
| 1 | `openai/gpt-oss-120b` | ~80GB+ | Default, MoE, reasoning model |
| 2 | `openai/gpt-oss-20b` | ~16-20GB | MoE, fast |
| 3 | `Qwen/Qwen2.5-7B-Instruct` | ~7GB | Very fast |
| 4 | `Qwen/Qwen2.5-14B-Instruct` | ~14GB | Fast |
| 5 | `Qwen/Qwen2.5-32B-Instruct` | ~30GB | Strong mid-size |
| 6 | `Qwen/Qwen2.5-72B-Instruct` | ~70GB | High quality |
| 7 | `mistralai/Mistral-7B-Instruct-v0.3` | ~7GB | Very fast |
| 8 | `mistralai/Mistral-Nemo-Instruct-2407` | ~12GB | 128k context |
| 9 | `mistralai/Mixtral-8x7B-Instruct-v0.1` | ~45GB | MoE, fast |
| 10 | `meta-llama/Llama-3.1-8B-Instruct` | ~8GB | Very fast (needs HF token) |
| 11 | `meta-llama/Llama-3.1-70B-Instruct` | ~65GB | High quality (needs HF token) |
| 12 | `microsoft/phi-4` | ~14-16GB | Small but smart |
| 13 | `google/gemma-2-27b-it` | ~24-28GB | Strong mid-size (needs HF token) |
| 14 | `deepseek-ai/DeepSeek-V2-Lite-Chat` | ~12-16GB | MoE, reasoning tuned |

## API Endpoints

Once running, the API is available on the head node:

| Endpoint | Description |
|----------|-------------|
| `http://<head-ip>:30000/health` | Health check |
| `http://<head-ip>:30000/v1/models` | List models |
| `http://<head-ip>:30000/v1/chat/completions` | Chat API (OpenAI compatible) |
| `http://<head-ip>:30000/v1/completions` | Completions API |
| `http://<head-ip>:30000/generate` | SGLang native API |

### Example: Chat Completion

```bash
curl http://localhost:30000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai/gpt-oss-120b",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Explain quantum computing briefly."}
    ],
    "max_tokens": 200,
    "temperature": 0.7
  }'
```

### Example: Python Client

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:30000/v1",
    api_key="not-needed"
)

response = client.chat.completions.create(
    model="openai/gpt-oss-120b",
    messages=[{"role": "user", "content": "Hello!"}],
    max_tokens=100
)
print(response.choices[0].message.content)
```

## Troubleshooting

### Server Not Starting / FlashInfer IPC Error

**Symptom:** Container crashes with `CUDART error: invalid device context`

**Cause:** SGLang auto-enables FlashInfer AllReduce Fusion on Blackwell GPUs, but this uses CUDA IPC which doesn't work across nodes.

**Solution:** Ensure `EXTRA_ARGS` includes `--enable-dp-attention`:
```bash
# In config.env or config.local.env:
EXTRA_ARGS="--enable-dp-attention"
```

### SSH Connection Failed

```bash
# Test SSH connectivity
ssh <username>@<worker-ip> "hostname"

# If it fails, setup passwordless SSH:
ssh-copy-id <username>@<worker-ip>
```

### Cluster Not Becoming Ready

```bash
# Check head node logs
docker logs -f sglang-head

# Check worker logs (from head node)
ssh <username>@<worker-ip> "docker logs sglang-worker-*"

# Look for "The server is fired up and ready to roll!"
```

### NCCL Communication Issues

```bash
# Check InfiniBand devices
ibv_devinfo

# In logs, look for:
# NCCL INFO Using network IBext_v10
# NCCL INFO Connected all rings

# If IB issues, try disabling IB:
export NCCL_IB_DISABLE=1
./start_cluster.sh
```

### Out of Memory

```bash
# Reduce memory fraction
export MEM_FRACTION=0.80
./start_cluster.sh

# Or try a smaller model
export MODEL="openai/gpt-oss-20b"
export TENSOR_PARALLEL=1
export NUM_NODES=1
./start_cluster.sh --head-only
```

### PyTorch CUDA Capability Warning

**Symptom:** Warning about CUDA capability 12.1 not supported

**Note:** This warning can be ignored. The `lmsysorg/sglang:spark` image includes necessary patches for Blackwell support, even though PyTorch reports the capability as unsupported.

## Advanced Usage

### Start Head Only (Single Node)

```bash
./start_cluster.sh --head-only
```

### Skip Docker Pull (Faster Restart)

```bash
./start_cluster.sh --skip-pull
```

### Stop Local Only

```bash
./stop_cluster.sh --local-only
```

### Custom Worker IP on Command Line

```bash
./start_cluster.sh --worker-ip 169.254.x.x
```

### View Container Logs in Real-Time

```bash
# Head node
docker logs -f sglang-head

# Worker (from head via SSH)
ssh <worker-ip> "docker logs -f sglang-worker-*"
```

## Performance Notes

### Expected Performance (GPT-OSS 120B on 2x DGX Spark)

| Metric | Value |
|--------|-------|
| Output Throughput | ~75 tok/s |
| Total Throughput | ~150 tok/s |
| Time to First Token | ~2.7s |
| Inter-Token Latency | ~58ms |

### Optimization Tips

1. **Tensor Parallel (TP=2)** is the default and recommended mode
   - Model weights split across both GPUs
   - Requires `DISABLE_CUDA_GRAPH=true` for multi-node

2. **Memory Fraction** - Set to 0.90 for max KV cache, reduce if OOM

3. **InfiniBand** - Ensure IB is working for best cross-node performance:
   ```bash
   # Should show "IBext" in logs:
   docker logs sglang-head 2>&1 | grep -i "NCCL.*network"
   ```

4. **Model Cache** - Pre-download models to `/raid/hf-cache` to avoid download delays

## File Structure

```
sglang-dgx-spark/
├── README.md              # This file
├── config.env             # Configuration template
├── config.local.env       # Your local config (gitignored)
├── setup-env.sh           # Interactive setup script
├── start_cluster.sh       # Main cluster startup script
├── stop_cluster.sh        # Cluster shutdown script
├── switch_model.sh        # Model switching utility
├── benchmark_current.sh   # Single model benchmark tool
├── benchmark_all.sh       # Multi-model comparison benchmark
└── benchmark_results/     # Benchmark output directory
```

## References

- [SGLang Documentation](https://docs.sglang.io/)
- [SGLang Multi-Node Deployment](https://docs.sglang.io/references/multi_node_deployment/multi_node_index.html)
- [NVIDIA DGX Spark SGLang Playbook](https://build.nvidia.com/spark/sglang)
- [SGLang on DGX Spark Forum](https://forums.developer.nvidia.com/t/run-sglang-in-spark/348863)
- [GPT-OSS Announcement](https://lmsys.org/blog/2025-11-03-gpt-oss-on-nvidia-dgx-spark/)
- [SGLang GitHub](https://github.com/sgl-project/sglang)

## License

MIT
