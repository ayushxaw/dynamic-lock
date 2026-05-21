#!/usr/bin/env bash
# install.sh — Install dynamic_lock (KDE Connect proximity lock)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${HOME}/.config/dynamic_lock"
SYSTEMD_DIR="${HOME}/.config/systemd/user"
BIN_DIR="${HOME}/.local/bin"

echo "=== Dynamic Lock — Installer ==="
echo ""

# 0. Stop old version if running
if systemctl --user is-active dynamic_lock.service &>/dev/null; then
    echo "[0/4] Stopping existing dynamic_lock..."
    systemctl --user stop dynamic_lock.service
    echo "      ✓ Stopped"
fi

# 1. Install the script
echo "[1/4] Installing dynamic_lock.sh to ${BIN_DIR}/ ..."
mkdir -p "$BIN_DIR"
install -m 755 "${SCRIPT_DIR}/dynamic_lock.sh" "${BIN_DIR}/dynamic_lock.sh"
echo "      ✓ Installed"

# 2. Create config directory & copy example config if none exists
echo "[2/4] Setting up config at ${CONFIG_DIR} ..."
mkdir -p "$CONFIG_DIR"
if [[ ! -f "${CONFIG_DIR}/config" ]]; then
    cp "${SCRIPT_DIR}/dynamic_lock.conf" "${CONFIG_DIR}/config"
    echo "      ✓ Created config — edit ${CONFIG_DIR}/config"
else
    echo "      ⏭ Config already exists, skipping"
fi

# 3. Install systemd user unit
echo "[3/4] Installing systemd user unit ..."
mkdir -p "$SYSTEMD_DIR"
cp "${SCRIPT_DIR}/dynamic_lock.service" "${SYSTEMD_DIR}/"
systemctl --user daemon-reload
echo "      ✓ Unit installed & daemon reloaded"

# 4. Enable and start
echo "[4/4] Enabling & starting service ..."
systemctl --user enable --now dynamic_lock.service
echo "      ✓ Service enabled and started"

echo ""
echo "=== Done! ==="
echo ""
echo "Commands:"
echo "  dynamic_lock.sh --status   Check daemon state"
echo "  dynamic_lock.sh --pause    Pause monitoring"
echo "  dynamic_lock.sh --resume   Resume monitoring"
echo "  dynamic_lock.sh --logs     View recent logs"
echo "  systemctl --user status dynamic_lock.service"
echo ""
echo "Config: ${CONFIG_DIR}/config"
