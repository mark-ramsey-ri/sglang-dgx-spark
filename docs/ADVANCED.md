# Advanced Configuration Guide

This document provides advanced configuration options for running SGLang on NVIDIA DGX Spark in a multi-node setup.

## Table of Contents

- [Model Selection](#model-selection)
- [Performance Tuning](#performance-tuning)
- [NCCL Configuration](#nccl-configuration)
- [Memory Management](#memory-management)
- [Scaling to More Nodes](#scaling-to-more-nodes)
- [Kubernetes Deployment](#kubernetes-deployment)
- [Monitoring and Observability](#monitoring-and-observability)

## Model Selection

### Recommended Models for DGX Spark

| Model | Parameters | Memory Required | Recommended TP |
|-------|------------|-----------------|----------------|
| Llama 3.1 8B | 8B | ~16GB | 1 |
| Llama 3.1 70B | 70B | ~140GB | 2 |
| DeepSeek-V3 | 685B | ~1TB+ | 8+ |
| Mistral 7B | 7B | ~14GB | 1 |
| Qwen 72B | 72B | ~144GB | 2 |

### Loading Custom Models

To use a custom or fine-tuned model:

```bash
# Set the model path in your .env file
MODEL_PATH=/path/to/your/model

# Or use a Hugging Face model
MODEL_PATH=your-username/your-model
```

For gated models, ensure your `HF_TOKEN` has access permissions.

## Performance Tuning

### SGLang Server Options

Key command-line arguments for performance optimization:

```bash
python3 -m sglang.launch_server \
  --model-path $MODEL_PATH \
  --host 0.0.0.0 \
  --port 30000 \
  --tp 2 \                              # Tensor parallelism
  --trust-remote-code \                 # Required for some models
  --attention-backend flashinfer \      # Optimized attention
  --mem-fraction-static 0.75 \          # GPU memory allocation
  --max-total-tokens 32768 \            # Maximum context length
  --schedule-heuristic lpm \            # Scheduling algorithm
  --chunked-prefill-size 8192           # Chunked prefill for long contexts
```

### Memory Fraction Configuration

The `--mem-fraction-static` parameter controls GPU memory allocation:

- `0.75` (default): Good balance for most use cases
- `0.85`: More aggressive, higher throughput, risk of OOM
- `0.65`: Conservative, lower throughput, safer for variable loads

### Request Batching

SGLang automatically batches requests. You can tune batching behavior:

```bash
--max-running-requests 128 \     # Maximum concurrent requests
--max-num-reqs 256               # Maximum queued requests
```

## NCCL Configuration

### Environment Variables

For optimal multi-node communication:

```bash
# Network interface for NCCL
export NCCL_SOCKET_IFNAME=enp1s0f1np1

# Debug level (set to INFO for troubleshooting)
export NCCL_DEBUG=INFO

# InfiniBand settings
export NCCL_IB_DISABLE=0
export NCCL_IB_GID_INDEX=3

# Tree-based algorithms (better for small messages)
export NCCL_TREE_THRESHOLD=0

# Ring-based algorithms (better for large messages)
# export NCCL_RING_THRESHOLD=0
```

### Bandwidth Testing

Test NCCL bandwidth between nodes:

```bash
# Run all-reduce benchmark
docker run --rm --gpus all \
  --net=host \
  -e NCCL_SOCKET_IFNAME=enp1s0f1np1 \
  nvcr.io/nvidia/pytorch:24.01-py3 \
  python -c "
import torch
import torch.distributed as dist
dist.init_process_group(backend='nccl')
# Run benchmark...
"
```

## Memory Management

### Unified Memory on DGX Spark

DGX Spark features 128GB unified CPU-GPU memory. To leverage this:

```bash
# Enable unified memory
export CUDA_MANAGED_MEMORY=1

# Set memory pool size
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
```

### KV Cache Optimization

For long context models, optimize KV cache:

```bash
--kv-cache-dtype fp8    # Use FP8 for KV cache (saves memory)
--context-length 32768  # Maximum context length
```

## Scaling to More Nodes

### Beyond Two Nodes

For more than two nodes, use an Ethernet switch:

```
[DGX Spark 1] ----+
                  |
[DGX Spark 2] ----+---- [Ethernet Switch]
                  |
[DGX Spark 3] ----+
                  |
[DGX Spark N] ----+
```

Update Docker Compose for additional nodes:

```yaml
services:
  sglang-node3:
    # ... similar to node1/node2
    environment:
      NODE_RANK: "2"
      WORLD_SIZE: "4"
```

### World Size Configuration

```bash
# For 4 nodes with TP=4
WORLD_SIZE=4
SGLANG_TP=4
```

## Kubernetes Deployment

### Prerequisites

1. Kubernetes cluster with GPU support
2. NVIDIA Device Plugin installed
3. Network policies allowing inter-pod communication

### Deploying to Kubernetes

```bash
# Apply the StatefulSet
kubectl apply -f k8s/sglang-distributed-sts.yaml

# Check pod status
kubectl get pods -n sglang

# View logs
kubectl logs -f sglang-0 -n sglang
```

### Scaling the StatefulSet

```bash
# Scale to 4 replicas
kubectl scale statefulset sglang --replicas=4 -n sglang
```

### Using GPUDirect RDMA in Kubernetes

For optimal performance with GPUDirect:

```yaml
spec:
  containers:
    - name: sglang
      resources:
        limits:
          nvidia.com/gpu: 1
          rdma/hca_shared_devices_a: 1  # RDMA device
```

## Monitoring and Observability

### Prometheus Metrics

SGLang exposes Prometheus metrics at `/metrics`:

```bash
curl http://localhost:30000/metrics
```

Key metrics to monitor:
- `sglang_request_latency_seconds`
- `sglang_tokens_generated_total`
- `sglang_running_requests`
- `sglang_gpu_memory_usage_bytes`

### Grafana Dashboard

Create a custom Grafana dashboard with panels for SGLang metrics, or use the example panel configuration below:

```json
{
  "panels": [
    {
      "title": "Request Latency",
      "type": "graph",
      "targets": [
        {
          "expr": "histogram_quantile(0.99, sglang_request_latency_seconds_bucket)"
        }
      ]
    }
  ]
}
```

### Health Checks

```bash
# Check server health
curl http://localhost:30000/health

# Get server info
curl http://localhost:30000/get_model_info
```

### Logging

Configure logging verbosity:

```bash
# In Docker Compose or command line
--log-level info     # Options: debug, info, warning, error
```

## Security Considerations

### Network Security

1. Use private networks for inter-node communication
2. Configure firewall rules to restrict access
3. Use TLS for external API endpoints

### API Authentication

```bash
# Enable API key authentication
--api-key your-secure-api-key
```

### Container Security

Run containers with minimal privileges:

```yaml
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
    add:
      - NET_BIND_SERVICE
```

## Troubleshooting

### Common Issues

1. **NCCL Timeout**: Increase timeout with `NCCL_TIMEOUT=1800`
2. **OOM Errors**: Reduce `--mem-fraction-static`
3. **Slow Inference**: Check NCCL debug logs for network issues

### Debug Commands

```bash
# Check GPU status
nvidia-smi

# Check NCCL connectivity
NCCL_DEBUG=INFO python -c "import torch.distributed as dist; ..."

# Check container logs
docker compose logs -f sglang-node1
```

## References

- [SGLang GitHub](https://github.com/sgl-project/sglang)
- [SGLang Documentation](https://docs.sglang.io/)
- [NVIDIA DGX Spark User Guide](https://docs.nvidia.com/dgx/dgx-spark/)
- [NCCL Documentation](https://docs.nvidia.com/deeplearning/nccl/)
