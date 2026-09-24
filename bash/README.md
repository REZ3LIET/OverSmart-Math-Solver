# External recovery watcher

The watcher runs on a separate machine. Because the application has no public
HTTP port, it connects over SSH and checks Gradio at `127.0.0.1:8015` from
inside the LXC. If the check fails, it sends the configured recovery script to
the LXC and runs it with Bash.

## Configuration

The watcher automatically loads `.env` from the repository root. Start from
`.env.example` on a fresh checkout and set the machine-specific values. Supply
the initial key that exists on a newly rebuilt LXC as
`BOOTSTRAP_SSH_IDENTITY_FILE`. The watcher automatically uses its stable watcher
key when that key is already installed remotely.

Current watcher command:

```bash
BOOTSTRAP_SSH_IDENTITY_FILE=student-admin_key ./bash/external_watcher.sh
```

Use an absolute path if the key is outside the repository directory:

```bash
BOOTSTRAP_SSH_IDENTITY_FILE=/absolute/path/to/student-admin_key \
  ./bash/external_watcher.sh
```

## Recovery setup script

`bash/setup.sh` is streamed to the LXC when the application health check fails.
It:

1. Clones the repository on first setup or updates the existing checkout.
2. Installs missing Ubuntu/Debian prerequisites, including `python3-venv` and
   `python3-pip`.
3. Creates or repairs `.venv` when its Python or pip is unavailable.
4. Installs dependencies only when `requirements.txt` changes.
5. Stops the previous recorded app process.
6. Starts Gradio on `0.0.0.0:8015` with `nohup` and probes it through
   `127.0.0.1:8015`.
7. Waits up to `APP_START_TIMEOUT` (180 seconds by default) for an HTTP
   response. This accommodates slow cold imports on a newly rebuilt LXC.

Application output and the PID are stored under:

```text
$HOME/OverSmart-Math-Solver/.runtime/
```

Setup progress is recorded in `$HOME/.check/status` as `build-system`,
`build-repo`, `build-venv`, `build-dependencies`, `build-app`, `failed`, or
`healthy`. The watcher still uses the HTTP response for normal application
health decisions. `bash/setup.sh.bk` is retained only as an earlier draft.

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
