# SGLang on DGX Spark Cluster

Deploy [SGLang](https://github.com/sgl-project/sglang) on **1 to N NVIDIA DGX Spark systems** — single Spark, two Sparks via direct QSFP cable, or 3+ Sparks via a switched fabric — for serving large language models with tensor parallelism scaling automatically with the cluster size.

> **DISCLAIMER**: This project is NOT affiliated with, endorsed by, or officially supported by NVIDIA, SGLang, LMSYS, or any other organization. This is a community-driven effort to run SGLang on DGX Spark hardware. Use at your own risk. The software is provided "AS IS", without warranty of any kind.

> **Updated (2026-05-01)**:
> - **1-to-N Spark support** — `WORKER_HOST` and `WORKER_IB_IP` are now space-separated lists; `TENSOR_PARALLEL` and `NUM_NODES` default to `1 + N` workers. The same scripts handle single Spark, 2 Sparks (direct cable), and 3+ Sparks (switched fabric). **Verified end-to-end on 1 and 2 Sparks**; the n>2 code paths are reviewed but not yet exercised on real hardware (a 4-Spark switched-fabric run is queued for the next test window).
> - **Container** `lmsysorg/sglang:v0.5.10.post1-cu130` (SGLang 0.5.10, CUDA 13.0.1, multi-arch arm64) replaces the older `lmsysorg/sglang:spark` (~5 months stale, SGLang 0.5.5, CUDA 12.x). Override via `SGLANG_IMAGE` if you need the legacy tag.
> - **Multi-Spark OS-setup steps inlined** in section 3 of this README (paraphrased from NVIDIA's playbook so you don't have to bounce between docs); `./setup-env.sh --discover` wraps NVIDIA's mDNS discovery for SSH key push.
> - **Quality-of-life fixes** — `stop_cluster.sh` auto-confirms in non-tty pipelines, `switch_model.sh` writes override-friendly `${X:-default}` form so env vars still win after switching models, and `start_cluster.sh` prints clearer errors when worker config is missing.

## Features

- **1-to-N Spark support** - Single Spark, two Sparks (stacked / direct cable), or 3+ Sparks (switched fabric). `WORKER_HOST` and `WORKER_IB_IP` are space-separated lists; `TENSOR_PARALLEL` defaults to `1 + N` workers.
- **Zero-config single-Spark** - No InfiniBand setup required for single-Spark deployments
- **Single-command deployment** - Start the entire cluster from the head Spark via SSH
- **Auto-detection** of InfiniBand IPs, network interfaces, and HCA devices (multi-Spark)
- **Latest SGLang container** (`v0.5.10.post1-cu130`, multi-arch arm64, CUDA 13)
- **GPT-OSS 120B** support with reasoning / tool parsers (`--reasoning-parser gpt-oss`)
- **Blackwell (sm120) GPU support** with the FlashInfer-IPC workaround (`--enable-dp-attention`) for cross-node TP
- **InfiniBand RDMA** for high-speed inter-Spark communication (200 Gb/s)
- **Comprehensive benchmarking** with multiple test profiles

## Cluster Architecture

### Single-Node Mode (1x DGX Spark)

```
┌─────────────────────────────────────────────────────────────────┐
│                    DGX Spark Single Node                        │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                      SINGLE NODE                          │  │
│  │                                                           │  │
│  │  GPU: 1x GB10 (Blackwell, sm120) ~120GB unified memory   │  │
│  │  /raid/hf-cache                                          │  │
│  │  Port: 30000 (API)                                       │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  Tensor Parallel (TP=1): Full model on single GPU              │
│  Best for: Models up to ~100GB (GPT-OSS 120B MXFP4, Llama 70B) │
└─────────────────────────────────────────────────────────────────┘
```

### Multi-Spark Mode (1 head + N workers)

The same scripts handle 2 Sparks (directly cabled QSFP) and 3+ Sparks (switched fabric). `TENSOR_PARALLEL` and `NUM_NODES` default to `1 + N` (one GPU per Spark) but can be overridden.

```
┌────────────────────────────────────────────────────────────────────┐
│            DGX Spark Cluster (1 Head + N Workers)                  │
│                                                                    │
│  ┌──────────────────────┐  ┌──────────────────────┐  ┌─────────┐  │
│  │     HEAD NODE        │  │   WORKER NODE 1      │  │  ...    │  │
│  │   (node-rank 0)      │  │   (node-rank 1)      │  │ Worker  │  │
│  │                      │  │                      │  │   N     │  │
│  │  GPU: 1x GB10        │◄►│  GPU: 1x GB10        │◄►│         │  │
│  │  (Blackwell, sm120)  │IB│  (Blackwell, sm120)  │IB│         │  │
│  │                      │  │                      │  │         │  │
│  │  /raid/hf-cache      │  │  /raid/hf-cache      │  │  ...    │  │
│  │  Port: 30000 (API)   │  │                      │  │         │  │
│  └──────────────────────┘  └──────────────────────┘  └─────────┘  │
│           ▲                          ▲                    ▲        │
│           └──────────────────────────┴────────────────────┘        │
│         200Gb/s QSFP - direct cable (2 Sparks) or switch (3+)      │
│                                                                    │
│  Tensor Parallel (TP=N+1): Model split across all GPUs             │
│  Default TP: 1 + WORKER_COUNT (override via TENSOR_PARALLEL=...)   │
│                                                                    │
│  SGLang uses --nnodes / --node-rank / --dist-init-addr for         │
│  cross-Spark coordination (no Ray dependency).                     │
└────────────────────────────────────────────────────────────────────┘
```

NVIDIA documents three reference topologies — see their official playbook at <https://build.nvidia.com/spark/sglang> (single Spark, stacked / direct-cable 2 Sparks, switched 3+ Sparks). Our scripts cover all three with the same code path.

## Hardware Requirements

### Single-Spark
- **Nodes:** 1x DGX Spark system
- **GPUs:** 1x NVIDIA GB10 (Grace Blackwell, sm120), ~120GB unified memory
- **Storage:** Model cache at `/raid/hf-cache` (or configure in `config.env`)

### Multi-Spark (2+ Sparks for larger models)
- **Nodes:** 2 or more DGX Spark systems
- **GPUs:** 1x NVIDIA GB10 per node, ~120GB unified memory each
- **Network:**
  - **2 Sparks**: 200Gb/s QSFP direct cable (no switch needed)
  - **3+ Sparks**: 200Gb/s QSFP through a switch
- **Storage:** Model cache at `/raid/hf-cache` on every Spark
- **SSH:** Passwordless SSH from head to every worker

## Prerequisites

Complete these steps on your server(s) before running `start_cluster.sh`.

**Single-node setups only require steps 1, 2, and 5 (HuggingFace token for gated models).** InfiniBand and SSH configuration are automatically skipped when running in single-node mode.

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
docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu22.04 nvidia-smi
```
If this fails, install/configure the NVIDIA Container Toolkit.

### 3. Multi-Spark Initial Setup (skip for single-Spark)

**Single-Spark users:** skip this entire section. Single-Spark mode needs only the GPU drivers and Docker (steps 1–2 above) plus a HuggingFace token (step 5 below).

**Multi-Spark users:** these are the prerequisites for getting 2+ DGX Sparks talking to each other before our cluster scripts take over. This section paraphrases NVIDIA's [Multi Sparks Through Switch](https://build.nvidia.com/spark/multi-sparks-through-switch/multi-sparks) playbook so you can do it without bouncing between docs. If you'd rather use NVIDIA's tooling directly (their `spark_cluster_setup.sh` is a JSON-config-driven one-shot), see the "Alternative: NVIDIA's bootstrap script" note at the end of this section.

#### 3a. Same username + password on every Spark

Our `start_cluster.sh` SSHes from the head Spark to every worker as the same user. Pick a username (e.g. your own login, or `nvidia`) and create it identically on every Spark:

```bash
# On each Spark, if the user doesn't already exist:
sudo useradd -m <username>
sudo usermod -aG sudo <username>
sudo passwd <username>          # use the same password on every Spark
```

If you already log in to every Spark with the same username, skip this step.

#### 3b. Verify the QSFP link is up at 200 Gb/s

The DGX Spark's CX7 NIC has two QSFP ports; each port has two logical interfaces (e.g. `enp1s0f1np1` and `enP2p1s0f1np1`). NVIDIA recommends using the **same physical port on every Spark** (the one farther from the Ethernet jack) to avoid NCCL headaches. On every Spark:

```bash
# Confirm interfaces show "(Up)" status
ibdev2netdev

# Confirm link speed
sudo ethtool enp1s0f1np1 | grep Speed
sudo ethtool enP2p1s0f1np1 | grep Speed
# Expect: Speed: 200000Mb/s
```

If the speed is below 200 Gb/s, auto-negotiation may not have settled the right rate. Disable auto-neg on the corresponding switch port and pin it to 200G manually (e.g. `200G-baseCR4`), per your switch's manual.

#### 3c. Configure CX7 IPs (netplan)

Three options, all using netplan (`/etc/netplan/40-cx7.yaml`, mode 600). Pick **one** and apply it on every Spark.

**Option A — DHCP from the switch** (recommended if your switch can run DHCP):
```yaml
# /etc/netplan/40-cx7.yaml
network:
  version: 2
  ethernets:
    enp1s0f1np1:
      dhcp4: true
    enP2p1s0f1np1:
      dhcp4: true
```

**Option B — Link-local IPv4** (zero-config; gives you `169.254.x.x` per spark):
```yaml
network:
  version: 2
  ethernets:
    enp1s0f1np1:
      link-local: [ ipv4 ]
    enP2p1s0f1np1:
      link-local: [ ipv4 ]
```

**Option C — Static** (use this if you want predictable IPs; example for 4 Sparks on `192.168.100.0/24`):
```yaml
# Spark 1
network:
  version: 2
  ethernets:
    enp1s0f1np1:
      addresses: [192.168.100.10/24]
    enP2p1s0f1np1:
      addresses: [192.168.100.11/24]

# Spark 2: .12/.13     Spark 3: .14/.15     Spark 4: .16/.17
```

Apply the config:
```bash
sudo chmod 600 /etc/netplan/40-cx7.yaml
sudo netplan apply
ip addr show enp1s0f1np1 | grep -w inet     # should show your IP
```

#### 3d. Switch configuration (3+ Sparks only)

For switched (3+ Spark) setups, the switch must put every CX7 port in a single layer-2 bridge so all Sparks share one broadcast domain. Some switches can only enable hardware offloading on a single bridge — keep them all on the default bridge if so. Refer to your switch's UI/CLI documentation for bridge management.

For 2-Spark stacked setups (direct QSFP cable), no switch — skip this step.

#### 3e. Passwordless SSH between Sparks

You need bidirectional passwordless SSH so the head Spark can launch the worker scripts and so workers can communicate. Two ways:

**Easy: use our `setup-env.sh --discover`** (wraps NVIDIA's mDNS-based discovery script). From any Spark:

```bash
./setup-env.sh --discover
```

This downloads NVIDIA's `discover-sparks` script, scans the local network for `dgx-spark-*.local` hostnames, prompts once for each Spark's password, and pushes SSH keys bidirectionally. Then re-run `source ./setup-env.sh` (without `--discover`) to capture the discovered IPs into `WORKER_HOST` / `WORKER_IB_IP`.

**Manual: `ssh-copy-id` per Spark**. From your head Spark:

```bash
# Find each Spark's IB IP
ip addr show enp1s0f1np1 | grep -w inet     # local IP
# repeat on every other Spark to collect their IPs

# Push keys (once per worker)
ssh-keygen -t ed25519                         # if you don't already have a key
ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<worker-IP>

# Verify
ssh <user>@<worker-IP> hostname
```

Repeat for every worker. For a 4-Spark cluster, that's 3 `ssh-copy-id` calls from the head.

#### 3f. (Optional) NCCL bandwidth smoke test

Before launching SGLang, you can verify cross-Spark NCCL throughput with `all_gather_perf` from [nccl-tests](https://github.com/NVIDIA/nccl-tests). This catches "NCCL fell back to TCP sockets" before it bites you mid-model-load.

```bash
# On every Spark (one-time): build the tests
git clone https://github.com/NVIDIA/nccl-tests
cd nccl-tests && make MPI=1 MPI_HOME=/usr/lib/aarch64-linux-gnu/openmpi

# From the head Spark, run a multi-host all_gather (example for 4 Sparks):
export NCCL_SOCKET_IFNAME=enp1s0f1np1
export UCX_NET_DEVICES=enp1s0f1np1
mpirun -np 4 \
  -H <head-IP>:1,<w1-IP>:1,<w2-IP>:1,<w3-IP>:1 \
  --mca plm_rsh_agent "ssh -o StrictHostKeyChecking=no" \
  -x LD_LIBRARY_PATH=$LD_LIBRARY_PATH \
  $HOME/nccl-tests/build/all_gather_perf
```

You should see ~150–180 Gb/s per host on a healthy 200G fabric. Numbers below ~50 Gb/s usually mean NCCL fell back to socket transport — check that `NCCL_IB_HCA` and `NCCL_SOCKET_IFNAME` point at your CX7 device.

#### 3g. Performance note: IB verbs vs TCP-on-QSFP

By default our cluster scripts enable RDMA verbs (`NCCL_IB_HCA`, `NCCL_NET_GDR_LEVEL=5`) for max throughput. NVIDIA's official playbook only sets `NCCL_SOCKET_IFNAME` and routes NCCL over TCP on the same QSFP interface — slower in theory but more compatible across switch configurations. If you hit NCCL hangs during model load, the easy workaround is to fall back to the TCP path:

```bash
export NCCL_IB_DISABLE=1
./start_cluster.sh
```

**Performance warning:** putting traffic on a slow Ethernet interface instead of the 200Gb/s QSFP link will cost you 10-20x throughput.

#### Alternative: NVIDIA's bootstrap script

If you'd rather have NVIDIA's tooling do steps 3a–3e in one shot from a JSON config:

```bash
git clone https://github.com/NVIDIA/dgx-spark-playbooks
cd dgx-spark-playbooks/nvidia/multi-sparks-through-switch/assets/spark_cluster_setup
# edit config/spark_config_b2b.json with {ip_address, port, user, password} per Spark
bash spark_cluster_setup.sh -c config/spark_config_b2b.json --run-setup
```

Once that completes, return here at section 4 (Firewall) and continue.

### 4. Firewall Configuration

Ensure the following ports are open between Sparks:

- **30000** - SGLang HTTP API (head only)
- **50000** - Distributed init port for `--dist-init-addr` (head only). Override via `DIST_INIT_PORT` in `config.env`.

Workers don't need any of these ports open inbound — they connect *to* the head's dist-init port outbound. NCCL traffic between Sparks uses the QSFP fabric directly and is generally not behind a host firewall.

### 5. Hugging Face Authentication (for gated models)

Some models (Llama, Gemma, etc.) require Hugging Face authorization:

```bash
# Install the Hugging Face CLI (run on every Spark)
pip install huggingface_hub

# Login to Hugging Face (run on every Spark)
hf auth login
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

### 2. Choose Your Configuration

#### Option A: Single-Spark (Simplest)

For running on a single DGX Spark with one GPU:

```bash
# Set tensor parallelism and node count to 1 (single GPU, single Spark)
export TENSOR_PARALLEL=1
export NUM_NODES=1

# Choose a model that fits in ~120GB unified memory
export MODEL="openai/gpt-oss-120b"   # ~65GB in MXFP4
# or: export MODEL="meta-llama/Llama-3.1-8B-Instruct"

# Start the server
./start_cluster.sh
```

That's it! **No InfiniBand, SSH setup, or worker configuration needed.** The script automatically detects single-Spark mode when `WORKER_HOST` is empty and `NUM_NODES=1`. In single-Spark mode:

- InfiniBand detection and configuration is skipped
- NCCL uses on-chip communication (NVLink-C2C / PCIe)
- The setup is simpler and faster

#### Option B: 2-Spark Cluster (Direct QSFP Cable)

For running across two DGX Spark systems via a direct QSFP cable:

**Setup SSH (one-time):**
```bash
# On head Spark, generate key if needed:
ssh-keygen -t ed25519  # Press enter for defaults

# Copy to worker (replace with your worker's IP):
ssh-copy-id <username>@<worker-ip>

# Test connection:
ssh <username>@<worker-ip> "hostname"
```

**Configure Environment:**

```bash
# Option 1: Interactive setup (recommended)
source ./setup-env.sh

# Option 2: Edit config file
cp config.env config.local.env
vim config.local.env

# Two Sparks (head + 1 worker):
# WORKER_HOST="<worker1-ethernet-ip>"
# WORKER_IB_IP="<worker1-infiniband-ip>"
# WORKER_USER="<ssh-username>"
#
# 3+ Sparks (head + N workers; lists are space-separated, 1:1 positional):
# WORKER_HOST="<w1-eth> <w2-eth> <w3-eth>"
# WORKER_IB_IP="<w1-ib> <w2-ib> <w3-ib>"
# WORKER_USER="<ssh-username>"
# # TENSOR_PARALLEL and NUM_NODES default to 1 + N — override only if needed
```

**Start the Cluster:**
```bash
./start_cluster.sh
```

This will:
1. Pull the Docker image on the head node (workers pull theirs on first launch)
2. SSH to every worker and start its SGLang container
3. Start SGLang on the head with `--nnodes=1+N` and `--node-rank 0`
4. Wait for all `1 + N` Sparks to rendezvous via `--dist-init-addr` (~2-5 minutes for 2 Sparks; +60s budget per additional worker)

#### Option C: 3+ Spark Cluster (NVIDIA's switched-fabric topology)

Same as Option B, just longer lists in `WORKER_HOST` and `WORKER_IB_IP`. Example for a 4-Spark cluster:

```bash
export WORKER_HOST="192.168.7.111 192.168.7.112 192.168.7.113"
export WORKER_IB_IP="169.254.216.8 169.254.216.9 169.254.216.10"
export WORKER_USER="rispark"
# TENSOR_PARALLEL defaults to 4 (= 1 + 3 workers); override only if needed
./start_cluster.sh
```

The same `start_cluster.sh` handles 2 Sparks (direct QSFP cable) and 3+ Sparks (switched fabric); all you change is the length of the lists. **Verified end-to-end on 1 and 2 Sparks at the time of writing; a 4-Spark switched-fabric run is queued for the next test window — the n>2 code paths are mechanically loop-equivalent to the verified 2-Spark path.**

### 3. Verify the Cluster

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

### 4. Run Benchmarks

```bash
# Quick sanity test (10 prompts)
./benchmark_current.sh quick

# Throughput test
./benchmark_current.sh throughput

# Custom benchmark
./benchmark_current.sh -n 100 -i 512 -o 256
```

### 5. Stop the Cluster

```bash
./stop_cluster.sh
```

## Scripts Overview

| Script | Description |
|--------|-------------|
| `setup-env.sh` | Interactive environment setup (source this!). `--discover` wraps NVIDIA's mDNS Spark discovery for SSH key push. |
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
# │ Multi-Spark Settings (Optional - skip for single-Spark)         │
# └─────────────────────────────────────────────────────────────────┘
# Space-separated lists, 1:1 positional (head + N workers).
# 1 worker:  WORKER_HOST="192.168.7.111"
#            WORKER_IB_IP="169.254.216.8"
# 3 workers: WORKER_HOST="192.168.7.111 192.168.7.112 192.168.7.113"
#            WORKER_IB_IP="169.254.216.8 169.254.216.9 169.254.216.10"
WORKER_HOST="<eth-ip(s)>"          # Ethernet IP(s) for SSH (optional)
WORKER_IB_IP="<ib-ip(s)>"          # InfiniBand IP(s) for NCCL (optional)
WORKER_USER="<username>"           # SSH username for workers

# ┌─────────────────────────────────────────────────────────────────┐
# │ Model Settings                                                  │
# └─────────────────────────────────────────────────────────────────┘
MODEL="openai/gpt-oss-120b"        # Model to serve
TENSOR_PARALLEL=""                 # Total GPUs across cluster; defaults to 1+N
NUM_NODES=""                       # Total nodes; defaults to 1+N
MEM_FRACTION="0.90"                # Memory fraction for KV cache

# ┌─────────────────────────────────────────────────────────────────┐
# │ Multi-Node Workarounds (Important!)                             │
# └─────────────────────────────────────────────────────────────────┘
DISABLE_CUDA_GRAPH="true"          # Required when TP across nodes triggers
                                   # FlashInfer IPC-incompatible kernels.
                                   # Often unnecessary with --enable-dp-attention.
EXTRA_ARGS="--enable-dp-attention" # Bypasses FlashInfer AllReduce Fusion's CUDA
                                   # IPC across nodes. Multi-Spark presets in
                                   # switch_model.sh add this automatically.

# ┌─────────────────────────────────────────────────────────────────┐
# │ Optional                                                        │
# └─────────────────────────────────────────────────────────────────┘
HF_TOKEN="hf_xxx"                  # For gated models (Llama, etc.)
SGLANG_IMAGE="lmsysorg/sglang:v0.5.10.post1-cu130"  # Docker image
```

### Single-Spark vs Multi-Spark Mode Detection

The script automatically determines which mode to use:

| Condition | Mode | InfiniBand |
|-----------|------|------------|
| `WORKER_HOST` empty AND `NUM_NODES=1` | Single-Spark | Not required |
| `WORKER_HOST` set with N IPs | Multi-Spark | Required |
| `WORKER_HOST` empty BUT `NUM_NODES>1` | Error — pick one |

In **single-Spark mode** (no workers, `NUM_NODES=1`):
- `--head-only` is implicit
- InfiniBand detection still runs but failure is non-fatal
- No SSH or worker setup needed

In **multi-Spark mode**:
- InfiniBand interfaces are auto-detected via `ibdev2netdev`
- HEAD_IP is auto-detected from the InfiniBand interface
- NCCL is configured for RDMA communication
- Workers are started by SSH'ing to each `WORKER_HOST` and launching the SGLang container with `--node-rank N --dist-init-addr <head-ib-ip>:50000`

### Finding Worker InfiniBand IP

On each **worker node**, run:
```bash
# Find InfiniBand interface name
ibdev2netdev

# Example output: mlx5_0 port 1 ==> enp1s0f1np1 (Up)

# Get IP address for that interface
ip addr show enp1s0f1np1 | grep "inet "

# Example output: inet 169.254.x.x/16 ...
```

## Switching Models

Use `switch_model.sh` to easily switch between models:

```bash
# List available models
./switch_model.sh --list

# Interactive selection
./switch_model.sh

# Direct selection (by number)
./switch_model.sh 3  # Switch to a specific model

# Update config only (don't restart)
./switch_model.sh -s 5
```

The generated `config.local.env` block uses `${X:-default}` form so any environment variable you export still wins over the model preset. This lets you keep a saved model preset but override one knob (e.g. `EXTRA_ARGS=""`) for a quick experiment without rewriting the config.

## Supported Models

| # | Model | Size | Notes |
|---|-------|------|-------|
| 1 | `openai/gpt-oss-120b` | ~80GB+ | MoE, reasoning model (`--reasoning-parser gpt-oss`) |
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
| 12 | `microsoft/phi-4` | ~14-16GB | Small but smart, `--trust-remote-code` |
| 13 | `google/gemma-2-27b-it` | ~24-28GB | Strong mid-size (needs HF token) |

Run `./switch_model.sh` for the interactive menu (it groups by Single-Spark vs Multi-Spark and shows gating). Spark's 120GB unified memory is shared between CPU and GPU; quantized variants (FP8 / NVFP4 / MXFP4) typically give the best throughput at usable batch sizes.

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

**Symptom:** Container crashes with `CUDART error: invalid device context` on multi-Spark TP.

**Cause:** SGLang auto-enables FlashInfer AllReduce Fusion on Blackwell GPUs, but this uses CUDA IPC which doesn't work across nodes.

**Solution:** Ensure `EXTRA_ARGS` includes `--enable-dp-attention`:
```bash
# In config.env or config.local.env:
EXTRA_ARGS="--enable-dp-attention"
```

The multi-Spark presets in `switch_model.sh` add this automatically.

### SSH Connection Failed

```bash
# Test SSH connectivity
ssh <username>@<worker-ip> "hostname"

# If it fails, setup passwordless SSH:
ssh-copy-id <username>@<worker-ip>

# Or use NVIDIA's discovery wrapper:
./setup-env.sh --discover
```

### Cluster Not Becoming Ready

```bash
# Check head node logs
docker logs -f sglang-head

# Check worker logs (from head node)
ssh <username>@<worker-ip> "docker logs \$(docker ps --format '{{.Names}}' | grep ^sglang-worker-)"

# Look for "The server is fired up and ready to roll!"
```

### Low Throughput (Using Ethernet instead of InfiniBand)

```bash
# Check NCCL transport in head logs
docker logs sglang-head 2>&1 | grep -E "NCCL.*(NET|IB|Socket)"

# Good:  "NCCL INFO NET/IB" or "Connected via IBext"
# Bad:   "NCCL INFO NET/Socket" (falling back to Ethernet)
```

If you see Socket transport, double-check that `WORKER_IB_IP` points at the 169.254.x.x IB IPs (not the slower Ethernet IPs).

### NCCL Communication Issues

```bash
# Check InfiniBand devices
ibv_devinfo

# In logs, look for:
# NCCL INFO Using network IBext_v10
# NCCL INFO Connected all rings

# If IB issues, fall back to TCP-on-QSFP:
export NCCL_IB_DISABLE=1
./start_cluster.sh
```

### Out of Memory

```bash
# Reduce memory fraction
export MEM_FRACTION=0.80
./start_cluster.sh

# Or try a smaller model in single-Spark mode
export MODEL="openai/gpt-oss-20b"
export TENSOR_PARALLEL=1
export NUM_NODES=1
unset WORKER_HOST WORKER_IB_IP
./start_cluster.sh
```

### Unified-Memory Pressure (UMA buffer-cache flush)

DGX Spark uses a Unified Memory Architecture (UMA) where CPU and GPU share the same physical DRAM. Linux's page cache can hold onto memory that SGLang/CUDA can't reclaim, leading to apparent OOM well within capacity. NVIDIA recommends flushing the buffer cache when this happens:

```bash
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
```

Run this on every Spark before launching a large model if you've recently been working with big files.

### NCCL: IB Verbs vs TCP-on-QSFP

Our multi-Spark scripts enable RDMA verbs (`NCCL_IB_HCA`, `NCCL_NET_GDR_LEVEL=5`) for best throughput. NVIDIA's official Spark playbook only sets `NCCL_SOCKET_IFNAME` and routes NCCL over TCP on the same QSFP interface — slower in theory but more compatible.

If you hit NCCL hangs during model load on a multi-Spark setup, the fast workaround is to fall back to NVIDIA's TCP path:

```bash
export NCCL_IB_DISABLE=1
./start_cluster.sh
```

That forces NCCL to use sockets only and matches the official playbook exactly.

### PyTorch CUDA Capability Warning

**Symptom:** `Found GPU0 NVIDIA GB10 which is of cuda capability 12.1. Minimum and Maximum cuda capability supported by this version of PyTorch is (8.0) - (12.0)`

**Note:** This warning is benign. The `lmsysorg/sglang:v0.5.10.post1-cu130` image runs on Blackwell despite PyTorch reporting the capability as out-of-range. Inference works correctly.

### `stop_cluster.sh` hangs in non-tty pipelines

Older revisions used `read -p "Proceed?"` unconditionally, which silently aborted to "default-no" in piped pipelines. Fixed in the 2026-05-01 update — `stop_cluster.sh` now auto-confirms when stdin is not a tty. If you're on an older revision, pull latest or pass `-f`.

## Advanced Usage

### Start Head Only (Skip Workers)

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

### Pass Worker IPs on Command Line

```bash
./start_cluster.sh \
  --worker-host "192.168.7.111 192.168.7.112" \
  --worker-ib-ip "169.254.216.8 169.254.216.9"
```

### View Container Logs in Real-Time

```bash
# Head node
docker logs -f sglang-head

# Worker (from head via SSH)
ssh <worker-ip> 'docker logs -f $(docker ps --format "{{.Names}}" | grep ^sglang-worker-)'
```

## Performance Notes

### Expected Performance (GPT-OSS 120B on 2x DGX Spark)

| Metric | Value |
|--------|-------|
| Output Throughput | ~75 tok/s |
| Total Throughput | ~150 tok/s |
| Time to First Token | ~2.7s |
| Inter-Token Latency | ~58ms |

These were measured on the older `lmsysorg/sglang:spark` container; numbers should be re-measured against `v0.5.10.post1-cu130` once the 4-Spark test window completes.

### Optimization Tips

1. **TP scales with N** — `TENSOR_PARALLEL` defaults to `1 + WORKER_COUNT` (one GPU per Spark). Override only if you intentionally want to under-utilize GPUs.
2. **Memory Fraction** — Set to 0.90 for max KV cache, reduce if OOM
3. **InfiniBand** — Ensure `WORKER_IB_IP` points at the 169.254.x.x InfiniBand addresses (not the slower Ethernet IPs). Verify via:
   ```bash
   docker logs sglang-head 2>&1 | grep -i "NCCL.*network"
   ```
4. **Model Cache** — Pre-download models to `/raid/hf-cache` to avoid download delays on first launch
5. **Quantized variants** — On Spark, NVFP4 / FP8 / MXFP4 generally beat BF16 at usable batch sizes since they free more unified memory for the KV cache

## Verified Configurations

| Sparks | TP | Model | Container | Status |
|---|---|---|---|---|
| 1 | 1 | `meta-llama/Llama-3.1-8B-Instruct` | `v0.5.10.post1-cu130` | ✅ Verified (2026-05-01) |
| 2 | 2 | `meta-llama/Llama-3.1-8B-Instruct` | `v0.5.10.post1-cu130` | ✅ Verified (2026-05-01) |
| 2 | 2 | `openai/gpt-oss-120b` | `lmsysorg/sglang:spark` | ✅ Verified (older container) |
| 4 | 4 | TBD | `v0.5.10.post1-cu130` | ⏳ Queued for next test window |

## File Structure

```
sglang-dgx-spark/
├── README.md              # This file
├── config.env             # Configuration template
├── config.local.env       # Your local config (gitignored)
├── setup-env.sh           # Interactive setup script (--discover wraps NVIDIA mDNS)
├── start_cluster.sh       # Main cluster startup script (1-to-N Sparks)
├── stop_cluster.sh        # Cluster shutdown script
├── switch_model.sh        # Model switching utility
├── benchmark_current.sh   # Single model benchmark tool
├── benchmark_all.sh       # Multi-model comparison benchmark
└── benchmark_results/     # Benchmark output directory
```

## References

- [SGLang Documentation](https://docs.sglang.io/)
- [SGLang Multi-Node Deployment](https://docs.sglang.io/references/multi_node_deployment/multi_node_index.html)
- [SGLang Container Tags on Docker Hub](https://hub.docker.com/r/lmsysorg/sglang/tags)
- [NVIDIA DGX Spark SGLang Playbook](https://build.nvidia.com/spark/sglang)
- [NVIDIA DGX Spark Multi-Sparks Playbook](https://build.nvidia.com/spark/multi-sparks-through-switch/multi-sparks)
- [NVIDIA dgx-spark-playbooks repo](https://github.com/NVIDIA/dgx-spark-playbooks) (source of the `discover-sparks` helper used by `--discover`)
- [SGLang on DGX Spark Forum](https://forums.developer.nvidia.com/t/run-sglang-in-spark/348863)
- [GPT-OSS Announcement](https://lmsys.org/blog/2025-11-03-gpt-oss-on-nvidia-dgx-spark/)
- [SGLang GitHub](https://github.com/sgl-project/sglang)

## Acknowledgments

Container build approach inspired by [Eugene R (@eugr)](https://github.com/eugr)'s work on [spark-vllm-docker](https://github.com/eugr/spark-vllm-docker).

## License

MIT
