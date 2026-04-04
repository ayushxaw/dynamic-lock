# 🔒 dynamic-lock

windows-style dynamic lock for linux — automatically locks your screen when your phone's bluetooth disconnects.

walk away from your laptop with your phone in your pocket → screen locks in 3 seconds. come back → auto-reconnects and re-arms. no idle timers, no manual locking.

```
phone connected ──→ phone leaves ──→ 3 seconds ──→ 🔒 screen locks
                                                         │
                   phone returns ←── auto-reconnect ←────┘
                        │
                   re-armed (next disconnect locks again)
```

## why this exists

GNOME and KDE have idle lock (lock after X minutes of inactivity). but that doesn't help if you walk away while a video is playing — the screen stays unlocked. and it doesn't help if you step away for 10 seconds — you'd need to wait for the full timeout.

dynamic-lock uses physical proximity instead of idle time. your phone is your key.

## how it works

1. a lightweight background service polls `bluetoothctl info` every second to check if your phone is connected
2. if the phone disconnects for 3 consecutive checks (~3 seconds), the screen locks
3. once locked, the script scans for your phone and auto-reconnects when it comes back
4. uses exponential backoff (45s → 90s → 3min → 5min) to save battery if you're genuinely away

no root needed. no pinging. no active scanning during normal monitoring. battery impact is ~0.15W (~1% of total laptop power).

## quick start

```bash
# clone and install (takes 30 seconds)
git clone https://github.com/ayushxaw/dynamic-lock.git
cd dynamic-lock
bash install.sh
```

the installer will:
- check that bluetooth is set up
- show your paired devices and let you pick your phone
- install the script and start monitoring

that's it. walk away and test it.

### prerequisites

- linux with systemd (ubuntu, fedora, arch, etc.)
- bluetooth (`bluez` package)
- a phone paired via bluetooth

if your phone isn't paired yet:

```bash
bluetoothctl
# inside bluetoothctl:
scan on
# wait for your phone to appear, then:
pair AA:BB:CC:DD:EE:FF
trust AA:BB:CC:DD:EE:FF
exit
```

> **important:** on your phone's bluetooth settings, make sure **"Phone calls"** is enabled for this laptop's connection. this keeps the bluetooth link alive.

## usage

```bash
# check if it's running and what state it's in
dynamic_lock.sh --status

# watch live activity
journalctl -t dynamic_lock -f

# pause temporarily (e.g. phone in another room but you don't want to lock)
touch ~/.dynamic_lock_pause

# resume
rm ~/.dynamic_lock_pause

# restart after config changes
systemctl --user restart dynamic_lock

# stop completely
systemctl --user stop dynamic_lock
```

## configuration

edit `~/.config/dynamic_lock/config`:

```bash
# your phone's bluetooth MAC (required)
PHONE_MAC="AA:BB:CC:DD:EE:FF"

# seconds between connection checks (default: 1)
POLL_INTERVAL=1

# consecutive misses before locking (default: 3)
MISS_THRESHOLD=3

# desktop notifications (1 = on, 0 = off)
NOTIFY=1

# auto-reconnect when phone returns (1 = on, 0 = off)
AUTO_RECONNECT=1

# initial reconnect interval in seconds (backs off automatically)
RECONNECT_INTERVAL=45
```

restart after changes: `systemctl --user restart dynamic_lock`

### lock speed tuning

| POLL_INTERVAL | MISS_THRESHOLD | lock delay | battery |
|:---:|:---:|:---:|:---:|
| 1 | 3 | ~3s | lowest impact |
| 3 | 3 | ~9s | slightly less |
| 10 | 3 | ~30s (like windows) | negligible |

## how is this different from...

**vs GNOME/KDE idle lock** — those lock on idle time. this locks on physical proximity. you can watch a 2-hour movie and it still works. step away for 5 seconds and it locks — no waiting for an idle timeout.

**vs other bluetooth lock scripts** — most use `l2ping` which needs root, actively pings your phone (drains its battery), and takes 3-5 seconds per check. this uses `bluetoothctl info` — passive, instant, unprivileged. plus, most scripts don't auto-reconnect or handle suspend/resume properly.

**vs windows dynamic lock** — windows takes ~30 seconds to lock after disconnect. this does it in ~3 seconds (configurable). and the auto-reconnect actually works — windows often requires manual re-pairing.

## features

- **instant lock** — 3 seconds from disconnect to locked screen
- **auto-reconnect** — scans and reconnects when phone returns (scan → connect sequence that works with android)
- **instant shutdown** — signal trap + interruptible sleep, exits in milliseconds (no 90s systemd timeout)
- **suspend-safe** — detects resume and resets state so bluetooth can re-initialize
- **battery aware** — exponential backoff on reconnect (45s → 90s → 180s → 5min cap)
- **audio safe** — preserves audio output during reconnect (prevents pipewire from routing to phone)
- **bluetooth safe** — checks adapter power state before counting misses (no false locks during bluetoothd restart)
- **multi-DE support** — lock falls through loginctl → gnome-screensaver → xdg-screensaver
- **pauseable** — `touch ~/.dynamic_lock_pause` to temporarily disable
- **no root needed** — runs as a regular user service

## architecture

```
┌─────────────────────────────────────────────────────────┐
│ systemd user service                                    │
│                                                         │
│  ┌───────────┐     ┌──────────┐     ┌───────────────┐  │
│  │  poll      │────→│ connected│────→│ SEEN=1        │  │
│  │  every 1s  │     │  ?       │     │ reset misses  │  │
│  │            │     └────┬─────┘     └───────────────┘  │
│  │            │          │ no                            │
│  │            │     ┌────▼─────┐                        │
│  │            │     │ MISS++   │                        │
│  │            │     │ ≥ 3?     │                        │
│  │            │     └────┬─────┘                        │
│  │            │          │ yes                           │
│  │            │     ┌────▼─────┐     ┌───────────────┐  │
│  │            │     │ LOCK     │────→│ LOCKED=1      │  │
│  │            │     │ screen   │     │ poll every 5s  │  │
│  └───────────┘     └──────────┘     └───────┬───────┘  │
│                                             │           │
│                                    ┌────────▼────────┐  │
│                                    │ try_reconnect   │  │
│                                    │ scan → connect  │  │
│                                    │ ↑ backoff: 45s  │  │
│                                    │   90s, 180s, 5m │  │
│                                    └─────────────────┘  │
│                                                         │
│  ┌────────────────────────────────────────────────────┐  │
│  │ safety checks:                                     │  │
│  │  • bt adapter down → pause misses                  │  │
│  │  • suspend detected → reset misses & backoff       │  │
│  │  • SIGTERM → exit immediately (interruptible)      │  │
│  └────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## troubleshooting

**"it locked when my phone was right here"**
- check if bluetooth briefly dropped: `journalctl -t dynamic_lock -n 50`
- increase `MISS_THRESHOLD` to 5 in config for more tolerance

**"it doesn't lock when i walk away"**
- verify phone is paired: `bluetoothctl info YOUR_MAC`
- check if service is running: `systemctl --user status dynamic_lock`
- make sure "Phone calls" is enabled in phone's BT settings for this laptop

**"my phone doesn't auto-reconnect"**
- verify the phone is paired AND trusted: `bluetoothctl info YOUR_MAC | grep -E "Paired|Trusted"`
- check `AUTO_RECONNECT=1` in config
- check logs: `journalctl -t dynamic_lock -f` and look for "scanning" / "reconnect" entries

**"it takes forever to shut down"**
- shouldn't happen with v4+ (exits in milliseconds). check version: `dynamic_lock.sh --version`
- if stuck, check: `systemctl --user status dynamic_lock`

## battery impact

| component | power | notes |
|-----------|-------|-------|
| normal monitoring | ~0.15W | polling `bluetoothctl info` every 1s |
| reconnect scan | ~0.3W burst | BLE scan for ~5s, then connect |
| total impact | **~1% of laptop power** | negligible vs screen (~5W) and CPU (~8W) |

## uninstall

```bash
bash uninstall.sh
```

removes the script, service, and temp files. config is preserved at `~/.config/dynamic_lock/` in case you want to reinstall later.

## supported

tested on ubuntu 22.04+ and fedora 39+ with GNOME (wayland). should work on any linux with:
- systemd
- bluez (bluetooth)
- a desktop environment with a lock screen

lock command falls through: `loginctl` → `gnome-screensaver` → `xdg-screensaver`.

## license

MIT
