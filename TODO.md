# Recovery TODO

## Completed

- [x] Use shallow Git clone/fetch during recovery.
- [x] Reuse the virtual environment and install dependencies only when
  `requirements.txt` changes.
- [x] Download the local model during recovery and preload it in the Gradio
  process before the deployment reports healthy.
- [x] Track the commit that successfully started and restart the app when a new
  commit is pushed.
- [x] Treat a live but temporarily unresponsive inference process as `busy`
  instead of immediately destroying it.
- [x] Use PID-file/`nohup` supervision for the current limited-permission test.
- [x] Confirm the original 3B local model downloaded and generated successfully;
  its measured baseline was 0.26 tokens/s and 3904 MB peak process memory.
- [x] Add an external deployment-cache archive containing `.venv` and the local
  model, with checksum-based SCP and restore on a fresh LXC.
- [x] Add a lightweight `/healthz` endpoint and log total recovery duration.
- [x] Benchmark cold download versus full-cache restore. Fresh download took
  341.0 seconds; SCP plus extraction took 606.2 seconds, so full-cache restore
  is retained as an optional reliability feature and disabled by default.
- [x] Track CPU, system memory, GPU utilization, and GPU memory in the combined
  watcher probe. Persist samples to `logs/resource_usage.csv` and emit
  rate-limited warnings when configured thresholds are exceeded.
- [x] Confirm successful local-model generation. The remote log contains
  completed generated responses from the configured model.
- [x] Add Gradio model-readiness and request-stage progress feedback.
- [x] Add rate-limited Discord webhook alerts for resource thresholds and
  repeated recovery failures without logging the webhook URL.
- [x] Replace the CUDA-oriented dependency path with CPU-only PyTorch, remove
  `bitsandbytes`/CUDA runtime packages, and select the smaller
  `Qwen/Qwen2.5-0.5B-Instruct` model with a 128-token default.

## Partially completed

- [ ] Optimize cold recovery further. The external archive now avoids dependency
  and model downloads, but is slower on this LXC. Investigate a smaller
  dependency set, a host-level prebuilt image, or an archive that can be used
  without extracting 7.7 GB.
- [ ] Deploy and benchmark the new 0.5B CPU configuration against the measured
  3B baseline (116.79 seconds, 0.26 tokens/s, and 3904 MB peak memory).

## Open

- [ ] Regenerate SSH host keys if cloned machines share the same host keys.
- [ ] Safely update the external watcher's `known_hosts` entry after an LXC gets
  a new SSH host key.
- [ ] Supply application secrets during recovery without committing them or
  printing them in logs.
- [ ] Add an overload reaction policy: switch to a smaller model, reduce token
  limits/concurrency, queue or reject new work, and show a near-capacity message
  in the UI. Add hysteresis so behavior does not flap around 80%.
