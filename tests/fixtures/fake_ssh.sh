#!/usr/bin/env bash

# Minimal SSH stand-in for watcher control-flow tests. Key installation and
# recovery commands succeed; combined probes return deterministic remote state.

set -u

if [[ -n "${FAKE_SSH_LOG:-}" ]]; then
    printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
fi

if [[ "$*" != *"CHECK_REVISION="* ]]; then
    exit 0
fi

health="${FAKE_PROBE_HEALTH:-healthy}"
printf '%s\n' \
    'remote_status=healthy' \
    "health_signal=$health" \
    'running_revision=test-revision' \
    'latest_revision=test-revision' \
    'running_model=Qwen/Qwen2.5-0.5B-Instruct' \
    'cpu_total=100' \
    'cpu_idle=50' \
    'cpu_usage_usec=100' \
    'cpu_sample_ns=1000000000' \
    'cpu_capacity=2' \
    "memory_percent=${FAKE_MEMORY_PERCENT:-10.0}" \
    'gpu_percent=unavailable' \
    'gpu_memory_percent=unavailable'
