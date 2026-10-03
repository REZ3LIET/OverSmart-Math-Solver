#!/usr/bin/env bash

# Exercises watcher decisions without connecting to a real machine.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHER="$REPO_ROOT/bash/external_watcher.sh"
FAKE_SSH="$REPO_ROOT/tests/fixtures/fake_ssh.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

bootstrap_key="$test_dir/bootstrap_ed25519"
credentials_dir="$test_dir/credentials"
env_file="$test_dir/watcher.env"
resource_log="$test_dir/resources.csv"
ssh-keygen -q -t ed25519 -N '' -f "$bootstrap_key"

printf '%s\n' \
    'WATCH_TARGET=user@fake-host' \
    "RECOVERY_SCRIPT=$REPO_ROOT/bash/setup.sh" \
    "BOOTSTRAP_SSH_IDENTITY_FILE=$bootstrap_key" \
    'SSH_PORT=22015' \
    "CREDENTIALS_DIR=$credentials_dir" \
    'SSH_STRICT_HOST_KEY_CHECKING=no' \
    'CHECK_INTERVAL=0.05' \
    'SETUP_CHECK_INTERVAL=0.05' \
    'DEPLOY_CHECK_INTERVAL=99999' \
    'SSH_RETRY_INTERVAL=0.05' \
    'SSH_CONNECT_TIMEOUT=1' \
    'SSH_CONTROL_PERSIST=1' \
    "SSH_BIN=$FAKE_SSH" \
    "RESOURCE_LOG_FILE=$resource_log" \
    'DISCORD_WEBHOOK_URL=' \
    > "$env_file"

run_case() {
    local health="$1"
    local output="$2"
    local exit_code

    set +e
    FAKE_PROBE_HEALTH="$health" timeout 1 \
        env ENV_FILE="$env_file" bash "$WATCHER" > "$output" 2>&1
    exit_code=$?
    set -e
    [[ "$exit_code" == 124 ]]
}

healthy_log="$test_dir/healthy.log"
run_case healthy "$healthy_log"
grep -q 'SSH connected using the bootstrap key.' "$healthy_log"
grep -q 'Remote access updated; active key:' "$healthy_log"
grep -q 'Application is healthy.' "$healthy_log"

busy_log="$test_dir/busy.log"
run_case busy "$busy_log"
grep -q 'SSH connected using the stable key.' "$busy_log"
grep -q 'Application process is busy but still running; recovery skipped.' "$busy_log"
! grep -q 'Application is unhealthy' "$busy_log"

missing_log="$test_dir/missing.log"
run_case missing "$missing_log"
grep -q 'Application is unhealthy; running recovery.' "$missing_log"
grep -q 'Recovery completed in' "$missing_log"

[[ -s "$resource_log" ]]
[[ -r "$credentials_dir/user_fake-host_ed25519" ]]

printf 'Watcher control-flow tests passed.\n'

