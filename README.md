# 🔒 Dynamic Lock for Linux

**Windows-style Dynamic Lock for Ubuntu/Linux.** Your screen locks automatically when you walk away with your phone — and stays unlocked when you're at your desk.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Linux-orange.svg)
![Shell](https://img.shields.io/badge/shell-bash-green.svg)
![No Root](https://img.shields.io/badge/sudo-not%20required-brightgreen.svg)

---

## How It Works

Dynamic Lock monitors your phone's Bluetooth connection. When your phone disconnects (because you walked away), the screen locks. Simple.

```
Phone connected ──► Phone disconnects ──► 3 seconds ──► 🔒 Screen locks
                                                              │
              Phone reconnects ◄─── You unlock & keep working ◄┘
                     │
                     ▼
              Re-armed (next departure locks again)
```

### Key behaviors

| Scenario | What happens |
|----------|-------------|
| You walk away with phone | Screen locks in ~3 seconds |
| You unlock manually (phone still away) | **Stays unlocked** — no re-lock loop |
| Phone reconnects | Dynamic Lock re-arms |
| Phone was never connected | Nothing happens (safe) |
| Brief Bluetooth glitch | No false lock (needs 3 consecutive misses) |
| Laptop suspends and resumes | No false lock (wake detection built in) |

> **This is exactly how Windows Dynamic Lock works** — but faster and configurable.

---

## Installation

### Prerequisites

- Ubuntu 20.04+ (or any Linux with BlueZ and systemd)
- Phone paired via Bluetooth (`bluetoothctl` must show your phone)
- No root/sudo required

### One-line install

```bash
git clone https://github.com/ayushxaw/dynamic-lock.git
cd dynamic-lock
bash install.sh
```

The installer will:
1. Ask for your phone's Bluetooth MAC address
2. Install the script to `~/.local/bin/`
3. Create a config at `~/.config/dynamic_lock/config`
4. Set up a systemd user service that starts on login

### Find your phone's MAC address

```bash
bluetoothctl devices
```

Output looks like: `Device 7C:F0:E5:AA:1A:AE OnePlus Nord CE5`

---

## Configuration

Edit `~/.config/dynamic_lock/config`:

```bash
# Your phone's Bluetooth MAC address (required)
PHONE_MAC="AA:BB:CC:DD:EE:FF"

# Seconds between connection checks (default: 1)
POLL_INTERVAL=1

# Consecutive disconnected checks before locking (default: 3 = ~3 seconds)
MISS_THRESHOLD=3

# Desktop notifications: 1 = enabled, 0 = silent
NOTIFY=1
```

After editing, restart the service:

```bash
systemctl --user restart dynamic_lock
```

### Tuning the lock delay

The lock delay ≈ `POLL_INTERVAL × MISS_THRESHOLD`

| Setting | Lock delay | Use case |
|---------|-----------|----------|
| `POLL=1, MISS=3` | ~3 seconds | Fast lock (default) |
| `POLL=5, MISS=3` | ~15 seconds | More tolerant of Bluetooth glitches |
| `POLL=10, MISS=3` | ~30 seconds | Similar to Windows Dynamic Lock |

---

## Usage

### Useful commands

```bash
# Check if it's running
systemctl --user status dynamic_lock

# Watch live logs
journalctl --user -u dynamic_lock -f

# Pause temporarily (e.g. phone is charging in another room)
touch ~/.dynamic_lock_pause

# Resume
rm ~/.dynamic_lock_pause

# Restart after config change
systemctl --user restart dynamic_lock

# Stop
systemctl --user stop dynamic_lock
```

### Pausing

If you need to keep your laptop unlocked while your phone is away (charging, in another room, etc.):

```bash
touch ~/.dynamic_lock_pause     # Pause — no locking
rm ~/.dynamic_lock_pause        # Resume — locking re-enabled
```

---

## How is this different from...

### Windows Dynamic Lock
Same concept, but:
- ⚡ **Faster** — locks in ~3s vs Windows' ~30s
- ⚙️ **Configurable** — tune poll interval, threshold, notifications
- 🔋 **Zero battery impact** — passive connection checks
- 🐧 Works on Linux

### GNOME screen lock / KDE auto-lock
Those lock based on **idle time**. Dynamic Lock locks based on **physical proximity**. You can be watching a video (not "idle") and it works. You can leave your desk for 5 seconds and it locks — no waiting for a 5-minute idle timeout.

### Other Bluetooth lock scripts
Most use `l2ping` which:
- Requires sudo/root permissions
- Actively pings your phone (battery drain)
- Takes 3-5 seconds per check (slow detection)
- Can fail due to Bluetooth congestion

Dynamic Lock uses `bluetoothctl info` — a passive, instant, unprivileged check.

---

## Uninstall

```bash
bash uninstall.sh
```

Or manually:

```bash
systemctl --user stop dynamic_lock
systemctl --user disable dynamic_lock
rm ~/.local/bin/dynamic_lock.sh
rm ~/.config/systemd/user/dynamic_lock.service
systemctl --user daemon-reload
```

Config is preserved at `~/.config/dynamic_lock/`. Delete manually if unwanted.

---

## Supported environments

| Desktop | Lock method | Status |
|---------|------------|--------|
| GNOME (Wayland) | `loginctl lock-session` | ✅ Tested |
| GNOME (X11) | `loginctl lock-session` | ✅ Should work |
| KDE | `loginctl lock-session` | ✅ Should work |
| XFCE | `xdg-screensaver lock` | ✅ Fallback |
| Others | Falls through lock command chain | ⚠️ May need testing |

---

## Troubleshooting

### Screen doesn't lock when phone disconnects

1. Check the service is running: `systemctl --user status dynamic_lock`
2. Check logs: `journalctl --user -u dynamic_lock -f`
3. Verify your phone shows as paired: `bluetoothctl info YOUR_MAC`
4. Make sure Bluetooth is on: `bluetoothctl show | grep Powered`

### Locks when I don't want it to

- **Phone in another room**: Use `touch ~/.dynamic_lock_pause` to pause
- **Bluetooth is flaky**: Increase `MISS_THRESHOLD` to 5 or 6 in config

### Service won't start

```bash
# Check for errors
journalctl --user -u dynamic_lock --no-pager -n 20

# Reload and restart
systemctl --user daemon-reload
systemctl --user restart dynamic_lock
```

---

## Contributing

PRs welcome! Some ideas:

- [ ] RSSI-based distance estimation
- [ ] Multiple phone support
- [ ] GUI settings app
- [ ] Auto-detect phone MAC from paired devices
- [ ] Support for smartwatches / BT beacons

---

## License

MIT — see [LICENSE](LICENSE)
