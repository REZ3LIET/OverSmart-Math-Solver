#!/usr/bin/env bash

# Compares a true cold dependency/model build with transfer and extraction of
# the prepared deployment cache. The live application directory is untouched.

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
REPO_URL="${REPO_URL:-https://github.com/REZ3LIET/OverSmart-Math-Solver.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
KEEP_BENCHMARK_DATA="${KEEP_BENCHMARK_DATA:-false}"

safe_target="${WATCH_TARGET//[^A-Za-z0-9_.-]/_}"
SSH_IDENTITY_FILE="${SSH_IDENTITY_FILE:-$CREDENTIALS_DIR/${safe_target}_ed25519}"
[[ -r "$SSH_IDENTITY_FILE" ]] || {
    echo "SSH key is not readable: $SSH_IDENTITY_FILE" >&2
    exit 1
}
[[ -r "$DEPLOY_CACHE_ARCHIVE" ]] || {
    echo "Deployment cache is not readable: $DEPLOY_CACHE_ARCHIVE" >&2
    exit 1
}

ssh_options=(
    -o BatchMode=yes
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
    -p "$SSH_PORT"
    -i "$SSH_IDENTITY_FILE"
)
remote_archive="/tmp/osms-benchmark-runtime-cache.tar"

cleanup() {
    "$SSH_BIN" "${ssh_options[@]}" "$WATCH_TARGET" \
        "KEEP_BENCHMARK_DATA=$KEEP_BENCHMARK_DATA REMOTE_ARCHIVE=$remote_archive bash -s" <<'REMOTE_CLEANUP' >/dev/null 2>&1 || true
set -euo pipefail
rm -f -- "$REMOTE_ARCHIVE"
if [[ "$KEEP_BENCHMARK_DATA" != true ]]; then
    rm -rf -- "$HOME/.osms-deploy-benchmark"
fi
REMOTE_CLEANUP
}
trap cleanup EXIT

echo "Benchmark 1/2: fresh venv, uncached packages, and fresh model download."
"$SSH_BIN" "${ssh_options[@]}" "$WATCH_TARGET" \
    "REPO_URL=$REPO_URL REPO_BRANCH=$REPO_BRANCH bash -s" <<'REMOTE_BUILD'
set -euo pipefail

bench="$HOME/.osms-deploy-benchmark"
fresh="$bench/fresh"
[[ "$bench" == "$HOME/.osms-deploy-benchmark" ]] || exit 1
rm -rf -- "$bench"
mkdir -p "$fresh"

seconds_since() {
    awk -v start="$1" -v end="$(date +%s.%N)" 'BEGIN { printf "%.3f", end - start }'
}

total_started="$(date +%s.%N)"

stage_started="$(date +%s.%N)"
git clone --quiet --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$fresh/repo"
clone_seconds="$(seconds_since "$stage_started")"

stage_started="$(date +%s.%N)"
python3 -m venv "$fresh/repo/.venv"
venv_seconds="$(seconds_since "$stage_started")"

stage_started="$(date +%s.%N)"
"$fresh/repo/.venv/bin/python" -m pip install \
    --disable-pip-version-check --no-cache-dir --quiet \
    -r "$fresh/repo/requirements.txt"
pip_seconds="$(seconds_since "$stage_started")"

stage_started="$(date +%s.%N)"
HF_HOME="$fresh/huggingface" "$fresh/repo/.venv/bin/python" - <<'PY'
from huggingface_hub import snapshot_download

snapshot_download("unsloth/Qwen2.5-Coder-3B-Instruct-bnb-4bit")
PY
model_seconds="$(seconds_since "$stage_started")"
total_seconds="$(seconds_since "$total_started")"

printf 'FRESH clone_seconds=%s venv_seconds=%s pip_seconds=%s model_seconds=%s total_seconds=%s\n' \
    "$clone_seconds" "$venv_seconds" "$pip_seconds" "$model_seconds" "$total_seconds"
REMOTE_BUILD

echo "Benchmark 2/2: one SCP archive transfer and extraction."
cached_started="$(date +%s.%N)"
scp_started="$(date +%s.%N)"
"$SCP_BIN" \
    -o BatchMode=yes \
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
    -P "$SSH_PORT" \
    -i "$SSH_IDENTITY_FILE" \
    "$DEPLOY_CACHE_ARCHIVE" \
    "$WATCH_TARGET:$remote_archive"
scp_finished="$(date +%s.%N)"
scp_seconds="$(awk -v start="$scp_started" -v end="$scp_finished" 'BEGIN { printf "%.3f", end - start }')"

extract_seconds="$({
    "$SSH_BIN" "${ssh_options[@]}" "$WATCH_TARGET" \
        "REMOTE_ARCHIVE=$remote_archive bash -s" <<'REMOTE_EXTRACT'
set -euo pipefail

cached="$HOME/.osms-deploy-benchmark/cached"
rm -rf -- "$cached"
mkdir -p "$cached"
started="$(date +%s.%N)"
tar -C "$cached" -xf "$REMOTE_ARCHIVE"
"$cached/OverSmart-Math-Solver/.venv/bin/python" -m pip --version >/dev/null
find -L \
    "$cached/.cache/huggingface/hub/models--unsloth--Qwen2.5-Coder-3B-Instruct-bnb-4bit/snapshots" \
    -type f -name model.safetensors -print -quit | grep -q .
awk -v start="$started" -v end="$(date +%s.%N)" 'BEGIN { printf "%.3f", end - start }'
REMOTE_EXTRACT
})"
cached_finished="$(date +%s.%N)"
cached_total_seconds="$(awk -v start="$cached_started" -v end="$cached_finished" 'BEGIN { printf "%.3f", end - start }')"

printf 'CACHED scp_seconds=%s extract_seconds=%s total_seconds=%s\n' \
    "$scp_seconds" "$extract_seconds" "$cached_total_seconds"
