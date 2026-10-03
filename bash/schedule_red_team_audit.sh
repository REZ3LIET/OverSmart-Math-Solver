#!/usr/bin/env bash

# Installs the one-time-effective CS553 audit job on the external machine.
# The audit script independently enforces the authorized 2026 window.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit_bootstrap_key.sh"
LOG_FILE="$REPO_ROOT/logs/red_team_2026-09-29.log"
MARKER='# osms-red-team-2026-09-29'
SCHEDULE_EPOCH=1790697600

[[ -x "$AUDIT_SCRIPT" ]] || {
    printf 'Audit script is missing or not executable: %s\n' "$AUDIT_SCRIPT" >&2
    exit 1
}

if (( $(date +%s) >= SCHEDULE_EPOCH )); then
    printf 'The 2026 red-team schedule time has passed; refusing to install a stale cron job.\n' >&2
    exit 1
fi

command -v crontab >/dev/null 2>&1 || {
    printf 'crontab is not installed on this machine.\n' >&2
    exit 1
}

timezone_name="$(TZ=America/New_York date '+%Z')"
[[ "$timezone_name" == EDT ]] || {
    printf 'America/New_York timezone data is unavailable (got %s).\n' \
        "$timezone_name" >&2
    exit 1
}

existing="$(crontab -l 2>/dev/null || true)"
if grep -qF "$MARKER" <<< "$existing"; then
    printf 'The red-team cron entry is already installed.\n'
    exit 0
fi

mkdir -p "$REPO_ROOT/logs"
printf -v quoted_script '%q' "$AUDIT_SCRIPT"
printf -v quoted_log '%q' "$LOG_FILE"

{
    [[ -z "$existing" ]] || printf '%s\n' "$existing"
    printf 'CRON_TZ=America/New_York\n'
    printf '0 12 29 9 * %s >> %s 2>&1 %s\n' \
        "$quoted_script" "$quoted_log" "$MARKER"
} | crontab -

printf 'Scheduled for 2026-09-29 12:00 America/New_York.\n'
printf 'Output: %s\n' "$LOG_FILE"
