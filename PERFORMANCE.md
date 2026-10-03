# Performance findings

## Original 3B baseline

- No NVIDIA GPU is exposed: `nvidia-smi` is unavailable and
  `torch.cuda.is_available()` is `False`.
- The container is pinned to two CPU cores (`27` and `30`), even though the host
  reports a 32-thread AMD Ryzen Threadripper PRO 5955WX.
- The cgroup memory limit is 4 GiB, with 2 GiB swap configured.
- The original local model contained approximately 2 GB of quantized weights
  and defaulted to as many as 512 generated tokens per request.
- The installed PyTorch build is `2.14.0+cu130`, so the environment includes
  CUDA-oriented packages despite having no usable GPU. The virtual environment
  is approximately 5.8 GB.

## Why local inference is slow

The original 3-billion-parameter model ran entirely on two CPU cores. The
first request must also load its weights into a memory-constrained process.
Generation is sequential, so asking for up to 512 new tokens magnifies CPU
latency. The application log confirms that local requests eventually generated
responses; this is resource-bound execution rather than a missing model.

The large CUDA-enabled Python environment also explained slow cold deployment:
an uncached dependency installation took 301.5 seconds even though the LXC
cannot use CUDA.

One measured request took 116.79 seconds for 30 generated tokens (0.26
tokens/second), used 97.8% CPU, and peaked at 3903.96 MB process memory.

## Implemented CPU configuration

- Default model: `Qwen/Qwen2.5-0.5B-Instruct`.
- Default maximum generation: 128 tokens.
- CPU-only PyTorch from the official PyTorch CPU wheel index.
- No `bitsandbytes`, NVIDIA runtime packages, or Triton in the deployment
  environment.
- Model download and preload occur during recovery.

## Measured CPU configuration

The deployed 0.5B model generated 128 tokens in 9.84 seconds at 13.01 tokens/s
and peaked at 1508.30 MB process memory. Compared with the recorded 3B run, this
was about 11.9 times faster by response time, about 50 times faster by token
throughput, and used about 61% less peak process memory.

The full-cache deployment experiment was removed from the final scripts because
its 606.2-second transfer/extraction path was slower than the 341.0-second fresh
path. Further cold-start work should target the dependency set or a host-level
image rather than transferring the complete virtual environment.
