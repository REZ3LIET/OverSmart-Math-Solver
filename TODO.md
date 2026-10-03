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
- [x] Add a lightweight `/healthz` endpoint and log total recovery duration.
- [x] Benchmark cold download versus full-cache restore. Fresh download took
  341.0 seconds; SCP plus extraction took 606.2 seconds. The slower cache path
  and its auxiliary scripts were removed from the final recovery design.
- [x] Track CPU, system memory, GPU utilization, and GPU memory in the combined
  watcher probe. Persist samples to `logs/resource_usage.csv` and emit
  rate-limited warnings when configured thresholds are exceeded.
- [x] Confirm successful local-model generation. The remote log contains
  completed generated responses from the configured model.
- [x] Add Gradio model-readiness and request-stage progress feedback.
- [x] Add rate-limited Discord webhook alerts for resource thresholds and
  repeated recovery failures without logging the webhook URL.
- [x] Add event-driven Discord notifications for repository deployments,
  SSH/server outages and restoration, failed remote state, and application
  health loss and restoration without adding monitoring probes.
- [x] Replace the CUDA-oriented dependency path with CPU-only PyTorch, remove
  `bitsandbytes`/CUDA runtime packages, and select the smaller
  `Qwen/Qwen2.5-0.5B-Instruct` model with a 128-token default.
- [x] Deploy and benchmark the 0.5B CPU model: 9.84 seconds, 13.01 tokens/s,
  and 1508.30 MB peak process memory in the recorded run.
- [x] Add a threshold-driven adaptive UI response. The watcher publishes a
  capacity flag only when threshold state changes; Gradio checks it every two
  seconds, displays a near-capacity warning, and clears it when resources return
  below all configured thresholds.

## Partially completed

- [ ] Optimize cold recovery further. Dependency installation remains the main
  bottleneck. Investigate a smaller dependency set or host-level prebuilt image.

## Security review follow-up

The review was assessed against the current simplified scripts on October 3,
2026. Line numbers in the review may be stale, but the issues below remain
applicable unless explicitly qualified.

### P0 — high severity

- [ ] **Deploy only reviewed, immutable artifacts.** Stop executing arbitrary
  changes from mutable `main`. Require an approved commit or verified signed
  tag; pin Python dependencies with hashes; pin the Hugging Face model revision;
  prefer `safetensors`; and remove `trust_remote_code=True` unless a reviewed,
  pinned model demonstrably requires it. Recovery must reject an unapproved
  revision instead of automatically executing it.
- [ ] **Make clean-rebuild deletion traversal-safe.** Resolve `$HOME` and
  `APP_DIR` with `realpath -m`, reject symlinks and `..` traversal, and allow
  recursive deletion only when the canonical path exactly matches the approved
  application directory. Add tests for `$HOME`, `/`, `$HOME/../...`, symlinked
  paths, and the valid deployment path.
- [ ] **Keep the generated account password out of process arguments.** Set
  `umask 077` before creating any credential, transmit a required password over
  standard input or a protected descriptor, and never place it in an SSH command
  argument. If assignment policy permits key-only access, remove password
  management and disable SSH password authentication instead.
- [ ] **Add a network/authentication boundary for standalone Gradio.** Since
  access already uses SSH forwarding, prefer binding the application to
  `127.0.0.1`; otherwise place it behind an authenticated TLS reverse proxy and
  firewall. Do not accept personal Hugging Face tokens over unauthenticated
  plaintext HTTP, and rate-limit or otherwise control expensive inference.
- [ ] **Evaluation tooling, separate/out of deployment scope:** replace the
  eval-backed SymPy parsing of model output with a strict token/AST allowlist or
  run it in a disposable unprivileged, network-isolated sandbox. Do not execute
  untrusted model text in the deployment account. This item does not block the
  requested `app.py` deployment work but remains a repository security issue.

### P1 — recovery correctness and containment

- [ ] **Verify process identity, not only a numeric PID.** Record the app start
  time and expected command/revision, confirm them before signaling, use a
  bounded TERM-then-KILL sequence, and fail deployment if the old process still
  owns port 8015. A deployment is successful only when the newly launched PID
  is alive and its readiness response reports the expected revision/model.
- [ ] **Make deployment atomic with rollback.** Build each revision and virtual
  environment in a versioned release directory, test it on a temporary port,
  atomically switch a `current` symlink, and retain at least one known-good
  release. Failed Git, dependency, model, or startup stages must leave the
  previous application runnable.
- [ ] **Bound every recovery stage.** Add explicit deadlines for apt, Git, pip,
  model download, and the complete streamed recovery command; configure SSH
  keepalives/dead-peer detection; cancel and clean up after a maximum recovery
  duration; and expose the timed-out stage in status/Discord messages.
- [ ] **Prevent concurrent mutation and supervise services.** Add a local
  per-target watcher lock and a remote deployment lock. Run the watcher and app
  under an approved supervisor (preferably hardened `systemd` units) with
  restart policy, resource limits, dedicated identities where feasible, and
  bounded journal retention.
- [ ] **Harden SSH key verification and retirement.** Add
  `IdentitiesOnly=yes`; identify managed authorized keys by a unique marker or
  fingerprint so entries with options are also retired; retry failed access
  updates with bounded backoff instead of clearing the retry flag; regenerate
  cloned server host keys; and provision expected host fingerprints out of band
  where infrastructure permits. Document any unavoidable `accept-new`/`no`
  trust tradeoff.
- [ ] **Recover secrets securely.** Supply application secrets after rebuild
  without committing them, placing them in command arguments, or printing them
  in logs. Define rotation and recovery procedures for the bootstrap key,
  account password (if retained), Hugging Face token, and Discord webhook.

### P2 — health, configuration, logging, and tests

- [ ] **Separate liveness from readiness.** Keep a cheap liveness endpoint, add
  readiness data for loaded model/revision, and impose a maximum `busy` duration
  so a wedged but live PID cannot suppress recovery forever. Use a low-frequency
  synthetic inference check for end-to-end confidence.
- [ ] **Use one shared deployment configuration.** Remove hardcoded app path,
  port, and branch assumptions from the watcher probe, or pass the same
  `APP_DIR`, `APP_PORT`, and `REPO_BRANCH` values used by setup. Add a test with
  non-default values.
- [ ] **Separate commands from observed status.** Replace the overloaded
  `build-repo` value with an atomically written command/request file and keep
  build progress in a distinct status file. A watcher restart during
  `build-repo` progress must not trigger a second destructive rebuild.
- [ ] **Bound resource and application logs.** Add rotation/retention for the
  two-second resource CSV and `.runtime/app.log`, handle write failures, and
  notify once when monitoring data can no longer be persisted.
- [ ] **Make the scheduled audit truly one-shot.** Preserve the current stale
  schedule and authorized-window guards, remove the marked cron entry after its
  intended execution, and document that `StrictHostKeyChecking=no` means the
  audit proves key acceptance but not host identity. Remove any already
  installed entry marked `# osms-red-team-2026-09-29` when no longer needed.
- [ ] **Strengthen recovery security tests.** Make the SSH fake validate key
  installation/retirement commands instead of accepting every non-probe call.
  Add cases for failed key update/retry, host-key change, stale/reused PID,
  traversal and symlink deletion attempts, command timeouts, two concurrent
  watchers, failed release rollback, maximum busy duration, and log rotation.
- [ ] **Harden the basic overload response.** The required near-capacity banner
  is implemented. Add sustained-sample hysteresis and, if stronger protection
  is needed, reduce token limits/concurrency or queue/reject new work so the
  state cannot flap around 80%.
