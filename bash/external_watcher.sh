#!/usr/bin/env bash

# Runs on the external monitoring machine.
# It waits for SSH, checks the remote health signal, and sends setup.sh when
# recovery is needed.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${ENV_FILE:-$SCRIPT_DIR/../.env}"

: "${WATCH_TARGET:?Set WATCH_TARGET in .env}"
: "${RECOVERY_SCRIPT:?Set RECOVERY_SCRIPT in .env}"
: "${BOOTSTRAP_SSH_IDENTITY_FILE:?Supply BOOTSTRAP_SSH_IDENTITY_FILE}"

SSH_PORT="${SSH_PORT:-22}"
CHECK_INTERVAL="${CHECK_INTERVAL:-2}"
SSH_RETRY_INTERVAL="${SSH_RETRY_INTERVAL:-1}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-2}"
CREDENTIALS_DIR="${CREDENTIALS_DIR:-$HOME/.ssh/osms-recovery}"
UPDATE_SSH_KEY_ON_FIRST_PING="${UPDATE_SSH_KEY_ON_FIRST_PING:-true}"
DEFAULT_HEALTH_COMMAND='curl --fail --silent --max-time 2 http://127.0.0.1:8015/ >/dev/null && printf healthy'
REMOTE_HEALTH_COMMAND="${REMOTE_HEALTH_COMMAND:-$DEFAULT_HEALTH_COMMAND}"
SSH_BIN="${SSH_BIN:-ssh}"

# Resolve repository-relative script paths.
[[ "$RECOVERY_SCRIPT" = /* ]] || RECOVERY_SCRIPT="$SCRIPT_DIR/../$RECOVERY_SCRIPT"
KEY_UPDATE_SCRIPT="$SCRIPT_DIR/update_ssh_key.sh"

log() {
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# Run one command on the remote machine using the requested private key.
remote() {
    local key="$1"
    shift
    "$SSH_BIN" \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
        -p "$SSH_PORT" \
        -i "$key" \
        "$WATCH_TARGET" "$@"
}

safe_target="${WATCH_TARGET//[^A-Za-z0-9_.-]/_}"
stable_key="$CREDENTIALS_DIR/${safe_target}_ed25519"
bootstrap_key="$BOOTSTRAP_SSH_IDENTITY_FILE"
active_key="$bootstrap_key"
[[ -r "$stable_key" ]] && active_key="$stable_key"

working_key=""
key_update_needed=true

# Try the stable key first. A rebuilt LXC falls back to its original key.
wait_for_ssh() {
    while true; do
        if remote "$active_key" true >/dev/null 2>&1; then
            working_key="$active_key"
            return
        fi

        if [[ "$bootstrap_key" != "$active_key" ]] && \
            remote "$bootstrap_key" true >/dev/null 2>&1
        then
            working_key="$bootstrap_key"
            return
        fi

        key_update_needed=true
        log "SSH is not ready; retrying."
        sleep "$SSH_RETRY_INTERVAL"
    done
}

# Install/reapply the stable watcher key and account password.
update_remote_access() {
    local updated_key

    if updated_key="$(
        WATCH_TARGET="$WATCH_TARGET" \
        SSH_PORT="$SSH_PORT" \
        SSH_IDENTITY_FILE="$working_key" \
        SSH_CONNECT_TIMEOUT="$SSH_CONNECT_TIMEOUT" \
        CREDENTIALS_DIR="$CREDENTIALS_DIR" \
        SSH_BIN="$SSH_BIN" \
        "$KEY_UPDATE_SCRIPT"
    )"
    then
        active_key="$updated_key"
        working_key="$updated_key"
        log "Remote access updated; active key: $updated_key"
    else
        log "Remote access update failed; keeping the current key."
    fi

    key_update_needed=false
}

while true; do
    wait_for_ssh

    if [[ "$key_update_needed" == true && "$UPDATE_SSH_KEY_ON_FIRST_PING" == true ]]; then
        update_remote_access
    fi

    # The command prints a signal and returns 0 only when the remote is healthy.
    health_signal="$(remote "$working_key" "$REMOTE_HEALTH_COMMAND" 2>&1)"
    health_result=$?
    log "Remote health signal: ${health_signal:-missing}"

    if (( health_result == 0 )); then
        log "Application is healthy."
    else
        # SSH itself uses exit code 255 when the connection disappears.
        (( health_result == 255 )) && key_update_needed=true
        log "Application is unhealthy; running recovery."

        if remote "$working_key" 'bash -s' < "$RECOVERY_SCRIPT"; then
            log "Recovery completed."
        else
            log "Recovery failed; the watcher will retry."
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
