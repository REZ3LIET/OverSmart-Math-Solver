#!/usr/bin/env bash

# Run this on the external watcher machine after one LXC has a working virtual
# environment and a fully downloaded local model. It creates one trusted cache
# archive that future rebuilt containers can restore instead of downloading.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${ENV_FILE:-$SCRIPT_DIR/../.env}"

: "${WATCH_TARGET:?Set WATCH_TARGET in .env}"
: "${DEPLOY_CACHE_ARCHIVE:?Set DEPLOY_CACHE_ARCHIVE in .env}"

SSH_PORT="${SSH_PORT:-22}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-5}"
CREDENTIALS_DIR="${CREDENTIALS_DIR:-$HOME/.ssh/osms-recovery}"
SSH_BIN="${SSH_BIN:-ssh}"
SCP_BIN="${SCP_BIN:-scp}"

safe_target="${WATCH_TARGET//[^A-Za-z0-9_.-]/_}"
SSH_IDENTITY_FILE="${SSH_IDENTITY_FILE:-$CREDENTIALS_DIR/${safe_target}_ed25519}"
[[ -r "$SSH_IDENTITY_FILE" ]] || {
    echo "SSH key is not readable: $SSH_IDENTITY_FILE" >&2
    exit 1
}

mkdir -p "$(dirname -- "$DEPLOY_CACHE_ARCHIVE")"
remote_archive="/tmp/osms-runtime-cache.tar"
temporary_archive="$(mktemp "$(dirname -- "$DEPLOY_CACHE_ARCHIVE")/.osms-runtime-cache.XXXXXX")"

cleanup() {
    rm -f -- "$temporary_archive"
    "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
        -p "$SSH_PORT" -i "$SSH_IDENTITY_FILE" "$WATCH_TARGET" \
        "rm -f -- $remote_archive" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ssh_options=(
    -o BatchMode=yes
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
    -p "$SSH_PORT"
    -i "$SSH_IDENTITY_FILE"
)

echo "Building deployment cache on $WATCH_TARGET."
"$SSH_BIN" "${ssh_options[@]}" "$WATCH_TARGET" "REMOTE_ARCHIVE=$remote_archive bash -s" <<'REMOTE'
set -euo pipefail

app_venv="$HOME/OverSmart-Math-Solver/.venv"
model_cache="$HOME/.cache/huggingface/hub/models--unsloth--Qwen2.5-Coder-3B-Instruct-bnb-4bit"
shared_blobs="$HOME/.cache/huggingface/hub/blobs"

[[ -x "$app_venv/bin/python" ]] || {
    echo "Remote virtual environment is missing." >&2
    exit 1
}
[[ -d "$model_cache/snapshots" ]] || {
    echo "Remote local-model cache is missing." >&2
    exit 1
}
if find "$model_cache" -type f -name '*.incomplete' -print -quit | grep -q .; then
    echo "Remote local-model cache contains an incomplete download." >&2
    exit 1
fi
find -L "$model_cache/snapshots" -type f -name model.safetensors -print -quit | \
    grep -q . || {
        echo "Remote model weights have a missing symlink target." >&2
        exit 1
    }
[[ -d "$shared_blobs" ]] || {
    echo "Remote shared Hugging Face blob cache is missing." >&2
    exit 1
}

rm -f -- "$REMOTE_ARCHIVE"
tar -C "$HOME" -cf "$REMOTE_ARCHIVE" \
    OverSmart-Math-Solver/.venv \
    .cache/huggingface/hub/models--unsloth--Qwen2.5-Coder-3B-Instruct-bnb-4bit \
    .cache/huggingface/hub/blobs
REMOTE

echo "Copying deployment cache to $DEPLOY_CACHE_ARCHIVE."
"$SCP_BIN" \
    -o BatchMode=yes \
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
    -P "$SSH_PORT" \
    -i "$SSH_IDENTITY_FILE" \
    "$WATCH_TARGET:$remote_archive" \
    "$temporary_archive"

mv -- "$temporary_archive" "$DEPLOY_CACHE_ARCHIVE"
sha256sum "$DEPLOY_CACHE_ARCHIVE" > "$DEPLOY_CACHE_ARCHIVE.sha256"
echo "Deployment cache is ready: $DEPLOY_CACHE_ARCHIVE"
