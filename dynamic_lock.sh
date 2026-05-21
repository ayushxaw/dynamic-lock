#!/usr/bin/env bash
# ============================================================================
# dynamic_lock.sh — Dynamic Lock for Linux/GNOME via KDE Connect
# ============================================================================
#
# DESCRIPTION:
#   Monitors phone proximity via KDE Connect reachability. When the paired
#   device becomes unreachable for a configurable number of consecutive
#   checks, the screen is locked automatically (Dynamic Lock).
#
# USAGE:
#   dynamic_lock.sh [--status|--pause|--resume|--logs|--help|--version]
#     (no flag)   Start the daemon in the foreground
#     --status    Show current daemon state and recent journal entries
#     --pause     Pause miss counting on the running daemon (SIGUSR1)
#     --resume    Resume miss counting on the running daemon (SIGUSR2)
#     --logs      Tail the last 50 journald entries for this daemon
#     --help      Show this help text
#     --version   Print version string
#
# CONFIG FILE:  ~/.config/dynamic_lock/config
#   Key=Value pairs (no quoting needed). Supported keys:
#     DEVICE_ID          Device ID, 32-40 hex chars (auto-detected if empty)
#     POLL_INTERVAL      Seconds between reachability checks  (default: 10)
#     MISS_THRESHOLD     Consecutive misses before locking     (default: 3)
#     GRACE_PERIOD        Seconds after reconnect to skip misses (default: 20)
#     WAKE_GRACE_PERIOD   Seconds after suspend-wake to skip    (default: 15)
#     NOTIFY             1=send desktop notifications, 0=silent (default: 1)
#     LOCK_CMD           Override the lock command (optional)
#
# LOCK FALLBACK CHAIN (when LOCK_CMD is unset):
#   loginctl lock-session → dbus screensaver → gnome-screensaver-command
#   → xdg-screensaver lock
#
# DEPENDENCIES: kdeconnect-cli, bash ≥4.2, flock, loginctl
# OPTIONAL:     notify-send, logger, journalctl
#
# LICENSE: MIT
# VERSION: 1.2.0
# ============================================================================

# NOTE: We intentionally do NOT use `set -e`. In a long-running daemon,
# set -e causes silent death on any unexpected non-zero exit code (e.g.,
# arithmetic evaluating to 0, grep finding no match, transient CLI failures).
# A daemon that silently dies at 2am is worse than one that logs an error
# and keeps running. All error paths are handled explicitly.
set -uo pipefail

# ── Constants ───────────────────────────────────────────────────────────────
readonly VERSION="1.2.0"
readonly SCRIPT_NAME="dynamic_lock"
readonly CONFIG_DIR="${HOME}/.config/dynamic_lock"
readonly CONFIG_FILE="${CONFIG_DIR}/config"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME}_${UID}.lock"
readonly STATE_FILE="/tmp/${SCRIPT_NAME}_${UID}.state"
readonly PID_FILE="/tmp/${SCRIPT_NAME}_${UID}.pid"

# Timeout for external commands (seconds) — prevents hangs if kdeconnect
# daemon is stuck or D-Bus session is broken
readonly CMD_TIMEOUT=5

# ── Default configuration ──────────────────────────────────────────────────
DEVICE_ID=""
POLL_INTERVAL=10
MISS_THRESHOLD=3
GRACE_PERIOD=20
WAKE_GRACE_PERIOD=15
NOTIFY=1
LOCK_CMD=""

# ── Runtime state ───────────────────────────────────────────────────────────
miss_count=0
paused=0
locked=0
seen=0
sleep_pid=""
shutdown_requested=0
lock_failures=0      # consecutive lock failures (for backoff)
_UPTIME=0            # current uptime cache (set by read_uptime)
_LAST_UPTIME=0       # previous tick's uptime
_FIRST_TICK=1        # skip wake detection on first tick
GRACE_UNTIL=0        # uptime-based: don't count misses until this uptime

# ============================================================================
# LOGGING
#   - Cache logger check once at startup (no fork on every call)
#   - Use printf '%(%T)T' (bash ≥4.2 builtin) — zero forks for timestamps
# ============================================================================
if command -v logger &>/dev/null; then
    log() { logger -t "$SCRIPT_NAME" "$*" 2>/dev/null || true; }
else
    log() { :; }
fi

log_info()  { log "[INFO] $*";  printf '%(%H:%M:%S)T [INFO] %s\n'  -1 "$*" >&2; }
log_warn()  { log "[WARN] $*";  printf '%(%H:%M:%S)T [WARN] %s\n'  -1 "$*" >&2; }
log_error() { log "[ERROR] $*"; printf '%(%H:%M:%S)T [ERROR] %s\n' -1 "$*" >&2; }

# ============================================================================
# NOTIFICATIONS  (timeout-protected — D-Bus can hang for ~25s if broken)
# ============================================================================
_has_notify=0
command -v notify-send &>/dev/null && _has_notify=1

notify() {
    [[ "$NOTIFY" -eq 1 ]] || return 0
    [[ "$_has_notify" -eq 1 ]] || return 0
    timeout 2 notify-send -a "Dynamic Lock" -i dialog-information "$@" 2>/dev/null || true
}

# ============================================================================
# SAFE CONFIG PARSER  (no source / eval — only known keys accepted)
# ============================================================================
parse_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        # skip blank lines and full-line comments
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" != *=* ]] && continue

        # split on first '=' only
        key="${line%%=*}"
        value="${line#*=}"
        # trim whitespace
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        # strip surrounding quotes (preserves # inside quoted values,
        # e.g. LOCK_CMD="i3lock -c #000000" keeps #000000)
        if [[ "$value" == '"'*'"' ]] || [[ "$value" == "'"*"'" ]]; then
            value="${value:1:${#value}-2}"
        fi

        # only accept known keys (prevents arbitrary variable injection)
        case "$key" in
            DEVICE_ID)         DEVICE_ID="$value" ;;
            POLL_INTERVAL)     POLL_INTERVAL="$value" ;;
            MISS_THRESHOLD)    MISS_THRESHOLD="$value" ;;
            GRACE_PERIOD)      GRACE_PERIOD="$value" ;;
            WAKE_GRACE_PERIOD) WAKE_GRACE_PERIOD="$value" ;;
            NOTIFY)            NOTIFY="$value" ;;
            LOCK_CMD)          LOCK_CMD="$value" ;;
            *) log_warn "Unknown config key: $key" ;;
        esac
    done < "$CONFIG_FILE"
}

# ============================================================================
# VALIDATION & CLAMPING
#   - Validates integers BEFORE clamping (prevents tight loop on "abc")
#   - Uses [[ ]] not (( )) — safe regardless of set -e
# ============================================================================
is_integer() {
    [[ "$1" =~ ^-?[0-9]+$ ]]
}

validate_config() {
    # Validate device ID format (32-40 hex chars, or UUID-style with hyphens)
    if [[ -n "$DEVICE_ID" ]]; then
        local stripped="${DEVICE_ID//-/}"
        if ! [[ "$stripped" =~ ^[0-9a-fA-F]{32,40}$ ]]; then
            log_error "Invalid DEVICE_ID format: '$DEVICE_ID' (expected 32-40 hex chars)"
            exit 1
        fi
    fi

    # Validate integers — fall back to defaults if non-numeric
    is_integer "$POLL_INTERVAL"     || { log_warn "POLL_INTERVAL='$POLL_INTERVAL' not integer, using 10"; POLL_INTERVAL=10; }
    is_integer "$MISS_THRESHOLD"    || { log_warn "MISS_THRESHOLD='$MISS_THRESHOLD' not integer, using 3"; MISS_THRESHOLD=3; }
    is_integer "$GRACE_PERIOD"      || { log_warn "GRACE_PERIOD='$GRACE_PERIOD' not integer, using 20"; GRACE_PERIOD=20; }
    is_integer "$WAKE_GRACE_PERIOD" || { log_warn "WAKE_GRACE_PERIOD='$WAKE_GRACE_PERIOD' not integer, using 15"; WAKE_GRACE_PERIOD=15; }
    is_integer "$NOTIFY"            || { log_warn "NOTIFY='$NOTIFY' not integer, using 1"; NOTIFY=1; }

    # Clamp to sane ranges
    [[ "$POLL_INTERVAL" -lt 2 ]]        && POLL_INTERVAL=2
    [[ "$POLL_INTERVAL" -gt 300 ]]      && POLL_INTERVAL=300
    [[ "$MISS_THRESHOLD" -lt 1 ]]       && MISS_THRESHOLD=1
    [[ "$MISS_THRESHOLD" -gt 60 ]]      && MISS_THRESHOLD=60
    [[ "$GRACE_PERIOD" -lt 0 ]]         && GRACE_PERIOD=0
    [[ "$GRACE_PERIOD" -gt 600 ]]       && GRACE_PERIOD=600
    [[ "$WAKE_GRACE_PERIOD" -lt 0 ]]    && WAKE_GRACE_PERIOD=0
    [[ "$WAKE_GRACE_PERIOD" -gt 600 ]]  && WAKE_GRACE_PERIOD=600
    [[ "$NOTIFY" -lt 0 ]]               && NOTIFY=0
    [[ "$NOTIFY" -gt 1 ]]               && NOTIFY=1

    return 0
}

# ============================================================================
# AUTO-DETECT DEVICE ID  (portable — no grep -P)
# ============================================================================
auto_detect_device() {
    [[ -n "$DEVICE_ID" ]] && return 0

    log_info "No DEVICE_ID configured, attempting auto-detection..."

    local output
    output=$(timeout "$CMD_TIMEOUT" kdeconnect-cli -l 2>/dev/null) || {
        log_error "kdeconnect-cli -l failed or timed out; cannot auto-detect device"
        exit 1
    }

    # Parse lines like: "- DeviceName: <device_id> (paired and reachable)"
    # Uses sed -E (extended regex) — portable across GNU/BSD (no PCRE needed)
    # Greedy `.*:` matches the LAST colon, so device names containing ":" are safe.
    local id
    id=$(echo "$output" | grep 'paired' \
        | sed -E 's/.*:[[:space:]]+([0-9a-fA-F_-]+)[[:space:]]+\(paired.*/\1/' \
        | head -1)

    if [[ -z "$id" ]]; then
        log_error "No paired device found. Pair a device first or set DEVICE_ID in config."
        exit 1
    fi

    DEVICE_ID="$id"
    log_info "Auto-detected device: $DEVICE_ID"
}

# ============================================================================
# LOCK SCREEN — FALLBACK CHAIN
#   - loginctl prefers graphical sessions (x11/wayland)
#   - Falls back through D-Bus, gnome-screensaver, xdg-screensaver
#   - Handles both old (no --value) and new loginctl output formats
# ============================================================================
do_lock() {
    # Custom lock command from config (highest priority)
    if [[ -n "$LOCK_CMD" ]]; then
        log_info "Locking via custom command: $LOCK_CMD"
        bash -c "$LOCK_CMD" 2>/dev/null && return 0
        log_warn "Custom lock command failed, trying fallbacks"
    fi

    # 1) loginctl — prefer graphical (x11/wayland) sessions over TTY
    if command -v loginctl &>/dev/null; then
        local session all_sessions stype
        # Try --value first (modern systemd), fall back to sed for older versions
        all_sessions=$(loginctl show-user "$USER" --property=Sessions --value 2>/dev/null) \
            || all_sessions=$(loginctl show-user "$USER" --property=Sessions 2>/dev/null \
                              | sed 's/^Sessions=//')
        all_sessions=$(echo "$all_sessions" | tr ' ' '\n' | grep -E '^[0-9]+$') || true

        # try graphical sessions first
        while IFS= read -r session; do
            [[ -z "$session" ]] && continue
            stype=$(loginctl show-session "$session" --property=Type --value 2>/dev/null) \
                || stype=$(loginctl show-session "$session" --property=Type 2>/dev/null \
                           | sed 's/^Type=//')
            if [[ "$stype" == "x11" || "$stype" == "wayland" || "$stype" == "mir" ]]; then
                log_info "Locking via loginctl (session $session, type=$stype)"
                loginctl lock-session "$session" 2>/dev/null && return 0
            fi
        done <<< "$all_sessions"
        # fall back to any session
        session=$(echo "$all_sessions" | head -1)
        [[ -n "$session" ]] && loginctl lock-session "$session" 2>/dev/null && return 0
    fi

    # 2) D-Bus screensaver interfaces (needs session bus)
    if command -v dbus-send &>/dev/null && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        log_info "Locking via D-Bus screensaver"
        dbus-send --session --type=method_call --dest=org.freedesktop.ScreenSaver \
            /org/freedesktop/ScreenSaver org.freedesktop.ScreenSaver.Lock \
            2>/dev/null && return 0
        dbus-send --session --type=method_call --dest=org.gnome.ScreenSaver \
            /org/gnome/ScreenSaver org.gnome.ScreenSaver.Lock \
            2>/dev/null && return 0
    fi

    # 3) gnome-screensaver-command
    if command -v gnome-screensaver-command &>/dev/null; then
        log_info "Locking via gnome-screensaver-command"
        gnome-screensaver-command --lock 2>/dev/null && return 0
    fi

    # 4) xdg-screensaver (generic last resort)
    if command -v xdg-screensaver &>/dev/null; then
        log_info "Locking via xdg-screensaver"
        xdg-screensaver lock 2>/dev/null && return 0
    fi

    log_error "All lock methods failed!"
    return 1
}

# ============================================================================
# ATOMIC STATE FILE WRITE (write to tmp + rename — no partial reads)
# ============================================================================
save_state() {
    local tmp="${STATE_FILE}.tmp"
    echo "$seen $locked $miss_count $paused" > "$tmp" && mv -f "$tmp" "$STATE_FILE"
}

read_state_file() {
    [[ -f "$STATE_FILE" ]] || { echo "  (no state file)"; return; }
    local s l m p
    read -r s l m p < "$STATE_FILE" 2>/dev/null || { echo "  (corrupt state)"; return; }
    local state_label="WAITING"
    if [[ "${p:-0}" -eq 1 ]]; then
        state_label="PAUSED"
    elif [[ "${l:-0}" -eq 1 ]]; then
        state_label="LOCKED"
    elif [[ "${s:-0}" -eq 1 ]]; then
        state_label="ARMED"
    fi
    echo "  State:  $state_label"
    echo "  Misses: ${m:-0}/$MISS_THRESHOLD"
}

# ============================================================================
# UPTIME — pure bash, zero forks (no cut/awk subshell per tick)
# Returns 1 on failure so callers can handle it.
# ============================================================================
read_uptime() {
    local raw
    read -r raw _ < /proc/uptime 2>/dev/null || return 1
    _UPTIME="${raw%%.*}"
    return 0
}

# ============================================================================
# INTERRUPTIBLE SLEEP — explicitly tracked PID for clean shutdown
# ============================================================================
isleep() {
    sleep "$1" &
    sleep_pid=$!
    wait "$sleep_pid" 2>/dev/null || true
    sleep_pid=""
}

# ============================================================================
# SIGNAL HANDLERS
# ============================================================================
on_pause() {
    paused=1
    log_info "Paused (SIGUSR1)"
    notify "⏸️ Paused" "Miss counting paused"
    save_state
}

on_resume() {
    paused=0
    miss_count=0
    log_info "Resumed (SIGUSR2)"
    notify "▶️ Resumed" "Miss counting resumed"
    save_state
}

on_shutdown() {
    shutdown_requested=1
    log_info "Shutdown signal received"
    # Kill tracked sleep child (not %% which could be wrong job)
    if [[ -n "$sleep_pid" ]] && kill -0 "$sleep_pid" 2>/dev/null; then
        kill "$sleep_pid" 2>/dev/null || true
    fi
}

cleanup() {
    log_info "Cleaning up..."
    rm -f "$PID_FILE" 2>/dev/null || true
    # intentionally keep STATE_FILE — --status reads it after exit
    log_info "Daemon stopped."
}

# ============================================================================
# SINGLE INSTANCE VIA FLOCK
# ============================================================================
acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        local existing_pid=""
        [[ -f "$PID_FILE" ]] && existing_pid=$(cat "$PID_FILE" 2>/dev/null)
        echo "ERROR: Already running (PID: ${existing_pid:-unknown})" >&2
        exit 1
    fi
    echo $$ > "$PID_FILE"
}

get_daemon_pid() {
    [[ -f "$PID_FILE" ]] || return 1
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    echo "$pid"
}

# ============================================================================
# CLI COMMANDS
# ============================================================================
cmd_help() {
    cat <<'EOF'
dynamic_lock.sh — Dynamic Lock for Linux via KDE Connect

USAGE:
    dynamic_lock.sh              Start the daemon (foreground)
    dynamic_lock.sh --status     Show daemon state & recent log
    dynamic_lock.sh --pause      Pause miss counting (SIGUSR1)
    dynamic_lock.sh --resume     Resume miss counting (SIGUSR2)
    dynamic_lock.sh --logs       Tail last 50 journal entries
    dynamic_lock.sh --help       Show this help
    dynamic_lock.sh --version    Print version

CONFIG: ~/.config/dynamic_lock/config
    DEVICE_ID=<hex>          Phone device ID (auto-detected if blank)
    POLL_INTERVAL=10         Seconds between checks
    MISS_THRESHOLD=3         Misses before lock
    GRACE_PERIOD=20          Seconds to skip after reconnect
    WAKE_GRACE_PERIOD=15     Seconds to skip after suspend wake
    NOTIFY=1                 Desktop notifications (0 to disable)
    LOCK_CMD=<command>       Override lock command
EOF
}

cmd_version() { echo "dynamic_lock $VERSION"; }

cmd_status() {
    local pid
    if pid=$(get_daemon_pid); then
        echo "● dynamic_lock is RUNNING (PID: $pid)"
    else
        echo "○ dynamic_lock is NOT running"
    fi
    echo ""
    read_state_file
    echo ""
    echo "Recent journal entries:"
    if command -v journalctl &>/dev/null; then
        journalctl --user -t "$SCRIPT_NAME" -n 10 --no-pager -o cat 2>/dev/null \
            || journalctl -t "$SCRIPT_NAME" -n 10 --no-pager -o cat 2>/dev/null \
            || echo "  (journalctl unavailable)"
    else
        echo "  (journalctl not found)"
    fi
}

cmd_pause() {
    local pid
    if pid=$(get_daemon_pid); then
        kill -USR1 "$pid"
        echo "Sent SIGUSR1 (pause) to PID $pid"
    else
        echo "ERROR: Daemon is not running" >&2; exit 1
    fi
}

cmd_resume() {
    local pid
    if pid=$(get_daemon_pid); then
        kill -USR2 "$pid"
        echo "Sent SIGUSR2 (resume) to PID $pid"
    else
        echo "ERROR: Daemon is not running" >&2; exit 1
    fi
}

cmd_logs() {
    if command -v journalctl &>/dev/null; then
        journalctl --user -t "$SCRIPT_NAME" -n 50 --no-pager -o cat 2>/dev/null \
            || journalctl -t "$SCRIPT_NAME" -n 50 --no-pager -o cat 2>/dev/null \
            || { echo "journalctl query failed" >&2; exit 1; }
    else
        echo "journalctl not available" >&2; exit 1
    fi
}

# ============================================================================
# REACHABILITY CHECK  (3-state: reachable / unreachable / check-failed)
#
# Returns:
#   0 = device confirmed reachable
#   1 = device confirmed unreachable (kdeconnect responded, phone not in range)
#   2 = check failed (timeout, kdeconnect daemon not running, D-Bus error)
#       → callers should NOT count this as a miss (it's a software issue,
#         not the phone being absent — otherwise a crashed kdeconnectd
#         causes a false screen lock within 30 seconds)
#
# Uses `kdeconnect-cli -a --id-only` (lists only reachable device IDs, one
# per line) as the primary check. This is more reliable than parsing the
# human-readable `-l` output which varies across versions. Falls back to
# `-l` text parsing if `-a --id-only` produces no output on older builds.
# ============================================================================
check_reachable() {
    local output exit_code

    # Primary: -a --id-only — clean, one device ID per line
    output=$(timeout "$CMD_TIMEOUT" kdeconnect-cli -a --id-only 2>/dev/null)
    exit_code=$?

    # timeout (124) or kdeconnect-cli failed entirely (daemon down / D-Bus error)
    if [[ "$exit_code" -eq 124 ]]; then
        return 2  # timeout — don't count as miss
    fi

    # If -a --id-only succeeded (exit 0), check if our device ID is listed
    if [[ "$exit_code" -eq 0 ]]; then
        # Check if our device ID appears in the available list
        if [[ "$output" == *"${DEVICE_ID}"* ]]; then
            return 0  # reachable
        fi
        return 1  # kdeconnect responded, our device not in available list
    fi

    # -a --id-only returned non-zero (non-timeout) — could be old version
    # that doesn't support --id-only, or daemon genuinely down.
    # Fallback: try -l and parse the text output
    output=$(timeout "$CMD_TIMEOUT" kdeconnect-cli -l 2>/dev/null)
    exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        return 2  # check failed — don't count as miss
    fi

    # Check for "paired and reachable" in text output
    if [[ "$output" == *"${DEVICE_ID}"*"paired and reachable"* ]]; then
        return 0  # reachable
    fi

    # kdeconnect responded but device isn't reachable
    return 1
}

# ============================================================================
# SUSPEND/WAKE DETECTION  (via /proc/uptime delta)
#
# On Linux, /proc/uptime INCLUDES suspend time. After a 1-hour suspend,
# uptime jumps by ~3600. So we detect wake when the delta is MUCH LARGER
# than expected (not smaller — that was the v1.0.0 bug).
# ============================================================================
handle_wake() {
    # If /proc/uptime read fails, skip wake detection entirely
    # (don't update _LAST_UPTIME with stale data → prevents false wake)
    read_uptime || return
    local delta normal_max
    delta=$(( _UPTIME - _LAST_UPTIME ))
    _LAST_UPTIME=$_UPTIME

    # First tick — nothing to compare against
    if [[ "$_FIRST_TICK" -eq 1 ]]; then
        _FIRST_TICK=0
        return
    fi

    # Normal tick: delta ≈ POLL_INTERVAL. Allow 15s jitter for scheduling.
    # If delta >> expected, system was suspended.
    normal_max=$(( POLL_INTERVAL + 15 ))
    [[ "$delta" -lt "$normal_max" && "$delta" -ge 0 ]] && return

    # ── Resumed from suspend ────────────────────────────────────────────
    log_info "Resume detected (${delta}s gap, expected ~${POLL_INTERVAL}s)"
    miss_count=0
    lock_failures=0
    save_state
    # Grace period so KDE Connect has time to re-establish connection
    GRACE_UNTIL=$(( _UPTIME + WAKE_GRACE_PERIOD ))
}

# ============================================================================
# MAIN LOOP
# ============================================================================
main_loop() {
    log_info "Daemon started (PID $$, device=$DEVICE_ID, poll=${POLL_INTERVAL}s, threshold=$MISS_THRESHOLD)"
    notify "🔒 Armed" "Dynamic Lock active — monitoring ${DEVICE_ID:0:8}…"

    read_uptime
    _LAST_UPTIME=$_UPTIME
    save_state

    while [[ "$shutdown_requested" -eq 0 ]]; do

        # ── Interruptible sleep (longer when already locked) ────────────
        if [[ "$locked" -eq 1 ]]; then
            isleep 5
        else
            isleep "$POLL_INTERVAL"
        fi
        [[ "$shutdown_requested" -eq 0 ]] || break

        # ── Suspend/wake detection ──────────────────────────────────────
        handle_wake

        # ── Skip if paused ──────────────────────────────────────────────
        if [[ "$paused" -eq 1 ]]; then
            continue
        fi

        # ── Skip during grace period (uses uptime, not wall-clock) ──────
        if [[ "$GRACE_UNTIL" -gt 0 ]]; then
            read_uptime
            if [[ "$_UPTIME" -lt "$GRACE_UNTIL" ]]; then
                continue
            fi
            GRACE_UNTIL=0
        fi

        # ── Reachability check (3-state) ────────────────────────────────
        local reach_status=0
        check_reachable || reach_status=$?

        if [[ "$reach_status" -eq 2 ]]; then
            # Check FAILED (timeout, daemon down, D-Bus error)
            # Do NOT count as a miss — this is a software issue, not the
            # phone being out of range. A crashed kdeconnectd should not
            # cause a false screen lock.
            log_warn "Reachability check failed (kdeconnect daemon down or timeout)"
            continue
        fi

        if [[ "$reach_status" -eq 0 ]]; then
            # ── Device is REACHABLE ─────────────────────────────────────
            if [[ "$seen" -eq 0 ]]; then
                log_info "Phone detected"
                notify "🔒 Armed" "Monitoring phone"
            fi

            if [[ "$locked" -eq 1 ]]; then
                log_info "Phone returned, re-armed"
                notify "📱 Reconnected" "Phone is back in range"
                read_uptime
                GRACE_UNTIL=$(( _UPTIME + GRACE_PERIOD ))
            elif [[ "$miss_count" -gt 0 ]]; then
                log_info "Device reachable again (was $miss_count miss(es))"
                read_uptime
                GRACE_UNTIL=$(( _UPTIME + GRACE_PERIOD ))
            fi

            seen=1
            miss_count=0
            locked=0
            lock_failures=0
        else
            # ── Device is CONFIRMED UNREACHABLE ─────────────────────────
            # Skip if phone was never seen this session
            [[ "$seen" -eq 0 ]] && continue

            # Already locked — just keep polling, don't re-lock
            [[ "$locked" -eq 1 ]] && continue

            # Count misses toward threshold
            # IMPORTANT: use $(( )) assignment, NOT (( miss_count++ ))
            miss_count=$(( miss_count + 1 ))
            log_info "Miss $miss_count/$MISS_THRESHOLD"

            if [[ "$miss_count" -ge "$MISS_THRESHOLD" ]]; then
                # Back off on repeated lock failures
                if [[ "$lock_failures" -gt 0 ]]; then
                    local backoff=$(( lock_failures * 30 ))
                    [[ "$backoff" -gt 300 ]] && backoff=300
                    log_warn "Lock failed $lock_failures time(s), backing off ${backoff}s"
                    isleep "$backoff"
                    [[ "$shutdown_requested" -eq 0 ]] || break
                    # Phone may have returned during backoff — recheck
                    check_reachable && { miss_count=0; continue; }
                    # Pause may have been requested during backoff
                    [[ "$paused" -eq 1 ]] && continue
                fi

                log_warn "Threshold reached — LOCKING SCREEN"
                if do_lock; then
                    locked=1
                    miss_count=0
                    lock_failures=0
                    notify "🔒 Locked" "Phone out of range — screen locked"
                    log_info "Screen locked successfully"
                else
                    log_error "Failed to lock screen"
                    lock_failures=$(( lock_failures + 1 ))
                    miss_count=0
                fi
            fi
        fi

        # ── Persist state every tick (miss_count changes need to be visible) ─
        save_state
    done
}

# ============================================================================
# ENTRY POINT
# ============================================================================
main() {
    case "${1:-}" in
        --help|-h)     cmd_help;    exit 0 ;;
        --version|-V)  cmd_version; exit 0 ;;
        --status|-s)   parse_config; validate_config; cmd_status; exit 0 ;;
        --pause|-p)    cmd_pause;   exit 0 ;;
        --resume|-r)   cmd_resume;  exit 0 ;;
        --logs|-l)     cmd_logs;    exit 0 ;;
        "")            ;;
        *)             echo "Unknown option: $1" >&2; cmd_help >&2; exit 1 ;;
    esac

    if ! command -v kdeconnect-cli &>/dev/null; then
        echo "ERROR: kdeconnect-cli not found. Install kdeconnect." >&2
        exit 1
    fi

    mkdir -p "$CONFIG_DIR"
    parse_config
    validate_config
    auto_detect_device
    acquire_lock

    trap on_pause   USR1
    trap on_resume  USR2
    trap on_shutdown TERM INT HUP
    trap cleanup    EXIT

    main_loop
}

main "$@"
