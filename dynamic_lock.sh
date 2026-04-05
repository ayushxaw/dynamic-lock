#!/bin/bash
#
# dynamic_lock.sh — bluetooth proximity screen lock for linux
#
# monitors a paired phone via bluetoothctl. when the phone disconnects
# for 3 consecutive checks (~3 seconds), the screen locks automatically.
# when the phone reconnects, the lock re-arms — just like windows dynamic lock.
#
# usage:
#   dynamic_lock.sh              run the daemon (normally via systemd)
#   dynamic_lock.sh --status     show current state (armed/locked/scanning)
#   dynamic_lock.sh --help       show this help
#   dynamic_lock.sh --version    show version
#
# config:  ~/.config/dynamic_lock/config
# logs:    journalctl -t dynamic_lock -f
# pause:   touch ~/.dynamic_lock_pause
# resume:  rm ~/.dynamic_lock_pause
#

VERSION="5.0.0"

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

    pid=$(pgrep -xf "/bin/bash.*dynamic_lock.sh\$" 2>/dev/null \
          | grep -vE "^($$|$PPID)$" | head -1)

    if [[ -z "$pid" ]]; then
        echo "● dynamic_lock is not running"
        exit 1
    fi

    echo "● dynamic_lock is running (PID $pid)"

    if [[ -f "$pause_file" ]]; then
        echo "  State:   PAUSED"
    elif [[ -f "$state_file" ]]; then
        read -r s l m < "$state_file" 2>/dev/null
        if [[ "${l:-0}" -eq 1 ]]; then
            echo "  State:   LOCKED (scanning for phone)"
        elif [[ "${s:-0}" -eq 1 ]]; then
            echo "  State:   ARMED (monitoring phone)"
        else
            echo "  State:   WAITING (phone not yet seen)"
        fi
    fi

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
LOG_TAG="dynamic_lock"

# ── signal handling ───────────────────────────────────────────────────────────

RUNNING=1
RECONNECT_PID=""

cleanup() {
    log "shutting down"
    RUNNING=0
    if [[ -n "$RECONNECT_PID" ]]; then
        kill -- -"$RECONNECT_PID" 2>/dev/null
        kill "$RECONNECT_PID" 2>/dev/null
        wait "$RECONNECT_PID" 2>/dev/null
    fi
    kill %% 2>/dev/null
    rm -f "$LOCK_FILE" 2>/dev/null
    # intentionally keep STATE_FILE — --status reads it after exit
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
LOCK_CMD=""
GRACE_PERIOD=10
WAKE_GRACE_PERIOD=15

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

if [[ -z "$PHONE_MAC" ]]; then
    echo "error: PHONE_MAC not set in $CONFIG_FILE"
    echo "       run: bluetoothctl devices"
    exit 1
fi

if ! [[ "$PHONE_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    echo "error: invalid MAC format: $PHONE_MAC"
    exit 1
fi

[[ "$POLL_INTERVAL" -lt 1 ]] 2>/dev/null   && POLL_INTERVAL=1
[[ "$POLL_INTERVAL" -gt 60 ]] 2>/dev/null  && POLL_INTERVAL=60
[[ "$MISS_THRESHOLD" -lt 1 ]] 2>/dev/null  && MISS_THRESHOLD=1
[[ "$MISS_THRESHOLD" -gt 30 ]] 2>/dev/null && MISS_THRESHOLD=30
[[ "$GRACE_PERIOD" -lt 0 ]] 2>/dev/null    && GRACE_PERIOD=0
[[ "$GRACE_PERIOD" -gt 120 ]] 2>/dev/null  && GRACE_PERIOD=120
[[ "$WAKE_GRACE_PERIOD" -lt 0 ]] 2>/dev/null   && WAKE_GRACE_PERIOD=0
[[ "$WAKE_GRACE_PERIOD" -gt 300 ]] 2>/dev/null && WAKE_GRACE_PERIOD=300

command -v bluetoothctl &>/dev/null || { echo "error: bluetoothctl not found"; exit 1; }

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "error: already running"; exit 1; }

# ── helpers (optimized at init time) ──────────────────────────────────────────

# cache logger availability once — avoids 'command -v' on every log call
if command -v logger &>/dev/null; then
    log() { logger -t "$LOG_TAG" "$*"; }
else
    log() { :; }
fi

notify() {
    [[ "$NOTIFY" -eq 1 ]] || return
    timeout 2 notify-send -a "Dynamic Lock" -i dialog-password "$1" "$2" 2>/dev/null || true
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

isleep() { sleep "$1" & wait $!; }

# read uptime into _UPTIME — pure bash, no fork (called many times per tick)
read_uptime() {
    local raw
    read -r raw _ < /proc/uptime 2>/dev/null
    _UPTIME="${raw%%.*}"
}

# ── bluetooth (D-Bus fast path with bluetoothctl fallback) ────────────────────
#
# dbus-send queries BlueZ properties directly: 1 fork, 6ms per call.
# bluetoothctl spawns an interactive session: 2-3 forks, 19ms per call.
#
# on systems where dbus-send can't reach org.bluez (containers, custom policies),
# we fall back to bluetoothctl automatically. detection happens once at startup.

_USE_DBUS=0
_DBUS_DEV_PATH="/org/bluez/hci0/dev_${PHONE_MAC//:/_}"
_ADAPTER_CHECK_CTR=0
_ADAPTER_CHECK_EVERY=30   # only check adapter power every 30 ticks

init_bluetooth() {
    if command -v dbus-send &>/dev/null && \
       dbus-send --system --dest=org.bluez --print-reply \
           "$_DBUS_DEV_PATH" org.freedesktop.DBus.Properties.Get \
           string:"org.bluez.Device1" string:"Connected" &>/dev/null; then
        _USE_DBUS=1
        log "bluetooth: using dbus (fast path)"
    else
        _USE_DBUS=0
        log "bluetooth: using bluetoothctl (fallback)"
    fi
}

# sets BT_ADAPTER_UP and BT_CONNECTED globals.
# adapter is only checked every 30 ticks (saves 1 fork 97% of the time).
poll_bluetooth() {
    BT_CONNECTED=0

    # throttle adapter check — it rarely changes
    (( _ADAPTER_CHECK_CTR++ ))
    if [[ $_ADAPTER_CHECK_CTR -ge $_ADAPTER_CHECK_EVERY ]] || [[ $BT_ADAPTER_UP -eq 0 ]]; then
        _ADAPTER_CHECK_CTR=0
        BT_ADAPTER_UP=0

        if [[ $_USE_DBUS -eq 1 ]]; then
            local out
            out=$(dbus-send --system --dest=org.bluez --print-reply \
                /org/bluez/hci0 org.freedesktop.DBus.Properties.Get \
                string:"org.bluez.Adapter1" string:"Powered" 2>/dev/null) || return
            [[ "$out" == *"boolean true"* ]] && BT_ADAPTER_UP=1
        else
            local out
            out=$(timeout 2 bluetoothctl show 2>/dev/null) || return
            [[ "$out" == *"Powered: yes"* ]] && BT_ADAPTER_UP=1
        fi
    fi

    [[ $BT_ADAPTER_UP -eq 1 ]] || return

    # connection check (runs every tick)
    if [[ $_USE_DBUS -eq 1 ]]; then
        local out
        out=$(dbus-send --system --dest=org.bluez --print-reply \
            "$_DBUS_DEV_PATH" org.freedesktop.DBus.Properties.Get \
            string:"org.bluez.Device1" string:"Connected" 2>/dev/null) || return
        [[ "$out" == *"boolean true"* ]] && BT_CONNECTED=1
    else
        local out
        out=$(timeout 3 bluetoothctl info "$PHONE_MAC" 2>/dev/null) || return
        [[ "$out" == *"Connected: yes"* ]] && BT_CONNECTED=1
    fi
}

# backoff: 45 → 90 → 180 → 300(cap). result in _BACKOFF (no subshell fork).
calc_backoff() {
    local shift=$RECONNECT_FAILURES
    [[ $shift -gt 3 ]] && shift=3
    _BACKOFF=$(( RECONNECT_INTERVAL << shift ))
    [[ $_BACKOFF -gt $MAX_RECONNECT_INTERVAL ]] && _BACKOFF=$MAX_RECONNECT_INTERVAL
}

# reconnect to the phone.
# sequence: quick check → BLE scan → connect → verify
# runs scan+connect in a killable subshell for instant shutdown.
try_reconnect() {
    [[ "$AUTO_RECONNECT" -eq 1 ]] || return 1

    # quick check — maybe the phone already reconnected on its own
    poll_bluetooth
    if [[ $BT_CONNECTED -eq 1 ]]; then
        log "phone already reconnected"
        return 0
    fi

    log "scanning for $PHONE_MAC"

    # save audio sink before connecting
    local prev_sink=""
    command -v pactl &>/dev/null && prev_sink=$(pactl get-default-sink 2>/dev/null)

    # scan + connect in killable subshell
    (
        timeout 6 bluetoothctl --timeout 5 scan on &>/dev/null
        sleep 1
        timeout 10 bluetoothctl connect "$PHONE_MAC" &>/dev/null
    ) &
    RECONNECT_PID=$!
    wait $RECONNECT_PID 2>/dev/null
    RECONNECT_PID=""

    [[ $RUNNING -eq 1 ]] || return 1

    # restore audio if hijacked
    if [[ -n "$prev_sink" ]] && command -v pactl &>/dev/null; then
        local curr_sink
        curr_sink=$(pactl get-default-sink 2>/dev/null)
        if [[ "$curr_sink" != "$prev_sink" ]]; then
            pactl set-default-sink "$prev_sink" 2>/dev/null
            log "restored audio output"
        fi
    fi

    # stability check — verify connection holds for 2 seconds
    poll_bluetooth
    if [[ $BT_CONNECTED -eq 1 ]]; then
        isleep 2
        [[ $RUNNING -eq 1 ]] || return 1
        poll_bluetooth
        if [[ $BT_CONNECTED -eq 1 ]]; then
            log "phone reconnected (stable)"
            return 0
        fi
        log "phone connected briefly but dropped"
    fi

    log "reconnect failed"
    return 1
}

# ── lock screen ───────────────────────────────────────────────────────────────

lock_session() {
    log "locking session"
    notify "screen locked" "phone disconnected"

    # custom lock command
    if [[ -n "$LOCK_CMD" ]]; then
        eval "$LOCK_CMD" &>/dev/null && return
        log "custom LOCK_CMD failed, trying fallbacks"
    fi

    # loginctl
    local session
    session=$(loginctl show-user "$USER" --property=Sessions --value 2>/dev/null \
              | tr ' ' '\n' | grep -m1 '[0-9]')
    [[ -n "$session" ]] && loginctl lock-session "$session" && return

    # GNOME dbus
    dbus-send --session --dest=org.gnome.ScreenSaver --type=method_call \
        /org/gnome/ScreenSaver org.gnome.ScreenSaver.Lock &>/dev/null && return

    # gnome-screensaver
    command -v gnome-screensaver-command &>/dev/null \
        && gnome-screensaver-command --lock && return

    # xdg-screensaver
    command -v xdg-screensaver &>/dev/null \
        && xdg-screensaver lock && return

    log "warning: no lock method found"
}

# ── suspend/wake detection ────────────────────────────────────────────────────
# tracks uptime in memory — no file I/O per tick (was 2 file ops per tick).
# detects gaps in uptime that indicate resume from suspend.

_LAST_UPTIME=0
_FIRST_TICK=1

handle_wake() {
    read_uptime
    local delta=$(( _UPTIME - _LAST_UPTIME ))
    local prev=$_LAST_UPTIME
    _LAST_UPTIME=$_UPTIME

    # first tick — nothing to compare
    [[ $_FIRST_TICK -eq 1 ]] && { _FIRST_TICK=0; return; }

    local normal_max=$(( POLL_INTERVAL + 15 ))
    [[ $delta -lt $normal_max && $delta -ge 0 ]] && return

    # resumed from suspend
    log "resume detected (${delta}s gap)"
    MISS=0; save_state
    RECONNECT_FAILURES=0; LAST_RECONNECT_TIME=0
    # force adapter re-check after wake
    _ADAPTER_CHECK_CTR=$_ADAPTER_CHECK_EVERY
    # prevent immediate lock right after waking up while BT is connecting
    GRACE_UNTIL=$(( _UPTIME + WAKE_GRACE_PERIOD ))
}

# ── main loop ─────────────────────────────────────────────────────────────────

load_state
init_bluetooth
BT_ADAPTER_UP=1  # assume adapter is up until proven otherwise
log "started v$VERSION: phone=$PHONE_MAC poll=${POLL_INTERVAL}s threshold=$MISS_THRESHOLD"

_PAUSED=0
PREV_SEEN=$SEEN
PREV_LOCKED=$LOCKED
LAST_RECONNECT_TIME=0
RECONNECT_FAILURES=0
GRACE_UNTIL=0

# write initial state immediately so --status always has a file to read
save_state

while [[ $RUNNING -eq 1 ]]; do

    if [[ $LOCKED -eq 1 ]]; then
        isleep 5
    else
        isleep "$POLL_INTERVAL"
    fi

    [[ $RUNNING -eq 1 ]] || break

    handle_wake

    # pause/resume
    if [[ -f "$PAUSE_FILE" ]]; then
        [[ "$_PAUSED" -eq 0 ]] && { log "paused"; notify "paused" "dynamic lock paused"; _PAUSED=1; }
        continue
    fi
    [[ "$_PAUSED" -eq 1 ]] && { log "resumed"; notify "resumed" "dynamic lock active"; _PAUSED=0; MISS=0; }

    # poll bluetooth (combined adapter + connection check)
    poll_bluetooth

    if [[ $BT_ADAPTER_UP -eq 0 ]]; then
        [[ $MISS -gt 0 ]] && { log "adapter down, resetting misses"; MISS=0; }
        continue
    fi

    # ── connection logic ──────────────────────────────────────────────────
    if [[ $BT_CONNECTED -eq 1 ]]; then
        [[ $SEEN -eq 0 ]] && { log "phone detected"; notify "armed" "monitoring phone"; }
        [[ $LOCKED -eq 1 ]] && { log "phone returned, re-armed"; notify "re-armed" "phone reconnected"; }
        SEEN=1; MISS=0; LOCKED=0
        RECONNECT_FAILURES=0
    else
        [[ $SEEN -eq 0 ]] && continue

        # grace period — skip miss counting right after reconnect
        if [[ $GRACE_UNTIL -gt 0 ]]; then
            read_uptime
            if [[ $_UPTIME -lt $GRACE_UNTIL ]]; then
                continue
            fi
            GRACE_UNTIL=0
        fi

        # already locked — try reconnecting with backoff
        if [[ $LOCKED -eq 1 ]]; then
            read_uptime
            _elapsed=$(( _UPTIME - LAST_RECONNECT_TIME ))
            calc_backoff

            if [[ $_elapsed -ge $_BACKOFF ]]; then
                LAST_RECONNECT_TIME=$_UPTIME
                if try_reconnect; then
                    notify "reconnected" "auto-reconnect succeeded"
                    SEEN=1; MISS=0; LOCKED=0
                    RECONNECT_FAILURES=0
                    read_uptime
                    GRACE_UNTIL=$(( _UPTIME + GRACE_PERIOD ))
                else
                    (( RECONNECT_FAILURES++ ))
                    calc_backoff
                    log "attempt $RECONNECT_FAILURES failed, retry in ${_BACKOFF}s"
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

    # save on transitions
    if [[ $SEEN -ne $PREV_SEEN || $LOCKED -ne $PREV_LOCKED ]]; then
        save_state
        PREV_SEEN=$SEEN; PREV_LOCKED=$LOCKED
    fi
done

log "stopped"
