#!/usr/bin/env bash

# Install the one-time-effective cron entry on the external watcher machine.
# The year/window check inside audit_bootstrap_key.sh makes later annual cron
# matches harmless, and this installer avoids duplicate entries.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit_bootstrap_key.sh"
LOG_FILE="$REPO_ROOT/logs/red_team_2026-09-29.log"
MARKER='# osms-red-team-2026-09-29'

command -v crontab >/dev/null 2>&1 || {
    printf 'crontab is not installed on this machine.\n' >&2
    exit 1
}

timezone_name="$(TZ=America/New_York date '+%Z')"
if [[ "$timezone_name" != EDT ]]; then
    printf 'America/New_York timezone data is unavailable (got %s).\n' "$timezone_name" >&2
    exit 1
fi

mkdir -p "$REPO_ROOT/logs"
existing="$(crontab -l 2>/dev/null || true)"
if grep -qF "$MARKER" <<< "$existing"; then
    printf 'The red-team cron entry is already installed.\n'
    exit 0
fi

printf -v quoted_script '%q' "$AUDIT_SCRIPT"
printf -v quoted_log '%q' "$LOG_FILE"
job="0 12 29 9 * $quoted_script >> $quoted_log 2>&1 $MARKER"

{
    [[ -z "$existing" ]] || printf '%s\n' "$existing"
    printf 'CRON_TZ=America/New_York\n'
    printf '%s\n' "$job"
} | crontab -

printf 'Scheduled for 2026-09-29 12:00 America/New_York.\n'
printf 'Output: %s\n' "$LOG_FILE"
