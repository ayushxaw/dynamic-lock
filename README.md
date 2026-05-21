# 🔒 dynamic-lock

windows-style dynamic lock for linux — automatically locks your screen when your phone leaves KDE Connect range.

walk away from your laptop with your phone in your pocket → screen locks in ~30 seconds. come back → re-arms automatically. no idle timers, no manual locking.

```
phone reachable ──→ phone leaves ──→ ~30 seconds ──→ 🔒 screen locks
                                                          │
                    phone returns ←── auto re-arm ←───────┘
                         │
                    armed (next disconnect locks again)
```

## why this exists

GNOME and KDE have idle lock (lock after X minutes of inactivity). but that doesn't help if you walk away while a video is playing — the screen stays unlocked. and it doesn't help if you step away for 10 seconds — you'd need to wait for the full timeout.

dynamic-lock uses physical proximity instead of idle time. your phone is your key.

## how it works

1. a lightweight background service polls KDE Connect every 10 seconds to check if your phone is reachable
2. if the phone is unreachable for 3 consecutive checks (~30 seconds), the screen locks
3. once locked, the script waits for the phone to return and automatically re-arms
4. uses grace periods after wake from suspend (15s) and after reconnect (20s) to avoid false locks

no root needed. battery impact is negligible (~1.3MB RAM, <1% CPU).

## requirements

- **linux** with GNOME, KDE, or any desktop with `loginctl`
- **KDE Connect** installed (`sudo apt install kdeconnect` / `sudo pacman -S kdeconnect`)
- **KDE Connect app** on your phone ([Google Play](https://play.google.com/store/apps/details?id=org.kde.kdeconnect_tp) / [F-Droid](https://f-droid.org/packages/org.kde.kdeconnect_tp/))
- phone and laptop on the same network (WiFi)

## quick start

```bash
git clone https://github.com/ayushxaw/dynamic-lock.git
cd dynamic-lock
chmod +x install.sh
./install.sh
```

that's it. the daemon starts immediately and auto-starts on login.

## configuration

edit `~/.config/dynamic_lock/config`:

```bash
# device ID — leave blank to auto-detect from paired devices
DEVICE_ID=

# seconds between reachability polls (2–300)
POLL_INTERVAL=10

# consecutive misses before locking (1–60)
MISS_THRESHOLD=3

# seconds to skip miss counting after phone reconnects (0–600)
GRACE_PERIOD=20

# seconds to skip miss counting after waking from suspend (0–600)
WAKE_GRACE_PERIOD=15

# desktop notifications: 1=enabled, 0=disabled
NOTIFY=1

# override lock command (leave blank for automatic fallback chain)
# LOCK_CMD=loginctl lock-session
```

## usage

```bash
dynamic_lock.sh --status    # show daemon state
dynamic_lock.sh --pause     # pause monitoring (e.g., phone charging elsewhere)
dynamic_lock.sh --resume    # resume monitoring
dynamic_lock.sh --logs      # view recent logs
dynamic_lock.sh --version   # print version
```

## lock method fallback chain

when your phone disappears, dynamic-lock tries these methods in order:

1. `loginctl lock-session` (prefers graphical x11/wayland sessions)
2. D-Bus `org.freedesktop.ScreenSaver.Lock`
3. D-Bus `org.gnome.ScreenSaver.Lock`
4. `gnome-screensaver-command --lock`
5. `xdg-screensaver lock`

or set `LOCK_CMD` in config to use your own (e.g., `i3lock`, `swaylock`).

## features

- **3-state reachability check** — distinguishes "phone gone" from "kdeconnect daemon crashed" (no false locks on software issues)
- **suspend/wake detection** — grace period after waking so KDE Connect has time to reconnect
- **reconnect grace period** — avoids flapping when phone connection is briefly unstable
- **safe config parser** — no `source`/`eval`, only known keys accepted
- **single instance** via `flock` — can't accidentally run two daemons
- **signal-based pause/resume** — `SIGUSR1` to pause, `SIGUSR2` to resume
- **timeout on all external calls** — kdeconnect-cli and notify-send can't hang the daemon
- **integer validation** — non-numeric config values fall back to defaults instead of crashing
- **lock failure backoff** — if lock command fails, backs off exponentially (30s → 300s)
- **atomic state file** — write+rename for `--status` reads
- **systemd hardening** — `ProtectSystem`, `ProtectHome`, `MemoryMax`, `CPUQuota`

## uninstall

```bash
./uninstall.sh
```

## license

MIT
