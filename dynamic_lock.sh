#!/bin/bash
#
# dynamic_lock.sh — bluetooth proximity screen lock (v4.0)
# Monitors phone via bluetoothctl; locks screen when it disconnects.
#
# v4.0:
#   - Interruptible reconnect (subshell + wait) — clean shutdown even mid-scan
#   - Audio output preserved during reconnect (pactl)
#   - Exponential backoff: 45s → 90s → 180s → 5min cap (saves battery)
# v3.0:
#   - Interruptible sleep, signal trap, timeout on bluetoothctl
#   - BT adapter power check, always reset MISS on wake
#

CONFIG_FILE="$HOME/.config/dynamic_lock/config"
STATE_FILE="/tmp/dynamic_lock_state_$UID"
LOCK_FILE="/tmp/dynamic_lock_$UID.lock"
PAUSE_FILE="$HOME/.dynamic_lock_pause"
WAKE_FILE="/tmp/dynamic_lock_wake_$UID"
LOG_TAG="dynamic_lock"

# ── signal handling ───────────────────────────────────────────────────────────
RUNNING=1
RECONNECT_PID=""

cleanup() {
    log "received shutdown signal, exiting cleanly"
    RUNNING=0
    # kill reconnect subshell if it's running
    if [[ -n "$RECONNECT_PID" ]]; then
        kill -- -"$RECONNECT_PID" 2>/dev/null   # kill process group
        kill "$RECONNECT_PID" 2>/dev/null       # fallback
        wait "$RECONNECT_PID" 2>/dev/null
    fi
    # kill any backgrounded sleep
    kill %% 2>/dev/null
    # preserve STATE_FILE across restarts
    rm -f "$LOCK_FILE" "$WAKE_FILE" 2>/dev/null
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# defaults
PHONE_MAC=""
POLL_INTERVAL=1
MISS_THRESHOLD=3
NOTIFY=1
AUTO_RECONNECT=1
RECONNECT_INTERVAL=45       # initial seconds between reconnect attempts
MAX_RECONNECT_INTERVAL=300  # cap at 5 minutes after repeated failures

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# validate
if [[ -z "$PHONE_MAC" ]]; then
    echo "PHONE_MAC not set in $CONFIG_FILE"
    echo "run: bluetoothctl devices"
    exit 1
fi

command -v bluetoothctl &>/dev/null || { echo "bluetoothctl not found"; exit 1; }

# single instance
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "already running"; exit 1; }

# ── helpers ───────────────────────────────────────────────────────────────────

log() { command -v logger &>/dev/null && logger -t "$LOG_TAG" "$*"; }

notify() {
    [[ "$NOTIFY" -eq 1 ]] || return
    notify-send -a "Dynamic Lock" -i dialog-password "$1" "$2" 2>/dev/null || true
}

save_state() { echo "$SEEN $LOCKED $MISS" > "$STATE_FILE"; }

load_state() {
    SEEN=0; LOCKED=0; MISS=0
    if [[ -f "$STATE_FILE" ]]; then
        read -r s l m < "$STATE_FILE" 2>/dev/null || return
        [[ "$s" =~ ^[01]$ ]]   && SEEN=$s
        [[ "$l" =~ ^[01]$ ]]   && LOCKED=$l
        [[ "$m" =~ ^[0-9]+$ ]] && MISS=$m
    fi
}

# Interruptible sleep — trap fires immediately when signal arrives
isleep() {
    sleep "$1" &
    wait $!
}

# ── bluetooth ─────────────────────────────────────────────────────────────────

is_bt_adapter_up() {
    timeout 2 bluetoothctl show 2>/dev/null | grep -q "Powered: yes"
}

is_connected() {
    timeout 3 bluetoothctl info "$PHONE_MAC" 2>/dev/null | grep -q "Connected: yes"
}

# Calculate reconnect interval with exponential backoff.
# 45 → 90 → 180 → 300(cap) → 300 → ...
# Saves battery when phone is genuinely gone (e.g. left at home).
get_backoff_interval() {
    _shift=$RECONNECT_FAILURES
    [[ $_shift -gt 3 ]] && _shift=3
    _interval=$(( RECONNECT_INTERVAL << _shift ))
    [[ $_interval -gt $MAX_RECONNECT_INTERVAL ]] && _interval=$MAX_RECONNECT_INTERVAL
    echo "$_interval"
}

# Reconnect to the phone.
# 1) Runs scan+connect in a SUBSHELL so SIGTERM can interrupt via wait
# 2) Preserves audio output to prevent PipeWire hijacking to phone speaker
try_reconnect() {
    [[ "$AUTO_RECONNECT" -eq 1 ]] || return 1
    log "scanning for $PHONE_MAC"

    # Save current audio output before connecting
    _prev_sink=""
    command -v pactl &>/dev/null && _prev_sink=$(pactl get-default-sink 2>/dev/null)

    # Run scan+connect in subshell — can be killed cleanly on shutdown
    (
        # BLE scan wakes up the phone's BT stack (~5s)
        timeout 6 bluetoothctl --timeout 5 scan on &>/dev/null
        sleep 1
        # Connect — phone is receptive after being scanned
        timeout 10 bluetoothctl connect "$PHONE_MAC" &>/dev/null
    ) &
    RECONNECT_PID=$!
    wait $RECONNECT_PID 2>/dev/null
    RECONNECT_PID=""

    # Check if we were killed during wait
    [[ $RUNNING -eq 1 ]] || return 1

    # Restore audio output if PipeWire/PulseAudio auto-switched to phone
    if [[ -n "$_prev_sink" ]] && command -v pactl &>/dev/null; then
        _curr_sink=$(pactl get-default-sink 2>/dev/null)
        if [[ "$_curr_sink" != "$_prev_sink" ]]; then
            pactl set-default-sink "$_prev_sink" 2>/dev/null
            log "restored audio output to $_prev_sink"
        fi
    fi

    if is_connected; then
        log "phone reconnected successfully"
        return 0
    else
        log "reconnect failed — phone may be out of range"
        return 1
    fi
}

# ── lock screen ───────────────────────────────────────────────────────────────

lock_session() {
    log "locking session"
    notify "screen locked" "phone disconnected"

    local session
    session=$(loginctl show-user "$USER" --property=Sessions --value 2>/dev/null \
              | tr ' ' '\n' | grep -m1 '[0-9]')

    [[ -n "$session" ]] && loginctl lock-session "$session" && return

    dbus-send --session --dest=org.gnome.ScreenSaver --type=method_call \
        /org/gnome/ScreenSaver org.gnome.ScreenSaver.Lock &>/dev/null && return

    command -v gnome-screensaver-command &>/dev/null \
        && gnome-screensaver-command --lock && return

    command -v xdg-screensaver &>/dev/null \
        && xdg-screensaver lock && return

    log "no lock command found"
}

# ── suspend/wake ──────────────────────────────────────────────────────────────

handle_wake() {
    local now last=0 delta
    now=$(awk '{print int($1)}' /proc/uptime)
    [[ -f "$WAKE_FILE" ]] && last=$(cat "$WAKE_FILE" 2>/dev/null)
    echo "$now" > "$WAKE_FILE"

    local normal_max=$(( POLL_INTERVAL + 15 ))
    delta=$(( now - last ))

    # normal tick
    [[ $last -eq 0 ]] || [[ $delta -lt $normal_max && $delta -ge 0 ]] && return

    # woke from suspend — always reset miss counter
    if [[ $MISS -gt 0 ]]; then
        log "wake detected (${delta}s gap), resetting miss counter"
        MISS=0
        save_state
    fi

    # also reset reconnect backoff on wake (phone might be nearby now)
    if [[ $RECONNECT_FAILURES -gt 0 ]]; then
        log "wake detected, resetting reconnect backoff"
        RECONNECT_FAILURES=0
        LAST_RECONNECT_TIME=0
    fi
}

# ── main ──────────────────────────────────────────────────────────────────────
load_state
log "started: $PHONE_MAC poll=${POLL_INTERVAL}s threshold=$MISS_THRESHOLD"

_PAUSED=0
PREV_SEEN=$SEEN
PREV_LOCKED=$LOCKED
LAST_RECONNECT_TIME=0
RECONNECT_FAILURES=0

while [[ $RUNNING -eq 1 ]]; do
    if [[ $LOCKED -eq 1 ]]; then
        isleep 5
    else
        isleep "$POLL_INTERVAL"
    fi

    [[ $RUNNING -eq 1 ]] || break

    handle_wake

    # pause check
    if [[ -f "$PAUSE_FILE" ]]; then
        [[ "$_PAUSED" -eq 0 ]] && { log "paused"; notify "dynamic lock paused" ""; _PAUSED=1; }
        continue
    fi
    [[ "$_PAUSED" -eq 1 ]] && { log "resumed"; notify "dynamic lock resumed" ""; _PAUSED=0; MISS=0; }

    # BT adapter check — don't count misses if adapter is down
    if ! is_bt_adapter_up; then
        [[ $MISS -gt 0 ]] && { log "BT adapter down, resetting miss counter"; MISS=0; }
        continue
    fi

    if is_connected; then
        # phone is here
        [[ $SEEN -eq 0 ]] && { log "phone detected, monitoring active"; notify "dynamic lock active" ""; }
        [[ $LOCKED -eq 1 ]] && { log "phone returned, re-armed"; notify "phone returned" "re-armed"; }
        SEEN=1; MISS=0; LOCKED=0
        RECONNECT_FAILURES=0
    else
        # phone gone
        [[ $SEEN -eq 0 ]] && continue  # never seen, do nothing

        # already locked — try auto-reconnect with exponential backoff
        if [[ $LOCKED -eq 1 ]]; then
            _now=$(awk '{print int($1)}' /proc/uptime)
            _elapsed=$(( _now - LAST_RECONNECT_TIME ))
            _backoff=$(get_backoff_interval)

            if [[ $_elapsed -ge $_backoff ]]; then
                LAST_RECONNECT_TIME=$_now
                if try_reconnect; then
                    log "reconnected to phone!"
                    notify "phone reconnected" "auto-reconnect succeeded"
                    SEEN=1; MISS=0; LOCKED=0
                    RECONNECT_FAILURES=0
                else
                    (( RECONNECT_FAILURES++ ))
                    _next=$(get_backoff_interval)
                    log "reconnect attempt $RECONNECT_FAILURES failed, next in ${_next}s"
                fi
            fi
            continue
        fi

        (( MISS++ ))
        log "miss $MISS/$MISS_THRESHOLD"
        if [[ $MISS -ge $MISS_THRESHOLD ]]; then
            lock_session
            LOCKED=1; MISS=0
            RECONNECT_FAILURES=0
            LAST_RECONNECT_TIME=0  # first reconnect attempt starts immediately
        fi
    fi

    # save only on change
    if [[ $SEEN -ne $PREV_SEEN || $LOCKED -ne $PREV_LOCKED ]]; then
        save_state
        PREV_SEEN=$SEEN; PREV_LOCKED=$LOCKED
    fi
done

log "exited main loop"
