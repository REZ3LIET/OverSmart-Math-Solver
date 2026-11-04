#!/usr/bin/env bash

# Command stand-in used by test_setup.sh.

set -u

case "$(basename -- "$0")" in
    dpkg)
        exit 0
        ;;
    curl)
        if [[ -n "${FAKE_CURL_LOG:-}" ]]; then
            printf '%s\n' "$*" >> "$FAKE_CURL_LOG"
        fi
        exit 0
        ;;
    git)
        if [[ "${1:-}" == clone ]]; then
            target="${!#}"
            fixture="$(readlink -f -- "$0")"
            mkdir -p "$target/.git" "$target/.venv/bin"
            printf 'transformers\n' > "$target/requirements.txt"
            sha256sum "$target/requirements.txt" | awk '{ print $1 }' \
                > "$target/.venv/.requirements.sha256"
            printf '# fixture\n' > "$target/app.py"
            ln -s "$fixture" "$target/.venv/bin/python"
        fi
        if [[ "$*" == *"rev-parse HEAD"* ]]; then
            printf 'test-revision\n'
        fi
        exit 0
        ;;
    python)
        if [[ " $* " == *" app.py "* ]]; then
            if [[ -n "${FAKE_APP_ENV_LOG:-}" ]]; then
                printf 'capacity_file=%s\n' "${OSMS_CAPACITY_FILE:-}" > "$FAKE_APP_ENV_LOG"
                printf 'server_port=%s\n' "${GRADIO_SERVER_PORT:-}" >> "$FAKE_APP_ENV_LOG"
            fi
            exec sleep 30
        fi
        exit 0
        ;;
    *)
        printf 'Unexpected fake command name: %s\n' "$0" >&2
        exit 1
        ;;
esac
