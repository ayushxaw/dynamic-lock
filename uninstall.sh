#!/usr/bin/env bash
# Remove installed files while preserving the user's private configuration.
set -euo pipefail

SYSTEMD_DIR="${HOME}/.config/systemd/user"
BIN_DIR="${HOME}/.local/bin"
LIB_DIR="${HOME}/.local/lib/dynamic-lock"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID}}/dynamic-lock"

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user disable --now dynamic_lock.service >/dev/null 2>&1 || true
fi
rm -f "$SYSTEMD_DIR/dynamic_lock.service"
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user daemon-reload
fi

rm -f "$BIN_DIR/dynamic_lock.sh"
rm -f "$LIB_DIR/dynamic_lock_monitor.js" "$LIB_DIR/dynamic_lock_state.js"
rmdir "$LIB_DIR" 2>/dev/null || true
rm -f "$RUNTIME_DIR/state" "$RUNTIME_DIR/state.tmp" "$RUNTIME_DIR/monitor.lock"
rmdir "$RUNTIME_DIR" 2>/dev/null || true

printf '%s\n' 'Dynamic Lock uninstalled.'
printf 'Private config preserved at %s/.config/dynamic_lock/config\n' "$HOME"
printf 'Remove it manually only if you also want to delete your Bluetooth address.\n'
