# Recovery TODO

## Completed

- [x] Use shallow Git clone/fetch during recovery.
- [x] Reuse the virtual environment and install dependencies only when
  `requirements.txt` changes.
- [x] Lazy-load the local model instead of blocking Gradio startup.
- [x] Track the commit that successfully started and restart the app when a new
  commit is pushed.
- [x] Treat a live but temporarily unresponsive inference process as `busy`
  instead of immediately destroying it.
- [x] Use PID-file/`nohup` supervision for the current limited-permission test.
- [x] Confirm the configured local model is downloaded completely. It currently
  occupies about 2 GB at
  `~/.cache/huggingface/hub/models--unsloth--Qwen2.5-Coder-3B-Instruct-bnb-4bit`.
- [x] Add an external deployment-cache archive containing `.venv` and the local
  model, with checksum-based SCP and restore on a fresh LXC.
- [x] Add a lightweight `/healthz` endpoint and log total recovery duration.
- [x] Benchmark cold download versus full-cache restore. Fresh download took
  341.0 seconds; SCP plus extraction took 606.2 seconds, so full-cache restore
  is retained as an optional reliability feature and disabled by default.

## Partially completed

- [ ] Optimize cold recovery further. The external archive now avoids dependency
  and model downloads, but is slower on this LXC. Investigate a smaller
  dependency set, a host-level prebuilt image, or an archive that can be used
  without extracting 7.7 GB.
- [ ] Finish validating local inference. The model snapshot and 2 GB weights are
  present with no incomplete files, but a successful local generation has not
  yet been confirmed. Add clear UI/status feedback while it downloads or loads.

## Open

- [ ] Regenerate SSH host keys if cloned machines share the same host keys.
- [ ] Safely update the external watcher's `known_hosts` entry after an LXC gets
  a new SSH host key.
- [ ] Supply application secrets during recovery without committing them or
  printing them in logs.
- [ ] Add notifications for recovery attempts that continue to fail.
