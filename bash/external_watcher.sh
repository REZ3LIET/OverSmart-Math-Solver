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
SETUP_CHECK_INTERVAL="${SETUP_CHECK_INTERVAL:-15}"
DEPLOY_CHECK_INTERVAL="${DEPLOY_CHECK_INTERVAL:-30}"
SSH_RETRY_INTERVAL="${SSH_RETRY_INTERVAL:-1}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-2}"
CREDENTIALS_DIR="${CREDENTIALS_DIR:-$HOME/.ssh/osms-recovery}"
DEPLOY_CACHE_ARCHIVE="${DEPLOY_CACHE_ARCHIVE:-}"
USE_DEPLOY_CACHE="${USE_DEPLOY_CACHE:-false}"
UPDATE_SSH_KEY_ON_FIRST_PING="${UPDATE_SSH_KEY_ON_FIRST_PING:-true}"
DEFAULT_HEALTH_COMMAND='if curl --fail --silent --max-time 2 http://127.0.0.1:8015/healthz >/dev/null || curl --fail --silent --max-time 2 http://127.0.0.1:8015/ >/dev/null; then printf healthy; else pid=$(cat "$HOME/OverSmart-Math-Solver/.runtime/app.pid" 2>/dev/null || true); test -n "$pid" && kill -0 "$pid" 2>/dev/null && printf busy; fi'
REMOTE_HEALTH_COMMAND="${REMOTE_HEALTH_COMMAND:-$DEFAULT_HEALTH_COMMAND}"
DEFAULT_STATUS_COMMAND='cat "$HOME/.check/status" 2>/dev/null || printf missing'
REMOTE_STATUS_COMMAND="${REMOTE_STATUS_COMMAND:-$DEFAULT_STATUS_COMMAND}"
SSH_BIN="${SSH_BIN:-ssh}"
SCP_BIN="${SCP_BIN:-scp}"

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

if [[ ! -r "$stable_key" && ! -r "$bootstrap_key" ]]; then
    log "No readable SSH key was found."
    log "Stable key checked: $stable_key"
    log "Bootstrap key checked: $bootstrap_key"
    exit 1
fi
if [[ ! -r "$bootstrap_key" ]]; then
    log "Warning: bootstrap key is not readable: $bootstrap_key"
    log "The stable key can reach the current LXC, but not a fresh rebuild."
fi

working_key=""
key_update_needed=true
recovery_pid=""
recovery_started_epoch=0
last_deploy_check=0

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

# Upload the prepared environment/model archive only to a fresh or explicitly
# rebuilt deployment. A checksum marker avoids repeating the large transfer.
sync_deploy_cache() {
    local force_rebuild="$1"
    local local_checksum remote_checksum

    recovery_cache_archive=""
    recovery_cache_checksum=""
    [[ "$USE_DEPLOY_CACHE" == true ]] || return 0
    [[ -n "$DEPLOY_CACHE_ARCHIVE" ]] || return 0
    if [[ ! -r "$DEPLOY_CACHE_ARCHIVE" ]]; then
        log "Deployment cache is not readable; continuing without it: $DEPLOY_CACHE_ARCHIVE"
        return 0
    fi

    if [[ -r "$DEPLOY_CACHE_ARCHIVE.sha256" ]]; then
        local_checksum="$(awk 'NR == 1 {print $1}' "$DEPLOY_CACHE_ARCHIVE.sha256")"
    else
        local_checksum="$(sha256sum "$DEPLOY_CACHE_ARCHIVE" | awk '{print $1}')"
    fi
    recovery_cache_checksum="$local_checksum"
    remote_checksum="$(remote "$working_key" \
        'cat "$HOME/.cache/osms-deploy-cache.sha256" 2>/dev/null || true' \
        2>/dev/null || true)"

    if [[ "$force_rebuild" != true && "$local_checksum" == "$remote_checksum" ]]; then
        log "Deployment cache is already installed."
        return 0
    fi

    recovery_cache_archive="/tmp/osms-deploy-cache.tar"
    log "Uploading prepared Python environment and model cache."
    if ! "$SCP_BIN" \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
        -P "$SSH_PORT" \
        -i "$working_key" \
        "$DEPLOY_CACHE_ARCHIVE" \
        "$WATCH_TARGET:$recovery_cache_archive"
    then
        log "Deployment cache upload failed; continuing with normal installation."
        recovery_cache_archive=""
    fi
}

run_recovery() {
    local force_rebuild="$1"

    sync_deploy_cache "$force_rebuild"
    if [[ -n "$recovery_cache_archive" ]]; then
        remote "$working_key" \
            "FORCE_REBUILD_REPO=$force_rebuild DEPLOY_CACHE_ARCHIVE=$recovery_cache_archive DEPLOY_CACHE_CHECKSUM=$recovery_cache_checksum bash -s" \
            < "$RECOVERY_SCRIPT"
    else
        remote "$working_key" \
            "FORCE_REBUILD_REPO=$force_rebuild bash -s" \
            < "$RECOVERY_SCRIPT"
    fi
}

start_recovery() {
    recovery_started_epoch="$(date +%s)"
    run_recovery "$1" &
    recovery_pid=$!
}

while true; do
    wait_for_ssh

    if [[ "$key_update_needed" == true && "$UPDATE_SSH_KEY_ON_FIRST_PING" == true ]]; then
        update_remote_access
    fi

    # A setup runs in the background so the watcher can report on it, but only
    # one setup is allowed at a time. Check it less often than normal health.
    if [[ -n "$recovery_pid" ]]; then
        if kill -0 "$recovery_pid" 2>/dev/null; then
            remote_status="$(remote "$working_key" "$REMOTE_STATUS_COMMAND" 2>/dev/null || true)"
            health_signal="$(remote "$working_key" "$REMOTE_HEALTH_COMMAND" 2>&1)"
            health_result=$?
            (( health_result == 255 )) && key_update_needed=true
            log "Setup is running; status: ${remote_status:-missing}; health: ${health_signal:-missing}"
            sleep "$SETUP_CHECK_INTERVAL"
            continue
        fi

        if wait "$recovery_pid"; then
            log "Recovery completed in $(( $(date +%s) - recovery_started_epoch )) seconds."
        else
            log "Recovery failed after $(( $(date +%s) - recovery_started_epoch )) seconds; returning to $CHECK_INTERVAL-second checks."
        fi
        recovery_pid=""
        sleep "$CHECK_INTERVAL"
        continue
    fi

    remote_status="$(remote "$working_key" "$REMOTE_STATUS_COMMAND" 2>/dev/null || true)"

    # Writing build-repo to the remote status file requests a clean checkout.
    if [[ "$remote_status" == "build-repo" ]]; then
        log "Clean repository rebuild requested."
        start_recovery true
        sleep "$SETUP_CHECK_INTERVAL"
        continue
    fi

    # The command prints a signal and returns 0 only when the remote is healthy.
    health_signal="$(remote "$working_key" "$REMOTE_HEALTH_COMMAND" 2>&1)"
    health_result=$?
    log "Remote status: ${remote_status:-missing}; health: ${health_signal:-missing}"

    if (( health_result == 0 )); then
        if [[ "$health_signal" == "healthy" ]]; then
            remote "$working_key" \
                'mkdir -p "$HOME/.check" && printf "healthy\n" > "$HOME/.check/status"' \
                >/dev/null 2>&1 || true
            log "Application is healthy."

            # Deploy a pushed commit once, then record the revision that
            # actually reached a healthy state. Never deploy while app is busy.
            now="$(date +%s)"
            if (( now - last_deploy_check >= DEPLOY_CHECK_INTERVAL )); then
                last_deploy_check="$now"
                revision_info="$(remote "$working_key" '
                    app="$HOME/OverSmart-Math-Solver"
                    running=$(cat "$app/.runtime/app.commit" 2>/dev/null || printf missing)
                    latest=$(git -C "$app" ls-remote origin refs/heads/main 2>/dev/null | awk "NR == 1 { print \$1 }")
                    test -n "$latest" || exit 1
                    printf "%s %s\n" "$running" "$latest"
                ' 2>/dev/null || true)"
                read -r running_revision latest_revision <<< "$revision_info"

                if [[ -n "${latest_revision:-}" && "$running_revision" != "$latest_revision" ]]; then
                    log "New commit detected: ${running_revision:-missing} -> $latest_revision; deploying."
                    start_recovery false
                    sleep "$SETUP_CHECK_INTERVAL"
                    continue
                fi
            fi
        else
            log "Application process is busy but still running; recovery skipped."
        fi
    else
        # SSH itself uses exit code 255 when the connection disappears.
        (( health_result == 255 )) && key_update_needed=true
        log "Application is unhealthy; running recovery."
        start_recovery false
        sleep "$SETUP_CHECK_INTERVAL"
        continue
    fi

    sleep "$CHECK_INTERVAL"
done
