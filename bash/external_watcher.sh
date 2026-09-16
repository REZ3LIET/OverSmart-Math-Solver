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
  SSH_IDENTITY_FILE  Initial/bootstrap SSH private key (normally supplied on CLI)

Optional environment variables:
  SSH_PORT              SSH port (default: 22)
  REMOTE_HEALTH_COMMAND Command run inside the LXC (default: curl localhost:7860)
  CHECK_INTERVAL        Seconds between checks (default: 2)
  SSH_RETRY_INTERVAL    Seconds between SSH attempts (default: 1)
  SSH_CONNECT_TIMEOUT   SSH connection timeout in seconds (default: 2)
  ROTATE_CREDENTIALS_ON_FIRST_PING
                          Rotate credentials on initial/recovered contact (default: true)
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
: "${SSH_IDENTITY_FILE:?Supply SSH_IDENTITY_FILE when starting the watcher}"

SSH_PORT="${SSH_PORT:-22}"
REMOTE_HEALTH_COMMAND="${REMOTE_HEALTH_COMMAND:-curl -fsS --max-time 2 http://127.0.0.1:7860/ >/dev/null}"
CHECK_INTERVAL="${CHECK_INTERVAL:-2}"
SSH_RETRY_INTERVAL="${SSH_RETRY_INTERVAL:-1}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-2}"
ROTATE_CREDENTIALS_ON_FIRST_PING="${ROTATE_CREDENTIALS_ON_FIRST_PING:-true}"
CREDENTIALS_DIR="${CREDENTIALS_DIR:-$HOME/.ssh/osms-recovery}"
ROTATION_SCRIPT="${ROTATION_SCRIPT:-$SCRIPT_DIR/rotate_ssh_credentials.sh}"
WATCHER_MAX_CYCLES="${WATCHER_MAX_CYCLES:-0}"
SSH_BIN="${SSH_BIN:-ssh}"

if [[ ! -r "$RECOVERY_SCRIPT" ]]; then
    echo "Recovery script is not readable: $RECOVERY_SCRIPT" >&2
    exit 1
fi

if [[ "$ROTATE_CREDENTIALS_ON_FIRST_PING" == "true" && ! -x "$ROTATION_SCRIPT" ]]; then
    echo "Credential rotation script is not executable: $ROTATION_SCRIPT" >&2
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

bootstrap_identity="$SSH_IDENTITY_FILE"
active_identity="$SSH_IDENTITY_FILE"
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

rotate_credentials() {
    local new_identity

    if ! new_identity="$(
        WATCH_TARGET="$WATCH_TARGET" \
        SSH_PORT="$SSH_PORT" \
        SSH_IDENTITY_FILE="$reachable_identity" \
        SSH_CONNECT_TIMEOUT="$SSH_CONNECT_TIMEOUT" \
        CREDENTIALS_DIR="$CREDENTIALS_DIR" \
        SSH_BIN="$SSH_BIN" \
        "$ROTATION_SCRIPT"
    )"
    then
        log "Credential rotation failed; retaining the current working key."
        return 1
    fi

    active_identity="$new_identity"
    reachable_identity="$new_identity"
    log "Credential rotation completed; new key: $new_identity"
}

while true; do
    wait_for_ssh

    if [[ "$first_ping" == "true" ]]; then
        log "First SSH contact detected."
        if [[ "$ROTATE_CREDENTIALS_ON_FIRST_PING" == "true" ]]; then
            rotate_credentials || true
        fi
        first_ping=false
    fi

    if ssh_with_identity "$reachable_identity" "$REMOTE_HEALTH_COMMAND" >/dev/null 2>&1; then
        log "Application is healthy."
    else
        log "Application health check failed; running recovery script."
        first_ping=true

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
