#!/usr/bin/env bash

set -euo pipefail

: "${WATCH_TARGET:?}"
: "${SSH_PORT:?}"
: "${SSH_IDENTITY_FILE:?}"
: "${SSH_CONNECT_TIMEOUT:?}"
: "${CREDENTIALS_DIR:?}"

SSH_BIN="${SSH_BIN:-ssh}"
SSH_KEYGEN_BIN="${SSH_KEYGEN_BIN:-ssh-keygen}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

mkdir -p "$CREDENTIALS_DIR"
chmod 700 "$CREDENTIALS_DIR"

safe_target="${WATCH_TARGET//[^A-Za-z0-9_.-]/_}"
stable_identity="$CREDENTIALS_DIR/${safe_target}_ed25519"
password_file="${stable_identity}.password"

if [[ ! -r "$stable_identity" ]]; then
    "$SSH_KEYGEN_BIN" \
        -q \
        -t ed25519 \
        -N '' \
        -C "osms-watcher-$safe_target" \
        -f "$stable_identity"
fi

chmod 600 "$stable_identity"

if [[ ! -r "$password_file" ]]; then
    "$OPENSSL_BIN" rand -hex 24 > "$password_file"
fi
chmod 600 "$password_file"

new_public_key="$(<"${stable_identity}.pub")"
new_password="$(<"$password_file")"
old_public_key="$("$SSH_KEYGEN_BIN" -y -f "$SSH_IDENTITY_FILE")"

login_user="${WATCH_TARGET%@*}"
if [[ "$login_user" == "$WATCH_TARGET" ]]; then
    echo "WATCH_TARGET must include the remote username (user@host)." >&2
    exit 1
fi

new_key_type="${new_public_key%% *}"
new_key_body="${new_public_key#* }"
new_key_body="${new_key_body%% *}"
old_key_type="${old_public_key%% *}"
old_key_body="${old_public_key#* }"
old_key_body="${old_key_body%% *}"

printf -v quoted_public_key '%q' "$new_public_key"
printf -v quoted_password '%q' "$new_password"
printf -v quoted_login_user '%q' "$login_user"

ssh_options=(
    -o BatchMode=yes
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
    -p "$SSH_PORT"
    -i "$SSH_IDENTITY_FILE"
)

"$SSH_BIN" "${ssh_options[@]}" "$WATCH_TARGET" \
    "NEW_PUBLIC_KEY=$quoted_public_key NEW_PASSWORD=$quoted_password LOGIN_USER=$quoted_login_user bash -s" <<'REMOTE_INSTALL'
set -euo pipefail

if [[ "$(id -u)" == "0" ]]; then
    printf '%s:%s\n' "$LOGIN_USER" "$NEW_PASSWORD" | chpasswd
else
    printf '%s:%s\n' "$LOGIN_USER" "$NEW_PASSWORD" | sudo -n chpasswd
fi

umask 077
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
if ! grep -qxF "$NEW_PUBLIC_KEY" "$HOME/.ssh/authorized_keys"; then
    printf '%s\n' "$NEW_PUBLIC_KEY" >> "$HOME/.ssh/authorized_keys"
fi
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"
REMOTE_INSTALL

if ! "$SSH_BIN" \
    -o BatchMode=yes \
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
    -p "$SSH_PORT" \
    -i "$stable_identity" \
    "$WATCH_TARGET" true >/dev/null
then
    echo "The watcher key was installed but could not be verified; the bootstrap key was not changed." >&2
    exit 1
fi

if [[ "$old_key_type" != "$new_key_type" || "$old_key_body" != "$new_key_body" ]]; then
    printf -v quoted_old_type '%q' "$old_key_type"
    printf -v quoted_old_body '%q' "$old_key_body"

    "$SSH_BIN" \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
        -p "$SSH_PORT" \
        -i "$stable_identity" \
        "$WATCH_TARGET" \
        "OLD_KEY_TYPE=$quoted_old_type OLD_KEY_BODY=$quoted_old_body bash -s" <<'REMOTE_COMMENT'
set -euo pipefail

authorized_keys="$HOME/.ssh/authorized_keys"
temporary_file="$(mktemp "$HOME/.ssh/authorized_keys.XXXXXX")"
awk -v key_type="$OLD_KEY_TYPE" -v key_body="$OLD_KEY_BODY" '
    $1 == key_type && $2 == key_body {
        print "# disabled-by-osms " $0
        next
    }
    { print }
' "$authorized_keys" > "$temporary_file"
chmod 600 "$temporary_file"
mv "$temporary_file" "$authorized_keys"
REMOTE_COMMENT
fi

printf '%s\n' "$stable_identity"
