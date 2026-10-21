#!/usr/bin/env bash
# Remove program files; preserve private configuration.
set -euo pipefail
SYSTEMD_DIR="${HOME}/.config/systemd/user"
BIN_DIR="${HOME}/.local/bin"
LIB_DIR="${HOME}/.local/lib/dynamic-lock"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID}}/dynamic-lock"

if [[ -e "$SYSTEMD_DIR/dynamic_lock.service" ]]; then
    systemctl --user show-environment >/dev/null 2>&1 || { printf 'ERROR: user systemd unavailable; cannot confirm service stopped. Retry from GNOME.\n' >&2; exit 1; }
    systemctl --user disable --now dynamic_lock.service
fi
/usr/bin/python3 - "$RUNTIME_DIR" <<'PY'
import fcntl, pathlib, sys
runtime = pathlib.Path(sys.argv[1])
lock = runtime / 'monitor.lock'
if lock.exists():
    with lock.open('a') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit('ERROR: foreground monitor/diagnostic running; stop it before uninstalling.')
        for name in ('state', 'state.tmp'):
            (runtime / name).unlink(missing_ok=True)
# Keep the lock inode: deleting it could allow two processes to acquire different locks.
PY
rm -f "$SYSTEMD_DIR/dynamic_lock.service"
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user daemon-reload
fi
rm -f "$BIN_DIR/dynamic_lock.sh"
for module in bluetooth config desktop gsconnect monitor state; do
    rm -f "$LIB_DIR/dynamic_lock_${module}.py"
    rm -f "$LIB_DIR/__pycache__/dynamic_lock_${module}."*.pyc
 done
rm -f "$LIB_DIR/dynamic_lock_monitor.js" "$LIB_DIR/dynamic_lock_state.js"
rmdir "$LIB_DIR/__pycache__" "$LIB_DIR" 2>/dev/null || true
printf 'Dynamic Lock uninstalled. Private config preserved at %s/.config/dynamic_lock/config\n' "$HOME"
