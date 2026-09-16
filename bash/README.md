# External recovery watcher

The watcher runs on a separate machine. Because the application has no public
HTTP port, it connects over SSH and checks Gradio at `127.0.0.1:7860` from
inside the LXC. If the check fails, it sends the configured recovery script to
the LXC and runs it with Bash.

## Configuration

The watcher automatically loads `.env` from the repository root. Start from
`.env.example` on a fresh checkout and set the machine-specific values. The SSH
identity can be supplied on the command line so its path is not stored in
`.env`.

Current watcher command:

```bash
SSH_IDENTITY_FILE=student-admin_key ./bash/external_watcher.sh
```

Use an absolute path if the key is outside the repository directory:

```bash
SSH_IDENTITY_FILE=/absolute/path/to/student-admin_key ./bash/external_watcher.sh
```

Run `./bash/external_watcher.sh --help` for all available settings. The recovery
setup script referenced by `RECOVERY_SCRIPT` has not been implemented yet and
is tracked in the repository's `TODO.md`.

## First-contact credential rotation

`first_ping` starts as `true` and is reset to `true` after an SSH or application
health failure. When `ROTATE_CREDENTIALS_ON_FIRST_PING=true`, the first
successful contact generates:

- A unique Ed25519 SSH login key.
- A random account password.

Credentials are stored on the external watcher machine under
`CREDENTIALS_DIR`, which defaults to:

```text
~/.ssh/osms-recovery/
```

The files follow this pattern:

```text
<machine>_<timestamp>_ed25519
<machine>_<timestamp>_ed25519.pub
<machine>_<timestamp>_ed25519.password
```

The watcher prints the active private-key path after successful rotation. The
new key is tested before the previous authorized key is removed.

## Finding the generated password

List password files from newest to oldest:

```bash
ls -t ~/.ssh/osms-recovery/*.password
```

Display the newest generated password:

```bash
cat "$(ls -t ~/.ssh/osms-recovery/*.password | head -1)"
```

Credential directories and password files are created with restricted
permissions. Do not commit or copy these files into the repository.

Password login works only when the LXC SSH server permits
`PasswordAuthentication`. Key authentication is preferred.

## Logging in with the generated key

Use the private-key path printed by the watcher:

```bash
ssh -i ~/.ssh/osms-recovery/<generated-key-name> \
  -p 22015 \
  student-admin@paffenroth-23.dyn.wpi.edu
```

## Requirements and failure behavior

- The initial `student-admin_key` must work on a newly created machine.
- `ssh-keygen` and `openssl` must exist on the external watcher machine.
- Password rotation requires either a root SSH account or non-interactive
  permission to run `sudo chpasswd` inside the LXC.
- The replacement key is installed and verified before the previous login key
  is removed. If rotation fails, the watcher retains the current working key.
- The watcher continues retrying SSH until the LXC becomes reachable.
