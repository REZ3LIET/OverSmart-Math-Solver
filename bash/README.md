# External recovery watcher

The watcher runs on a separate machine. Because the application has no public
HTTP port, it connects over SSH and checks Gradio at `127.0.0.1:8015` from
inside the LXC. If the check fails, it sends the configured recovery script to
the LXC and runs it with Bash.

## Configuration

The watcher automatically loads `.env` from the repository root. Start from
`.env.example` on a fresh checkout and set the machine-specific values. Put the
path of the initial key restored by a fresh LXC in `.env` once:

```text
BOOTSTRAP_SSH_IDENTITY_FILE=/absolute/path/to/student-admin_key
```

The watcher always tries its generated stable key first. If that fails after a
rebuild, it automatically tries the bootstrap key, reinstalls and verifies the
stable key, disables the bootstrap key remotely, and continues with the stable
key. You do not choose a key when launching it.

The watcher command is simply:

```bash
./bash/external_watcher.sh
```

The watcher stores server host keys in `$CREDENTIALS_DIR/known_hosts`, separate
from your normal `~/.ssh/known_hosts`. The default
`SSH_STRICT_HOST_KEY_CHECKING=accept-new` accepts first contact but stops if a
known server's host key changes. That protects against impersonation.

If this disposable test LXC generates a new SSH host key after every rebuild
and fully unattended recovery is more important than host authentication, set:

```text
SSH_STRICT_HOST_KEY_CHECKING=no
```

Use `no` only when you trust the lab network and endpoint. There is no secure
way for the watcher to distinguish an expected rebuilt LXC from an attacker if
the machine has no persistent host identity. SSH failures now include the final
error line every five attempts instead of only saying that SSH is not ready.

## Recovery setup script

`bash/setup.sh` is streamed to the LXC when the application health check fails.
It:

1. Clones the repository on first setup or updates the existing checkout.
2. Installs missing Ubuntu/Debian prerequisites, including `python3-venv` and
   `python3-pip`.
3. Creates or repairs `.venv` when its Python or pip is unavailable.
4. Ensures PyTorch is the CPU-only build, removes CUDA-only packages, and
   installs application dependencies when `requirements.txt` changes.
5. Downloads and verifies the configured local Hugging Face model. Existing
   cached files are reused.
6. Stops the previous recorded app process.
7. Starts Gradio on `0.0.0.0:8015` with `nohup`, preloads the local model into
   that process, and probes it through
   `127.0.0.1:8015`.
8. Waits up to `APP_START_TIMEOUT` (180 seconds by default) for an HTTP
   response. Because model preload occurs before the HTTP server starts, a
   healthy response means the local fallback is ready for requests.

Application output and the PID are stored under:

```text
$HOME/OverSmart-Math-Solver/.runtime/
```

Follow the application log from the watcher machine with:

```bash
ssh -i "$CREDENTIALS_DIR/student-admin_paffenroth-23.dyn.wpi.edu_ed25519" \
  -p 22015 student-admin@paffenroth-23.dyn.wpi.edu \
  'tail -n 100 -F "$HOME/OverSmart-Math-Solver/.runtime/app.log"'
```

If you are already inside the LXC, use:

```bash
tail -n 100 -F "$HOME/OverSmart-Math-Solver/.runtime/app.log"
```

Setup progress is recorded in `$HOME/.check/status` as `build-system`,
`build-repo`, `build-cache`, `build-venv`, `build-dependencies`, `build-model`,
`build-app`, `failed`, or `healthy`. The watcher uses `/healthz` plus process
liveness for normal health decisions. `bash/setup.sh.bk` is retained only as
an earlier draft.

## Prepared environment and model cache

After one LXC has a working virtual environment and the local model has fully
downloaded, build an external deployment cache:

```bash
./bash/build_deploy_cache.sh
```

The configured archive location is:

```text
/root/osms-deploy-cache/osms-runtime-cache.tar
```

The archive contains `.venv`, the configured Hugging Face model cache, and any
shared blob targets referenced by that model. It is not committed to Git. On a
fresh or cleanly rebuilt LXC, the watcher SCPs this archive to `/tmp`, and
`setup.sh` restores it under the remote user's home directory before checking
dependencies. A SHA-256 marker prevents repeated multi-gigabyte uploads to an
unchanged LXC.

Rebuild the archive whenever `requirements.txt`, the Python/OS version, or the
local model changes. The cached virtual environment assumes the rebuilt LXC uses
the same username, home path, OS architecture, and Python minor version.

Enable automatic cache upload with:

```text
USE_DEPLOY_CACHE=true
```

It defaults to `false` because the September 28, 2026 benchmark on this LXC
found that its slow extraction made the complete archive slower than fresh
downloads:

| Path | Stage | Seconds |
|---|---|---:|
| Fresh | Git clone | 0.7 |
| Fresh | Create venv | 2.2 |
| Fresh | Uncached pip install | 301.5 |
| Fresh | Model download | 36.6 |
| Fresh | **Total** | **341.0** |
| Cached | SCP 7.7 GB archive | 240.9 |
| Cached | Extract and verify | 365.3 |
| Cached | **Total** | **606.2** |

The cache remains useful for offline or deterministic recovery, but enabling it
increased recovery time by about 78% on this machine.

Request a clean repository rebuild by writing `build-repo` from the watcher
machine:

```bash
ssh -i /root/.ssh/osms-recovery/student-admin_paffenroth-23.dyn.wpi.edu_ed25519 \
  -p 22015 student-admin@paffenroth-23.dyn.wpi.edu \
  'mkdir -p "$HOME/.check" && printf "build-repo\\n" > "$HOME/.check/status"'
```

On its next check, the watcher stops the recorded app process, removes the
existing application directory, clones a clean copy, and completes setup. Other
`build-*` values report progress and do not request another setup.

## First-contact SSH key update

`first_ping` starts as `true` and is reset to `true` only when SSH connectivity
is lost. An unhealthy application does not reset it. When
`UPDATE_SSH_KEY_ON_FIRST_PING=true`, the initial successful contact and the
first successful contact after an SSH outage run the key-update procedure.

The procedure:

1. Creates one stable Ed25519 watcher key if it does not already exist.
2. Creates one stable random account password if it does not already exist.
3. Applies that password to the remote account.
4. Adds the watcher public key to the remote `authorized_keys` file.
5. Verifies that the watcher key can log in.
6. Comments out the previously used key with `# disabled-by-osms`.

It reuses the stable key and password rather than generating new credentials on
every contact.

Credentials are stored on the external watcher machine under
`CREDENTIALS_DIR`, which defaults to:

```text
~/.ssh/osms-recovery/
```

For the current test, `.env` sets:

```text
CREDENTIALS_DIR=/root/.ssh/osms-recovery
```

Each machine has one stable watcher-key pair:

```text
<machine>_ed25519
<machine>_ed25519.pub
<machine>_ed25519.password
```

The watcher prints the active private-key path after a successful update. The
old key is commented only after the new key has been verified.

Display the account password with:

```bash
cat /root/.ssh/osms-recovery/student-admin_paffenroth-23.dyn.wpi.edu_ed25519.password
```

The password file is created with mode `0600` and must not be committed to the
repository.

When the watcher is restarted, it automatically tries the stable watcher key
for the configured machine first. It retains the key supplied through
`BOOTSTRAP_SSH_IDENTITY_FILE` as the fallback for a newly rebuilt LXC, so the
normal watcher command does not need to change after the key update.

## Logging in with the watcher key

Use the private-key path printed by the watcher:

```bash
ssh -i /root/.ssh/osms-recovery/student-admin_paffenroth-23.dyn.wpi.edu_ed25519 \
  -p 22015 \
  student-admin@paffenroth-23.dyn.wpi.edu
```

## Requirements and failure behavior

- The initial `student-admin_key` must work on a newly created machine.
- `ssh-keygen` and `openssl` must exist on the external watcher machine.
- Applying the account password requires either a root SSH account or
  non-interactive permission to run `sudo chpasswd` inside the LXC.
- The watcher key is installed and verified before the previous login key is
  commented. If the update fails, the watcher retains the working key.
- The watcher continues retrying SSH until the LXC becomes reachable.
- System package installation requires root or passwordless `sudo` on the LXC.
- Normal health checks run every `CHECK_INTERVAL` (two seconds by default).
- A slow Solve request reports `busy` when Gradio's HTTP check times out but
  the recorded application PID is still alive. Busy applications are never
  restarted merely because inference is taking time.
- Every `DEPLOY_CHECK_INTERVAL` (30 seconds by default), a healthy app compares
  its successfully started commit with GitHub `main`. A new commit triggers one
  setup run, restart, and updated `.runtime/app.commit` marker.
- While setup is running, the watcher checks its progress every
  `SETUP_CHECK_INTERVAL` (15 seconds by default) and never starts an overlapping
  setup. After setup succeeds or fails, two-second health checks resume.

## SSH connection reuse

Normal monitoring uses one combined SSH probe per cycle. That probe returns the
remote build status, application health, and—every 30 seconds—the running and
latest Git revisions. The preliminary SSH reachability check runs only while
establishing or re-establishing contact, not before every health probe.

SSH multiplexing is enabled by default:

```text
SSH_MULTIPLEXING=true
SSH_CONTROL_PERSIST=60
```

The first command performs the normal TCP connection, key exchange, and key
authentication. Later probes open lightweight channels over that authenticated
connection. The control socket is stored beneath
`$CREDENTIALS_DIR/ssh-control/`. If the transport is lost, the watcher discards
its active connection state and resumes the stable-key/bootstrap-key retry
sequence.

## Resource monitoring

The same combined SSH probe reads cumulative CPU counters, available system
memory, and—when `nvidia-smi` exists—GPU utilization and GPU memory. Samples are
written to:

```text
logs/resource_usage.csv
```

The first CPU sample is `unavailable` because CPU utilization requires two
cumulative readings; subsequent samples cover the interval between watcher
checks. Default warning thresholds are:

```text
CPU_THRESHOLD=80
MEMORY_THRESHOLD=80
GPU_THRESHOLD=80
GPU_MEMORY_THRESHOLD=80
RESOURCE_ALERT_COOLDOWN=60
```

Warnings appear in watcher output and are limited to one per cooldown period.
When `DISCORD_WEBHOOK_URL` is configured, the same rate-limited warning is sent
to Discord. Recovery failures are separately limited by
`RECOVERY_ALERT_COOLDOWN`. The webhook URL is never printed. An unavailable GPU
is recorded as `unavailable`, not as zero utilization.

Configure Discord in `.env`:

```text
DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/...'
DISCORD_USERNAME='OSMS Watcher'
DISCORD_NOTIFY_REPO_UPDATES=true
DISCORD_NOTIFY_SERVER_STATE=true
DISCORD_NOTIFY_APP_STATE=true
DISCORD_NOTIFY_RECOVERY=true
SERVER_DOWN_NOTIFY_AFTER=3
```

Send one test notification without starting the monitoring loop:

```bash
./bash/external_watcher.sh --test-discord
```

Notifications are event-driven and reuse existing probes; they do not add SSH
checks. The watcher reports:

- repository revision changes and the resulting deployment;
- model-configuration drift even when the Git revision is unchanged;
- SSH/server unavailability after three failed cycles, plus connectivity
  restoration;
- SSH authentication or host-verification failures without mislabeling them as
  a powered-off server;
- remote `.check/status=failed` and its return to `healthy`;
- application health loss and restoration (`busy` is not treated as down);
- threshold violations, subject to `RESOURCE_ALERT_COOLDOWN`;
- recovery success or failure, with repeated failures limited by
  `RECOVERY_ALERT_COOLDOWN`.

Set any `DISCORD_NOTIFY_*` value to `false` to disable that category. The
server-down grace count avoids notifying on a single transient SSH failure.

The standalone deployment defaults to `Qwen/Qwen2.5-0.5B-Instruct`, CPU-only
PyTorch, and 128 maximum new tokens. Gradio displays model readiness when the
page opens and shows progress messages for remote inference, local loading,
CPU generation, and fallback.

Follow resource samples on the watcher machine with:

```bash
tail -n 20 -F logs/resource_usage.csv
```

## Authorized bootstrap-key audit

`audit_bootstrap_key.sh` follows the instructor-provided reference pattern. It
makes exactly two sequential passes over group ports 22001 through 22021, waits
five seconds between passes, permits one SSH connection attempt per port per
pass, and runs only the read-only `hostname` command. It records UTC timestamps
and refuses to run outside noon September 29 through noon October 1, 2026 in
`America/New_York`.

It uses `BOOTSTRAP_SSH_IDENTITY_FILE` from `.env` by default:

```bash
./bash/audit_bootstrap_key.sh
```

Install its scheduled run on the external watcher machine before noon:

```bash
./bash/schedule_red_team_audit.sh
```

The installer adds a cron entry for `2026-09-29 12:00 America/New_York` and
writes output to `logs/red_team_2026-09-29.log`. The audit's fixed 2026 window
guard prevents the retained annual cron expression from making later network
attempts. A successful authentication must be used only as the assignment
allows: retain the evidence, notify the other team, and make no changes.
