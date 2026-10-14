# Dynamic Lock for GNOME with GSConnect

Lock a GNOME session after a paired GSConnect phone disconnects, then re-arm when it reconnects. The monitor reads GSConnect's D-Bus device status; it does not use Bluetooth RSSI or KDE Connect's command-line tool. It locks only after a confirmed disconnect and GNOME reports the session idle. It never unlocks the session.

This follows GSConnect/KDE Connect network connectivity, which is the behavior this setup uses. It is not Windows Dynamic Lock: Windows uses Bluetooth signal strength and an idle check. A phone and laptop on the same Wi-Fi can remain connected across rooms, so this monitor reacts to network disconnection rather than Bluetooth distance.

## Requirements and support

- GNOME session managed by systemd's user manager
- GSConnect enabled and the phone paired in GSConnect
- System Python 3 with PyGObject (`python3-gi` on Ubuntu)
- A GNOME session bus and Mutter idle monitor

This version reads GSConnect's D-Bus API directly. GSConnect and KDE Connect are related implementations of the KDE Connect protocol, but their local D-Bus interfaces are different; this release specifically supports GSConnect on GNOME. KDE Connect CLI is not required or used. Other desktops and non-systemd sessions are not verified.

## Install

Pair your phone in GSConnect, then install:

```bash
git clone https://github.com/theayushlab/dynamic-lock.git
cd dynamic-lock
./install.sh
```

The installer preserves the private config, migrates away the old Bluetooth address and RSSI settings, and starts the service when GSConnect is running.

Run a single no-lock probe:

```bash
~/.local/bin/dynamic_lock.sh --probe
```

The probe reports whether GSConnect currently sees the phone connected. It does not lock. For a connection-loss test, keep the phone paired, leave it off the laptop's Wi-Fi/network until GSConnect reports it disconnected, and leave the laptop idle. Turning Bluetooth off alone may not disconnect GSConnect.

## Behavior

1. The monitor reads the paired phone's `Connected` state from GSConnect over the session D-Bus.
2. It requires three successful connected samples after startup or resume before arming.
3. A GSConnect disconnect starts the configured departure confirmation period. A GSConnect D-Bus error is treated as unknown: the monitor resets its state and will not interpret the error as a phone departure.
4. After a confirmed disconnect, it requests a lock only when GNOME reports the session idle for at least `IDLE_AFTER_SECONDS`.
5. A stable reconnect re-arms the next departure. It does not unlock the session.
6. Suspend clears the presence state. After resume, the monitor requires fresh connected samples before arming again.

The low-rate poll interval defaults to five seconds. Typical detection takes the polling interval plus `AWAY_CONFIRM_SECONDS`, with additional delay possible while GSConnect notices a network disconnect.

## Configuration

The file is `~/.config/dynamic_lock/config`; the installer sets its permissions to `600`.

```ini
# Optional if exactly one paired phone is configured in GSConnect.
GSCONNECT_DEVICE_NAME=
POLL_SECONDS=5
AWAY_CONFIRM_SECONDS=30
RETURN_CONFIRM_SECONDS=5
IDLE_AFTER_SECONDS=1
# LOCK_CMD=loginctl lock-session
```

- `GSCONNECT_DEVICE_NAME`: exact GSConnect display name to select when more than one paired phone exists. If blank, the monitor requires exactly one paired phone.
- `POLL_SECONDS`: status check interval (2–30 seconds).
- `AWAY_CONFIRM_SECONDS`: how long the phone must remain disconnected before the idle gate (5–300 seconds).
- `RETURN_CONFIRM_SECONDS`: how long it must stay connected before re-arming (1–60 seconds).
- `IDLE_AFTER_SECONDS`: required GNOME idle time before locking (0–3600 seconds).
- `LOCK_CMD`: optional executable and arguments, parsed without a shell. If it fails, built-in GNOME lock methods are tried.

Invalid values use safe defaults and are reported in the service log.

## Commands

```bash
~/.local/bin/dynamic_lock.sh --probe
~/.local/bin/dynamic_lock.sh --status
~/.local/bin/dynamic_lock.sh --pause
~/.local/bin/dynamic_lock.sh --resume
~/.local/bin/dynamic_lock.sh --logs
~/.local/bin/dynamic_lock.sh --version
```

`--status` shows whether the service is active and its last recorded state; when inactive, the state may be stale. Pause and resume signal the running monitor. After resume it requires a fresh GSConnect connection before arming. Logs come from the user journal:

```bash
journalctl --user -u dynamic_lock.service -b
```

## Troubleshooting

- **GSConnect status is unavailable:** confirm the GNOME extension is enabled, then inspect `journalctl --user -u dynamic_lock.service -b`.
- **No paired phone or multiple phones are found:** pair the phone in GSConnect. If more than one paired phone is listed, set `GSCONNECT_DEVICE_NAME` to the intended phone's exact display name.
- **Phone is away but still connected:** the phone may still share the same Wi-Fi/LAN. Disconnect it from that network or move beyond its coverage; this monitor follows GSConnect connectivity, not Bluetooth range.
- **The phone reconnects during the confirmation period:** the departure is canceled and the monitor re-arms after `RETURN_CONFIRM_SECONDS`.
- **Idle-monitor or lock errors:** confirm this is a GNOME session, inspect the journal, and test `loginctl lock-session` manually.
- **Need to pause temporarily:** use `--pause`; use `--resume` to require a fresh connection before it arms again.

## Uninstall

```bash
./uninstall.sh
```

The uninstaller removes the service and installed program files. It preserves `~/.config/dynamic_lock/config`.

## Implementation and verification status

Implemented: GSConnect D-Bus connection monitoring, stable-connected arming, confirmed-disconnect and return periods, idle-gated locking, no automatic unlock, suspend/resume handling, private configuration, pause/resume/status/log commands, and a GNOME user service.

Automated tests cover the presence state machine, including arming, departure confirmation, idle gating, return behavior, lock retries, and one lock per departure. They do not validate live GSConnect network loss or actual GNOME locking. Run them with:

```bash
python3 -m unittest discover -s tests
```

On the development laptop, GSConnect reported both connected and disconnected states during a Wi-Fi-off test. The monitor reached `AWAY_PENDING` and `AWAY_WAITING_FOR_IDLE`. A unit mismatch in the idle-time conversion was then fixed; the final live GNOME lock still needs verification after a fresh disconnect.

## Design references

- [Microsoft: Dynamic lock](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/hello-feature-dynamic-lock) documents Windows' Bluetooth RSSI and idle behavior.
- [GSConnect](https://github.com/GSConnect/gnome-shell-extension-gsconnect) implements KDE Connect integration for GNOME.
- [KDE Connect protocol](https://community.kde.org/KDEConnect) documents its network-based device connection.
- [GNOME Desktop IdleMonitor API](https://gnome.pages.gitlab.gnome.org/gnome-desktop/html/gnome-desktop3/gnome-desktop3-GnomeIdleMonitor.html) documents GNOME idle-time monitoring.
- [GNOME session systemd integration](https://gnome.pages.gitlab.gnome.org/gnome-session/re01.html) documents `graphical-session.target` for desktop-session services.

## License

See [LICENSE](LICENSE).
