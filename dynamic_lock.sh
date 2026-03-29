#!/bin/bash
# =============================================================================
# dynamic_lock.sh — Ubuntu Dynamic Lock (v3.0)
#
# Works like Windows Dynamic Lock:
#   - Monitors your phone's Bluetooth connection
#   - Locks screen when phone disconnects (you walked away)
#   - Does NOT re-lock after you manually unlock (you can keep working)
#   - Re-arms only when phone reconnects and leaves again
#
# Zero battery impact — uses passive bluetoothctl checks, no active pinging.
# =============================================================================

# ── Config file ──────────────────────────────────────────────────────────────
CONFIG_FILE="$HOME/.config/dynamic_lock/config"
STATE_FILE="/tmp/dynamic_lock_state_$UID"
LOCK_FILE="/tmp/dynamic_lock_$UID.lock"
PAUSE_FILE="$HOME/.dynamic_lock_pause"
WAKE_FILE="/tmp/dynamic_lock_wake_$UID"
LOG_TAG="dynamic_lock"

# Defaults (override any of these in the config file)
PHONE_MAC=""
POLL_INTERVAL=1         # seconds between connection checks
MISS_THRESHOLD=3        # consecutive misses before locking (~3s with default)
NOTIFY=1                # 1 = desktop notifications, 0 = silent

# Load user config
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# ── Validate ──────────────────────────────────────────────────────────────────
if [[ -z "$PHONE_MAC" ]]; then
    echo "ERROR: PHONE_MAC not set."
    echo "Create $CONFIG_FILE and add:"
    echo "  PHONE_MAC=\"AA:BB:CC:DD:EE:FF\""
    echo ""
    echo "Find your phone's MAC:  bluetoothctl devices"
    exit 1
fi

if ! command -v bluetoothctl &>/dev/null; then
    echo "ERROR: bluetoothctl not found. Install: sudo apt install bluez"
    exit 1
fi

# ── Single instance enforcement ───────────────────────────────────────────────
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "dynamic_lock is already running. Exiting."
    exit 1
fi

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    if command -v logger &>/dev/null; then
        logger -t "$LOG_TAG" "$*"
    fi
}

notify() {
    [[ "$NOTIFY" -eq 1 ]] || return
    notify-send -a "Dynamic Lock" -i dialog-password "$1" "$2" 2>/dev/null || true
}

# ── State persistence ─────────────────────────────────────────────────────────
# Survives service restarts. Format: "SEEN LOCKED MISS"
save_state() {
    echo "$SEEN $LOCKED $MISS" > "$STATE_FILE"
}

load_state() {
    SEEN=0; LOCKED=0; MISS=0
    if [[ -f "$STATE_FILE" ]]; then
        read -r s l m < "$STATE_FILE" 2>/dev/null || return
        [[ "$s" =~ ^[01]$    ]] && SEEN=$s
        [[ "$l" =~ ^[01]$    ]] && LOCKED=$l
        [[ "$m" =~ ^[0-9]+$  ]] && MISS=$m
    fi
}

# ── Connection detection ──────────────────────────────────────────────────────
# Passive check via bluetoothctl — no pinging, no sudo, no battery drain.
# Returns 0 (true) if phone shows "Connected: yes".
is_connected() {
    local info
    info=$(bluetoothctl info "$PHONE_MAC" 2>/dev/null) || return 1
    echo "$info" | grep -q "Connected: yes"
}

# ── Session lock ──────────────────────────────────────────────────────────────
lock_session() {
    log "Locking session."
    notify "🔒 Screen locked" "Phone disconnected from Bluetooth"

    # Prefer loginctl with explicit session ID — avoids silent DBus failures
    local session
    session=$(loginctl show-user "$USER" --property=Sessions --value 2>/dev/null \
              | tr ' ' '\n' | grep -m1 '[0-9]')

    if [[ -n "$session" ]]; then
        loginctl lock-session "$session" && return
    fi

    # Fallback chain for different DEs / Wayland compositors
    dbus-send --session \
        --dest=org.gnome.ScreenSaver \
        --type=method_call \
        /org/gnome/ScreenSaver \
        org.gnome.ScreenSaver.Lock &>/dev/null && return

    command -v gnome-screensaver-command &>/dev/null \
        && gnome-screensaver-command --lock && return

    command -v xdg-screensaver &>/dev/null \
        && xdg-screensaver lock && return

    log "ERROR: No working lock command found."
}

# ── Suspend/wake detection ────────────────────────────────────────────────────
# When the lid opens, BT adapter takes a few seconds to reconnect.
# Without this, those first polls see phone as absent, MISS increments,
# and the laptop locks the second you open it. This resets MISS on wake.
handle_wake() {
    local now
    now=$(awk '{print int($1)}' /proc/uptime)
    local last=0
    [[ -f "$WAKE_FILE" ]] && last=$(cat "$WAKE_FILE" 2>/dev/null)
    echo "$now" > "$WAKE_FILE"

    # Normal tick ceiling: poll interval + generous margin.
    local normal_max=$(( POLL_INTERVAL + 15 ))

    local delta=$(( now - last ))
    if [[ $last -eq 0 ]] || [[ $delta -lt $normal_max && $delta -ge 0 ]]; then
        return  # Normal tick or first run
    fi

    # Large delta = genuinely resumed from suspend
    if [[ $delta -lt 300 && $MISS -gt 0 ]]; then
        log "Wake from suspend detected (gap=${delta}s) — resetting MISS counter."
        MISS=0
        save_state
    fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
load_state
log "Started. Phone: $PHONE_MAC | Poll: ${POLL_INTERVAL}s | Threshold: $MISS_THRESHOLD misses"
log "State restored: SEEN=$SEEN LOCKED=$LOCKED MISS=$MISS"
log "Pause monitoring: touch $PAUSE_FILE"

_PAUSED=0
PREV_SEEN=$SEEN
PREV_LOCKED=$LOCKED

while true; do
    # Adaptive polling: fast when armed, slower when already locked
    if [[ $LOCKED -eq 1 ]]; then
        sleep 5
    else
        sleep "$POLL_INTERVAL"
    fi

    handle_wake

    # ── Pause flag ────────────────────────────────────────────────────────────
    if [[ -f "$PAUSE_FILE" ]]; then
        if [[ "$_PAUSED" -eq 0 ]]; then
            log "Monitoring paused (pause file exists)."
            notify "⏸ Dynamic Lock paused" "Remove $PAUSE_FILE to resume"
            _PAUSED=1
        fi
        continue
    fi
    if [[ "$_PAUSED" -eq 1 ]]; then
        log "Monitoring resumed."
        notify "▶ Dynamic Lock resumed" ""
        _PAUSED=0
        MISS=0  # Clean slate after a pause
    fi

    # ── Connection check ──────────────────────────────────────────────────────
    if is_connected; then
        # ── Phone is connected ────────────────────────────────────────────────
        if [[ $SEEN -eq 0 ]]; then
            log "Phone detected for first time — monitoring active."
            notify "🔓 Dynamic Lock active" "Screen locks when phone disconnects"
        elif [[ $LOCKED -eq 1 ]]; then
            log "Phone returned — system re-armed."
            notify "🔓 Phone returned" "Dynamic Lock re-armed"
        fi

        SEEN=1
        MISS=0
        LOCKED=0

    else
        # ── Phone is not connected ────────────────────────────────────────────
        if [[ $SEEN -eq 0 ]]; then
            : # Phone never seen → script does nothing (safe cold start)

        elif [[ $LOCKED -eq 1 ]]; then
            : # Already locked once → no re-lock spam (Windows behavior)

        else
            (( MISS++ ))
            log "Phone absent — miss $MISS/$MISS_THRESHOLD"
            if [[ $MISS -ge $MISS_THRESHOLD ]]; then
                lock_session
                LOCKED=1
                MISS=0
            fi
        fi
    fi

    # Write state only when flags actually change (minimize file I/O)
    if [[ $SEEN -ne $PREV_SEEN || $LOCKED -ne $PREV_LOCKED ]]; then
        save_state
        PREV_SEEN=$SEEN
        PREV_LOCKED=$LOCKED
    fi

done
