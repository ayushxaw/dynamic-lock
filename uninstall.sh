#!/bin/bash
# =============================================================================
# uninstall.sh — remove Dynamic Lock completely
# =============================================================================

set -e

echo ""
echo "🗑  Uninstalling Dynamic Lock..."
echo ""

# Stop and disable service
systemctl --user stop dynamic_lock.service 2>/dev/null || true
systemctl --user disable dynamic_lock.service 2>/dev/null || true
echo "✅ Service stopped and disabled"

# Remove files
rm -f "$HOME/.local/bin/dynamic_lock.sh"
rm -f "$HOME/.config/systemd/user/dynamic_lock.service"
rm -f "/tmp/dynamic_lock_state_$UID"
rm -f "/tmp/dynamic_lock_$UID.lock"
rm -f "/tmp/dynamic_lock_wake_$UID"
echo "✅ Files removed"

# Remove old l2ping sudoers rule if it exists (from v2)
if [[ -f "/etc/sudoers.d/dynamic_lock" ]]; then
    sudo rm -f /etc/sudoers.d/dynamic_lock 2>/dev/null && \
        echo "✅ Removed old sudoers rule (from v2)" || \
        echo "⚠️  Could not remove /etc/sudoers.d/dynamic_lock (run with sudo)"
fi

systemctl --user daemon-reload

echo ""
echo "✅ Dynamic Lock uninstalled."
echo ""
echo "Note: Config preserved at ~/.config/dynamic_lock/config"
echo "      Delete it manually if you don't want it:  rm -rf ~/.config/dynamic_lock"
echo ""
