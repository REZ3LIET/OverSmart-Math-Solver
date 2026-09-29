#!/usr/bin/env bash

# Runs on the external monitoring machine.
# It waits for SSH, checks the remote health signal, and sends setup.sh when
# recovery is needed.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${ENV_FILE:-$SCRIPT_DIR/../.env}"

: "${WATCH_TARGET:?Set WATCH_TARGET in .env}"
: "${RECOVERY_SCRIPT:?Set RECOVERY_SCRIPT in .env}"
: "${BOOTSTRAP_SSH_IDENTITY_FILE:?Set BOOTSTRAP_SSH_IDENTITY_FILE in .env}"

SSH_PORT="${SSH_PORT:-22}"
CHECK_INTERVAL="${CHECK_INTERVAL:-2}"
SETUP_CHECK_INTERVAL="${SETUP_CHECK_INTERVAL:-15}"
DEPLOY_CHECK_INTERVAL="${DEPLOY_CHECK_INTERVAL:-30}"
SSH_RETRY_INTERVAL="${SSH_RETRY_INTERVAL:-1}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-2}"
CREDENTIALS_DIR="${CREDENTIALS_DIR:-$HOME/.ssh/osms-recovery}"
SSH_STRICT_HOST_KEY_CHECKING="${SSH_STRICT_HOST_KEY_CHECKING:-accept-new}"
SSH_KNOWN_HOSTS_FILE="${SSH_KNOWN_HOSTS_FILE:-$CREDENTIALS_DIR/known_hosts}"
SSH_DIAGNOSTIC_INTERVAL="${SSH_DIAGNOSTIC_INTERVAL:-5}"
DEPLOY_CACHE_ARCHIVE="${DEPLOY_CACHE_ARCHIVE:-}"
USE_DEPLOY_CACHE="${USE_DEPLOY_CACHE:-false}"
UPDATE_SSH_KEY_ON_FIRST_PING="${UPDATE_SSH_KEY_ON_FIRST_PING:-true}"
DEFAULT_HEALTH_COMMAND='if curl --fail --silent --max-time 2 http://127.0.0.1:8015/healthz >/dev/null || curl --fail --silent --max-time 2 http://127.0.0.1:8015/ >/dev/null; then printf healthy; else pid=$(cat "$HOME/OverSmart-Math-Solver/.runtime/app.pid" 2>/dev/null || true); test -n "$pid" && kill -0 "$pid" 2>/dev/null && printf busy; fi'
REMOTE_HEALTH_COMMAND="${REMOTE_HEALTH_COMMAND:-$DEFAULT_HEALTH_COMMAND}"
DEFAULT_STATUS_COMMAND='cat "$HOME/.check/status" 2>/dev/null || printf missing'
REMOTE_STATUS_COMMAND="${REMOTE_STATUS_COMMAND:-$DEFAULT_STATUS_COMMAND}"
SSH_BIN="${SSH_BIN:-ssh}"
SCP_BIN="${SCP_BIN:-scp}"
CURL_BIN="${CURL_BIN:-curl}"
SSH_MULTIPLEXING="${SSH_MULTIPLEXING:-true}"
SSH_CONTROL_PERSIST="${SSH_CONTROL_PERSIST:-60}"
CPU_THRESHOLD="${CPU_THRESHOLD:-80}"
MEMORY_THRESHOLD="${MEMORY_THRESHOLD:-80}"
GPU_THRESHOLD="${GPU_THRESHOLD:-80}"
GPU_MEMORY_THRESHOLD="${GPU_MEMORY_THRESHOLD:-80}"
RESOURCE_ALERT_COOLDOWN="${RESOURCE_ALERT_COOLDOWN:-60}"
RECOVERY_ALERT_COOLDOWN="${RECOVERY_ALERT_COOLDOWN:-300}"
RESOURCE_LOG_FILE="${RESOURCE_LOG_FILE:-$SCRIPT_DIR/../logs/resource_usage.csv}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
DISCORD_USERNAME="${DISCORD_USERNAME:-OSMS Watcher}"
OSMS_MODEL_NAME="${OSMS_MODEL_NAME:-Qwen/Qwen2.5-0.5B-Instruct}"
OSMS_PRELOAD_LOCAL_MODEL="${OSMS_PRELOAD_LOCAL_MODEL:-true}"

# Keep watcher host keys separate from the user's normal SSH configuration.
mkdir -p "$CREDENTIALS_DIR"
chmod 700 "$CREDENTIALS_DIR"
touch "$SSH_KNOWN_HOSTS_FILE"
chmod 600 "$SSH_KNOWN_HOSTS_FILE"
ssh_host_options=(
    -o "StrictHostKeyChecking=$SSH_STRICT_HOST_KEY_CHECKING"
    -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS_FILE"
)

# Multiplexing keeps one authenticated transport alive. Later SSH/SCP commands
# open lightweight channels over it instead of repeating a full handshake.
ssh_control_options=()
if [[ "$SSH_MULTIPLEXING" == true ]]; then
    SSH_CONTROL_DIR="${SSH_CONTROL_DIR:-$CREDENTIALS_DIR/ssh-control}"
    mkdir -p "$SSH_CONTROL_DIR"
    chmod 700 "$SSH_CONTROL_DIR"
    ssh_control_options=(
        -o ControlMaster=auto
        -o ControlPersist="$SSH_CONTROL_PERSIST"
        -o ControlPath="$SSH_CONTROL_DIR/%C"
    )
fi

# Resolve repository-relative script and key paths. This makes the watcher
# independent of the directory from which it is launched.
[[ "$RECOVERY_SCRIPT" = /* ]] || RECOVERY_SCRIPT="$SCRIPT_DIR/../$RECOVERY_SCRIPT"
[[ "$BOOTSTRAP_SSH_IDENTITY_FILE" = /* ]] || \
    BOOTSTRAP_SSH_IDENTITY_FILE="$SCRIPT_DIR/../$BOOTSTRAP_SSH_IDENTITY_FILE"
KEY_UPDATE_SCRIPT="$SCRIPT_DIR/update_ssh_key.sh"

log() {
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

send_discord_notification() {
    local message="$1"
    local payload

    [[ -n "$DISCORD_WEBHOOK_URL" ]] || return 0
    if ! payload="$(python3 - "$message" "$DISCORD_USERNAME" <<'PY'
import json
import sys

print(json.dumps({"content": sys.argv[1][:1900], "username": sys.argv[2]}))
PY
    )"; then
        log "Discord notification encoding failed."
        return 1
    fi

    # Feed the URL through curl's stdin config so the secret is not exposed in
    # the process command line. Discord webhook URLs contain URL-safe text.
    if ! printf 'url = "%s"\n' "$DISCORD_WEBHOOK_URL" | "$CURL_BIN" \
        --config - \
        --fail \
        --silent \
        --show-error \
        --max-time 5 \
        -H 'Content-Type: application/json' \
        --data-binary "$payload" \
        >/dev/null
    then
        log "Discord notification delivery failed."
        return 1
    fi
}

if [[ "${1:-}" == "--test-discord" ]]; then
    if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
        log "DISCORD_WEBHOOK_URL is not configured."
        exit 1
    fi
    if send_discord_notification "OSMS watcher test notification for $WATCH_TARGET"; then
        log "Discord test notification delivered."
        exit 0
    fi
    exit 1
elif (( $# > 0 )); then
    log "Unknown argument: $1"
    exit 2
fi

# Run one command on the remote machine using the requested private key.
remote() {
    local key="$1"
    shift
    "$SSH_BIN" \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
        "${ssh_host_options[@]}" \
        "${ssh_control_options[@]}" \
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
last_resource_alert=0
last_recovery_alert=0
previous_cpu_total=""
previous_cpu_idle=""
previous_cpu_usage_usec=""
previous_cpu_sample_ns=""

[[ "$RESOURCE_LOG_FILE" = /* ]] || RESOURCE_LOG_FILE="$SCRIPT_DIR/../$RESOURCE_LOG_FILE"
mkdir -p "$(dirname -- "$RESOURCE_LOG_FILE")"
if [[ ! -e "$RESOURCE_LOG_FILE" ]]; then
    printf 'timestamp,cpu_percent,memory_percent,gpu_percent,gpu_memory_percent,status,health\n' \
        > "$RESOURCE_LOG_FILE"
fi

# Try the stable key first. A rebuilt LXC falls back to its original key.
wait_for_ssh() {
    local retry_count=0
    local ssh_error=""

    while true; do
        if ssh_error="$(remote "$active_key" true 2>&1)"; then
            working_key="$active_key"
            if [[ "$working_key" == "$stable_key" ]]; then
                log "SSH connected using the stable key."
            else
                log "SSH connected using the bootstrap key."
            fi
            return
        fi

        if [[ "$bootstrap_key" != "$active_key" && -r "$bootstrap_key" ]]; then
            if ssh_error="$(remote "$bootstrap_key" true 2>&1)"; then
                working_key="$bootstrap_key"
                log "Stable key was unavailable; SSH connected using the bootstrap key."
                return
            fi
        fi

        key_update_needed=true
        log "SSH is not ready; retrying."
        (( retry_count += 1 ))
        if (( retry_count == 1 || retry_count % SSH_DIAGNOSTIC_INTERVAL == 0 )); then
            ssh_error="$(tail -n 1 <<< "$ssh_error")"
            [[ -n "$ssh_error" ]] && log "SSH detail: $ssh_error"
        fi
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
        SSH_STRICT_HOST_KEY_CHECKING="$SSH_STRICT_HOST_KEY_CHECKING" \
        SSH_KNOWN_HOSTS_FILE="$SSH_KNOWN_HOSTS_FILE" \
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

# Collect status, health, and (when requested) Git revisions through one SSH
# session. Fixed key=value lines keep parsing simple on the watcher side.
probe_remote() {
    local check_revision="$1"
    local quoted_health_command quoted_status_command

    printf -v quoted_health_command '%q' "$REMOTE_HEALTH_COMMAND"
    printf -v quoted_status_command '%q' "$REMOTE_STATUS_COMMAND"

    remote "$working_key" \
        "CHECK_REVISION=$check_revision HEALTH_COMMAND=$quoted_health_command STATUS_COMMAND=$quoted_status_command bash -s" \
        <<'REMOTE_PROBE'
set -u

remote_status="$(bash -c "$STATUS_COMMAND" 2>/dev/null || printf missing)"
if health_signal="$(bash -c "$HEALTH_COMMAND" 2>/dev/null)"; then
    health_signal="${health_signal:-healthy}"
else
    health_signal=missing
fi

running_revision=""
latest_revision=""
if [[ "$CHECK_REVISION" == true ]]; then
    app="$HOME/OverSmart-Math-Solver"
    running_revision="$(cat "$app/.runtime/app.commit" 2>/dev/null || printf missing)"
    latest_revision="$(
        git -C "$app" ls-remote origin refs/heads/main 2>/dev/null |
            awk 'NR == 1 { print $1 }'
    )"
fi

read -r cpu_total cpu_idle < <(
    awk '/^cpu / {
        total = 0
        for (field = 2; field <= NF; field++) total += $field
        print total, $5 + $6
        exit
    }' /proc/stat
)
cpu_usage_usec=unavailable
if [[ -r /sys/fs/cgroup/cpu.stat ]]; then
    cpu_usage_usec="$(awk '$1 == "usage_usec" { print $2 }' /sys/fs/cgroup/cpu.stat)"
fi
cpu_sample_ns="$(date +%s%N)"
cpu_capacity="$(nproc)"
memory_percent="$(
    awk '
        /MemTotal:/ { total = $2 }
        /MemAvailable:/ { available = $2 }
        END {
            if (total > 0) printf "%.1f", (total - available) * 100 / total
            else printf "unavailable"
        }
    ' /proc/meminfo
)"

gpu_percent=unavailable
gpu_memory_percent=unavailable
if command -v nvidia-smi >/dev/null 2>&1; then
    gpu_line="$(
        nvidia-smi \
            --query-gpu=utilization.gpu,memory.used,memory.total \
            --format=csv,noheader,nounits 2>/dev/null |
            awk 'NR == 1 { gsub(/ /, ""); print }'
    )"
    if [[ -n "$gpu_line" ]]; then
        IFS=, read -r gpu_percent gpu_memory_used gpu_memory_total <<< "$gpu_line"
        gpu_memory_percent="$(
            awk -v used="$gpu_memory_used" -v total="$gpu_memory_total" \
                'BEGIN { if (total > 0) printf "%.1f", used * 100 / total; else print "unavailable" }'
        )"
    fi
fi

printf 'remote_status=%s\n' "$remote_status"
printf 'health_signal=%s\n' "$health_signal"
printf 'running_revision=%s\n' "$running_revision"
printf 'latest_revision=%s\n' "$latest_revision"
printf 'cpu_total=%s\n' "$cpu_total"
printf 'cpu_idle=%s\n' "$cpu_idle"
printf 'cpu_usage_usec=%s\n' "$cpu_usage_usec"
printf 'cpu_sample_ns=%s\n' "$cpu_sample_ns"
printf 'cpu_capacity=%s\n' "$cpu_capacity"
printf 'memory_percent=%s\n' "$memory_percent"
printf 'gpu_percent=%s\n' "$gpu_percent"
printf 'gpu_memory_percent=%s\n' "$gpu_memory_percent"
REMOTE_PROBE
}

# Parse one combined probe. A nonzero result means SSH/probing failed, not that
# the application is unhealthy.
collect_probe() {
    local check_revision="$1"
    local probe_output key value

    remote_status=missing
    health_signal=missing
    running_revision=""
    latest_revision=""
    cpu_total=""
    cpu_idle=""
    cpu_usage_usec=unavailable
    cpu_sample_ns=""
    cpu_capacity=1
    memory_percent=unavailable
    gpu_percent=unavailable
    gpu_memory_percent=unavailable

    if ! probe_output="$(probe_remote "$check_revision")"; then
        return 1
    fi

    while IFS='=' read -r key value; do
        case "$key" in
            remote_status) remote_status="$value" ;;
            health_signal) health_signal="$value" ;;
            running_revision) running_revision="$value" ;;
            latest_revision) latest_revision="$value" ;;
            cpu_total) cpu_total="$value" ;;
            cpu_idle) cpu_idle="$value" ;;
            cpu_usage_usec) cpu_usage_usec="$value" ;;
            cpu_sample_ns) cpu_sample_ns="$value" ;;
            cpu_capacity) cpu_capacity="$value" ;;
            memory_percent) memory_percent="$value" ;;
            gpu_percent) gpu_percent="$value" ;;
            gpu_memory_percent) gpu_memory_percent="$value" ;;
        esac
    done <<< "$probe_output"
}

threshold_exceeded() {
    local value="$1"
    local threshold="$2"

    [[ "$value" != unavailable && -n "$value" ]] || return 1
    awk -v value="$value" -v threshold="$threshold" \
        'BEGIN { exit !(value > threshold) }'
}

record_resources() {
    local timestamp now total_delta idle_delta usage_delta elapsed_usec
    local cpu_percent=unavailable
    local warnings=()

    if [[ "$cpu_usage_usec" != unavailable && -n "$previous_cpu_usage_usec" ]]; then
        usage_delta=$(( cpu_usage_usec - previous_cpu_usage_usec ))
        elapsed_usec="$(
            awk -v current="$cpu_sample_ns" -v previous="$previous_cpu_sample_ns" \
                'BEGIN { printf "%.0f", (current - previous) / 1000 }'
        )"
        if (( elapsed_usec > 0 && cpu_capacity > 0 )); then
            cpu_percent="$(
                awk -v usage="$usage_delta" -v elapsed="$elapsed_usec" \
                    -v capacity="$cpu_capacity" \
                    'BEGIN { printf "%.1f", usage * 100 / (elapsed * capacity) }'
            )"
        fi
    elif [[ -n "$previous_cpu_total" && -n "$cpu_total" ]]; then
        total_delta=$(( cpu_total - previous_cpu_total ))
        idle_delta=$(( cpu_idle - previous_cpu_idle ))
        if (( total_delta > 0 )); then
            cpu_percent="$(
                awk -v total="$total_delta" -v idle="$idle_delta" \
                    'BEGIN { printf "%.1f", (total - idle) * 100 / total }'
            )"
        fi
    fi
    previous_cpu_total="$cpu_total"
    previous_cpu_idle="$cpu_idle"
    if [[ "$cpu_usage_usec" != unavailable ]]; then
        previous_cpu_usage_usec="$cpu_usage_usec"
        previous_cpu_sample_ns="$cpu_sample_ns"
    fi

    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$timestamp" "$cpu_percent" "$memory_percent" "$gpu_percent" \
        "$gpu_memory_percent" "$remote_status" "$health_signal" \
        >> "$RESOURCE_LOG_FILE"

    log "Resources: CPU ${cpu_percent}%; memory ${memory_percent}%; GPU ${gpu_percent}%; GPU memory ${gpu_memory_percent}%."

    threshold_exceeded "$cpu_percent" "$CPU_THRESHOLD" && \
        warnings+=("CPU ${cpu_percent}% > ${CPU_THRESHOLD}%")
    threshold_exceeded "$memory_percent" "$MEMORY_THRESHOLD" && \
        warnings+=("memory ${memory_percent}% > ${MEMORY_THRESHOLD}%")
    threshold_exceeded "$gpu_percent" "$GPU_THRESHOLD" && \
        warnings+=("GPU ${gpu_percent}% > ${GPU_THRESHOLD}%")
    threshold_exceeded "$gpu_memory_percent" "$GPU_MEMORY_THRESHOLD" && \
        warnings+=("GPU memory ${gpu_memory_percent}% > ${GPU_MEMORY_THRESHOLD}%")

    now="$(date +%s)"
    if (( ${#warnings[@]} > 0 && now - last_resource_alert >= RESOURCE_ALERT_COOLDOWN )); then
        log "RESOURCE WARNING: ${warnings[*]}"
        send_discord_notification \
            "OSMS resource warning on $WATCH_TARGET: ${warnings[*]}" || true
        last_resource_alert="$now"
    fi
}

mark_ssh_lost() {
    key_update_needed=true
    working_key=""
    log "SSH connection was lost; returning to connection retries."
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
        "${ssh_host_options[@]}" \
        "${ssh_control_options[@]}" \
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
    local quoted_model_name quoted_preload

    printf -v quoted_model_name '%q' "$OSMS_MODEL_NAME"
    printf -v quoted_preload '%q' "$OSMS_PRELOAD_LOCAL_MODEL"

    sync_deploy_cache "$force_rebuild"
    if [[ -n "$recovery_cache_archive" ]]; then
        remote "$working_key" \
            "FORCE_REBUILD_REPO=$force_rebuild DEPLOY_CACHE_ARCHIVE=$recovery_cache_archive DEPLOY_CACHE_CHECKSUM=$recovery_cache_checksum OSMS_MODEL_NAME=$quoted_model_name OSMS_PRELOAD_LOCAL_MODEL=$quoted_preload bash -s" \
            < "$RECOVERY_SCRIPT"
    else
        remote "$working_key" \
            "FORCE_REBUILD_REPO=$force_rebuild OSMS_MODEL_NAME=$quoted_model_name OSMS_PRELOAD_LOCAL_MODEL=$quoted_preload bash -s" \
            < "$RECOVERY_SCRIPT"
    fi
}

start_recovery() {
    recovery_started_epoch="$(date +%s)"
    run_recovery "$1" &
    recovery_pid=$!
}

while true; do
    [[ -n "$working_key" ]] || wait_for_ssh

    if [[ "$key_update_needed" == true && "$UPDATE_SSH_KEY_ON_FIRST_PING" == true ]]; then
        update_remote_access
    fi

    # A setup runs in the background so the watcher can report on it, but only
    # one setup is allowed at a time. Check it less often than normal health.
    if [[ -n "$recovery_pid" ]]; then
        if kill -0 "$recovery_pid" 2>/dev/null; then
            if ! collect_probe false; then
                mark_ssh_lost
                sleep "$SSH_RETRY_INTERVAL"
                continue
            fi
            record_resources
            log "Setup is running; status: ${remote_status:-missing}; health: ${health_signal:-missing}"
            sleep "$SETUP_CHECK_INTERVAL"
            continue
        fi

        if wait "$recovery_pid"; then
            log "Recovery completed in $(( $(date +%s) - recovery_started_epoch )) seconds."
        else
            log "Recovery failed after $(( $(date +%s) - recovery_started_epoch )) seconds; returning to $CHECK_INTERVAL-second checks."
            now="$(date +%s)"
            if (( now - last_recovery_alert >= RECOVERY_ALERT_COOLDOWN )); then
                send_discord_notification \
                    "OSMS recovery failed on $WATCH_TARGET; the watcher will retry." || true
                last_recovery_alert="$now"
            fi
        fi
        recovery_pid=""
        sleep "$CHECK_INTERVAL"
        continue
    fi

    now="$(date +%s)"
    check_revision=false
    (( now - last_deploy_check >= DEPLOY_CHECK_INTERVAL )) && check_revision=true

    if ! collect_probe "$check_revision"; then
        mark_ssh_lost
        sleep "$SSH_RETRY_INTERVAL"
        continue
    fi
    record_resources

    # Writing build-repo to the remote status file requests a clean checkout.
    if [[ "$remote_status" == "build-repo" ]]; then
        log "Clean repository rebuild requested."
        start_recovery true
        sleep "$SETUP_CHECK_INTERVAL"
        continue
    fi

    log "Remote status: ${remote_status:-missing}; health: ${health_signal:-missing}"

    if [[ "$health_signal" == "healthy" ]]; then
        log "Application is healthy."

        # Revision data was included in this same probe when its timer was due.
        if [[ "$check_revision" == true ]]; then
            last_deploy_check="$now"
            if [[ -n "$latest_revision" && "$running_revision" != "$latest_revision" ]]; then
                log "New commit detected: ${running_revision:-missing} -> $latest_revision; deploying."
                start_recovery false
                sleep "$SETUP_CHECK_INTERVAL"
                continue
            fi
        fi
    elif [[ "$health_signal" == "busy" ]]; then
        log "Application process is busy but still running; recovery skipped."
    else
        log "Application is unhealthy; running recovery."
        start_recovery false
        sleep "$SETUP_CHECK_INTERVAL"
        continue
    fi

    sleep "$CHECK_INTERVAL"
done
