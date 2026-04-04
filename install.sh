#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# install.sh — interactive setup for dynamic-lock
#
# what it does:
#   1. checks system requirements (bluetooth, systemd)
#   2. lists your paired phones and lets you pick one
#   3. installs the script and systemd service
#   4. creates a config file with your phone's MAC
#   5. starts monitoring immediately
#
# run:  bash install.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# colors
R='\033[0;31m'   G='\033[0;32m'   Y='\033[0;33m'
C='\033[0;36m'   B='\033[1m'      N='\033[0m'

ok()   { echo -e "  ${G}✔${N} $*"; }
warn() { echo -e "  ${Y}⚠${N} $*"; }
fail() { echo -e "  ${R}✖${N} $*"; exit 1; }
step() { echo -e "\n${C}${B}[$1/6]${N} ${B}$2${N}"; }

echo -e "${C}${B}"
echo "┌──────────────────────────────────────────┐"
echo "│     🔒 Dynamic Lock — Installer          │"
echo "│     auto-lock when phone disconnects     │"
echo "└──────────────────────────────────────────┘"
echo -e "${N}"

# ── step 1: requirements ─────────────────────────────────────────────────────
step 1 "Checking system requirements"

# bluetooth
if ! command -v bluetoothctl &>/dev/null; then
    fail "bluetoothctl not found. install it:"
    echo "       Ubuntu/Debian:  sudo apt install bluez"
    echo "       Fedora:         sudo dnf install bluez"
    echo "       Arch:           sudo pacman -S bluez bluez-utils"
    exit 1
fi
ok "bluetoothctl found"

# systemd (user session)
if ! command -v systemctl &>/dev/null; then
    fail "systemd not found — this tool requires systemd"
fi
ok "systemd found"

# bluetooth service running
if ! systemctl is-active --quiet bluetooth 2>/dev/null; then
    warn "bluetooth.service is not running"
    echo -e "     start it with: ${B}sudo systemctl start bluetooth${N}"
    read -rp "     try to start it now? (y/n): " start_bt
    if [[ "$start_bt" == "y" || "$start_bt" == "Y" ]]; then
        sudo systemctl start bluetooth && ok "bluetooth started" || fail "could not start bluetooth"
    else
        warn "continuing without bluetooth — you'll need to start it manually"
    fi
else
    ok "bluetooth.service is running"
fi

# check if adapter is powered on
if ! bluetoothctl show 2>/dev/null | grep -q "Powered: yes"; then
    warn "bluetooth adapter is powered off"
    echo -e "     turning it on..."
    bluetoothctl power on &>/dev/null && ok "adapter powered on" || warn "could not power on adapter"
fi

# notify-send (optional)
if command -v notify-send &>/dev/null; then
    ok "notify-send found (desktop notifications enabled)"
else
    warn "notify-send not found — notifications disabled (install libnotify)"
fi

# ── step 2: pick your phone ──────────────────────────────────────────────────
step 2 "Selecting your phone"

echo ""
echo -e "  your paired bluetooth devices:"
echo -e "  ${B}────────────────────────────────────────${N}"

# list devices with numbers
mapfile -t DEVICES < <(bluetoothctl devices Paired 2>/dev/null)

if [[ ${#DEVICES[@]} -eq 0 ]]; then
    warn "no paired devices found"
    echo ""
    echo -e "  pair your phone first:"
    echo -e "    1. open bluetooth settings on your phone"
    echo -e "    2. on this laptop, run: ${B}bluetoothctl${N}"
    echo -e "    3. type: ${B}scan on${N}"
    echo -e "    4. when your phone appears: ${B}pair <MAC>${N}"
    echo -e "    5. then: ${B}trust <MAC>${N}"
    echo -e "    6. re-run this installer"
    echo ""
    exit 1
fi

i=1
for dev in "${DEVICES[@]}"; do
    mac=$(echo "$dev" | awk '{print $2}')
    name=$(echo "$dev" | cut -d' ' -f3-)
    # check if it looks like a phone
    icon=$(bluetoothctl info "$mac" 2>/dev/null | grep "Icon:" | awk '{print $2}')
    if [[ "$icon" == "phone" ]]; then
        echo -e "  ${G}$i)${N} $name ${C}[$mac]${N} 📱"
    else
        echo -e "  $i) $name ${C}[$mac]${N}"
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
    read -rp "  enter the number of your phone (or type a MAC address): " choice

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

# verify the device is trusted
if ! bluetoothctl info "$PHONE_MAC" 2>/dev/null | grep -q "Trusted: yes"; then
    echo -e "  trusting device..."
    bluetoothctl trust "$PHONE_MAC" &>/dev/null && ok "device trusted" || warn "could not trust device"
fi

# ── step 3: install script ───────────────────────────────────────────────────
step 3 "Installing script"

mkdir -p "$HOME/.local/bin"
cp "$SCRIPT_DIR/dynamic_lock.sh" "$HOME/.local/bin/dynamic_lock.sh"
chmod +x "$HOME/.local/bin/dynamic_lock.sh"
ok "installed to ~/.local/bin/dynamic_lock.sh"

# make sure ~/.local/bin is in PATH
if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    warn "~/.local/bin is not in your PATH"
    echo "     add this to your ~/.bashrc:"
    echo -e "     ${B}export PATH=\"\$HOME/.local/bin:\$PATH\"${N}"
fi

# ── step 4: write config ────────────────────────────────────────────────────
step 4 "Writing configuration"

mkdir -p "$HOME/.config/dynamic_lock"

if [[ -f "$HOME/.config/dynamic_lock/config" ]]; then
    # update just the MAC, preserve other settings
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
# lower = faster lock, slightly more battery
POLL_INTERVAL=1

# consecutive missed checks before locking (default: 3 = ~3s)
MISS_THRESHOLD=3

# desktop notifications (1 = on, 0 = off)
NOTIFY=1

# auto-reconnect when phone comes back in range (1 = on, 0 = off)
AUTO_RECONNECT=1

# seconds between reconnect attempts (increases automatically via backoff)
RECONNECT_INTERVAL=45
EOF
    ok "config written to ~/.config/dynamic_lock/config"
fi

# ── step 5: install systemd service ──────────────────────────────────────────
step 5 "Setting up systemd service"

mkdir -p "$HOME/.config/systemd/user"
cp "$SCRIPT_DIR/dynamic_lock.service" "$HOME/.config/systemd/user/dynamic_lock.service"
systemctl --user daemon-reload
systemctl --user enable dynamic_lock.service 2>/dev/null
ok "service installed and enabled"

# stop old instance if running, start fresh
systemctl --user restart dynamic_lock.service
ok "service started"

# ── step 6: verify ───────────────────────────────────────────────────────────
step 6 "Verifying installation"

sleep 2

if systemctl --user is-active --quiet dynamic_lock.service; then
    ok "service is running"
else
    warn "service failed to start"
    echo "     check logs: journalctl --user -u dynamic_lock -n 20"
fi

# check if phone is currently connected
if bluetoothctl info "$PHONE_MAC" 2>/dev/null | grep -q "Connected: yes"; then
    ok "phone is connected — dynamic lock is armed!"
else
    warn "phone is not connected right now"
    echo "     connect your phone's bluetooth to start monitoring"
    echo "     the script will auto-detect when it connects"
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
echo -e "  ${C}tip: the script auto-reconnects your phone if it disconnects.${N}"
echo -e "  ${C}     make sure 'Phone calls' is enabled in your phone's${N}"
echo -e "  ${C}     bluetooth settings for this laptop.${N}"
echo ""
