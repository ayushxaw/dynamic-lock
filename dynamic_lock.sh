#!/usr/bin/env bash
# User controls. Configuration is parsed as data by Python, never sourced.
set -euo pipefail

readonly VERSION="2.1.0"
readonly SERVICE="dynamic_lock.service"
readonly CONFIG_FILE="${HOME}/.config/dynamic_lock/config"
readonly MONITOR="${HOME}/.local/lib/dynamic-lock/dynamic_lock_monitor.py"
readonly RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID}}/dynamic-lock"
readonly PYTHON="/usr/bin/python3"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Dynamic Lock — Bluetooth connection proximity for Ubuntu GNOME
  --doctor                  Check prerequisites and one connection reading; never locks
  --dry-run [--duration N]   Run production decisions with locking disabled (Ctrl+C to stop)
  --probe [--duration N]     Same dry-run, defaults to 30 seconds
  --enable                  Check readiness, then enable and start automatic locking
  --disable                 Stop automatic locking and disable startup
  --status                  Show activation, live state, signal units and inhibited reason
  --pause / --resume         Pause/resume an active service; resume requires fresh arming
  --logs                    Show the last 50 service journal entries
  --daemon                  Run automatic monitor (used by systemd)
  --help / --version

Configuration: ~/.config/dynamic_lock/config
Install leaves automatic locking disabled. Test background and departure behavior
with --dry-run before --enable. Return only re-arms; it never unlocks.
EOF
}
require_monitor() {
    [[ -x "$PYTHON" ]] || fail 'Install system python3 on Ubuntu.'
    [[ -r "$MONITOR" ]] || fail 'Monitor is missing; run install.sh.'
}
require_systemd() {
    command -v systemctl >/dev/null 2>&1 || fail 'systemctl is required.'
    systemctl --user show-environment >/dev/null 2>&1 || fail 'Run from your logged-in GNOME user session; user systemd is unavailable.'
}
active() { systemctl --user is-active --quiet "$SERVICE"; }

option="${1:---help}"
if (( $# )); then shift; fi
case "$option" in
    --probe|--dry-run) ;;
    *) (( $# == 0 )) || { usage >&2; exit 2; } ;;
esac
case "$option" in
    --help|-h) usage ;;
    --version|-V) printf 'dynamic_lock %s\n' "$VERSION" ;;
    --daemon|--doctor|--dry-run|--probe)
        require_monitor
        if [[ "$option" == --daemon ]]; then
            exec "$PYTHON" -B "$MONITOR" --config "$CONFIG_FILE"
        fi
        exec "$PYTHON" -B "$MONITOR" --config "$CONFIG_FILE" "$option" "$@"
        ;;
    --enable)
        require_systemd
        require_monitor
        if active; then
            systemctl --user enable "$SERVICE"
            printf 'Automatic service already running; use --status for readiness.\n'
        else
            "$PYTHON" -B "$MONITOR" --config "$CONFIG_FILE" --doctor || fail 'Readiness check failed; automatic locking was not enabled.'
            systemctl --user enable --now "$SERVICE"
            active || fail 'Service did not start; inspect --logs.'
            printf 'Automatic locking enabled. Fresh near readings are required before it can arm.\n'
        fi
        ;;
    --disable)
        require_systemd
        systemctl --user disable --now "$SERVICE"
        printf 'Automatic locking stopped and startup disabled. Foreground dry-runs stop with Ctrl+C.\n'
        ;;
    --status)
        require_systemd
        if active; then printf 'Service: active\n'; else printf 'Service: inactive\n'; fi
        if systemctl --user is-enabled --quiet "$SERVICE"; then printf 'Startup: enabled\n'; else printf 'Startup: disabled\n'; fi
        "$PYTHON" -B - "$RUNTIME_DIR" <<'PY'
import fcntl, json, pathlib, sys, time
runtime = pathlib.Path(sys.argv[1])
try:
    with (runtime / 'monitor.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            live = False
        except BlockingIOError:
            live = True
    state = json.loads((runtime / 'state').read_text())
    age = time.time() - state['updated_at']
    if not live or not 0 <= age <= 15:
        print('No fresh live monitor status. Historical readings are not readiness evidence.')
    else:
        for key in ('mode', 'state', 'sensor', 'signal_units', 'raw_rssi', 'median_rssi', 'reading_age_seconds', 'reason', 'sensor_reason'):
            print(f'{key}: {state.get(key)}')
except (OSError, ValueError, KeyError):
    print('Monitor state: unavailable; run --doctor or --dry-run.')
PY
        ;;
    --pause|--resume)
        require_systemd
        active || fail 'Service is inactive. Start a dry-run or use --enable after testing.'
        if [[ "$option" == --pause ]]; then sig=SIGUSR1; else sig=SIGUSR2; fi
        systemctl --user kill --kill-whom=main --signal="$sig" "$SERVICE"
        printf 'Requested %s; check --status for the resulting state.\n' "${option#--}"
        ;;
    --logs)
        command -v journalctl >/dev/null 2>&1 || fail 'journalctl is required.'
        exec journalctl --user -u "$SERVICE" -n 50 --no-pager -o cat
        ;;
    *) usage >&2; exit 2 ;;
esac
