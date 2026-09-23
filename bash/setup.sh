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

# The base LXC must provide these small system-level tools.
for command in git "$PYTHON_BIN" curl sha256sum; do
    command -v "$command" >/dev/null || {
        log "Missing required command: $command"
        exit 1
    }
done

# Clone on first setup; otherwise update the existing deployment checkout.
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
if [[ ! -x .venv/bin/python ]]; then
    log "Creating Python virtual environment."
    "$PYTHON_BIN" -m venv .venv
fi

requirements_hash="$(sha256sum requirements.txt | awk '{print $1}')"
installed_hash="$(cat .venv/.requirements.sha256 2>/dev/null || true)"
if [[ "$requirements_hash" != "$installed_hash" ]]; then
    log "Installing Python dependencies."
    .venv/bin/python -m pip install --disable-pip-version-check -r requirements.txt
    printf '%s\n' "$requirements_hash" > .venv/.requirements.sha256
fi

# Keep the PID and application output together in a disposable runtime folder.
mkdir -p .runtime
pid_file="$APP_DIR/.runtime/app.pid"
log_file="$APP_DIR/.runtime/app.log"

if [[ -r "$pid_file" ]]; then
    old_pid="$(<"$pid_file")"
    if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
        log "Stopping previous app process $old_pid."
        kill "$old_pid"
        for _ in {1..20}; do
            kill -0 "$old_pid" 2>/dev/null || break
            sleep 0.25
        done
    fi
fi

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
