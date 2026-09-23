#!/usr/bin/env bash

# Runs inside the remote LXC when the watcher detects an unhealthy app.
# The script is safe to rerun: it updates the checkout, reuses the virtual
# environment, restarts the app, and verifies port 8015.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/REZ3LIET/OverSmart-Math-Solver.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
APP_DIR="${APP_DIR:-$HOME/OverSmart-Math-Solver}"
APP_HOST="${APP_HOST:-127.0.0.1}"
APP_PORT="${APP_PORT:-8015}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
FORCE_REBUILD_REPO="${FORCE_REBUILD_REPO:-false}"

STATE_DIR="$HOME/.check"
mkdir -p "$STATE_DIR"

log() {
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# Leave a useful remote signal if any setup command fails.
mark_failed() {
    printf 'failed\n' > "$STATE_DIR/status"
}
trap mark_failed ERR

printf 'recovering\n' > "$STATE_DIR/status"

# Stop the process recorded by a previous setup, if it is still running.
stop_recorded_app() {
    local pid_file="$APP_DIR/.runtime/app.pid"
    local old_pid

    [[ -r "$pid_file" ]] || return
    old_pid="$(<"$pid_file")"
    [[ "$old_pid" =~ ^[0-9]+$ ]] || return
    kill -0 "$old_pid" 2>/dev/null || return

    log "Stopping previous app process $old_pid."
    kill "$old_pid"
    for _ in {1..20}; do
        kill -0 "$old_pid" 2>/dev/null || return
        sleep 0.25
    done
}

# Install the small OS-level prerequisites on Ubuntu/Debian. Already-installed
# packages are skipped, so apt is normally used only on a fresh LXC.
printf 'build-system\n' > "$STATE_DIR/status"
packages=(git curl ca-certificates coreutils python3 python3-venv python3-pip)
missing_packages=()
for package in "${packages[@]}"; do
    dpkg -s "$package" >/dev/null 2>&1 || missing_packages+=("$package")
done

if (( ${#missing_packages[@]} > 0 )); then
    log "Installing system packages: ${missing_packages[*]}"
    if [[ "$(id -u)" == 0 ]]; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
    else
        sudo -n apt-get update
        sudo -n env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y "${missing_packages[@]}"
    fi
fi

# Clone on first setup; otherwise update the existing deployment checkout.
printf 'build-repo\n' > "$STATE_DIR/status"
if [[ "$FORCE_REBUILD_REPO" == true ]]; then
    # Restrict recursive deletion to an application directory below HOME.
    if [[ -z "$APP_DIR" || "$APP_DIR" == "$HOME" || "$APP_DIR" != "$HOME/"* ]]; then
        log "Refusing unsafe application directory: $APP_DIR"
        exit 1
    fi
    stop_recorded_app
    log "Removing existing application checkout."
    rm -rf -- "$APP_DIR"
fi

if [[ -d "$APP_DIR/.git" ]]; then
    log "Updating application checkout."
    git -C "$APP_DIR" fetch --depth 1 origin "$REPO_BRANCH"
    git -C "$APP_DIR" checkout -B "$REPO_BRANCH" FETCH_HEAD
elif [[ -e "$APP_DIR" ]]; then
    log "$APP_DIR exists but is not a Git checkout; refusing to overwrite it."
    exit 1
else
    log "Cloning application."
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
fi

cd "$APP_DIR"

# Reuse the environment after the first setup. Reinstall only when the
# requirements file changes.
printf 'build-venv\n' > "$STATE_DIR/status"
if [[ ! -x .venv/bin/python ]] || ! .venv/bin/python -m pip --version >/dev/null 2>&1; then
    log "Creating or repairing Python virtual environment."
    "$PYTHON_BIN" -m venv --clear .venv
fi

requirements_hash="$(sha256sum requirements.txt | awk '{print $1}')"
installed_hash="$(cat .venv/.requirements.sha256 2>/dev/null || true)"
if [[ "$requirements_hash" != "$installed_hash" ]]; then
    printf 'build-dependencies\n' > "$STATE_DIR/status"
    log "Installing Python dependencies."
    .venv/bin/python -m pip install --disable-pip-version-check -r requirements.txt
    printf '%s\n' "$requirements_hash" > .venv/.requirements.sha256
fi

# Keep the PID and application output together in a disposable runtime folder.
mkdir -p .runtime
pid_file="$APP_DIR/.runtime/app.pid"
log_file="$APP_DIR/.runtime/app.log"

stop_recorded_app

printf 'build-app\n' > "$STATE_DIR/status"
log "Starting Gradio on $APP_HOST:$APP_PORT."
nohup env \
    GRADIO_SERVER_NAME="$APP_HOST" \
    GRADIO_SERVER_PORT="$APP_PORT" \
    .venv/bin/python app.py \
    > "$log_file" 2>&1 < /dev/null &
app_pid=$!
printf '%s\n' "$app_pid" > "$pid_file"

# Do not report successful recovery until Gradio answers on port 8015.
for _ in {1..60}; do
    if curl --fail --silent --max-time 1 \
        "http://$APP_HOST:$APP_PORT/" >/dev/null
    then
        printf 'healthy\n' > "$STATE_DIR/status"
        trap - ERR
        log "Application is healthy (PID $app_pid)."
        exit 0
    fi

    if ! kill -0 "$app_pid" 2>/dev/null; then
        log "Application exited during startup."
        tail -n 40 "$log_file" >&2 || true
        exit 1
    fi

    sleep 0.5
done

log "Application did not become healthy within 30 seconds."
tail -n 40 "$log_file" >&2 || true
exit 1
