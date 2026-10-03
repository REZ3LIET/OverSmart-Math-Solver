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
bash "$SETUP" > "$test_dir/setup.log" 2>&1

[[ "$(<"$test_dir/home/.check/status")" == healthy ]]
[[ "$(<"$app_dir/.runtime/app.commit")" == test-revision ]]
[[ "$(<"$app_dir/.runtime/app.model")" == Qwen/Qwen2.5-0.5B-Instruct ]]
app_pid="$(<"$app_dir/.runtime/app.pid")"
kill -0 "$app_pid"
kill "$app_pid"

grep -q 'Using repository commit test-re.' "$test_dir/setup.log"
grep -q 'Application is healthy' "$test_dir/setup.log"
printf 'Setup control-flow test passed.\n'
