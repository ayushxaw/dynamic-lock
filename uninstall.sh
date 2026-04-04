#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# uninstall.sh — completely remove dynamic-lock from your system
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

R='\033[0;31m'   G='\033[0;32m'   Y='\033[0;33m'
B='\033[1m'      N='\033[0m'

ok()   { echo -e "  ${G}✔${N} $*"; }
warn() { echo -e "  ${Y}⚠${N} $*"; }

echo ""
echo -e "${R}${B}  🗑  Uninstalling Dynamic Lock${N}"
echo ""

# stop and disable service
systemctl --user stop dynamic_lock.service 2>/dev/null && ok "service stopped" || true
systemctl --user disable dynamic_lock.service 2>/dev/null && ok "service disabled" || true

# remove files
rm -f "$HOME/.local/bin/dynamic_lock.sh"      && ok "removed script"
rm -f "$HOME/.config/systemd/user/dynamic_lock.service" && ok "removed service file"

# clean temp files
rm -f "/tmp/dynamic_lock_state_$UID"
rm -f "/tmp/dynamic_lock_$UID.lock"
rm -f "/tmp/dynamic_lock_wake_$UID"
rm -f "$HOME/.dynamic_lock_pause"
ok "cleaned temp files"

# remove old sudoers rule (from legacy versions)
if [[ -f "/etc/sudoers.d/dynamic_lock" ]]; then
    sudo rm -f /etc/sudoers.d/dynamic_lock 2>/dev/null && ok "removed legacy sudoers rule" || \
        warn "could not remove /etc/sudoers.d/dynamic_lock (run with sudo)"
fi

systemctl --user daemon-reload 2>/dev/null

echo ""
echo -e "  ${G}${B}✔ Dynamic Lock uninstalled${N}"
echo ""
echo -e "  config preserved at: ${B}~/.config/dynamic_lock/config${N}"
echo -e "  to delete it too:    ${B}rm -rf ~/.config/dynamic_lock${N}"
echo ""
