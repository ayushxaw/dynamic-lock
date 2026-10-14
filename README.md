# Dynamic Lock for GNOME

Lock a GNOME session when a paired phone's **Bluetooth signal gets weaker**, then re-arm after the signal returns. This follows the useful part of Windows Dynamic Lock: Bluetooth proximity plus an idle check. It does not use Wi-Fi, GSConnect, KDE Connect, or a network connection, so the phone and laptop can stay on the same Wi-Fi. It never unlocks the session.

The monitor reads Bluetooth RSSI from BlueZ over D-Bus. RSSI is a rough radio measurement, not a reliable distance in meters: walls, pockets, antenna placement, and radio interference affect it. The monitor learns a near baseline when it starts receiving the phone and uses a configurable drop from that baseline. Test your phone and laptop before relying on automatic locking.

## Requirements and support

- Ubuntu GNOME with a systemd user session and BlueZ (`bluetooth` package/service)
- System Python 3 with PyGObject (`python3-gi` on Ubuntu)
- A Bluetooth adapter and phone paired in Ubuntu Settings → Bluetooth
- A GNOME session bus and Mutter idle monitor

This project currently targets GNOME on Ubuntu. Other desktops, distributions, Bluetooth adapters, and phone models are not verified. The phone must provide RSSI updates during BlueZ discovery; some phones may not provide them consistently while idle.

## Install and select the phone

```bash
git clone https://github.com/theayushlab/dynamic-lock.git
cd dynamic-lock
./install.sh
```

Pair the phone in **Ubuntu Settings → Bluetooth**. Then find the paired device address:

```bash
bluetoothctl devices Paired
```

Edit `~/.config/dynamic_lock/config` and put the phone's address in `PHONE_ADDRESS`. This file is private (mode `600`) and is not part of the repository. Enable the service:

```bash
systemctl --user enable --now dynamic_lock.service
```

Run a 20-second RSSI probe before relying on the service:

```bash
~/.local/bin/dynamic_lock.sh --probe
```

The probe starts a BlueZ scan, shows RSSI reports and GNOME idle time, and **cannot lock**. Run it with the phone beside the laptop, then farther away with Bluetooth still on. If no reports arrive, automatic locking is not ready; see Troubleshooting.

## Behavior

1. BlueZ scans for the selected paired phone and reports its RSSI through D-Bus.
2. Three RSSI samples establish the initial near baseline and arm the monitor.
3. A sustained signal drop or stale signal starts the away confirmation. A return above the hysteresis threshold cancels it and re-arms.
4. After the away confirmation, the screen locks only when GNOME reports the session idle for the configured duration.
5. A successful lock happens once per departure. A return re-arms the next departure; it never unlocks.
6. Bluetooth adapter or BlueZ failures stop the monitor without treating the error as a phone departure. Suspend and resume clear old readings and require fresh readings to re-arm.

The default departure confirmation is 30 seconds, in addition to the 15-second RSSI stale timeout if the phone stops reporting. Signal loss caused by turning Bluetooth off is treated as away after those safeguards. Wi-Fi state does not matter.

## Configuration

Edit `~/.config/dynamic_lock/config` (permissions should be `600`):

```ini
PHONE_ADDRESS=
RSSI_DROP_DB=10
RSSI_STALE_SECONDS=15
AWAY_CONFIRM_SECONDS=30
RETURN_CONFIRM_SECONDS=5
IDLE_AFTER_SECONDS=1
POLL_SECONDS=5
# LOCK_CMD=loginctl lock-session
```

- `PHONE_ADDRESS`: Bluetooth address of the paired phone. Keep it in the private config; never commit your personal address.
- `RSSI_DROP_DB`: signal drop from the learned baseline that begins the away timer (3–30 dB). A larger value requires a larger drop.
- `RSSI_STALE_SECONDS`: how long without a phone RSSI report before the away timer can begin (5–120 seconds).
- `AWAY_CONFIRM_SECONDS`: sustained away duration before checking the idle gate (5–300 seconds).
- `RETURN_CONFIRM_SECONDS`: stable near duration before re-arming (1–60 seconds).
- `IDLE_AFTER_SECONDS`: required GNOME idle time before locking (0–3600 seconds).
- `POLL_SECONDS`: state and idle check interval (2–30 seconds). Bluetooth RSSI itself arrives from D-Bus events.
- `LOCK_CMD`: optional executable and arguments, parsed without a shell. Built-in GNOME lock methods are tried if it fails.

RSSI varies by hardware and location. Start with the defaults, record probe readings near and far, and adjust `RSSI_DROP_DB` only if the readings show a useful separation. Do not copy a threshold from another laptop/phone combination.

## Commands

```bash
~/.local/bin/dynamic_lock.sh --probe
~/.local/bin/dynamic_lock.sh --status
~/.local/bin/dynamic_lock.sh --pause
~/.local/bin/dynamic_lock.sh --resume
~/.local/bin/dynamic_lock.sh --logs
```

`--status` shows service state and the last recorded monitor state; the latter may be stale when the service is inactive. Pause and resume signal the running monitor. After resume it requires fresh Bluetooth samples. Logs are available with:

```bash
journalctl --user -u dynamic_lock.service -b
```

## Troubleshooting

- **`PHONE_ADDRESS` is missing or not known to BlueZ:** pair the phone through Ubuntu Settings → Bluetooth, then set the exact address from `bluetoothctl devices Paired` in the private config.
- **Probe receives no RSSI reports:** confirm Bluetooth is on, the phone is paired, and its address is correct. Keep the phone awake/unlocked during the probe. If no samples arrive, this phone/adapter combination may not expose usable RSSI through BlueZ discovery.
- **Near and far readings are similar:** RSSI cannot distinguish those locations reliably on this hardware. Try moving the phone farther away and keep it outside a pocket during calibration; if values remain similar, this setup cannot provide dependable proximity detection.
- **Monitor stops after Bluetooth is turned off or BlueZ restarts:** enable Bluetooth and restart with `systemctl --user restart dynamic_lock.service`. It does not lock based on a scanner/adapter failure.
- **Idle-monitor or lock errors:** confirm this is a GNOME session and inspect the journal. The monitor refuses to lock if GNOME idle status cannot be read.
- **Pause temporarily:** `--pause`; use `--resume` to require fresh near samples before monitoring again.

## Uninstall

```bash
./uninstall.sh
```

The uninstaller removes the service and installed program files and preserves `~/.config/dynamic_lock/config`.

## Implementation and verification status

Implemented: BlueZ RSSI event monitoring, a smoothed relative-signal state machine, away/return hysteresis, stale-signal timeout, GNOME idle gating, verified GNOME locking, suspend/resume handling, private configuration, and systemd user service controls.

Automated tests cover the proximity state machine and monitor helpers. They do not prove that a specific phone/adapter reports usable RSSI or that its values separate near from far. The Bluetooth near/far behavior must be verified with `--probe` on the target hardware before enabling automatic lock. No claim of universal Linux or phone compatibility is made.

Run the automated tests with:

```bash
python3 -m unittest discover -s tests
```

## Design references

- [Microsoft: Dynamic lock](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/hello-feature-dynamic-lock) describes Windows' Bluetooth-based presence signal and idle behavior.
- [BlueZ D-Bus API](https://github.com/bluez/bluez/blob/master/doc/device-api.txt) documents device RSSI properties.
- [BlueZ Adapter API](https://github.com/bluez/bluez/blob/master/doc/adapter-api.txt) documents Bluetooth discovery and discovery filters.
- [GNOME Desktop IdleMonitor API](https://gnome.pages.gitlab.gnome.org/gnome-desktop/html/gnome-desktop3/gnome-desktop3-GnomeIdleMonitor.html) documents GNOME idle-time monitoring.

## License

See [LICENSE](LICENSE).
