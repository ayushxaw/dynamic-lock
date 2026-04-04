#!/bin/bash
#
# dynamic_lock.sh — bluetooth proximity screen lock (v3.0)
# Monitors phone via bluetoothctl; locks screen when it disconnects.
#
# Fixes in v3.0:
#   - Interruptible sleep (sleep & wait) for instant shutdown
#   - Signal trap for SIGTERM/SIGINT/SIGHUP
#   - timeout on bluetoothctl to prevent hangs
#   - Fixed operator precedence on sleep branch
#   - BT adapter power check to prevent false locks during bluetoothd restart
#   - Always reset MISS on wake to prevent false locks after deep sleep
#

CONFIG_FILE="$HOME/.config/dynamic_lock/config"
STATE_FILE="/tmp/dynamic_lock_state_$UID"
LOCK_FILE="/tmp/dynamic_lock_$UID.lock"
PAUSE_FILE="$HOME/.dynamic_lock_pause"
WAKE_FILE="/tmp/dynamic_lock_wake_$UID"
LOG_TAG="dynamic_lock"

# ── signal handling ───────────────────────────────────────────────────────────
# Catch SIGTERM (systemd stop), SIGINT (Ctrl-C), SIGHUP so we exit instantly
# instead of making systemd wait 90s during shutdown/suspend.
RUNNING=1
cleanup() {
    log "received shutdown signal, exiting cleanly"
    RUNNING=0
    # kill any backgrounded sleep so we don't leave orphans
    kill %% 2>/dev/null
    # preserve STATE_FILE so we remember SEEN=1 across restarts
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
RECONNECT_INTERVAL=45  # seconds between reconnect attempts when locked

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

# logging
log() { command -v logger &>/dev/null && logger -t "$LOG_TAG" "$*"; }

notify() {
    [[ "$NOTIFY" -eq 1 ]] || return
    notify-send -a "Dynamic Lock" -i dialog-password "$1" "$2" 2>/dev/null || true
}

# state persistence
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

# ── interruptible sleep ──────────────────────────────────────────────────────
# Plain 'sleep N' blocks signal handling in bash. By backgrounding sleep
# and using 'wait', the trap fires immediately when a signal arrives.
isleep() {
    sleep "$1" &
    wait $!
}

# ── bluetooth checks ─────────────────────────────────────────────────────────

# Check if the BT adapter itself is powered on.
# Prevents false locks when bluetoothd restarts or adapter is temporarily down.
is_bt_adapter_up() {
    timeout 2 bluetoothctl show 2>/dev/null | grep -q "Powered: yes"
}

# Check if the phone is connected.
# timeout prevents hang if BT adapter is down during shutdown.
is_connected() {
    timeout 3 bluetoothctl info "$PHONE_MAC" 2>/dev/null | grep -q "Connected: yes"
}

# Try to reconnect to the phone.
# The key insight: Android phones ignore incoming classic BT connections
# from PCs UNLESS you scan first. The BLE scan "wakes up" the phone's
# BT stack, after which bluetoothctl connect succeeds immediately.
# Sequence: scan → connect → verify
try_reconnect() {
    [[ "$AUTO_RECONNECT" -eq 1 ]] || return 1
    log "scanning for $PHONE_MAC"

    # Step 1: BLE scan to wake up the phone's BT stack (~5 seconds)
    timeout 6 bluetoothctl --timeout 5 scan on &>/dev/null
    sleep 1

    # Step 2: Now connect — phone is receptive after being scanned
    log "connecting to $PHONE_MAC"
    timeout 10 bluetoothctl connect "$PHONE_MAC" &>/dev/null

    # Step 3: Verify
    if is_connected; then
        log "phone reconnected successfully"
        return 0
    else
        log "reconnect failed — phone may be out of range"
        return 1
    fi
}

# lock screen
lock_session() {
    log "locking session"
    notify "screen locked" "phone disconnected"

    # try loginctl first, then fallbacks
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

# suspend/wake — reset miss counter after lid open so we don't
# false-lock while BT adapter is still reconnecting.
# Always resets MISS on wake regardless of suspend duration, because the
# BT adapter needs time to re-initialize after any sleep.
handle_wake() {
    local now last=0 delta
    now=$(awk '{print int($1)}' /proc/uptime)
    [[ -f "$WAKE_FILE" ]] && last=$(cat "$WAKE_FILE" 2>/dev/null)
    echo "$now" > "$WAKE_FILE"

    local normal_max=$(( POLL_INTERVAL + 15 ))
    delta=$(( now - last ))

    # normal tick — no gap detected
    [[ $last -eq 0 ]] || [[ $delta -lt $normal_max && $delta -ge 0 ]] && return

    # woke from suspend (any duration) — always reset miss counter
    # BT adapter needs time to reconnect after sleep, don't false-lock
    if [[ $MISS -gt 0 ]]; then
        log "wake detected (${delta}s gap), resetting miss counter"
        MISS=0
        save_state
    fi
}

# ── main ──────────────────────────────────────────────────────────────────────
load_state
log "started: $PHONE_MAC poll=${POLL_INTERVAL}s threshold=$MISS_THRESHOLD"

_PAUSED=0
PREV_SEEN=$SEEN
PREV_LOCKED=$LOCKED
LAST_RECONNECT_TIME=0

while [[ $RUNNING -eq 1 ]]; do
    # FIX: proper if/else instead of && || to avoid operator precedence bug
    if [[ $LOCKED -eq 1 ]]; then
        isleep 5
    else
        isleep "$POLL_INTERVAL"
    fi

    # check if we were signalled during sleep
    [[ $RUNNING -eq 1 ]] || break

    handle_wake

    # pause check
    if [[ -f "$PAUSE_FILE" ]]; then
        [[ "$_PAUSED" -eq 0 ]] && { log "paused"; notify "dynamic lock paused" ""; _PAUSED=1; }
        continue
    fi
    [[ "$_PAUSED" -eq 1 ]] && { log "resumed"; notify "dynamic lock resumed" ""; _PAUSED=0; MISS=0; }

    # FIX: check if BT adapter is up before counting misses.
    # If the adapter is down (bluetoothd restart, system update, etc.),
    # don't count misses — the phone isn't really "gone", BT is just offline.
    if ! is_bt_adapter_up; then
        [[ $MISS -gt 0 ]] && { log "BT adapter down, resetting miss counter"; MISS=0; }
        continue
    fi

    if is_connected; then
        # phone is here
        [[ $SEEN -eq 0 ]] && { log "phone detected, monitoring active"; notify "dynamic lock active" ""; }
        [[ $LOCKED -eq 1 ]] && { log "phone returned, re-armed"; notify "phone returned" "re-armed"; }
        SEEN=1; MISS=0; LOCKED=0
    else
        # phone gone
        [[ $SEEN -eq 0 ]] && continue  # never seen, do nothing

        # already locked — try auto-reconnect periodically using timestamps
        if [[ $LOCKED -eq 1 ]]; then
            _now=$(awk '{print int($1)}' /proc/uptime)
            _elapsed=$(( _now - LAST_RECONNECT_TIME ))
            if [[ $_elapsed -ge $RECONNECT_INTERVAL ]]; then
                LAST_RECONNECT_TIME=$_now
                if try_reconnect; then
                    log "reconnected to phone!"
                    notify "phone reconnected" "auto-reconnect succeeded"
                    SEEN=1; MISS=0; LOCKED=0
                fi
            fi
            continue
        fi

        (( MISS++ ))
        log "miss $MISS/$MISS_THRESHOLD"
        if [[ $MISS -ge $MISS_THRESHOLD ]]; then
            lock_session
            LOCKED=1; MISS=0
        fi
    fi

    # save only on change
    if [[ $SEEN -ne $PREV_SEEN || $LOCKED -ne $PREV_LOCKED ]]; then
        save_state
        PREV_SEEN=$SEEN; PREV_LOCKED=$LOCKED
    fi
done

log "exited main loop"
