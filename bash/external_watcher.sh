#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../.env}"

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

if [[ "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Monitor an app inside an SSH-only LXC and run recovery when it is unhealthy.

Required environment variables:
  WATCH_TARGET       SSH destination, for example: user@192.0.2.10
  RECOVERY_SCRIPT    Local script to pipe to bash on the target
  BOOTSTRAP_SSH_IDENTITY_FILE
                     Initial key present on a newly rebuilt LXC

Optional environment variables:
  SSH_PORT              SSH port (default: 22)
  REMOTE_HEALTH_COMMAND Command run inside the LXC (default: read .check/status)
  CHECK_INTERVAL        Seconds between checks (default: 2)
  SSH_RETRY_INTERVAL    Seconds between SSH attempts (default: 1)
  SSH_CONNECT_TIMEOUT   SSH connection timeout in seconds (default: 2)
  UPDATE_SSH_KEY_ON_FIRST_PING
                          Update the login key on initial/recovered contact (default: true)
  CREDENTIALS_DIR       Local directory for generated credentials
  WATCHER_MAX_CYCLES    Stop after N checks; 0 runs forever (default: 0)
  SSH_BIN               ssh-compatible executable (default: ssh)

The watcher automatically loads .env from the repository root. Set ENV_FILE to
use a different file. Values assigned by that file override exported values.
EOF
    exit 0
fi

: "${WATCH_TARGET:?Set WATCH_TARGET to the SSH destination}"
: "${RECOVERY_SCRIPT:?Set RECOVERY_SCRIPT to the local recovery script}"

# SSH_IDENTITY_FILE remains a compatibility alias for older commands.
BOOTSTRAP_SSH_IDENTITY_FILE="${BOOTSTRAP_SSH_IDENTITY_FILE:-${SSH_IDENTITY_FILE:-}}"
: "${BOOTSTRAP_SSH_IDENTITY_FILE:?Supply BOOTSTRAP_SSH_IDENTITY_FILE when starting the watcher}"

SSH_PORT="${SSH_PORT:-22}"
REMOTE_HEALTH_COMMAND="${REMOTE_HEALTH_COMMAND:-status=\$(cat \"\$HOME/.check/status\" 2>/dev/null || printf missing); printf '%s' \"\$status\"; test \"\$status\" = healthy}"
CHECK_INTERVAL="${CHECK_INTERVAL:-2}"
SSH_RETRY_INTERVAL="${SSH_RETRY_INTERVAL:-1}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-2}"
UPDATE_SSH_KEY_ON_FIRST_PING="${UPDATE_SSH_KEY_ON_FIRST_PING:-true}"
CREDENTIALS_DIR="${CREDENTIALS_DIR:-$HOME/.ssh/osms-recovery}"
KEY_UPDATE_SCRIPT="${KEY_UPDATE_SCRIPT:-$SCRIPT_DIR/update_ssh_key.sh}"
WATCHER_MAX_CYCLES="${WATCHER_MAX_CYCLES:-0}"
SSH_BIN="${SSH_BIN:-ssh}"

if [[ "$RECOVERY_SCRIPT" != /* ]]; then
    RECOVERY_SCRIPT="$SCRIPT_DIR/../$RECOVERY_SCRIPT"
fi

if [[ ! -r "$RECOVERY_SCRIPT" ]]; then
    echo "Recovery script is not readable: $RECOVERY_SCRIPT" >&2
    exit 1
fi

if [[ "$UPDATE_SSH_KEY_ON_FIRST_PING" == "true" && ! -x "$KEY_UPDATE_SCRIPT" ]]; then
    echo "SSH key update script is not executable: $KEY_UPDATE_SCRIPT" >&2
    exit 1
fi

log() {
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

ssh_with_identity() {
    local identity_file="$1"
    shift
    "$SSH_BIN" \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
        -p "$SSH_PORT" \
        -i "$identity_file" \
        "$WATCH_TARGET" "$@"
}

bootstrap_identity="$BOOTSTRAP_SSH_IDENTITY_FILE"
active_identity="$BOOTSTRAP_SSH_IDENTITY_FILE"

safe_target="${WATCH_TARGET//[^A-Za-z0-9_.-]/_}"
stable_identity="$CREDENTIALS_DIR/${safe_target}_ed25519"
if [[ -r "$stable_identity" ]]; then
    active_identity="$stable_identity"
else
    shopt -s nullglob
    generated_identities=("$CREDENTIALS_DIR/${safe_target}_"*_ed25519)
    shopt -u nullglob
    if (( ${#generated_identities[@]} > 0 )); then
        active_identity="${generated_identities[-1]}"
    fi
fi

reachable_identity=""
first_ping=true
cycle_count=0

wait_for_ssh() {
    while true; do
        if ssh_with_identity "$active_identity" true >/dev/null 2>&1; then
            reachable_identity="$active_identity"
            return 0
        fi

        if [[ "$bootstrap_identity" != "$active_identity" ]] && \
            ssh_with_identity "$bootstrap_identity" true >/dev/null 2>&1
        then
            reachable_identity="$bootstrap_identity"
            return 0
        fi

        first_ping=true
        log "SSH is not ready; retrying."
        sleep "$SSH_RETRY_INTERVAL"
    done
}

update_ssh_key() {
    local new_identity

    if ! new_identity="$(
        WATCH_TARGET="$WATCH_TARGET" \
        SSH_PORT="$SSH_PORT" \
        SSH_IDENTITY_FILE="$reachable_identity" \
        SSH_CONNECT_TIMEOUT="$SSH_CONNECT_TIMEOUT" \
        CREDENTIALS_DIR="$CREDENTIALS_DIR" \
        SSH_BIN="$SSH_BIN" \
        "$KEY_UPDATE_SCRIPT"
    )"
    then
        log "SSH key update failed; retaining the current working key."
        return 1
    fi

    active_identity="$new_identity"
    reachable_identity="$new_identity"
    log "SSH key update completed; active key: $new_identity"
}

while true; do
    wait_for_ssh

    if [[ "$first_ping" == "true" ]]; then
        log "First SSH contact detected."
        if [[ "$UPDATE_SSH_KEY_ON_FIRST_PING" == "true" ]]; then
            update_ssh_key || true
        fi
        first_ping=false
    fi

    health_output="$(ssh_with_identity "$reachable_identity" "$REMOTE_HEALTH_COMMAND" 2>&1)"
    health_status=$?

    if [[ -n "$health_output" ]]; then
        log "Remote health signal: $health_output"
    fi

    if (( health_status == 0 )); then
        log "Application is healthy."
    else
        if (( health_status == 255 )); then
            first_ping=true
            log "SSH connectivity was lost during the health check."
        fi
        log "Application health check failed; running recovery script."

        if ssh_with_identity "$reachable_identity" 'bash -s' < "$RECOVERY_SCRIPT"; then
            log "Recovery script completed."
        else
            log "Recovery script failed; monitoring will retry."
        fi
    fi

    cycle_count=$((cycle_count + 1))
    if (( WATCHER_MAX_CYCLES > 0 && cycle_count >= WATCHER_MAX_CYCLES )); then
        log "Configured cycle limit reached; stopping."
        exit 0
    fi

    sleep "$CHECK_INTERVAL"
done
