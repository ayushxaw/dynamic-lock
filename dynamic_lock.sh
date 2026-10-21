#!/usr/bin/env bash
# User controls. Configuration is parsed as data by Python, never sourced.
set -euo pipefail
umask 077

readonly VERSION="2.2.0"
readonly SERVICE="dynamic_lock.service"
readonly CONFIG_FILE="${HOME}/.config/dynamic_lock/config"
readonly MONITOR="${HOME}/.local/lib/dynamic-lock/dynamic_lock_monitor.py"
readonly RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID}}/dynamic-lock"
readonly PYTHON="/usr/bin/python3"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Dynamic Lock — Bluetooth proximity lock for Ubuntu GNOME
  --doctor                  Check prerequisites and phone connection; never locks
  --setup                   Select a paired phone for the configured backend; save privately
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
    --daemon|--doctor|--dry-run|--probe|--setup)
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
            printf 'Automatic locking enabled. Fresh presence checks are required before it can arm.\n'
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
    with (runtime / 'monitor.lock').open('a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            live = False
        except BlockingIOError:
            live = True
        owner_pid = None
        if live:
            lock.seek(0)
            try:
                owner_pid = int(lock.read(32))
            except ValueError:
                pass
    state = json.loads((runtime / 'state').read_text())
    age = time.time() - state['updated_at']
    if not live or owner_pid is None or owner_pid <= 0 or owner_pid != state.get('pid') or not 0 <= age <= 15:
        print('No fresh live monitor status. Historical readings are not readiness evidence.')
        print('No live background reconnects confirmed. Run --dry-run for continuous testing; --doctor exits after one check.')
    else:
        if state.get('mode') == 'dry-run':
            print('Diagnostic: active; locking disabled. Monitoring follows the state shown below.')
        keys = ('mode', 'backend', 'state', 'sensor', 'signal_units', 'raw_rssi', 'median_rssi', 'reading_age_seconds', 'reason', 'sensor_reason')
        if state.get('backend') == 'bluetooth':
            keys += ('sdp_connection_attempts', 'last_connection_attempt_age_seconds')
        for key in keys:
            print(f'{key}: {state.get(key)}')
except (OSError, ValueError, KeyError):
    print('Monitor state: unavailable; run --doctor or --dry-run.')
    print('Pairing alone does not start background reconnects. --doctor exits after one check; --dry-run keeps monitoring.')
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
