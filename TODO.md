# Project TODO

## Application TODO

No required application work remains before the Docker migration. The Gradio
UI, remote inference, automatic local fallback, progress feedback, error
reporting, and optional user-provided Hugging Face token flow are implemented.

## Completed legacy LXD recovery work

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
- [x] Correct the course port boundary: Gradio and the watchdog use internal
  port 7860, while the infrastructure exposes that service on host port 8015.
  Pass one `APP_PORT` value to both setup and the remote health probe.
- [x] Make wipe recovery tolerate the disposable LXC's regenerated SSH host
  key by using the documented lab-only `StrictHostKeyChecking=no` default.
- [x] Restrict clean-rebuild deletion to the canonical
  `$HOME/OverSmart-Math-Solver` path and reject home, traversal, and symlink
  targets before `rm -rf`.
- [x] Create watcher credentials under `umask 077` and transmit the generated
  account password through SSH standard input instead of process arguments.
- [x] Remove unnecessary `trust_remote_code=True` model loading and make the
  remote-inference tests runnable with the Python standard library.

## Docker / Deployment TODO

These tasks concern packaging, ingress, runtime health, secrets, monitoring, or
retiring the legacy LXD recovery path. They are not application feature work.

### Performance

- [ ] Optimize cold recovery further. Dependency installation remains the main
  bottleneck. Use Docker image layers or a prebuilt image instead of installing
  the environment during each recovery.

### Security review follow-up

The review was assessed against the current simplified scripts on October 3,
2026. Line numbers in the review may be stale, but the issues below remain
applicable unless explicitly qualified.

#### P0 — high severity

- [ ] **Deploy only reviewed, immutable artifacts.** Stop executing arbitrary
  changes from mutable `main`. Require an approved commit or verified signed
  tag; pin Python dependencies with hashes; pin the Hugging Face model revision;
  and prefer `safetensors`. Recovery must reject an unapproved revision instead
  of automatically executing it.
- [ ] **Configure secure public ingress and inference controls.** Publish only
  an HTTPS ngrok endpoint, keep Traffic Inspector Full Capture disabled,
  document fine-grained Hugging Face tokens, and rate-limit or otherwise
  control expensive inference. Decide separately whether the public product
  requires access authentication; manual token entry may remain.

#### P1 — recovery correctness and containment

- [ ] **Verify process identity, not only a numeric PID.** Record the app start
  time and expected command/revision, confirm them before signaling, use a
  bounded TERM-then-KILL sequence, and fail deployment if the old process still
  owns internal port 7860. A deployment is successful only when the newly
  launched PID is alive and its readiness response reports the expected
  revision/model.
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

#### P2 — health, configuration, logging, and tests

- [ ] **Separate liveness from readiness.** Keep a cheap liveness endpoint, add
  readiness data for loaded model/revision, and impose a maximum `busy` duration
  so a wedged but live PID cannot suppress recovery forever. Use a low-frequency
  synthetic inference check for end-to-end confidence.
- [ ] **Finish shared deployment configuration.** `APP_PORT` is shared by setup
  and the watcher; remove the remaining hardcoded app-path and branch
  assumptions if the legacy SSH deployment remains after container migration.
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
