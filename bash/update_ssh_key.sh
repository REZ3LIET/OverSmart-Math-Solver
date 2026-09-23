#!/usr/bin/env bash

# Runs on the external monitoring machine.
# It creates one stable key/password, installs them remotely, verifies the new
# key, and comments the key that was used to bootstrap the connection.

set -euo pipefail

: "${WATCH_TARGET:?}"
: "${SSH_PORT:?}"
: "${SSH_IDENTITY_FILE:?}"
: "${SSH_CONNECT_TIMEOUT:?}"
: "${CREDENTIALS_DIR:?}"

SSH_BIN="${SSH_BIN:-ssh}"

mkdir -p "$CREDENTIALS_DIR"
chmod 700 "$CREDENTIALS_DIR"

safe_target="${WATCH_TARGET//[^A-Za-z0-9_.-]/_}"
stable_key="$CREDENTIALS_DIR/${safe_target}_ed25519"
password_file="$stable_key.password"

# Generate each credential once, then reuse it after reconnects and rebuilds.
if [[ ! -f "$stable_key" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "osms-watcher-$safe_target" -f "$stable_key"
fi
if [[ ! -f "$password_file" ]]; then
    openssl rand -hex 24 > "$password_file"
fi
chmod 600 "$stable_key" "$password_file"

public_key="$(<"$stable_key.pub")"
password="$(<"$password_file")"
login_user="${WATCH_TARGET%@*}"
[[ "$login_user" != "$WATCH_TARGET" ]] || {
    echo "WATCH_TARGET must use user@host format." >&2
    exit 1
}

# Quote values before placing them in the remote shell environment.
printf -v quoted_public_key '%q' "$public_key"
printf -v quoted_password '%q' "$password"
printf -v quoted_login_user '%q' "$login_user"

connect() {
    local key="$1"
    shift
    "$SSH_BIN" \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
        -p "$SSH_PORT" \
        -i "$key" \
        "$WATCH_TARGET" "$@"
}

# Apply the account password and add the stable watcher key.
connect "$SSH_IDENTITY_FILE" \
    "NEW_PUBLIC_KEY=$quoted_public_key NEW_PASSWORD=$quoted_password LOGIN_USER=$quoted_login_user bash -s" <<'REMOTE_INSTALL'
set -euo pipefail

if [[ "$(id -u)" == 0 ]]; then
    printf '%s:%s\n' "$LOGIN_USER" "$NEW_PASSWORD" | chpasswd
else
    printf '%s:%s\n' "$LOGIN_USER" "$NEW_PASSWORD" | sudo -n chpasswd
fi

umask 077
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
grep -qxF "$NEW_PUBLIC_KEY" "$HOME/.ssh/authorized_keys" || \
    printf '%s\n' "$NEW_PUBLIC_KEY" >> "$HOME/.ssh/authorized_keys"
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"
REMOTE_INSTALL

# Never disable the old key until the stable key has successfully logged in.
connect "$stable_key" true >/dev/null || {
    echo "New key verification failed; the previous key remains active." >&2
    exit 1
}

read -r old_type old_body _ < <(ssh-keygen -y -f "$SSH_IDENTITY_FILE")
read -r new_type new_body _ < "$stable_key.pub"

if [[ "$old_type $old_body" != "$new_type $new_body" ]]; then
    printf -v quoted_old_type '%q' "$old_type"
    printf -v quoted_old_body '%q' "$old_body"

    # Keep the old line for audit, but make sshd ignore it as a comment.
    connect "$stable_key" \
        "OLD_KEY_TYPE=$quoted_old_type OLD_KEY_BODY=$quoted_old_body bash -s" <<'REMOTE_DISABLE'
set -euo pipefail

file="$HOME/.ssh/authorized_keys"
tmp="$(mktemp "$HOME/.ssh/authorized_keys.XXXXXX")"
awk -v type="$OLD_KEY_TYPE" -v body="$OLD_KEY_BODY" '
    $1 == type && $2 == body { print "# disabled-by-osms " $0; next }
    { print }
' "$file" > "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$file"
REMOTE_DISABLE
fi

# The watcher captures this final line as the active private-key path.
printf '%s\n' "$stable_key"
