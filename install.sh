#!/usr/bin/env bash
# Install Dynamic Lock for the current GNOME user.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${HOME}/.config/dynamic_lock"
SYSTEMD_DIR="${HOME}/.config/systemd/user"
BIN_DIR="${HOME}/.local/bin"
LIB_DIR="${HOME}/.local/lib/dynamic-lock"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for dependency in python3 flock systemctl install grep; do
    command -v "$dependency" >/dev/null 2>&1 || fail "required command '$dependency' is missing. Install it before running this installer."
done
python3 -c 'import gi, socket; assert hasattr(socket, "AF_BLUETOOTH") and hasattr(socket, "BTPROTO_L2CAP")' >/dev/null 2>&1 || \
    fail "system Python needs PyGObject and Bluetooth L2CAP support (python3-gi on Ubuntu)."
systemctl --user show-environment >/dev/null 2>&1 || fail "the systemd user manager is unavailable. Run this from your logged-in GNOME session."

printf '%s\n' '=== Dynamic Lock installer ==='
if systemctl --user is-active --quiet dynamic_lock.service; then
    printf '%s\n' 'Stopping the existing service...'
    systemctl --user stop dynamic_lock.service
fi

install -d -m 755 "$BIN_DIR" "$LIB_DIR" "$SYSTEMD_DIR"
install -m 755 "$SCRIPT_DIR/dynamic_lock.sh" "$BIN_DIR/dynamic_lock.sh"
install -m 644 "$SCRIPT_DIR/dynamic_lock_monitor.py" "$LIB_DIR/dynamic_lock_monitor.py"
install -m 644 "$SCRIPT_DIR/dynamic_lock_state.py" "$LIB_DIR/dynamic_lock_state.py"
rm -f "$LIB_DIR/dynamic_lock_monitor.js" "$LIB_DIR/dynamic_lock_state.js"

install -d -m 700 "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/config" ]]; then
    install -m 600 "$SCRIPT_DIR/dynamic_lock.conf" "$CONFIG_DIR/config"
    printf 'Created private config: %s\n' "$CONFIG_DIR/config"
else
    chmod 600 "$CONFIG_DIR/config"
    printf 'Kept existing config and set permissions to 600: %s\n' "$CONFIG_DIR/config"
fi

install -m 644 "$SCRIPT_DIR/dynamic_lock.service" "$SYSTEMD_DIR/dynamic_lock.service"
systemctl --user daemon-reload

if grep -Eiq '^PHONE_ADDRESS=([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$' "$CONFIG_DIR/config"; then
    systemctl --user enable --now dynamic_lock.service
    printf '\nInstalled, enabled, and started the monitor.\n'
else
    systemctl --user disable dynamic_lock.service >/dev/null 2>&1 || true
    printf '\nInstalled, but not enabled yet because PHONE_ADDRESS is not configured.\n'
    printf '1. Pair your phone in GNOME Settings → Bluetooth.\n'
    printf '2. Set PHONE_ADDRESS in %s/config.\n' "$CONFIG_DIR"
    printf '3. Run %s/dynamic_lock.sh --probe and confirm the phone answers the Bluetooth check.\n' "$BIN_DIR"
    printf '4. Enable with: systemctl --user enable --now dynamic_lock.service\n'
fi

printf '\nCommands use the full installed path: %s/dynamic_lock.sh --status\n' "$BIN_DIR"
