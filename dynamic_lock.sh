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
#   dynamic_lock.sh --status     show current state
#   dynamic_lock.sh --pause      pause monitoring temporarily
#   dynamic_lock.sh --resume     resume monitoring
#   dynamic_lock.sh --logs       tail live logs
#   dynamic_lock.sh --help       show this help
#   dynamic_lock.sh --version    show version
#
# config:  ~/.config/dynamic_lock/config
# logs:    journalctl -t dynamic_lock -f
#

VERSION="5.4.0"

# ── CLI flags ─────────────────────────────────────────────────────────────────

PAUSE_FILE="$HOME/.dynamic_lock_pause"

show_help() {
    sed -n '2,17p' "$0" | sed 's/^# \?//'
    exit 0
}

show_version() {
    echo "dynamic_lock $VERSION"
    exit 0
}

show_status() {
    local state_file="/tmp/dynamic_lock_state_$UID"
    local lock_file="/tmp/dynamic_lock_$UID.lock"
    local pid=""

    # prefer reading PID from lock file (reliable, no pgrep false-match)
    [[ -f "$lock_file" ]] && read -r pid < "$lock_file" 2>/dev/null
    # fall back to pgrep if lock file missing or stale
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        pid=$(pgrep -xf "/bin/bash.*dynamic_lock.sh\$" 2>/dev/null \
              | grep -vE "^($$|$PPID)$" | head -1)
    fi

    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        echo "● dynamic_lock is not running"
        exit 1
    fi

    echo "● dynamic_lock is running (PID $pid)"

    if [[ -f "$PAUSE_FILE" ]]; then
        echo "  State:   PAUSED"
    elif [[ -f "$state_file" ]]; then
        local s l m
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

do_pause() {
    touch "$PAUSE_FILE"
    echo "dynamic_lock paused — run 'dynamic_lock.sh --resume' to re-arm"
    exit 0
}

do_resume() {
    rm -f "$PAUSE_FILE"
    echo "dynamic_lock resumed"
    exit 0
}

do_logs() {
    exec journalctl -t dynamic_lock -f --no-pager -o cat
}

case "${1:-}" in
    --help|-h)    show_help ;;
    --version|-v) show_version ;;
    --status|-s)  show_status ;;
    --pause)      do_pause ;;
    --resume)     do_resume ;;
    --logs|-l)    do_logs ;;
esac

# ── paths ─────────────────────────────────────────────────────────────────────

CONFIG_FILE="$HOME/.config/dynamic_lock/config"
STATE_FILE="/tmp/dynamic_lock_state_$UID"
LOCK_FILE="/tmp/dynamic_lock_$UID.lock"
LOG_TAG="dynamic_lock"

# ── signal handling ───────────────────────────────────────────────────────────

RUNNING=1
RECONNECT_PID=""
SLEEP_PID=""        # track isleep PID explicitly (fixes %% killing wrong job)

cleanup() {
    log "shutting down"
    RUNNING=0
    # kill reconnect subshell + all its children
    if [[ -n "$RECONNECT_PID" ]]; then
        kill -- -"$RECONNECT_PID" 2>/dev/null
        kill "$RECONNECT_PID" 2>/dev/null
        wait "$RECONNECT_PID" 2>/dev/null
    fi
    # kill the tracked sleep (not %% which could be wrong job)
    if [[ -n "$SLEEP_PID" ]]; then
        kill "$SLEEP_PID" 2>/dev/null
        wait "$SLEEP_PID" 2>/dev/null
    fi
    rm -f "$LOCK_FILE" 2>/dev/null
    # intentionally keep STATE_FILE — --status reads it after exit
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# ── config (safe parser — no arbitrary code execution) ───────────────────────
#
# we do NOT use `source "$CONFIG_FILE"` directly because that would execute
# any bash code in the file. instead we parse only key=value lines.

PHONE_MAC=""
POLL_INTERVAL=1
MISS_THRESHOLD=3
NOTIFY=1
AUTO_RECONNECT=1
RECONNECT_INTERVAL=45
MAX_RECONNECT_INTERVAL=300
LOCK_CMD=""
GRACE_PERIOD=10
WAKE_GRACE_PERIOD=8   # 8s: enough for BT to init after wake, short enough to not delay locks

_load_config() {
    local key val line
    while IFS= read -r line; do
        # skip blank lines and full-line comments
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" != *=* ]] && continue
        # split on first = only
        key="${line%%=*}"
        val="${line#*=}"
        # trim whitespace from key
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"  
        # trim leading/trailing whitespace from val
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"  
        # strip surrounding quotes from val (preserves # inside quoted values
        # e.g. LOCK_CMD="i3lock -c #000000" correctly keeps #000000)
        if [[ "$val" == '"'*'"' ]] || [[ "$val" == "'"*"'" ]]; then
            val="${val:1:${#val}-2}"
        fi
        # only accept known keys (prevents arbitrary variable injection)
        case "$key" in
            PHONE_MAC|POLL_INTERVAL|MISS_THRESHOLD|NOTIFY|AUTO_RECONNECT|\
            RECONNECT_INTERVAL|MAX_RECONNECT_INTERVAL|LOCK_CMD|\
            GRACE_PERIOD|WAKE_GRACE_PERIOD)
                printf -v "$key" '%s' "$val"
                ;;
        esac
    done < "$CONFIG_FILE"
}
[[ -f "$CONFIG_FILE" ]] && _load_config

# validate
if [[ -z "$PHONE_MAC" ]]; then
    echo "error: PHONE_MAC not set in $CONFIG_FILE"
    echo "       run: bluetoothctl devices"
    exit 1
fi

if ! [[ "$PHONE_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    echo "error: invalid MAC format: $PHONE_MAC"
    exit 1
fi

# clamp to sane ranges (2>/dev/null suppresses non-integer errors)
[[ "$POLL_INTERVAL" -lt 1 ]] 2>/dev/null      && POLL_INTERVAL=1
[[ "$POLL_INTERVAL" -gt 60 ]] 2>/dev/null     && POLL_INTERVAL=60
[[ "$MISS_THRESHOLD" -lt 1 ]] 2>/dev/null     && MISS_THRESHOLD=1
[[ "$MISS_THRESHOLD" -gt 30 ]] 2>/dev/null    && MISS_THRESHOLD=30
[[ "$GRACE_PERIOD" -lt 0 ]] 2>/dev/null       && GRACE_PERIOD=0
[[ "$GRACE_PERIOD" -gt 120 ]] 2>/dev/null     && GRACE_PERIOD=120
[[ "$WAKE_GRACE_PERIOD" -lt 0 ]] 2>/dev/null  && WAKE_GRACE_PERIOD=0
[[ "$WAKE_GRACE_PERIOD" -gt 300 ]] 2>/dev/null && WAKE_GRACE_PERIOD=300

command -v bluetoothctl &>/dev/null || { echo "error: bluetoothctl not found"; exit 1; }

# single instance via flock
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "error: already running (pid $(cat "$LOCK_FILE" 2>/dev/null))"; exit 1; }
echo $$ > "$LOCK_FILE"

# ── helpers ───────────────────────────────────────────────────────────────────

# cache logger check once — no fork on every log call
if command -v logger &>/dev/null; then
    log() { logger -t "$LOG_TAG" "$*"; }
else
    log() { :; }
fi

notify() {
    [[ "$NOTIFY" -eq 1 ]] || return
    local urgency="$4"
    [[ -z "$urgency" ]] && urgency="normal"
    timeout 2 notify-send -a "Dynamic Lock" -u "$urgency" -i "$2" "$1" "$3" 2>/dev/null || true
}

# atomic state save — write to tmp then rename to avoid partial reads in --status
save_state() {
    local tmp="${STATE_FILE}.tmp"
    echo "$SEEN $LOCKED $MISS" > "$tmp" && mv -f "$tmp" "$STATE_FILE"
}

load_state() {
    SEEN=0; LOCKED=0; MISS=0
    if [[ -f "$STATE_FILE" ]]; then
        local s l m
        read -r s l m < "$STATE_FILE" 2>/dev/null || return
        [[ "$s" =~ ^[01]$ ]]   && SEEN=$s
        [[ "$l" =~ ^[01]$ ]]   && LOCKED=$l
        # intentionally NOT restoring MISS from state:
        # if service restarts, MISS resets to 0 to avoid premature locks
        # (a partial miss-count before restart shouldn't persist)
    fi
}

# explicitly-tracked interruptible sleep — fixes %% killing wrong job
isleep() {
    sleep "$1" &
    SLEEP_PID=$!
    wait $SLEEP_PID 2>/dev/null
    SLEEP_PID=""
}

# read uptime into _UPTIME — pure bash, zero forks
read_uptime() {
    local raw
    read -r raw _ < /proc/uptime 2>/dev/null
    _UPTIME="${raw%%.*}"
}

# ── bluetooth (D-Bus fast path with auto-adapter-detection) ──────────────────
#
# automatically finds the correct BT adapter path (hci0, hci1, etc.)
# instead of hardcoding hci0 — which breaks with USB BT dongles or
# systems where the adapter resets and re-registers with a new index.

_USE_DBUS=0
_DBUS_DEV_PATH=""
_DBUS_ADAPTER_PATH=""
_ADAPTER_CHECK_CTR=0
_ADAPTER_CHECK_EVERY=30
_ADAPTER_DOWN_CTR=0       # throttle D-Bus calls when adapter is known down
_ADAPTER_DOWN_MAX=10      # check at most every 10s when adapter is down

# auto-detect BT adapter path from D-Bus object tree (pure bash — no echo|grep subshell)
_detect_adapter() {
    local objects
    objects=$(dbus-send --system --dest=org.bluez --print-reply \
        / org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null) || return 1
    # extract first /org/bluez/hciN path using bash pattern matching (no grep fork)
    local _work="$objects"
    local adapter=""
    while [[ "$_work" == */org/bluez/hci* ]]; do
        _work="${_work#*/org/bluez/hci}"
        local idx="${_work%%[^0-9]*}"
        [[ -n "$idx" ]] && adapter="/org/bluez/hci${idx}" && break
    done
    [[ -n "$adapter" ]] || return 1
    _DBUS_ADAPTER_PATH="$adapter"
    _DBUS_DEV_PATH="${adapter}/dev_${PHONE_MAC//:/_}"
    return 0
}

init_bluetooth() {
    if command -v dbus-send &>/dev/null && _detect_adapter; then
        # verify device path is accessible
        if dbus-send --system --dest=org.bluez --print-reply \
               "$_DBUS_DEV_PATH" org.freedesktop.DBus.Properties.Get \
               string:"org.bluez.Device1" string:"Connected" &>/dev/null; then
            _USE_DBUS=1
            log "bluetooth: dbus fast path (${_DBUS_ADAPTER_PATH})"
        else
            _USE_DBUS=0
            log "bluetooth: bluetoothctl fallback (device not in dbus yet)"
        fi
    else
        _USE_DBUS=0
        log "bluetooth: bluetoothctl fallback"
    fi
}

# sets BT_ADAPTER_UP and BT_CONNECTED globals
poll_bluetooth() {
    BT_CONNECTED=0

    # throttle adapter check:
    #   - when UP: only check every 30 ticks (saves forks)
    #   - when DOWN: throttle to every 10 ticks (avoids D-Bus spam every second)
    (( _ADAPTER_CHECK_CTR++ )) || true
    local _do_adapter_check=0
    if [[ $_ADAPTER_CHECK_CTR -ge $_ADAPTER_CHECK_EVERY ]]; then
        _do_adapter_check=1
    elif [[ ${BT_ADAPTER_UP:-0} -eq 0 ]]; then
        (( _ADAPTER_DOWN_CTR++ )) || true
        if [[ $_ADAPTER_DOWN_CTR -ge $_ADAPTER_DOWN_MAX ]]; then
            _ADAPTER_DOWN_CTR=0
            _do_adapter_check=1
        fi
    fi

    if [[ $_do_adapter_check -eq 1 ]]; then
        _ADAPTER_CHECK_CTR=0
        BT_ADAPTER_UP=0

        if [[ $_USE_DBUS -eq 1 ]]; then
            local out
            out=$(dbus-send --system --dest=org.bluez --print-reply \
                "$_DBUS_ADAPTER_PATH" org.freedesktop.DBus.Properties.Get \
                string:"org.bluez.Adapter1" string:"Powered" 2>/dev/null)
            if [[ $? -ne 0 ]]; then
                # D-Bus failed — bluetoothd may have restarted, re-detect adapter
                if _detect_adapter; then
                    log "re-detected adapter: $_DBUS_ADAPTER_PATH"
                else
                    _USE_DBUS=0
                    log "D-Bus unavailable, switched to bluetoothctl"
                fi
                return
            fi
            [[ "$out" == *"boolean true"* ]] && BT_ADAPTER_UP=1
        else
            local out
            out=$(timeout 2 bluetoothctl show 2>/dev/null) || return
            [[ "$out" == *"Powered: yes"* ]] && BT_ADAPTER_UP=1
        fi
    fi

    [[ ${BT_ADAPTER_UP:-0} -eq 1 ]] || return

    # connection check (every tick)
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

# backoff: 45 → 90 → 180 → 300(cap). result in _BACKOFF no subshell.
calc_backoff() {
    local shift=$RECONNECT_FAILURES
    [[ $shift -gt 3 ]] && shift=3
    _BACKOFF=$(( RECONNECT_INTERVAL << shift ))
    [[ $_BACKOFF -gt $MAX_RECONNECT_INTERVAL ]] && _BACKOFF=$MAX_RECONNECT_INTERVAL
}

# reconnect: quick pre-check → BLE scan → connect → 2s stability verify
try_reconnect() {
    [[ "$AUTO_RECONNECT" -eq 1 ]] || return 1

    # quick pre-check — maybe phone reconnected on its own while we waited
    poll_bluetooth
    if [[ $BT_CONNECTED -eq 1 ]]; then
        log "phone already reconnected"
        return 0
    fi

    log "scanning for $PHONE_MAC"

    # save audio before reconnect to restore if PipeWire hijacks output
    local prev_sink=""
    command -v pactl &>/dev/null && prev_sink=$(pactl get-default-sink 2>/dev/null)

    # scan + connect in a killable subshell
    # explicitly stop scan after attempt — prevents adapter staying in scan mode
    # (bluetoothctl timeout kills the process but BlueZ keeps scanning internally)
    (
        timeout 6 bluetoothctl --timeout 5 scan on &>/dev/null
        bluetoothctl scan off &>/dev/null
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

    # stability check — confirm connection holds for 2 interruptible seconds
    poll_bluetooth
    if [[ $BT_CONNECTED -eq 1 ]]; then
        isleep 2   # interruptible — uses SLEEP_PID tracking, safe on shutdown
        [[ $RUNNING -eq 1 ]] || return 1
        poll_bluetooth
        if [[ $BT_CONNECTED -eq 1 ]]; then
            log "phone reconnected (stable)"
            return 0
        fi
        log "phone connected briefly but dropped"
    fi

    # reset adapter-down throttle counter — adapter is confirmed UP after reconnect
    _ADAPTER_DOWN_CTR=0

    log "reconnect failed"
    return 1
}

# ── lock screen ───────────────────────────────────────────────────────────────

lock_session() {
    log "locking session"
    notify "Screen Locked" "dialog-password" "Phone disconnected" "critical"

    # custom lock command from config
    if [[ -n "$LOCK_CMD" ]]; then
        eval "$LOCK_CMD" &>/dev/null && return
        log "custom LOCK_CMD failed, trying fallbacks"
    fi

    # loginctl — prefer graphical (x11/wayland) sessions over TTY sessions
    local session
    local all_sessions
    all_sessions=$(loginctl show-user "$USER" --property=Sessions --value 2>/dev/null \
                   | tr ' ' '\n' | grep -E '^[0-9]+$')
    # try to find a graphical session first
    while IFS= read -r session; do
        local stype
        stype=$(loginctl show-session "$session" --property=Type --value 2>/dev/null)
        if [[ "$stype" == "x11" || "$stype" == "wayland" || "$stype" == "mir" ]]; then
            loginctl lock-session "$session" && return
        fi
    done <<< "$all_sessions"
    # fall back to any session
    session=$(echo "$all_sessions" | head -1)
    [[ -n "$session" ]] && loginctl lock-session "$session" && return

    # KDE / generic freedesktop screensaver (works on KDE Plasma, XFCE, etc.)
    if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        dbus-send --session --dest=org.freedesktop.ScreenSaver --type=method_call \
            /org/freedesktop/ScreenSaver org.freedesktop.ScreenSaver.Lock &>/dev/null && return
        # GNOME dbus (GNOME-specific fallback)
        dbus-send --session --dest=org.gnome.ScreenSaver --type=method_call \
            /org/gnome/ScreenSaver org.gnome.ScreenSaver.Lock &>/dev/null && return
    fi

    # gnome-screensaver-command
    command -v gnome-screensaver-command &>/dev/null \
        && gnome-screensaver-command --lock && return

    # xdg-screensaver (generic)
    command -v xdg-screensaver &>/dev/null \
        && xdg-screensaver lock && return

    log "warning: no lock method found"
}

# ── suspend/wake detection ────────────────────────────────────────────────────

_LAST_UPTIME=0
_FIRST_TICK=1

handle_wake() {
    read_uptime
    local delta normal_max  # declare separately to preserve exit codes
    delta=$(( _UPTIME - _LAST_UPTIME ))
    _LAST_UPTIME=$_UPTIME

    # first tick — nothing to compare
    if [[ $_FIRST_TICK -eq 1 ]]; then
        _FIRST_TICK=0
        return
    fi

    normal_max=$(( POLL_INTERVAL + 15 ))
    [[ $delta -lt $normal_max && $delta -ge 0 ]] && return

    # resumed from suspend
    log "resume detected (${delta}s gap)"
    MISS=0; save_state
    RECONNECT_FAILURES=0; LAST_RECONNECT_TIME=0
    # reset both adapter throttle counters so adapter is checked immediately after wake
    _ADAPTER_CHECK_CTR=$_ADAPTER_CHECK_EVERY
    _ADAPTER_DOWN_CTR=$_ADAPTER_DOWN_MAX  # force immediate check even if was down
    # grace period so BT hardware has time to re-init before counting misses
    GRACE_UNTIL=$(( _UPTIME + WAKE_GRACE_PERIOD ))
}

# ── main loop ─────────────────────────────────────────────────────────────────

load_state
init_bluetooth
# start with BT_ADAPTER_UP=0 and force an immediate check on first tick
# (avoids 30-tick false assumption if adapter is actually down at startup)
BT_ADAPTER_UP=0
_ADAPTER_CHECK_CTR=$_ADAPTER_CHECK_EVERY

log "started v$VERSION: phone=$PHONE_MAC poll=${POLL_INTERVAL}s threshold=$MISS_THRESHOLD"

_PAUSED=0
PREV_SEEN=$SEEN
PREV_LOCKED=$LOCKED
LAST_RECONNECT_TIME=0
RECONNECT_FAILURES=0
GRACE_UNTIL=0

# write initial state so --status has a file immediately
save_state

while [[ $RUNNING -eq 1 ]]; do

    if [[ $LOCKED -eq 1 ]]; then
        isleep 5
    else
        isleep "$POLL_INTERVAL"
    fi

    [[ $RUNNING -eq 1 ]] || break

    handle_wake

    # ── pause / resume ────────────────────────────────────────────────────
    if [[ -f "$PAUSE_FILE" ]]; then
        if [[ "$_PAUSED" -eq 0 ]]; then
            log "paused"
            notify "Dynamic Lock Paused" "dialog-information" "Run --resume to re-arm" "normal"
            _PAUSED=1
        fi
        continue
    fi
    if [[ "$_PAUSED" -eq 1 ]]; then
        log "resumed"
        notify "Dynamic Lock Active" "dialog-information" "Monitoring phone" "normal"
        _PAUSED=0; MISS=0
    fi

    # ── bluetooth combined poll ───────────────────────────────────────────
    poll_bluetooth

    if [[ ${BT_ADAPTER_UP:-0} -eq 0 ]]; then
        if [[ $MISS -gt 0 ]]; then
            log "adapter down, resetting misses"
            MISS=0
        fi
        continue
    fi

    # ── connection logic ──────────────────────────────────────────────────
    if [[ $BT_CONNECTED -eq 1 ]]; then
        [[ $SEEN -eq 0 ]] && { log "phone detected"; notify "Dynamic Lock Armed" "dialog-information" "Monitoring phone" "normal"; }
        if [[ $LOCKED -eq 1 ]]; then
            log "phone returned, re-armed"
            notify "Dynamic Lock Re-armed" "dialog-information" "Phone reconnected" "normal"
            # set grace period even on natural reconnect (phone may be briefly flaky)
            read_uptime
            GRACE_UNTIL=$(( _UPTIME + GRACE_PERIOD ))
        fi
        SEEN=1; MISS=0; LOCKED=0
        RECONNECT_FAILURES=0

    else
        # skip if phone was never seen this session
        [[ $SEEN -eq 0 ]] && continue

        # grace period — don't count misses right after reconnect or wake
        if [[ $GRACE_UNTIL -gt 0 ]]; then
            read_uptime
            if [[ $_UPTIME -lt $GRACE_UNTIL ]]; then
                continue
            fi
            GRACE_UNTIL=0
        fi

        # already locked — try reconnecting with exponential backoff
        if [[ $LOCKED -eq 1 ]]; then
            read_uptime
            _elapsed=$(( _UPTIME - LAST_RECONNECT_TIME ))
            calc_backoff

            if [[ $_elapsed -ge $_BACKOFF ]]; then
                LAST_RECONNECT_TIME=$_UPTIME
                if try_reconnect; then
                    notify "Reconnected" "dialog-information" "Auto-reconnect succeeded" "normal"
                    SEEN=1; MISS=0; LOCKED=0
                    RECONNECT_FAILURES=0
                    read_uptime
                    GRACE_UNTIL=$(( _UPTIME + GRACE_PERIOD ))
                else
                    RECONNECT_FAILURES=$(( RECONNECT_FAILURES + 1 ))  # safe: no set -e issue
                    calc_backoff
                    log "attempt $RECONNECT_FAILURES failed, retry in ${_BACKOFF}s"
                fi
            fi
            continue
        fi

        # not yet locked — count misses toward threshold
        MISS=$(( MISS + 1 ))  # safe arithmetic (no (( )) exit-code gotcha)
        log "miss $MISS/$MISS_THRESHOLD"
        if [[ $MISS -ge $MISS_THRESHOLD ]]; then
            lock_session
            LOCKED=1; MISS=0
            RECONNECT_FAILURES=0
            LAST_RECONNECT_TIME=0
        fi
    fi

    # persist state on transitions only (avoids unnecessary I/O every tick)
    if [[ $SEEN -ne $PREV_SEEN || $LOCKED -ne $PREV_LOCKED ]]; then
        save_state
        PREV_SEEN=$SEEN
        PREV_LOCKED=$LOCKED
    fi
done

# note: cleanup() calls exit 0 on SIGTERM/SIGINT so this line is only
# reached if the while loop exits naturally (RUNNING set to 0 by future code)
log "stopped"
