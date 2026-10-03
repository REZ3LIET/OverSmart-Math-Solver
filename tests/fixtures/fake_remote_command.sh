#!/usr/bin/env bash

# Command stand-in used by test_setup.sh.

set -u

case "$(basename -- "$0")" in
    dpkg|curl)
        exit 0
        ;;
    git)
        if [[ "$*" == *"rev-parse HEAD"* ]]; then
            printf 'test-revision\n'
        fi
        exit 0
        ;;
    python)
        if [[ " $* " == *" app.py "* ]]; then
            exec sleep 30
        fi
        exit 0
        ;;
    *)
        printf 'Unexpected fake command name: %s\n' "$0" >&2
        exit 1
        ;;
esac

