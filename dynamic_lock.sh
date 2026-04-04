#!/bin/bash
#
# dynamic_lock.sh — bluetooth proximity screen lock for linux
#
# monitors a paired phone via bluetoothctl. when the phone disconnects
# for 3 consecutive checks (~3 seconds), the screen locks automatically.
# when the phone reconnects, the lock re-arms — just like windows dynamic lock.
#
# usage:
#   dynamic_lock.sh              run the daemon (normally started via systemd)
#   dynamic_lock.sh --status     show current state (armed/locked/scanning)
#   dynamic_lock.sh --help       show this help
#   dynamic_lock.sh --version    show version
#
# config:  ~/.config/dynamic_lock/config
# logs:    journalctl -t dynamic_lock -f
# pause:   touch ~/.dynamic_lock_pause
# resume:  rm ~/.dynamic_lock_pause
#

VERSION="4.1.0"

# ── CLI flags ─────────────────────────────────────────────────────────────────

show_help() {
    sed -n '2,18p' "$0" | sed 's/^# \?//'
    exit 0
}

show_version() {
    echo "dynamic_lock $VERSION"
    exit 0
}

show_status() {
    local state_file="/tmp/dynamic_lock_state_$UID"
    local pause_file="$HOME/.dynamic_lock_pause"
    local pid

    pid=$(pgrep -f "dynamic_lock.sh$" | grep -v "$$" | head -1)

    if [[ -z "$pid" ]]; then
        echo "● dynamic_lock is not running"
        exit 1
    fi

    echo "● dynamic_lock is running (PID $pid)"

    if [[ -f "$pause_file" ]]; then
        echo "  State:   PAUSED"
    elif [[ -f "$state_file" ]]; then
        read -r s l m < "$state_file" 2>/dev/null
        if [[ "$l" -eq 1 ]]; then
            echo "  State:   LOCKED (scanning for phone)"
        elif [[ "$s" -eq 1 ]]; then
            echo "  State:   ARMED (monitoring phone)"
        else
            echo "  State:   WAITING (phone not yet seen)"
        fi
    fi

    # show last few log lines
    echo "  Recent:"
    journalctl -t dynamic_lock -n 5 --no-pager -o cat 2>/dev/null | sed 's/^/    /'
    exit 0
}

case "${1:-}" in
    --help|-h)    show_help ;;
    --version|-v) show_version ;;
    --status|-s)  show_status ;;
esac

# ── paths ─────────────────────────────────────────────────────────────────────

CONFIG_FILE="$HOME/.config/dynamic_lock/config"
STATE_FILE="/tmp/dynamic_lock_state_$UID"
LOCK_FILE="/tmp/dynamic_lock_$UID.lock"
PAUSE_FILE="$HOME/.dynamic_lock_pause"
WAKE_FILE="/tmp/dynamic_lock_wake_$UID"
LOG_TAG="dynamic_lock"

# ── signal handling ───────────────────────────────────────────────────────────
# trap SIGTERM (systemd stop), SIGINT (ctrl-c), SIGHUP so the service
# exits instantly during shutdown instead of waiting for the default 90s.

RUNNING=1
RECONNECT_PID=""

cleanup() {
    log "shutting down"
    RUNNING=0
    # kill any running reconnect subshell
    if [[ -n "$RECONNECT_PID" ]]; then
        kill "$RECONNECT_PID" 2>/dev/null
        wait "$RECONNECT_PID" 2>/dev/null
    fi
    kill %% 2>/dev/null
    rm -f "$LOCK_FILE" "$WAKE_FILE" 2>/dev/null
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# ── config ────────────────────────────────────────────────────────────────────

PHONE_MAC=""
POLL_INTERVAL=1
MISS_THRESHOLD=3
NOTIFY=1
AUTO_RECONNECT=1
RECONNECT_INTERVAL=45
MAX_RECONNECT_INTERVAL=300

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# validate required config
if [[ -z "$PHONE_MAC" ]]; then
    echo "error: PHONE_MAC not set in $CONFIG_FILE"
    echo "       run: bluetoothctl devices"
    exit 1
fi

if ! [[ "$PHONE_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    echo "error: invalid MAC address format: $PHONE_MAC"
    exit 1
fi

# clamp config values to sane ranges
[[ "$POLL_INTERVAL" -lt 1 ]] 2>/dev/null   && POLL_INTERVAL=1
[[ "$POLL_INTERVAL" -gt 60 ]] 2>/dev/null  && POLL_INTERVAL=60
[[ "$MISS_THRESHOLD" -lt 1 ]] 2>/dev/null  && MISS_THRESHOLD=1
[[ "$MISS_THRESHOLD" -gt 30 ]] 2>/dev/null && MISS_THRESHOLD=30

command -v bluetoothctl &>/dev/null || { echo "error: bluetoothctl not found"; exit 1; }

# single instance — prevents duplicate daemons
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "error: already running"; exit 1; }

# ── helpers ───────────────────────────────────────────────────────────────────

log() {
    command -v logger &>/dev/null && logger -t "$LOG_TAG" "$*"
}

notify() {
    [[ "$NOTIFY" -eq 1 ]] || return
    # timeout prevents hang if notification daemon is stuck
    timeout 2 notify-send -a "Dynamic Lock" -i dialog-password "$1" "$2" 2>/dev/null || true
}

save_state() {
    echo "$SEEN $LOCKED $MISS" > "$STATE_FILE"
}

load_state() {
    SEEN=0; LOCKED=0; MISS=0
    if [[ -f "$STATE_FILE" ]]; then
        read -r s l m < "$STATE_FILE" 2>/dev/null || return
        [[ "$s" =~ ^[01]$ ]]   && SEEN=$s
        [[ "$l" =~ ^[01]$ ]]   && LOCKED=$l
        [[ "$m" =~ ^[0-9]+$ ]] && MISS=$m
    fi
}

# interruptible sleep — backgrounded so signals can interrupt via wait
isleep() {
    sleep "$1" &
    wait $!
}

# ── bluetooth ─────────────────────────────────────────────────────────────────

# check if the bt adapter is powered on.
# prevents false locks when bluetoothd restarts or adapter goes down.
is_bt_adapter_up() {
    timeout 2 bluetoothctl show 2>/dev/null | grep -q "Powered: yes"
}

# check if the phone is connected. timeout prevents hangs during shutdown.
is_connected() {
    timeout 3 bluetoothctl info "$PHONE_MAC" 2>/dev/null | grep -q "Connected: yes"
}

# exponential backoff: 45 → 90 → 180 → 300(cap).
# reduces battery usage when the phone is genuinely out of range.
get_backoff_interval() {
    local shift=$RECONNECT_FAILURES
    [[ $shift -gt 3 ]] && shift=3
    local interval=$(( RECONNECT_INTERVAL << shift ))
    [[ $interval -gt $MAX_RECONNECT_INTERVAL ]] && interval=$MAX_RECONNECT_INTERVAL
    echo "$interval"
}

# reconnect to the phone.
#
# android phones don't auto-accept incoming BT connections from PCs the
# way they do for earbuds (which use A2DP/HFP auto-reconnect). the trick
# is to trigger a BLE scan first — this "wakes up" the phone's BT stack,
# after which bluetoothctl connect succeeds immediately.
#
# the scan+connect runs in a subshell so SIGTERM can interrupt it via wait
# (otherwise a shutdown would block for up to 17 seconds).
#
# after connecting, audio output is restored to prevent PipeWire/PulseAudio
# from routing laptop audio through the phone speaker.
try_reconnect() {
    [[ "$AUTO_RECONNECT" -eq 1 ]] || return 1
    log "scanning for $PHONE_MAC"

    # save current audio sink
    local prev_sink=""
    command -v pactl &>/dev/null && prev_sink=$(pactl get-default-sink 2>/dev/null)

    # run in subshell — killable on shutdown
    (
        timeout 6 bluetoothctl --timeout 5 scan on &>/dev/null
        sleep 1
        timeout 10 bluetoothctl connect "$PHONE_MAC" &>/dev/null
    ) &
    RECONNECT_PID=$!
    wait $RECONNECT_PID 2>/dev/null
    RECONNECT_PID=""

    [[ $RUNNING -eq 1 ]] || return 1

    # restore audio if it was hijacked
    if [[ -n "$prev_sink" ]] && command -v pactl &>/dev/null; then
        local curr_sink
        curr_sink=$(pactl get-default-sink 2>/dev/null)
        if [[ "$curr_sink" != "$prev_sink" ]]; then
            pactl set-default-sink "$prev_sink" 2>/dev/null
            log "restored audio output"
        fi
    fi

    # verify connection is stable (wait 2s then re-check)
    if is_connected; then
        sleep 2
        if is_connected; then
            log "phone reconnected (stable)"
            return 0
        fi
        log "phone connected briefly but dropped"
    fi

    log "reconnect failed"
    return 1
}

# ── lock screen ───────────────────────────────────────────────────────────────
# tries multiple lock commands in order of preference.
# works on GNOME (wayland/x11), KDE, XFCE, and most systemd distros.

lock_session() {
    log "locking session"
    notify "screen locked" "phone disconnected"

    # method 1: loginctl (works on most systemd distros)
    local session
    session=$(loginctl show-user "$USER" --property=Sessions --value 2>/dev/null \
              | tr ' ' '\n' | grep -m1 '[0-9]')
    [[ -n "$session" ]] && loginctl lock-session "$session" && return

    # method 2: GNOME screensaver dbus
    dbus-send --session --dest=org.gnome.ScreenSaver --type=method_call \
        /org/gnome/ScreenSaver org.gnome.ScreenSaver.Lock &>/dev/null && return

    # method 3: gnome-screensaver-command
    command -v gnome-screensaver-command &>/dev/null \
        && gnome-screensaver-command --lock && return

    # method 4: xdg-screensaver (generic fallback)
    command -v xdg-screensaver &>/dev/null \
        && xdg-screensaver lock && return

    log "warning: no lock command found"
}

# ── suspend/wake detection ────────────────────────────────────────────────────
# detects resume from suspend by checking for gaps in /proc/uptime.
# resets miss counter and reconnect backoff so we don't false-lock while
# the bluetooth adapter is still re-initializing after sleep.

handle_wake() {
    local now last=0 delta
    now=$(awk '{print int($1)}' /proc/uptime)
    [[ -f "$WAKE_FILE" ]] && last=$(cat "$WAKE_FILE" 2>/dev/null)
    echo "$now" > "$WAKE_FILE"

    local normal_max=$(( POLL_INTERVAL + 15 ))
    delta=$(( now - last ))

    [[ $last -eq 0 ]] || [[ $delta -lt $normal_max && $delta -ge 0 ]] && return

    # resumed from suspend
    log "resume detected (${delta}s gap)"

    if [[ $MISS -gt 0 ]]; then
        MISS=0
        save_state
    fi

    if [[ $RECONNECT_FAILURES -gt 0 ]]; then
        RECONNECT_FAILURES=0
        LAST_RECONNECT_TIME=0
    fi
}

# ── main loop ─────────────────────────────────────────────────────────────────

load_state
log "started v$VERSION: phone=$PHONE_MAC poll=${POLL_INTERVAL}s threshold=$MISS_THRESHOLD"

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

    # ── pause/resume ──────────────────────────────────────────────────────
    if [[ -f "$PAUSE_FILE" ]]; then
        [[ "$_PAUSED" -eq 0 ]] && { log "paused"; notify "paused" "dynamic lock paused"; _PAUSED=1; }
        continue
    fi
    [[ "$_PAUSED" -eq 1 ]] && { log "resumed"; notify "resumed" "dynamic lock active"; _PAUSED=0; MISS=0; }

    # ── bt adapter check ──────────────────────────────────────────────────
    if ! is_bt_adapter_up; then
        [[ $MISS -gt 0 ]] && { log "adapter down, resetting misses"; MISS=0; }
        continue
    fi

    # ── connection check ──────────────────────────────────────────────────
    if is_connected; then
        [[ $SEEN -eq 0 ]] && { log "phone detected"; notify "armed" "monitoring phone"; }
        [[ $LOCKED -eq 1 ]] && { log "phone returned, re-armed"; notify "re-armed" "phone reconnected"; }
        SEEN=1; MISS=0; LOCKED=0
        RECONNECT_FAILURES=0
    else
        [[ $SEEN -eq 0 ]] && continue

        # already locked — try reconnecting with backoff
        if [[ $LOCKED -eq 1 ]]; then
            _now=$(awk '{print int($1)}' /proc/uptime)
            _elapsed=$(( _now - LAST_RECONNECT_TIME ))
            _backoff=$(get_backoff_interval)

            if [[ $_elapsed -ge $_backoff ]]; then
                LAST_RECONNECT_TIME=$_now
                if try_reconnect; then
                    notify "reconnected" "auto-reconnect succeeded"
                    SEEN=1; MISS=0; LOCKED=0
                    RECONNECT_FAILURES=0
                else
                    (( RECONNECT_FAILURES++ ))
                    _next=$(get_backoff_interval)
                    log "attempt $RECONNECT_FAILURES failed, retry in ${_next}s"
                fi
            fi
            continue
        fi

        # not yet locked — count misses
        (( MISS++ ))
        log "miss $MISS/$MISS_THRESHOLD"
        if [[ $MISS -ge $MISS_THRESHOLD ]]; then
            lock_session
            LOCKED=1; MISS=0
            RECONNECT_FAILURES=0
            LAST_RECONNECT_TIME=0
        fi
    fi

    # persist state on transitions
    if [[ $SEEN -ne $PREV_SEEN || $LOCKED -ne $PREV_LOCKED ]]; then
        save_state
        PREV_SEEN=$SEEN; PREV_LOCKED=$LOCKED
    fi
done

log "stopped"
