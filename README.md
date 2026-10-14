# Dynamic Lock for GNOME

Lock a GNOME session after a paired Bluetooth phone moves away, then re-arm when its signal returns. Dynamic Lock uses the phone's Bluetooth signal strength (RSSI), with smoothing and confirmation periods to reduce false triggers. It never unlocks the session.

This is a small personal-laptop tool inspired by Windows Dynamic Lock. Microsoft describes its feature as using a paired phone's Bluetooth signal and locking when that signal falls below a threshold, typically within about a minute after leaving range. This project uses its own visible RSSI and timing settings; it cannot reproduce Windows' private signal processing exactly.

## Support and requirements

- GNOME session managed by systemd's user manager
- BlueZ Bluetooth service and a paired phone
- GJS, `flock`, `timeout`, and systemd user commands
- A GNOME session bus and Mutter idle monitor

GSConnect does not provide the BlueZ RSSI feed used here, and KDE Connect's CLI is not required. GSConnect can remain installed for its other features; this monitor reads Bluetooth information from BlueZ directly.

This version targets GNOME with BlueZ. KDE, other desktop environments, non-systemd sessions, and phones that do not provide usable RSSI updates are not supported or verified. Bluetooth range is not a precise distance measurement: walls, body position, radio interference, and adapter/phone behavior can change RSSI.

## Install

Pair the phone in **GNOME Settings → Bluetooth** first. Then install:

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

Edit `~/.config/dynamic_lock/config` and set `PHONE_ADDRESS` to the phone's Bluetooth address. Keep that address private; do not add your personal config to this repository or paste it into public issue reports. Then test the signal without locking:

```bash
~/.local/bin/dynamic_lock.sh --probe
```

Move the phone away and back. Confirm that readings change in a useful, repeatable way. Press `Ctrl-C` to stop the probe. When it behaves well, enable the monitor:

```bash
systemctl --user enable --now dynamic_lock.service
```

If `bluetoothctl devices Paired` is unavailable, install the BlueZ command-line tools for your distribution or get the address from GNOME Bluetooth settings. The `bluetoothctl` command is needed for setup only, not by the daemon.

## Behavior

1. The monitor starts BlueZ discovery and listens for RSSI changes for the selected paired phone.
2. It requires three signal readings before arming, so a service restart while the phone is away cannot immediately lock the session.
3. A relative drop from the strongest nearby signal, or stale readings after the monitor has seen the phone, starts the away confirmation period.
4. It waits for the configured away period and for GNOME to report the session idle before requesting a lock.
5. A stable return re-arms the next departure. It does not unlock the session.
6. On suspend, readings are cleared. On resume, Bluetooth discovery is retried and the monitor must see fresh nearby readings before it can arm again.

The monitor listens for Bluetooth events rather than launching `bluetoothctl` on a polling loop. A one-second local timer advances confirmation periods and checks session idle time only after departure is confirmed.

## Configuration

Edit `~/.config/dynamic_lock/config` while the service is stopped. The file is parsed as simple `KEY=value` lines; it is never sourced or evaluated as shell code. Unknown keys are ignored.

```ini
PHONE_ADDRESS=AA:BB:CC:DD:EE:FF
RSSI_DROP_DB=10
RSSI_STALE_SECONDS=15
AWAY_CONFIRM_SECONDS=30
RETURN_CONFIRM_SECONDS=5
IDLE_AFTER_SECONDS=1
# LOCK_CMD=loginctl lock-session
```

- `RSSI_DROP_DB`: relative weakening from the strongest nearby sample that starts departure confirmation (3–30 dB).
- `RSSI_STALE_SECONDS`: how long without a reading before the phone is treated as potentially away (5–120 seconds).
- `AWAY_CONFIRM_SECONDS`: how long away evidence must persist before the idle check (5–300 seconds).
- `RETURN_CONFIRM_SECONDS`: how long the signal must remain in the return band to re-arm (1–60 seconds).
- `IDLE_AFTER_SECONDS`: required GNOME idle time before locking (0–3600 seconds).
- `LOCK_CMD`: optional executable and arguments, parsed without a shell. If it fails, built-in GNOME lock methods are tried.

Values outside the documented ranges use safe defaults and are reported in the service log. Because Bluetooth RSSI varies by hardware and environment, use `--probe` and tune one setting at a time. `RSSI_DROP_DB=10` is a starting point, not a guaranteed distance threshold.

## Commands

```bash
~/.local/bin/dynamic_lock.sh --status
~/.local/bin/dynamic_lock.sh --pause
~/.local/bin/dynamic_lock.sh --resume
~/.local/bin/dynamic_lock.sh --logs
~/.local/bin/dynamic_lock.sh --version
```

`--status` shows whether the service is active and its last recorded state; when inactive, that state may be stale. Pause and resume signal the running monitor. After resume it clears readings and waits for the phone nearby before re-arming. Logs come from the user journal:

```bash
journalctl --user -u dynamic_lock.service -b
```

## Troubleshooting

- **Installer says GJS or a command is missing:** install the named package with your distribution's package manager, then rerun `./install.sh`.
- **`PHONE_ADDRESS` is missing or malformed:** set it to the paired phone's Bluetooth address in the private config.
- **Phone is not known to BlueZ / pairing error:** pair it in GNOME Bluetooth settings, check `bluetoothctl devices Paired`, and update the config.
- **Adapter is unavailable or discovery fails:** turn Bluetooth on, then inspect `journalctl --user -u dynamic_lock.service -b` and the system Bluetooth log (`journalctl -u bluetooth -b`).
- **No useful RSSI readings:** run `--probe` while moving the phone; some phone/controller combinations do not provide RSSI updates often enough for proximity detection.
- **Monitor exits after a Bluetooth error:** correct the Bluetooth issue and restart with `systemctl --user restart dynamic_lock.service`. It fails closed instead of treating a broken scanner as proof that the phone left.
- **It reports idle-monitor or lock errors:** confirm this is a GNOME session, inspect the user journal, and test `loginctl lock-session` manually. The monitor refuses to lock if it cannot read GNOME idle state.
- **Need to pause temporarily:** use `--pause`; use `--resume` to require a fresh nearby signal before it arms again.

## Uninstall

```bash
./uninstall.sh
```

The uninstaller removes the service and installed program files. It preserves `~/.config/dynamic_lock/config` so you can reinstall without losing settings. Remove that file manually if you also want to delete the stored Bluetooth address.

## Implementation and verification status

Implemented in this version: BlueZ RSSI monitoring, near/away hysteresis, idle-gated lock requests, no automatic unlock, suspend/resume handling, private configuration, pause/resume/status/log commands, and a hardened GNOME user service.

Automated state-machine tests cover arming, away confirmation, idle gating, stale readings, return behavior, lock retries, and invalid RSSI. They do not validate Bluetooth hardware behavior or actual GNOME locking. Run them with:

```bash
gjs -I . tests/test_state_machine.js
```

The current development environment has not been tested with the user's phone. RSSI behavior and lock delivery must be verified on the target laptop before relying on it.

## Design references

- [Microsoft: Sign-in options in Windows](https://support.microsoft.com/en-au/accounts-billing/security/sign-in-options-in-windows) describes Dynamic Lock using a paired phone's Bluetooth signal and locking within about a minute after it leaves range.
- [BlueZ Adapter API](https://bluez.readthedocs.io/en/latest/adapter-api/) documents discovery sessions, RSSI filtering, and device property change signals.
- [GNOME Desktop IdleMonitor API](https://gnome.pages.gitlab.gnome.org/gnome-desktop/html/gnome-desktop3/gnome-desktop3-GnomeIdleMonitor.html) describes GNOME's Mutter-backed idle time interface.
- [GNOME session systemd integration](https://gnome.pages.gitlab.gnome.org/gnome-session/re01.html) documents `graphical-session.target` for desktop-session services.

## License

MIT
