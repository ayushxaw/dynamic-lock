#!/usr/bin/env bash
# Install Dynamic Lock for the current GNOME user.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${HOME}/.config/dynamic_lock"
SYSTEMD_DIR="${HOME}/.config/systemd/user"
BIN_DIR="${HOME}/.local/bin"
LIB_DIR="${HOME}/.local/lib/dynamic-lock"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for dependency in python3 flock systemctl install; do
    command -v "$dependency" >/dev/null 2>&1 || fail "required command '$dependency' is missing. Install it before running this installer."
done
python3 -c 'import gi' >/dev/null 2>&1 || fail "system Python needs PyGObject (python3-gi on Ubuntu)."
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

python3 - "$CONFIG_DIR/config" <<'PY'
from pathlib import Path
import os
import sys

config = Path(sys.argv[1])
legacy = {"PHONE_ADDRESS", "RSSI_DROP_DB", "RSSI_STALE_SECONDS"}
lines = config.read_text(encoding="utf-8").splitlines()
filtered = [line for line in lines if line.split("=", 1)[0].strip() not in legacy]
if not any(line.split("=", 1)[0].strip() == "GSCONNECT_DEVICE_NAME" for line in filtered if "=" in line):
    filtered.insert(0, "GSCONNECT_DEVICE_NAME=")
config.write_text("\n".join(filtered) + "\n", encoding="utf-8")
os.chmod(config, 0o600)
PY

install -m 644 "$SCRIPT_DIR/dynamic_lock.service" "$SYSTEMD_DIR/dynamic_lock.service"
systemctl --user daemon-reload

if python3 - <<'PY'
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
owned = bus.call_sync(
    "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
    "NameHasOwner", GLib.Variant("(s)", ("org.gnome.Shell.Extensions.GSConnect",)),
    None, Gio.DBusCallFlags.NONE, 2000, None,
).unpack()[0]
raise SystemExit(0 if owned else 1)
PY
then
    systemctl --user enable --now dynamic_lock.service
    printf '\nInstalled and started the monitor; GSConnect is running.\n'
else
    systemctl --user disable dynamic_lock.service >/dev/null 2>&1 || true
    printf '\nInstalled, but GSConnect is not running in this GNOME session.\n'
    printf 'Open GSConnect, pair your phone, and then enable with: systemctl --user enable --now dynamic_lock.service\n'
fi

printf '\nCommands use the full installed path: %s/dynamic_lock.sh --status\n' "$BIN_DIR"
