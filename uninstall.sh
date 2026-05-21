#!/usr/bin/env bash
# uninstall.sh — Remove dynamic_lock
set -euo pipefail

echo "=== Dynamic Lock — Uninstaller ==="
echo ""

if systemctl --user is-active dynamic_lock.service &>/dev/null; then
    echo "Stopping service..."
    systemctl --user stop dynamic_lock.service
fi

if systemctl --user is-enabled dynamic_lock.service &>/dev/null; then
    echo "Disabling service..."
    systemctl --user disable dynamic_lock.service
fi

rm -f "${HOME}/.config/systemd/user/dynamic_lock.service"
systemctl --user daemon-reload
echo "✓ Service removed"

rm -f "${HOME}/.local/bin/dynamic_lock.sh"
echo "✓ Script removed"

echo ""
echo "Config preserved at: ~/.config/dynamic_lock/config"
echo "To remove config too: rm -rf ~/.config/dynamic_lock"
echo ""
echo "=== Done ==="
