#!/bin/bash
# =============================================================================
# install.sh — one-command setup for Dynamic Lock
# Run from the cloned repo:  bash install.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHONE_MAC=""

echo -e "\033[1;36m"
echo "╔══════════════════════════════════════════╗"
echo "║     🔒 Dynamic Lock — Installer          ║"
echo "║     Windows-style Bluetooth lock         ║"
echo "╚══════════════════════════════════════════╝"
echo -e "\033[0m"
echo ""

# ── Step 1: Check bluetoothctl ─────────────────────────────────────────────────
if ! command -v bluetoothctl &>/dev/null; then
    echo "❌ bluetoothctl not found."
    echo "   Install it with: sudo apt install bluez"
    exit 1
fi
echo "✅ bluetoothctl found"

# ── Step 2: Get phone MAC ─────────────────────────────────────────────────────
echo ""
echo "Your paired Bluetooth devices:"
echo "─────────────────────────────────"
bluetoothctl devices 2>/dev/null || echo "(none found — is Bluetooth on?)"
echo ""
read -rp "Enter your phone's MAC address (e.g. AA:BB:CC:DD:EE:FF): " PHONE_MAC

if ! [[ "$PHONE_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    echo "❌ Invalid MAC address format."
    exit 1
fi

# Verify the device exists
if ! bluetoothctl info "$PHONE_MAC" &>/dev/null; then
    echo "⚠️  Device $PHONE_MAC not found in paired devices."
    read -rp "Continue anyway? (y/n): " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] || exit 1
fi

# ── Step 3: Install script ────────────────────────────────────────────────────
mkdir -p "$HOME/.local/bin"
cp "$SCRIPT_DIR/dynamic_lock.sh" "$HOME/.local/bin/dynamic_lock.sh"
chmod +x "$HOME/.local/bin/dynamic_lock.sh"
echo "✅ Script installed to ~/.local/bin/dynamic_lock.sh"

# ── Step 4: Write config ──────────────────────────────────────────────────────
mkdir -p "$HOME/.config/dynamic_lock"
if [[ -f "$HOME/.config/dynamic_lock/config" ]]; then
    echo "⚠️  Config already exists. Updating PHONE_MAC only."
    sed -i "s/^PHONE_MAC=.*/PHONE_MAC=\"$PHONE_MAC\"/" "$HOME/.config/dynamic_lock/config"
else
    cat > "$HOME/.config/dynamic_lock/config" <<EOF
# Dynamic Lock configuration
# Edit these values to customize behavior

# Your phone's Bluetooth MAC address (required)
PHONE_MAC="$PHONE_MAC"

# Seconds between connection checks (default: 1)
POLL_INTERVAL=1

# Consecutive disconnected checks before locking (default: 3 = ~3 seconds)
MISS_THRESHOLD=3

# Desktop notifications: 1 = enabled, 0 = silent
NOTIFY=1

# Custom lock command (optional, overrides loginctl/gnome-screensaver)
# e.g. LOCK_CMD="custom-lock-script.sh"
LOCK_CMD=""
EOF
fi
echo "✅ Config written to ~/.config/dynamic_lock/config"

# ── Step 5: Install systemd service ──────────────────────────────────────────
mkdir -p "$HOME/.config/systemd/user"
cp "$SCRIPT_DIR/dynamic_lock.service" "$HOME/.config/systemd/user/dynamic_lock.service"
systemctl --user daemon-reload
systemctl --user enable --now dynamic_lock.service
echo "✅ Service installed and started"

# ── Done ──────────────────────────────────────────────────────────────────────
echo -e "\033[1;32m"
echo "╔══════════════════════════════════════════╗"
echo "║     ✅ Installation complete!            ║"
echo "╚══════════════════════════════════════════╝"
echo -e "\033[0m"
echo "  Status:    systemctl --user status dynamic_lock"
echo "  Logs:      journalctl --user -u dynamic_lock -f"
echo "  Pause:     touch ~/.dynamic_lock_pause"
echo "  Resume:    rm ~/.dynamic_lock_pause"
echo "  Stop:      systemctl --user stop dynamic_lock"
echo "  Uninstall: bash $(basename "$SCRIPT_DIR")/uninstall.sh"
echo ""
echo "  Connect your phone's Bluetooth now to start monitoring."
echo ""
