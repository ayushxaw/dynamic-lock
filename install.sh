#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# install.sh — interactive setup for dynamic-lock
#
# what it does:
#   1. checks system requirements (bluetooth, systemd, bash 4+)
#   2. lists your paired phones and lets you pick one
#   3. installs the script and systemd service
#   4. creates a config file with your phone's MAC
#   5. starts monitoring immediately
#   6. runs a live verification test
#
# run:  bash install.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# colors
R='\033[0;31m'   G='\033[0;32m'   Y='\033[0;33m'
C='\033[0;36m'   B='\033[1m'      D='\033[2m'
N='\033[0m'

ok()   { echo -e "  ${G}✔${N} $*"; }
warn() { echo -e "  ${Y}⚠${N} $*"; }
fail() { echo -e "  ${R}✖${N} $*"; exit 1; }
step() { echo -e "\n${C}${B}[$1/6]${N} ${B}$2${N}"; }

# spinner for slow operations
spin() {
    local pid=$1 msg=$2
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${D}%s${N} %s" "${chars:$((i%10)):1}" "$msg"
        sleep 0.1
        (( i++ )) || true
    done
    printf "\r\033[K"  # clear line
}

echo -e "${C}${B}"
echo "┌──────────────────────────────────────────┐"
echo "│     🔒 Dynamic Lock — Installer          │"
echo "│     auto-lock when phone disconnects     │"
echo "└──────────────────────────────────────────┘"
echo -e "${N}"

# ── pre-checks ────────────────────────────────────────────────────────────────

if [[ $EUID -eq 0 ]]; then
    fail "don't run as root. user services need your regular user: ${B}bash install.sh${N}"
fi

if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
    fail "bash 4+ required (you have ${BASH_VERSION}). upgrade with your package manager."
fi

# ── step 1: requirements ─────────────────────────────────────────────────────
step 1 "Checking system requirements"

# bluetoothctl
if ! command -v bluetoothctl &>/dev/null; then
    echo -e "  ${R}✖${N} bluetoothctl not found. install bluetooth:"
    echo ""
    echo -e "    Ubuntu/Debian:  ${B}sudo apt install bluez${N}"
    echo -e "    Fedora/RHEL:    ${B}sudo dnf install bluez${N}"
    echo -e "    Arch:           ${B}sudo pacman -S bluez bluez-utils${N}"
    echo -e "    openSUSE:       ${B}sudo zypper install bluez${N}"
    echo ""
    exit 1
fi
ok "bluetoothctl found"

# systemd
command -v systemctl &>/dev/null || fail "systemd not found — dynamic-lock requires systemd"
ok "systemd found"

# bluetooth service
if ! systemctl is-active --quiet bluetooth 2>/dev/null; then
    warn "bluetooth.service is not running"
    read -rp "     start it now? (Y/n): " start_bt
    if [[ "${start_bt:-Y}" != "n" && "${start_bt:-Y}" != "N" ]]; then
        sudo systemctl start bluetooth && ok "bluetooth started" || fail "could not start bluetooth"
    fi
else
    ok "bluetooth.service is running"
fi

# adapter power
if ! bluetoothctl show 2>/dev/null | grep -q "Powered: yes"; then
    warn "bluetooth adapter is off — turning on..."
    bluetoothctl power on &>/dev/null && ok "adapter powered on" || warn "could not power on"
fi

# optional deps
command -v notify-send &>/dev/null && ok "notify-send found (notifications enabled)" || \
    warn "notify-send not found — install libnotify for notifications"

command -v dbus-send &>/dev/null && ok "dbus-send found (fast bluetooth queries)" || \
    warn "dbus-send not found — using bluetoothctl (slightly slower)"

# detect DE for lock command suggestion
_DE="unknown"
case "${XDG_CURRENT_DESKTOP:-}" in
    *GNOME*|*Unity*|*ubuntu*) _DE="gnome" ;;
    *KDE*)                     _DE="kde" ;;
    *XFCE*|*Xfce*)             _DE="xfce" ;;
    *sway*|*Sway*)             _DE="sway" ;;
    *i3*)                      _DE="i3" ;;
    *Hyprland*)                _DE="hyprland" ;;
esac
ok "desktop: ${_DE} (${XDG_SESSION_TYPE:-x11})"

# ── step 2: pick your phone ──────────────────────────────────────────────────
step 2 "Selecting your phone"

echo ""
echo -e "  paired bluetooth devices:"
echo -e "  ${B}────────────────────────────────────────${N}"

mapfile -t DEVICES < <(bluetoothctl devices Paired 2>/dev/null || bluetoothctl devices 2>/dev/null)

if [[ ${#DEVICES[@]} -eq 0 ]]; then
    warn "no paired devices found"
    echo ""
    echo -e "  pair your phone first:"
    echo -e "    1. open bluetooth settings on your phone"
    echo -e "    2. on this laptop, run: ${B}bluetoothctl${N}"
    echo -e "    3. type: ${B}scan on${N}"
    echo -e "    4. when your phone appears: ${B}pair AA:BB:CC:DD:EE:FF${N}"
    echo -e "    5. then: ${B}trust AA:BB:CC:DD:EE:FF${N}"
    echo -e "    6. re-run: ${B}bash install.sh${N}"
    echo ""
    exit 1
fi

i=1
for dev in "${DEVICES[@]}"; do
    mac=$(echo "$dev" | awk '{print $2}')
    name=$(echo "$dev" | cut -d' ' -f3-)
    icon=$(bluetoothctl info "$mac" 2>/dev/null | grep "Icon:" | awk '{print $2}')
    connected=""
    bluetoothctl info "$mac" 2>/dev/null | grep -q "Connected: yes" && connected=" ${G}●${N}"

    if [[ "$icon" == "phone" ]]; then
        echo -e "  ${G}${B}$i)${N} $name ${D}[$mac]${N} 📱${connected}"
    else
        echo -e "  ${D}$i)${N} $name ${D}[$mac]${N}${connected}"
    fi
    (( i++ ))
done

echo ""

if [[ ${#DEVICES[@]} -eq 1 ]]; then
    PHONE_MAC=$(echo "${DEVICES[0]}" | awk '{print $2}')
    PHONE_NAME=$(echo "${DEVICES[0]}" | cut -d' ' -f3-)
    echo -e "  only one device found: ${B}$PHONE_NAME${N}"
    read -rp "  use this device? (Y/n): " confirm
    [[ "$confirm" == "n" || "$confirm" == "N" ]] && { echo "  cancelled."; exit 0; }
else
    read -rp "  enter the number of your phone (or a MAC address): " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#DEVICES[@]} ]]; then
        PHONE_MAC=$(echo "${DEVICES[$((choice-1))]}" | awk '{print $2}')
        PHONE_NAME=$(echo "${DEVICES[$((choice-1))]}" | cut -d' ' -f3-)
    elif [[ "$choice" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        PHONE_MAC="$choice"
        PHONE_NAME=$(bluetoothctl info "$PHONE_MAC" 2>/dev/null | grep "Name:" | sed 's/.*Name: //' || echo "Unknown")
    else
        fail "invalid selection"
    fi
fi

ok "selected: $PHONE_NAME ($PHONE_MAC)"

# auto-trust
if ! bluetoothctl info "$PHONE_MAC" 2>/dev/null | grep -q "Trusted: yes"; then
    bluetoothctl trust "$PHONE_MAC" &>/dev/null && ok "device trusted" || warn "could not trust device"
fi

# ── step 3: install script ───────────────────────────────────────────────────
step 3 "Installing script"

mkdir -p "$HOME/.local/bin"
cp "$SCRIPT_DIR/dynamic_lock.sh" "$HOME/.local/bin/dynamic_lock.sh"
chmod +x "$HOME/.local/bin/dynamic_lock.sh"
ok "installed to ~/.local/bin/dynamic_lock.sh"

if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    warn "~/.local/bin is not in PATH"
    echo -e "     add to ~/.bashrc: ${B}export PATH=\"\$HOME/.local/bin:\$PATH\"${N}"
fi

# ── step 4: write config ────────────────────────────────────────────────────
step 4 "Writing configuration"

mkdir -p "$HOME/.config/dynamic_lock"

# suggest LOCK_CMD based on detected DE
_SUGGESTED_LOCK=""
case "$_DE" in
    sway)     _SUGGESTED_LOCK='swaylock -f' ;;
    i3)       _SUGGESTED_LOCK='i3lock -c 000000' ;;
    hyprland) _SUGGESTED_LOCK='hyprlock' ;;
esac

if [[ -f "$HOME/.config/dynamic_lock/config" ]]; then
    if grep -q "^PHONE_MAC=" "$HOME/.config/dynamic_lock/config"; then
        sed -i "s/^PHONE_MAC=.*/PHONE_MAC=\"$PHONE_MAC\"/" "$HOME/.config/dynamic_lock/config"
    else
        echo "PHONE_MAC=\"$PHONE_MAC\"" >> "$HOME/.config/dynamic_lock/config"
    fi
    ok "updated PHONE_MAC in existing config"
else
    cat > "$HOME/.config/dynamic_lock/config" <<EOF
# ─────────────────────────────────────────────────────────────────
# Dynamic Lock — configuration
# edit and restart:  systemctl --user restart dynamic_lock
# ─────────────────────────────────────────────────────────────────

# your phone's bluetooth MAC address (required)
PHONE_MAC="$PHONE_MAC"

# how often to check the connection (seconds)
POLL_INTERVAL=1

# consecutive missed checks before locking (default: 3 = ~3s)
MISS_THRESHOLD=3

# desktop notifications (1 = on, 0 = off)
NOTIFY=1

# auto-reconnect when phone comes back in range (1 = on, 0 = off)
AUTO_RECONNECT=1

# seconds between reconnect attempts (increases with backoff: 45 → 90 → 180 → 5min)
RECONNECT_INTERVAL=45

# grace period after reconnect — prevents rapid re-lock if BT is unstable (seconds)
GRACE_PERIOD=10

# wake grace period — prevents instant lock right after waking laptop from sleep
# gives Bluetooth time to initialize and find the phone (seconds)
WAKE_GRACE_PERIOD=15

# custom lock command (leave empty for automatic detection)
# the auto-detection tries: loginctl → gnome-screensaver → xdg-screensaver
LOCK_CMD="${_SUGGESTED_LOCK}"
EOF
    ok "config written to ~/.config/dynamic_lock/config"
    if [[ -n "$_SUGGESTED_LOCK" ]]; then
        ok "auto-detected lock command for ${_DE}: ${B}${_SUGGESTED_LOCK}${N}"
    fi
fi

# ── step 5: install systemd service ──────────────────────────────────────────
step 5 "Setting up systemd service"

mkdir -p "$HOME/.config/systemd/user"
cp "$SCRIPT_DIR/dynamic_lock.service" "$HOME/.config/systemd/user/dynamic_lock.service"

systemctl --user daemon-reload &
spin $! "reloading systemd..."
ok "service file installed"

systemctl --user enable dynamic_lock.service 2>/dev/null
systemctl --user restart dynamic_lock.service
ok "service started"

# ── step 6: verify ───────────────────────────────────────────────────────────
step 6 "Verifying installation"

sleep 2

if systemctl --user is-active --quiet dynamic_lock.service; then
    ok "service is running"

    # check version
    version=$("$HOME/.local/bin/dynamic_lock.sh" --version 2>/dev/null || echo "unknown")
    ok "version: $version"

    # show BT query mode from journal
    mode=$(journalctl -t dynamic_lock -n 10 --no-pager -o cat 2>/dev/null | grep -o "using.*path\|using.*fallback" | tail -1)
    [[ -n "$mode" ]] && ok "bluetooth: $mode"
else
    warn "service didn't start — check: journalctl --user -u dynamic_lock -n 20"
fi

# check phone connection
if bluetoothctl info "$PHONE_MAC" 2>/dev/null | grep -q "Connected: yes"; then
    ok "phone is connected — ${B}dynamic lock is armed!${N}"
else
    warn "phone is not connected right now"
    echo "     connect it via bluetooth to start monitoring"
fi

# ── done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${G}${B}┌──────────────────────────────────────────┐${N}"
echo -e "${G}${B}│     ✔ Installation complete!             │${N}"
echo -e "${G}${B}└──────────────────────────────────────────┘${N}"
echo ""
echo -e "  ${B}quick reference:${N}"
echo ""
echo "  status     │ dynamic_lock.sh --status"
echo "  logs       │ journalctl -t dynamic_lock -f"
echo "  pause      │ touch ~/.dynamic_lock_pause"
echo "  resume     │ rm ~/.dynamic_lock_pause"
echo "  restart    │ systemctl --user restart dynamic_lock"
echo "  uninstall  │ bash uninstall.sh"
echo ""
echo -e "  ${C}tip: make sure 'Phone calls' is enabled in your phone's${N}"
echo -e "  ${C}     bluetooth settings for this laptop's connection.${N}"
echo ""
