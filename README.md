# SGLang on NVIDIA DGX Spark Multi-Node Setup

This repository provides configuration files, scripts, and documentation for running [SGLang](https://github.com/sgl-project/sglang) inference server on two NVIDIA DGX Spark systems in a distributed multi-node setup.

## Overview

SGLang is a fast serving framework for large language models and vision language models. When combined with NVIDIA DGX Spark's Blackwell GPUs and 128GB unified memory, you can run large language models with high throughput across multiple nodes.

This setup enables:
- **Tensor Parallelism** across two DGX Spark nodes
- **High-bandwidth GPU-to-GPU communication** via QSFP cable
- **Distributed LLM inference** for large models like DeepSeek, Llama 3, and more

## Prerequisites

### Hardware Requirements
- 2x NVIDIA DGX Spark systems
- 1x QSFP cable (compatible with DGX Spark multi-node ports)
- Network connectivity between nodes

### Software Requirements
- Ubuntu 24.04 or later
- NVIDIA GPU drivers (pre-installed on DGX Spark)
- Docker Engine 20.x or later
- NVIDIA Container Toolkit
- Passwordless SSH between nodes (for distributed operations)

## Quick Start

### 1. Network Setup (QSFP Connection)

Connect the two DGX Spark systems using a QSFP cable, then configure the network:

```bash
# Run the network setup script on both nodes
./scripts/setup-network.sh
```

Or configure manually:

**Node 1:**
```bash
sudo ip addr add 192.168.100.10/24 dev enp1s0f1np1
sudo ip link set enp1s0f1np1 up
```

**Node 2:**
```bash
sudo ip addr add 192.168.100.11/24 dev enp1s0f1np1
sudo ip link set enp1s0f1np1 up
```

Verify connectivity:
```bash
ping -c 3 192.168.100.11  # from Node 1
ping -c 3 192.168.100.10  # from Node 2
```

### 2. SSH Setup

Enable passwordless SSH between nodes:

```bash
# Run on both nodes
./scripts/setup-ssh.sh
```

### 3. Docker Setup

Ensure Docker is configured with NVIDIA runtime:

```bash
# Verify Docker and NVIDIA setup
./scripts/verify-setup.sh
```

### 4. Start SGLang

**Using Docker Compose:**

```bash
cd docker
docker compose up -d
```

**Verify the deployment:**
```bash
curl http://localhost:30000/health
```

## Configuration Files

### Docker Compose (`docker/compose.yml`)

The main Docker Compose configuration for running SGLang on two nodes with tensor parallelism.

Key environment variables:
- `HF_TOKEN`: Your Hugging Face access token
- `MODEL_PATH`: Path to the model (e.g., `meta-llama/Llama-3.1-8B-Instruct`)
- `SGLANG_TP`: Tensor parallelism size (default: 2 for two nodes)

### Kubernetes Deployment (`k8s/`)

For production deployments, Kubernetes configurations are provided:
- `k8s/sglang-distributed-sts.yaml`: StatefulSet for distributed SGLang deployment

## Environment Variables

Create a `.env` file in the `docker/` directory with the following variables:

```bash
HF_TOKEN=your_huggingface_token_here
MODEL_PATH=meta-llama/Llama-3.1-8B-Instruct
```

## Directory Structure

```
.
├── README.md                 # This file
├── docker/
│   ├── compose.yml          # Docker Compose configuration
│   ├── .env.example         # Example environment variables
│   └── daemon.json          # Docker daemon configuration
├── scripts/
│   ├── setup-network.sh     # Network configuration script
│   ├── setup-ssh.sh         # SSH key setup script
│   └── verify-setup.sh      # Verification script
├── k8s/
│   └── sglang-distributed-sts.yaml  # Kubernetes StatefulSet
└── docs/
    └── ADVANCED.md          # Advanced configuration guide
```

## API Usage

Once SGLang is running, you can interact with it using the OpenAI-compatible API:

```bash
curl http://localhost:30000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.1-8B-Instruct",
    "messages": [
      {"role": "user", "content": "Hello, how are you?"}
    ]
  }'
```

## Troubleshooting

### Common Issues

1. **Network connectivity issues**
   - Verify QSFP cable is properly connected
   - Check interface status: `ip link show`
   - Ensure correct IP addresses are assigned

2. **Docker GPU access issues**
   - Verify NVIDIA runtime: `docker run --rm nvidia/cuda:12.0-base nvidia-smi`
   - Check `/etc/docker/daemon.json` configuration

3. **Model loading failures**
   - Ensure sufficient GPU memory
   - Verify HuggingFace token is valid
   - Check model path is correct

### Logs

View container logs:
```bash
docker compose logs -f sglang-node1
docker compose logs -f sglang-node2
```

## References

- [SGLang Documentation](https://docs.sglang.io/)
- [NVIDIA DGX Spark User Guide](https://docs.nvidia.com/dgx/dgx-spark/)
- [DGX Spark Playbooks](https://github.com/NVIDIA/dgx-spark-playbooks)
- [Connect Two Sparks Guide](https://build.nvidia.com/spark/connect-two-sparks/)

## License

This project is provided as-is for educational and reference purposes. Please refer to the respective licenses of SGLang and NVIDIA software for usage terms