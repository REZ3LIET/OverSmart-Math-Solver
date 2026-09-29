#!/usr/bin/env bash

# Authorized CS553 red-team exercise based on the instructor's reference code.
# It makes exactly two finite passes over the 21 documented group ports, with
# one SSH attempt per port per pass and no SSH-level retries.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
[[ -r "$ENV_FILE" ]] && source "$ENV_FILE"

AUDIT_MACHINE="${AUDIT_MACHINE:-paffenroth-23.dyn.wpi.edu}"
AUDIT_BASE_PORT="${AUDIT_BASE_PORT:-22000}"
AUDIT_CONNECT_TIMEOUT="${AUDIT_CONNECT_TIMEOUT:-3}"
AUDIT_USER="${AUDIT_USER:-student-admin}"
AUDIT_KEY="${AUDIT_KEY:-${BOOTSTRAP_SSH_IDENTITY_FILE:-}}"

# Noon September 29 through noon October 1, 2026 in New York is 16:00 UTC
# because New York is observing EDT (UTC-4) on these dates.
WINDOW_START_EPOCH=1790697600
WINDOW_END_EPOCH=1790870400
PASSES=2
SECONDS_BETWEEN_PASSES=5

now="$(date +%s)"
if (( now < WINDOW_START_EPOCH || now >= WINDOW_END_EPOCH )); then
    printf 'Refusing to run outside the authorized red-team window.\n' >&2
    printf 'Window: 2026-09-29 12:00 through 2026-10-01 12:00 America/New_York.\n' >&2
    exit 1
fi

if [[ -z "$AUDIT_KEY" ]]; then
    printf 'Set AUDIT_KEY or BOOTSTRAP_SSH_IDENTITY_FILE in .env.\n' >&2
    exit 1
fi
[[ "$AUDIT_KEY" = /* ]] || AUDIT_KEY="$REPO_ROOT/$AUDIT_KEY"
if [[ ! -r "$AUDIT_KEY" ]]; then
    printf 'Audit key is not readable: %s\n' "$AUDIT_KEY" >&2
    exit 1
fi

accepted=0
attempted=0

printf 'Authorized CS553 red-team check started at %s UTC.\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'Two passes; ports 22001-22021; five seconds between passes.\n\n'

for pass in 1 2; do
    printf 'Pass %d of %d\n' "$pass" "$PASSES"

    for group in {1..21}; do
        port=$(( AUDIT_BASE_PORT + group ))
        (( attempted += 1 ))
        printf '%s group=%02d port=%d: ' \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$group" "$port"

        # Match the instructor's read-only proof: authenticate and print only
        # the remote hostname. No interactive shell or configuration changes.
        if ssh \
            -o BatchMode=yes \
            -o ConnectionAttempts=1 \
            -o ConnectTimeout="$AUDIT_CONNECT_TIMEOUT" \
            -o IdentitiesOnly=yes \
            -o KbdInteractiveAuthentication=no \
            -o PasswordAuthentication=no \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            -i "$AUDIT_KEY" \
            -p "$port" \
            "$AUDIT_USER@$AUDIT_MACHINE" \
            hostname
        then
            (( accepted += 1 ))
        else
            printf 'not accessible\n'
        fi
    done

    if (( pass < PASSES )); then
        printf '\nWaiting %d seconds before the final pass.\n\n' \
            "$SECONDS_BETWEEN_PASSES"
        sleep "$SECONDS_BETWEEN_PASSES"
    fi
done

printf '\nFinished at %s UTC: %d successful authentications; %d total attempts.\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$accepted" "$attempted"
