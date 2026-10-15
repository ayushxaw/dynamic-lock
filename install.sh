#!/usr/bin/env bash
# Install for the current user. Activation is always a separate explicit step.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${HOME}/.config/dynamic_lock"
SYSTEMD_DIR="${HOME}/.config/systemd/user"
BIN_DIR="${HOME}/.local/bin"
LIB_DIR="${HOME}/.local/lib/dynamic-lock"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for dependency in systemctl install; do
    command -v "$dependency" >/dev/null 2>&1 || fail "Required command missing: $dependency"
done
[[ -x /usr/bin/python3 ]] || fail 'Install system python3.'
/usr/bin/python3 -c 'import gi, socket; from gi.repository import Gio, GLib, GLibUnix; assert hasattr(socket, "AF_BLUETOOTH")' >/dev/null 2>&1 || fail 'Install python3-gi and gir1.2-glib-2.0 with system Python on Ubuntu; Linux Bluetooth socket support is required.'
systemctl --user show-environment >/dev/null 2>&1 || fail 'Run this from your GNOME user session; the systemd user manager is unavailable.'

if [[ -e "$SYSTEMD_DIR/dynamic_lock.service" ]]; then
    systemctl --user disable --now dynamic_lock.service
fi
# A foreground diagnostic also owns the program files; do not upgrade underneath it.
/usr/bin/python3 - "${XDG_RUNTIME_DIR:-/run/user/${UID}}/dynamic-lock/monitor.lock" <<'PY'
import fcntl, pathlib, sys
path = pathlib.Path(sys.argv[1])
if path.exists():
    with path.open('a') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit('ERROR: a foreground monitor/diagnostic is running; stop it before installing.')
PY

install -d -m 755 "$BIN_DIR" "$LIB_DIR" "$SYSTEMD_DIR"
install -m 755 "$SCRIPT_DIR/dynamic_lock.sh" "$BIN_DIR/dynamic_lock.sh"
for module in bluetooth config desktop monitor state; do
    install -m 644 "$SCRIPT_DIR/dynamic_lock_${module}.py" "$LIB_DIR/dynamic_lock_${module}.py"
done
rm -f "$LIB_DIR/dynamic_lock_monitor.js" "$LIB_DIR/dynamic_lock_state.js"
install -d -m 700 "$CONFIG_DIR"
if [[ ! -e "$CONFIG_DIR/config" ]]; then
    install -m 600 "$SCRIPT_DIR/dynamic_lock.conf" "$CONFIG_DIR/config"
else
    chmod 600 "$CONFIG_DIR/config"
    printf 'Preserved existing configuration contents. Obsolete settings are reported, not converted.\n'
fi
install -m 644 "$SCRIPT_DIR/dynamic_lock.service" "$SYSTEMD_DIR/dynamic_lock.service"
systemctl --user daemon-reload
systemctl --user disable dynamic_lock.service
printf 'Installed with automatic locking DISABLED, including on upgrades.\n'
/usr/bin/python3 -B "$LIB_DIR/dynamic_lock_monitor.py" --check-config --config "$CONFIG_DIR/config" || fail 'Files installed, but configuration needs correction before use.'
printf 'Edit %s/config, then run:\n' "$CONFIG_DIR"
printf '  %s/dynamic_lock.sh --doctor\n  %s/dynamic_lock.sh --dry-run\n' "$BIN_DIR" "$BIN_DIR"
printf 'After successful background/departure tests, activate with --enable.\n'
