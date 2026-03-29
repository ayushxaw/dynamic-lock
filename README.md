# dynamic-lock

windows-style dynamic lock for linux. locks your screen when your phone's bluetooth disconnects.

## how it works

your phone is paired via bluetooth. the script checks if it's still connected every second. if it drops for 3 checks in a row (~3 seconds), your screen locks. once locked, it won't re-lock — you can unlock with your password and keep working, same as windows dynamic lock.

```
phone connected → phone disconnects → 3s → screen locks
                                              |
        phone reconnects ← you unlock ←──────┘
               |
         re-armed (next disconnect locks again)
```

uses `bluetoothctl info` to passively check connection state — no pinging, no sudo, no battery drain.

## install

```bash
git clone https://github.com/ayushxaw/dynamic-lock.git
cd dynamic-lock
bash install.sh
```

the installer asks for your phone's bluetooth MAC, sets up a systemd user service, and starts monitoring immediately.

### find your phone's MAC

```
bluetoothctl devices
```

## config

edit `~/.config/dynamic_lock/config`:

```bash
PHONE_MAC="AA:BB:CC:DD:EE:FF"
POLL_INTERVAL=1       # seconds between checks
MISS_THRESHOLD=3      # misses before locking (~3s)
NOTIFY=1              # desktop notifications
```

restart after changes: `systemctl --user restart dynamic_lock`

### lock speed

| poll | miss | delay |
|------|------|-------|
| 1 | 3 | ~3s (default) |
| 5 | 3 | ~15s |
| 10 | 3 | ~30s (like windows) |

## usage

```bash
# status
systemctl --user status dynamic_lock

# live logs
journalctl --user -u dynamic_lock -f

# pause (phone in another room etc)
touch ~/.dynamic_lock_pause

# resume
rm ~/.dynamic_lock_pause

# restart
systemctl --user restart dynamic_lock
```

## how is this different

**vs GNOME/KDE idle lock** — those lock on idle time. this locks on physical proximity. you can be watching a 2 hour movie and it still works. you can leave for 5 seconds and it locks — no waiting for some idle timeout.

**vs other bluetooth lock scripts** — most use `l2ping` which needs root, actively pings your phone (battery drain), and takes 3-5s per check. this uses `bluetoothctl info` — passive, instant, unprivileged.

## supported

tested on ubuntu 22.04+ with GNOME (wayland). should work on any linux with bluez and systemd — KDE, XFCE, etc. the lock command falls through loginctl → gnome-screensaver → xdg-screensaver.

## uninstall

```bash
bash uninstall.sh
```

## license

MIT
