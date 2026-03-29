#!/bin/bash
#
# dynamic_lock.sh — bluetooth proximity screen lock
# checks if phone is connected via bluetoothctl, locks screen if it drops
#

CONFIG_FILE="$HOME/.config/dynamic_lock/config"
STATE_FILE="/tmp/dynamic_lock_state_$UID"
LOCK_FILE="/tmp/dynamic_lock_$UID.lock"
PAUSE_FILE="$HOME/.dynamic_lock_pause"
WAKE_FILE="/tmp/dynamic_lock_wake_$UID"
LOG_TAG="dynamic_lock"

# defaults
PHONE_MAC=""
POLL_INTERVAL=1
MISS_THRESHOLD=3
NOTIFY=1

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

# connection check — passive, no ping, no sudo
is_connected() {
    bluetoothctl info "$PHONE_MAC" 2>/dev/null | grep -q "Connected: yes"
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
# false-lock while BT adapter is still reconnecting
handle_wake() {
    local now last=0 delta
    now=$(awk '{print int($1)}' /proc/uptime)
    [[ -f "$WAKE_FILE" ]] && last=$(cat "$WAKE_FILE" 2>/dev/null)
    echo "$now" > "$WAKE_FILE"

    local normal_max=$(( POLL_INTERVAL + 15 ))
    delta=$(( now - last ))

    # normal tick
    [[ $last -eq 0 ]] || [[ $delta -lt $normal_max && $delta -ge 0 ]] && return

    # woke from suspend
    if [[ $delta -lt 300 && $MISS -gt 0 ]]; then
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

while true; do
    [[ $LOCKED -eq 1 ]] && sleep 5 || sleep "$POLL_INTERVAL"

    handle_wake

    # pause check
    if [[ -f "$PAUSE_FILE" ]]; then
        [[ "$_PAUSED" -eq 0 ]] && { log "paused"; notify "dynamic lock paused" ""; _PAUSED=1; }
        continue
    fi
    [[ "$_PAUSED" -eq 1 ]] && { log "resumed"; notify "dynamic lock resumed" ""; _PAUSED=0; MISS=0; }

    if is_connected; then
        # phone is here
        [[ $SEEN -eq 0 ]] && { log "phone detected, monitoring active"; notify "dynamic lock active" ""; }
        [[ $LOCKED -eq 1 ]] && { log "phone returned, re-armed"; notify "phone returned" "re-armed"; }
        SEEN=1; MISS=0; LOCKED=0
    else
        # phone gone
        [[ $SEEN -eq 0 ]] && continue  # never seen, do nothing
        [[ $LOCKED -eq 1 ]] && continue  # already locked, no spam

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
