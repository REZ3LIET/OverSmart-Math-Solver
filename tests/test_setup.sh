#!/usr/bin/env bash

# Verifies setup state transitions and runtime markers in an isolated HOME.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$REPO_ROOT/bash/setup.sh"
FAKE_COMMAND="$REPO_ROOT/tests/fixtures/fake_remote_command.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

fake_bin="$test_dir/bin"
app_dir="$test_dir/home/OverSmart-Math-Solver"
mkdir -p "$fake_bin" "$app_dir/.git" "$app_dir/.venv/bin"
for command_name in dpkg git curl; do
    ln -s "$FAKE_COMMAND" "$fake_bin/$command_name"
done
ln -s "$FAKE_COMMAND" "$app_dir/.venv/bin/python"

printf 'transformers\n' > "$app_dir/requirements.txt"
requirements_hash="$(sha256sum "$app_dir/requirements.txt" | awk '{print $1}')"
printf '%s\n' "$requirements_hash" > "$app_dir/.venv/.requirements.sha256"
printf '# fixture\n' > "$app_dir/app.py"

HOME="$test_dir/home" \
PATH="$fake_bin:$PATH" \
APP_DIR="$app_dir" \
APP_START_TIMEOUT=2 \
OSMS_MODEL_NAME='Qwen/Qwen2.5-0.5B-Instruct' \
FAKE_APP_ENV_LOG="$test_dir/app-environment.log" \
FAKE_CURL_LOG="$test_dir/curl.log" \
bash "$SETUP" > "$test_dir/setup.log" 2>&1

[[ "$(<"$test_dir/home/.check/status")" == healthy ]]
[[ "$(<"$app_dir/.runtime/app.commit")" == test-revision ]]
[[ "$(<"$app_dir/.runtime/app.model")" == Qwen/Qwen2.5-0.5B-Instruct ]]
grep -Fxq "capacity_file=$test_dir/home/.check/capacity" "$test_dir/app-environment.log"
grep -Fxq 'server_port=7860' "$test_dir/app-environment.log"
grep -q 'http://127.0.0.1:7860/healthz' "$test_dir/curl.log"
app_pid="$(<"$app_dir/.runtime/app.pid")"
kill -0 "$app_pid"
kill "$app_pid"

grep -q 'Using repository commit test-re.' "$test_dir/setup.log"
grep -q 'Application is healthy' "$test_dir/setup.log"

assert_rebuild_rejected() {
    local name="$1"
    local case_home="$2"
    local unsafe_app_dir="$3"
    local marker="$4"
    local exit_code

    set +e
    HOME="$case_home" \
    PATH="$fake_bin:$PATH" \
    APP_DIR="$unsafe_app_dir" \
    FORCE_REBUILD_REPO=true \
    bash "$SETUP" > "$test_dir/$name.log" 2>&1
    exit_code=$?
    set -e

    [[ "$exit_code" -ne 0 ]]
    grep -q 'Refusing unsafe application directory' "$test_dir/$name.log"
    [[ -e "$marker" ]]
}

home_case="$test_dir/reject-home/home"
mkdir -p "$home_case"
touch "$home_case/keep"
assert_rebuild_rejected home "$home_case" "$home_case" "$home_case/keep"

traversal_home="$test_dir/reject-traversal/home"
traversal_target="$test_dir/reject-traversal/outside"
mkdir -p "$traversal_home/app" "$traversal_target"
touch "$traversal_target/keep"
assert_rebuild_rejected \
    traversal \
    "$traversal_home" \
    "$traversal_home/app/../../outside" \
    "$traversal_target/keep"

symlink_home="$test_dir/reject-symlink/home"
symlink_target="$test_dir/reject-symlink/target"
mkdir -p "$symlink_home" "$symlink_target"
touch "$symlink_target/keep"
ln -s "$symlink_target" "$symlink_home/OverSmart-Math-Solver"
assert_rebuild_rejected \
    symlink \
    "$symlink_home" \
    "$symlink_home/OverSmart-Math-Solver" \
    "$symlink_target/keep"

valid_home="$test_dir/valid-rebuild/home"
valid_app="$valid_home/OverSmart-Math-Solver"
mkdir -p "$valid_app/.git"
touch "$valid_app/old-checkout-marker"
HOME="$valid_home" \
PATH="$fake_bin:$PATH" \
APP_DIR="$valid_app" \
APP_START_TIMEOUT=2 \
FORCE_REBUILD_REPO=true \
FAKE_APP_ENV_LOG="$test_dir/rebuild-app-environment.log" \
FAKE_CURL_LOG="$test_dir/rebuild-curl.log" \
bash "$SETUP" > "$test_dir/valid-rebuild.log" 2>&1
[[ ! -e "$valid_app/old-checkout-marker" ]]
[[ "$(<"$valid_home/.check/status")" == healthy ]]
rebuild_pid="$(<"$valid_app/.runtime/app.pid")"
kill -0 "$rebuild_pid"
kill "$rebuild_pid"

printf 'Setup control-flow test passed.\n'
