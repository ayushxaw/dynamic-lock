# Dynamic Lock for GNOME

Lock a GNOME session after a paired phone stops answering over Bluetooth, then re-arm when it answers again. The monitor holds a Classic Bluetooth SDP link and sends small keepalive requests. It only locks after the departure is confirmed and GNOME reports the session idle. It never unlocks the session.

Windows documents Dynamic Lock as using a paired phone's Bluetooth RSSI and only locking while the PC is idle. This project started with RSSI too, but RSSI from this phone and laptop did not reliably track distance. The current monitor uses an active Bluetooth presence check inspired by [BLE Lock Session](https://github.com/azratul/ble-lock-session), while retaining the idle gate and lock-only behavior. It is a practical approximation, not Microsoft's private Windows implementation.

## Support and requirements

- GNOME session managed by systemd's user manager
- BlueZ and a phone paired in GNOME Bluetooth settings
- System Python 3 with PyGObject and Bluetooth L2CAP socket support (`python3-gi` on Ubuntu)
- A GNOME session bus and Mutter idle monitor

GSConnect can remain installed. This monitor talks to BlueZ directly; it does not require KDE Connect or GSConnect. KDE Connect and GSConnect report network reachability over the local network, which can remain available when a phone is physically away and is a poorer match for Dynamic Lock.

This version targets GNOME with BlueZ and phones that answer Classic Bluetooth SDP requests. Other desktops, non-systemd sessions, BLE-only devices, and unsupported phone/controller combinations are not verified.

## Install

Pair the phone in **GNOME Settings → Bluetooth**, then install:

```bash
git clone https://github.com/theayushlab/dynamic-lock.git
cd dynamic-lock
./install.sh
```

The installer copies the monitor and command wrapper, creates a private config directory with mode `700`, and stores the config with mode `600`. It does not enable the service until a phone address is configured.

Find the paired phone's address:

```bash
bluetoothctl devices Paired
```

Set `PHONE_ADDRESS` in `~/.config/dynamic_lock/config` to that phone's Bluetooth address. Keep the address private; do not add your personal config to the repository or paste it into public issue reports. Run a single no-lock probe:

```bash
~/.local/bin/dynamic_lock.sh --probe
```

Run the probe once with the phone beside the laptop and again from a place where it should be out of range. The first should report a reply; the second should report no reply. If the phone answers while Bluetooth is supposedly off, verify that its Bluetooth radio is actually disabled and that the configured address belongs to the phone. The probe never locks.

When the phone responds reliably nearby and stops responding where you intend to walk away, enable the monitor:

```bash
systemctl --user enable --now dynamic_lock.service
```

## Behavior

1. The monitor checks that the local BlueZ adapter is available, then contacts the paired phone's SDP service over Bluetooth L2CAP.
2. It keeps a successful channel open and sends a small SDP keepalive every `POLL_SECONDS`. A reply means present; a timeout or link loss starts departure confirmation.
3. It requires three successful replies after startup or resume before arming. It requires the phone to stay absent for `AWAY_CONFIRM_SECONDS` before checking idle state.
4. It requests a lock only after GNOME reports at least `IDLE_AFTER_SECONDS` of idle time. If the idle monitor is unavailable, it refuses to lock.
5. A stable return re-arms the next departure. It does not unlock the session.
6. If the laptop's Bluetooth adapter or BlueZ is unavailable, the monitor clears its state and refuses to interpret that local error as the phone leaving.
7. Suspend clears the presence state. After resume, the monitor waits for fresh replies before arming again.

The monitor checks presence at a low fixed interval. Typical departure detection takes the polling interval plus the configured confirmation period.

## Configuration

Edit `~/.config/dynamic_lock/config` while the service is stopped. The file is parsed as simple `KEY=value` lines; it is never sourced or evaluated as shell code. Unknown keys are ignored.

```ini
PHONE_ADDRESS=AA:BB:CC:DD:EE:FF
POLL_SECONDS=5
AWAY_CONFIRM_SECONDS=30
RETURN_CONFIRM_SECONDS=5
IDLE_AFTER_SECONDS=1
# LOCK_CMD=loginctl lock-session
```

- `POLL_SECONDS`: interval between Bluetooth keepalive checks (2–30 seconds).
- `AWAY_CONFIRM_SECONDS`: how long failed presence checks must persist before the idle gate (5–300 seconds).
- `RETURN_CONFIRM_SECONDS`: how long successful checks must persist before re-arming (1–60 seconds).
- `IDLE_AFTER_SECONDS`: required GNOME idle time before locking (0–3600 seconds).
- `LOCK_CMD`: optional executable and arguments, parsed without a shell. If it fails, built-in GNOME lock methods are tried.

Invalid values use safe defaults and are reported in the service log. Legacy `RSSI_DROP_DB` and `RSSI_STALE_SECONDS` entries are ignored with a warning.

## Commands

```bash
~/.local/bin/dynamic_lock.sh --status
~/.local/bin/dynamic_lock.sh --pause
~/.local/bin/dynamic_lock.sh --resume
~/.local/bin/dynamic_lock.sh --logs
~/.local/bin/dynamic_lock.sh --version
```

`--status` shows whether the service is active and its last recorded state; when inactive, that state may be stale. Pause and resume signal the running monitor. After resume it waits for fresh nearby Bluetooth replies before re-arming. Logs come from the user journal:

```bash
journalctl --user -u dynamic_lock.service -b
```

## Troubleshooting

- **Installer reports a missing Python or Bluetooth feature:** use the system Python and install `python3-gi` plus the distribution's BlueZ package.
- **Phone is not known to BlueZ / pairing error:** pair it in GNOME Bluetooth settings, check `bluetoothctl devices Paired`, and update the private config.
- **Probe reports no reply beside the laptop:** verify that the phone is paired, Bluetooth is on, and `PHONE_ADDRESS` points to the phone. Some phones do not expose SDP while screen-locked or in power-saving mode.
- **Probe still replies when the phone is far or Bluetooth is off:** the direct link still reaches that paired address, so this phone/laptop combination is not yet validated for departure detection. Do not lower the confirmation periods to hide this; investigate the phone's Bluetooth behavior first.
- **Adapter is unavailable:** turn Bluetooth on, then inspect `journalctl --user -u dynamic_lock.service -b` and `journalctl -u bluetooth -b`. Local adapter failures do not count as a phone departure.
- **Idle-monitor or lock errors:** confirm this is a GNOME session, inspect the user journal, and test `loginctl lock-session` manually.
- **Need to pause temporarily:** use `--pause`; use `--resume` to require fresh replies before arming again.

## Uninstall

```bash
./uninstall.sh
```

The uninstaller removes the service and installed program files. It preserves `~/.config/dynamic_lock/config` so you can reinstall without losing settings. Remove that file manually if you also want to delete the stored Bluetooth address.

## Implementation and verification status

Implemented: direct SDP presence checks, stable-near arming, confirmed-away and return periods, idle-gated locking, no automatic unlock, suspend/resume handling, private configuration, pause/resume/status/log commands, and a hardened GNOME user service.

Automated tests cover arming, away confirmation, idle gating, return behavior, lock retries, and one lock per departure. They do not validate Bluetooth hardware or actual GNOME locking. Run them with:

```bash
python3 -m unittest discover -s tests
```

On the development laptop, the paired phone answered a direct Bluetooth SDP request. The real away transition and GNOME lock still need a separate live test before relying on this tool.

## Design references

- [Microsoft: Dynamic lock](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/hello-feature-dynamic-lock) documents the RSSI threshold and idle requirement.
- [BLE Lock Session](https://github.com/azratul/ble-lock-session) demonstrates a Bluetooth SDP link check used for device presence; its automatic-unlock behavior is not used here.
- [GSConnect](https://github.com/GSConnect/gnome-shell-extension-gsconnect) implements KDE Connect for GNOME. KDE Connect's [network protocol](https://community.kde.org/KDEConnect) makes network reachability distinct from Bluetooth proximity.
- [GNOME Desktop IdleMonitor API](https://gnome.pages.gitlab.gnome.org/gnome-desktop/html/gnome-desktop3/gnome-desktop3-GnomeIdleMonitor.html) documents GNOME's idle-time interface.
- [GNOME session systemd integration](https://gnome.pages.gitlab.gnome.org/gnome-session/re01.html) documents `graphical-session.target` for desktop-session services.

## License

MIT
