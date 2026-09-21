# External recovery watcher

The watcher runs on a separate machine. Because the application has no public
HTTP port, it connects over SSH and reads a health signal from the LXC. If the
signal is unhealthy, it sends the configured recovery script to the LXC and
runs it with Bash.

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

Run `./bash/external_watcher.sh --help` for all available settings.

## Recovery setup script

`bash/setup.sh` is streamed to the LXC when the application health check fails.
For the current test, it creates `$HOME/.check` on the remote machine and
increments the integer stored in `$HOME/.check/count` for every detected
failure. It then changes `$HOME/.check/status` to `healthy` to simulate a
successful recovery. To inspect the state on the LXC:

```bash
cat ~/.check/status
cat ~/.check/count
```

The previous application deployment implementation is preserved as
`bash/setup.sh.bk` for later use.

## Smoke-testing health signals

The watcher reads `$HOME/.check/status` on the remote machine and logs its
contents as `Remote health signal`. Only the exact value `healthy` produces a
successful health check. A missing file or any other value triggers the current
recovery script.

From an interactive remote SSH session, simulate a healthy application with:

```bash
mkdir -p ~/.check
printf 'healthy\n' > ~/.check/status
```

Simulate an unhealthy or not-yet-installed application with:

```bash
printf 'app_not_setup\n' > ~/.check/status
```

Inspect the current signal and failure count with:

```bash
cat ~/.check/status
cat ~/.check/count
```

This is a pull-based signal: the remote machine maintains the state file and
the external watcher reads it over SSH every `CHECK_INTERVAL` seconds.

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
