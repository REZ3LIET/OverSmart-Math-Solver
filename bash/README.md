# External recovery watcher

Only three runtime scripts are required:

- `external_watcher.sh` runs continuously on the external WPI machine.
- `update_ssh_key.sh` installs and verifies the stable watcher key.
- `setup.sh` runs inside the LXC to deploy or recover the application.

The previous cache benchmark/build scripts and setup backup were removed. The
cache benchmark showed that a fresh deployment took 341.0 seconds while
transferring and extracting the 7.7 GB archive took 606.2 seconds. Removing
those paths does not change the active recovery behavior.

Two separate support scripts preserve the authorized red-team procedure for
documentation and reproducibility. They are not part of application recovery:

- `audit_bootstrap_key.sh` enforces the fixed authorized time window.
- `schedule_red_team_audit.sh` installs the original one-time-effective job and
  now refuses to install it after the 2026 schedule time.

## Configure and run

Copy `.env.example` to `.env` and set at least:

```text
WATCH_TARGET=student-admin@host
SSH_PORT=22015
BOOTSTRAP_SSH_IDENTITY_FILE=/absolute/path/to/student-admin_key
CREDENTIALS_DIR=~/.ssh/osms-recovery
```

Then run the watcher from the repository root:

```bash
./bash/external_watcher.sh
```

The watcher loads `.env` automatically. It resolves repository-relative key and
script paths, so the launch command does not need identity variables.

## Recovery flow

1. Retry SSH until the LXC is reachable.
2. Try the generated stable key first and the bootstrap key second.
3. On first contact or reconnection, install and verify the stable key before
   commenting out the bootstrap key.
4. Use one multiplexed SSH probe to read build status, application health,
   revisions/model state, and resources.
5. If the app is missing, stale, or explicitly marked `build-repo`, stream
   `setup.sh` to the LXC.
6. While setup runs, report progress every 15 seconds without starting another
   recovery. Normal checks resume every two seconds afterward.

The watcher checks Git/model drift every 30 seconds. A changed revision or
model triggers setup and process restart, so a pulled update cannot leave the
old Python process running.

## Remote setup

`setup.sh` is safe to rerun. It:

1. Installs missing Git, curl, certificates, Python, venv, and pip packages.
2. Shallow-clones the repository or updates the existing checkout.
3. Removes and reclones only the validated application directory when
   `FORCE_REBUILD_REPO=true`.
4. Creates or repairs `.venv`.
5. Enforces CPU-only PyTorch and installs requirements only when their hash
   changes.
6. Downloads/verifies the configured local model, reusing Hugging Face cache.
7. Stops the recorded application process and starts Gradio with `nohup` on
   `0.0.0.0:8015`.
8. Waits for `/healthz`; success records the PID, commit, model, and `healthy`
   status.

Progress is written to `$HOME/.check/status` as `recovering`, `build-system`,
`build-repo`, `build-venv`, `build-dependencies`, `build-model`, `build-app`,
`failed`, or `healthy`.

Writing `build-repo` requests a clean checkout on the next watcher cycle:

```bash
mkdir -p "$HOME/.check"
printf 'build-repo\n' > "$HOME/.check/status"
```

## SSH credentials

The watcher creates one stable Ed25519 key and one random account password per
target under `CREDENTIALS_DIR`. It reuses them after reconnects and rebuilds.
The key updater follows this order:

1. Connect with the currently working key.
2. Apply the stored replacement password.
3. Add the stable public key if absent.
4. Verify a login with the stable private key.
5. Comment the bootstrap key as `# disabled-by-osms ...` only after successful
   verification.

The stable private key and password file use mode `0600`; the credential
directory uses `0700`. Do not commit them.

Log in manually with the same stable key:

```bash
ssh -i "$HOME/.ssh/osms-recovery/<target>_ed25519" \
  -p 22015 student-admin@host
```

After a fresh LXC rebuild, the watcher automatically falls back to the bootstrap
key and reinstalls the stable key. You do not change the launch command.

## Host-key policy

Watcher host keys are stored separately in `$CREDENTIALS_DIR/known_hosts`.
`SSH_STRICT_HOST_KEY_CHECKING=accept-new` accepts first contact but rejects a
changed host identity. A disposable LXC that regenerates its host key may use:

```text
SSH_STRICT_HOST_KEY_CHECKING=no
```

This enables unattended recovery but cannot distinguish a legitimate rebuild
from impersonation. Use it only for the trusted lab endpoint.

## Health and process behavior

The app exposes `/healthz`. The combined probe returns:

- `healthy` when the endpoint responds;
- `busy` when HTTP times out but the recorded PID is alive;
- `missing` otherwise.

`busy` never triggers recovery, preventing a slow CPU inference from being
killed. A missing app starts recovery. Setup itself does not report `healthy`
until the local model has preloaded and `/healthz` responds.

Application runtime files are stored in:

```text
$HOME/OverSmart-Math-Solver/.runtime/
```

Inside the LXC, follow the app log with:

```bash
tail -n 100 -F "$HOME/OverSmart-Math-Solver/.runtime/app.log"
```

## SSH connection reuse

Normal monitoring uses one combined probe per cycle. SSH multiplexing is always
enabled, so later probes open channels over the existing authenticated
connection instead of repeating TCP setup, key exchange, and authentication.
Control sockets live below `$CREDENTIALS_DIR/ssh-control/` and expire after
`SSH_CONTROL_PERSIST` seconds.

## Resource monitoring and Discord

Each combined probe measures CPU, system memory, and, when available through
`nvidia-smi`, GPU utilization and GPU memory. Samples are appended to
`logs/resource_usage.csv`. An unavailable GPU is recorded as `unavailable`.

Default warning thresholds are 80%. `RESOURCE_ALERT_COOLDOWN` rate-limits
threshold alerts, while `RECOVERY_ALERT_COOLDOWN` limits repeated recovery
failure messages. Optional Discord notifications cover:

- threshold violations;
- repository/model deployments;
- SSH loss and restoration;
- authentication or host-verification failure;
- remote failed/healthy state changes;
- app down/restored state;
- recovery success/failure.

The watcher also publishes `$HOME/.check/capacity` when any monitored resource
exceeds its threshold and removes it when all resources are below threshold.
It performs this remote write only when the state changes. Gradio checks the
flag every two seconds and displays “System near capacity” while it exists.

Test the configured webhook without entering the watcher loop:

```bash
./bash/external_watcher.sh --test-discord
```

The webhook URL is read from `.env`, is not printed, and is supplied to `curl`
through standard input rather than the process command line.

## Validation

Run syntax and isolated control-flow checks without contacting the real LXC:

```bash
bash -n bash/*.sh tests/*.sh tests/fixtures/*.sh
python3 tests/test_capacity_status.py
./tests/test_setup.sh
./tests/test_watcher.sh
```

The setup test checks final health/PID/commit/model markers. The watcher test
checks bootstrap-to-stable key handling plus healthy, busy, unhealthy, and
successful recovery branches through a fake SSH transport.

The red-team scripts can also be checked safely after the assignment window:
both exit before creating a cron entry or making an SSH attempt.

## Requirements and limitations

- The bootstrap key must authenticate to a fresh LXC.
- The watcher machine needs Bash, SSH, `ssh-keygen`, OpenSSL, curl, and Python 3.
- The remote account needs root or noninteractive `sudo` for `apt` and
  `chpasswd`.
- Deployment needs GitHub, Ubuntu repositories, PyPI/PyTorch, and Hugging Face
  network access on a fresh rebuild.
- The watcher is a long-running process; use an approved supervisor or a single
  startup task if it must survive reboot of the watcher machine.
