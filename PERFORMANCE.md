# Performance findings

## Current LXC limits

- No NVIDIA GPU is exposed: `nvidia-smi` is unavailable and
  `torch.cuda.is_available()` is `False`.
- The container is pinned to two CPU cores (`27` and `30`), even though the host
  reports a 32-thread AMD Ryzen Threadripper PRO 5955WX.
- The cgroup memory limit is 4 GiB, with 2 GiB swap configured.
- The local model contains approximately 2 GB of weights and defaults to as many
  as 512 generated tokens per request.
- The installed PyTorch build is `2.14.0+cu130`, so the environment includes
  CUDA-oriented packages despite having no usable GPU. The virtual environment
  is approximately 5.8 GB.

## Why local inference is slow

The configured 3-billion-parameter model runs entirely on two CPU cores. The
first request must also load its weights into a memory-constrained process.
Generation is sequential, so asking for up to 512 new tokens magnifies CPU
latency. The application log confirms that local requests eventually generated
responses; this is resource-bound execution rather than a missing model.

The large CUDA-enabled Python environment also explains slow cold deployment:
an uncached dependency installation took 301.5 seconds even though the LXC
cannot use CUDA.

## Highest-impact next experiments

1. Install a CPU-only PyTorch build and remove GPU-only dependencies from the
   standalone deployment requirements.
2. Use a smaller CPU-oriented model, preferably around 0.5B–1.5B parameters.
3. Reduce the default `max_new_tokens` from 512 to 128 or lower.
4. Limit concurrent local generations to one and queue additional requests.
5. Prefer authenticated remote inference when low response latency matters.
