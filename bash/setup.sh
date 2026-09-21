#!/usr/bin/env bash

set -euo pipefail

CHECK_DIR="${CHECK_DIR:-$HOME/.check}"
COUNT_FILE="$CHECK_DIR/count"

mkdir -p "$CHECK_DIR"

STATUS_FILE="$CHECK_DIR/status"
if [[ ! -e "$STATUS_FILE" ]]; then
    printf 'app_not_setup\n' > "$STATUS_FILE"
fi

failure_count=0
if [[ -r "$COUNT_FILE" ]]; then
    stored_count="$(<"$COUNT_FILE")"
    if [[ "$stored_count" =~ ^[0-9]+$ ]]; then
        failure_count="$stored_count"
    fi
fi

failure_count=$((failure_count + 1))
temporary_count_file="$(mktemp "$CHECK_DIR/count.XXXXXX")"
printf '%s\n' "$failure_count" > "$temporary_count_file"
mv "$temporary_count_file" "$COUNT_FILE"

printf 'healthy\n' > "$STATUS_FILE"

printf 'Failure count: %s; remote status: %s\n' \
    "$failure_count" \
    "$(<"$STATUS_FILE")"
