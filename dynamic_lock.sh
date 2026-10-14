#!/usr/bin/env bash
# Command-line controls for the Dynamic Lock user service.
set -uo pipefail

readonly VERSION="2.0.0"
readonly SERVICE="dynamic_lock.service"
readonly CONFIG_FILE="${HOME}/.config/dynamic_lock/config"
readonly MONITOR="${HOME}/.local/lib/dynamic-lock/dynamic_lock_monitor.py"
readonly RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID}}/dynamic-lock"

usage() {
    cat <<'EOF'
Dynamic Lock — GSConnect presence lock for GNOME

Usage:
  dynamic_lock.sh --daemon   Run the monitor (used by systemd)
  dynamic_lock.sh --probe    Check GSConnect connection without locking
  dynamic_lock.sh --status   Show service and monitor state
  dynamic_lock.sh --pause    Pause the running service
  dynamic_lock.sh --resume   Resume the running service
  dynamic_lock.sh --logs     Show recent service logs
  dynamic_lock.sh --help     Show this help
  dynamic_lock.sh --version  Show version

Configuration: ~/.config/dynamic_lock/config
EOF
}

service_active() {
    command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet "$SERVICE"
}

case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --version|-V) printf 'dynamic_lock %s\n' "$VERSION"; exit 0 ;;
    --daemon)
        for dependency in python3 flock; do
            if ! command -v "$dependency" >/dev/null 2>&1; then
                printf 'ERROR: required command not found: %s\n' "$dependency" >&2
                exit 1
            fi
        done
        if ! python3 -c 'import gi' >/dev/null 2>&1; then
            printf 'ERROR: system Python needs PyGObject. On Ubuntu, install python3-gi.\n' >&2
            exit 1
        fi
        if [[ ! -r "$CONFIG_FILE" ]]; then
            printf 'ERROR: config not found: %s\n' "$CONFIG_FILE" >&2
            printf 'Run install.sh, then pair your phone in GSConnect.\n' >&2
            exit 1
        fi
        if [[ ! -r "$MONITOR" ]]; then
            printf 'ERROR: monitor not found: %s\n' "$MONITOR" >&2
            exit 1
        fi
        mkdir -p "$RUNTIME_DIR" || exit 1
        exec 9>"${RUNTIME_DIR}/monitor.lock"
        if ! flock -n 9; then
            printf 'ERROR: another Dynamic Lock monitor is already running.\n' >&2
            exit 1
        fi
        exec python3 "$MONITOR" \
            --config "$CONFIG_FILE" --state "${RUNTIME_DIR}/state"
        ;;
    --probe)
        command -v python3 >/dev/null 2>&1 || { printf 'ERROR: install python3.\n' >&2; exit 1; }
        [[ -r "$MONITOR" ]] || { printf 'ERROR: monitor not found: %s\n' "$MONITOR" >&2; exit 1; }
        exec python3 "$MONITOR" --probe --config "$CONFIG_FILE"
        ;;
    --status)
        if service_active; then
            printf 'Dynamic Lock service: active\n'
        else
            printf 'Dynamic Lock service: inactive\n'
        fi
        if [[ -r "${RUNTIME_DIR}/state" ]]; then
            printf 'Last runtime state (may be stale if the service is inactive):\n'
            cat "${RUNTIME_DIR}/state"
        else
            printf 'Monitor state: unavailable\n'
        fi
        ;;
    --pause|--resume)
        command -v systemctl >/dev/null 2>&1 || { printf 'ERROR: systemctl is required.\n' >&2; exit 1; }
        if ! service_active; then
            printf 'ERROR: Dynamic Lock service is not running.\n' >&2
            exit 1
        fi
        if [[ "$1" == --pause ]]; then signal=SIGUSR1; else signal=SIGUSR2; fi
        systemctl --user kill --signal="$signal" "$SERVICE" || exit 1
        printf 'Sent %s to %s\n' "$signal" "$SERVICE"
        ;;
    --logs)
        command -v journalctl >/dev/null 2>&1 || { printf 'ERROR: journalctl is required.\n' >&2; exit 1; }
        exec journalctl --user -u "$SERVICE" -n 50 --no-pager -o cat
        ;;
    "")
        usage >&2
        exit 2
        ;;
    *)
        printf 'Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
esac
