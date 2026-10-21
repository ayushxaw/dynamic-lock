# Dynamic Lock for Ubuntu GNOME

Lock your laptop after your paired phone moves out of Bluetooth range or its connection signal stays weak. A confirmed nearby return re-arms monitoring. **It never unlocks your session. Wi-Fi is irrelevant.**

This is an app-free Bluetooth prototype of Windows-style Dynamic Lock for Ubuntu GNOME. It uses a live Bluetooth Classic connection, GNOME's idle monitor, and a systemd **user** service. No phone app, root service, or continuous Bluetooth discovery scan is required. The optional [GSConnect backend](docs/GSCONNECT.md) is available as a network-disconnect fallback; Bluetooth is the default.

**Current status:** a tested prototype, with automated and live results in the verification record. Actual walk-away distance, phone-off behavior, and screen-off stability must be distinguished from simulated tests and individual RSSI readings. See [verification results and remaining checks](VERIFICATION.md). Installation leaves automatic locking **disabled**, including upgrades.

## What “range” means

Microsoft describes Dynamic Lock as Bluetooth signal-based locking gated by inactivity. This project follows that approach, with its own explicit thresholds and confirmation times; it does not reproduce Windows internals. [Microsoft documentation](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/hello-feature-dynamic-lock)

Classic **connection RSSI** is relative to the receiver's preferred signal range. `0` is a valid reading inside that range, negative means below it, and positive means above it. It is **not discovery RSSI in dBm** and is not a distance in metres. Walls, pockets, antennas, and controller power management affect results. Being in another room may still be within range. [Bluetooth Core specification, §7.5.4](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-54/out/en/host-controller-interface/host-controller-interface-functional-specification.html)

GSConnect/KDE Connect network reachability cannot establish that you have left your desk while both devices remain on the same home Wi-Fi. The default Bluetooth backend does not use that integration for proximity decisions.

## Requirements and support scope

- Ubuntu GNOME on Wayland with a running graphical session, systemd user manager, and BlueZ.
- System `/usr/bin/python3`, PyGObject (`python3-gi`, `gir1.2-glib-2.0`), and Linux Bluetooth socket support.
- A phone paired through **Ubuntu Settings → Bluetooth**.
- A paired phone that accepts encrypted Bluetooth Classic SDP queries while its screen is off, and a controller/kernel exposing readable connection RSSI without extra privileges.
- GNOME screen locking enabled; the session must support Mutter `GetIdletime` and `org.gnome.ScreenSaver`.

The inspected system is Ubuntu 26.04.1, BlueZ 5.85, Python 3.14.4, GNOME Wayland. Android and iPhone are intended targets, **not verified compatibility claims**. Other desktops, architectures, distributions, and phone models have not completed acceptance testing. BLE-only devices do not support this sensor.

On Ubuntu, install missing system packages if `install.sh` reports them:

```bash
sudo apt install python3 python3-gi gir1.2-glib-2.0 bluez
```

Run the installer and monitor **as your normal desktop user**, without sudo. No `hcitool`, `sdptool`, PyBluez, Bluetooth address scanning tool, or custom privileged helper is needed.

## Install, test, then activate

```bash
git clone https://github.com/theayushlab/dynamic-lock.git
cd dynamic-lock
./install.sh
```

While changes are under review, use the branch attached to [PR #1](https://github.com/theayushlab/dynamic-lock/pull/1) to try this implementation.

1. Pair the phone in **Ubuntu Settings → Bluetooth**. Find its address locally with `bluetoothctl devices Paired`.
2. Run `~/.local/bin/dynamic_lock.sh --setup`. It selects one paired phone and saves its address only in `~/.config/dynamic_lock/config`. If several phones are paired, set `PHONE_ADDRESS` privately to choose one first. Do not publish that file.
3. Run a no-lock prerequisite check:

   ```bash
   ~/.local/bin/dynamic_lock.sh --doctor
   ```

4. Close the phone's Bluetooth settings, leave its screen off, and keep it beside the laptop. Run the production monitor with the lock actuator disabled:

   ```bash
   ~/.local/bin/dynamic_lock.sh --dry-run --duration 1800
   ```

   Require stable `NEAR_ARMED` behavior and **zero** `DRY RUN: would lock` decisions during this nearby test. `UNKNOWN` means the test is inconclusive, not a pass.

5. Run an unrestricted-duration dry-run and complete the [departure/recovery checklist](VERIFICATION.md#hardware-acceptance-checklist). Wi-Fi can stay on for every test.
6. After those checks pass, explicitly activate:

   ```bash
   ~/.local/bin/dynamic_lock.sh --enable
   ~/.local/bin/dynamic_lock.sh --status
   ```

   Activation checks prerequisites again. Verify an actual lock and that your password is required before relying on it.

A daemon, probe, doctor, and dry-run share a single-instance lock. Use `--disable` before a foreground diagnostic; stop that diagnostic with Ctrl+C before enabling the service. `--enable` checks immediate readiness; it cannot certify that you performed the physical acceptance tests.

Pairing alone does not run the monitor. `--doctor` performs one check and closes
its own Bluetooth channel on exit; `--probe` also stops after its duration.
Only a running daemon or dry-run keeps the measurement channel open and retries
outbound connections. Keep `--dry-run` running during a reconnection test and
check `--status` for **Diagnostic: active**. Automatic locking stays disabled in
that mode.

## Decisions and recovery

| Input or condition | Behavior |
|---|---|
| Startup or recovery | Wait for at least three fresh near readings over at least ten seconds. Starting with the phone absent never locks. |
| Connection RSSI at/below away threshold | Require the median of three readings to be weak, plus sustained weak reports for 30 seconds. |
| Remote connection timeout | Count as absence evidence only after BlueZ pairing/adapter checks and a successful local HCI controller read. Repeated timeouts must span the departure period. |
| Value between thresholds or a near reading | Cancel pending departure immediately; confirm a stable near return before re-arming after a lock. |
| No samples, unavailable RSSI, protocol error, permission failure, refused service, missing pairing, or local Bluetooth fault | `UNKNOWN`; clear departure evidence and require fresh nearby arming. Retry with delays capped at 30 seconds. |
| Confirmed departure | Recheck fresh sensor evidence, GNOME lock settings, and idleness before requesting a lock. |
| Lock request | Require an acknowledged GNOME `Lock` request and `GetActive=true`; retry failures with backoff capped at five minutes, only while departure remains confirmed. |
| Confirmed return | Re-arm after five seconds of near evidence; never unlock. |
| Suspend/resume or a long scheduling gap | Discard old readings and delayed worker results; close only our sockets; require fresh arming. User pause survives suspend. |

At defaults, measurements start about every five seconds; one bounded worker performs radio operations. A connection attempt can take up to six seconds. No job queue grows while the radio is slow. The sample filter keeps at most three readings, expiring after 15 seconds. There is no learned or drifting baseline.

## Configuration

The installer preserves existing configuration contents and sets the directory/file permissions to `700`/`600`. Missing settings use these defaults:

```ini
BACKEND=bluetooth
PHONE_ADDRESS=
RSSI_NEAR_THRESHOLD=-5
RSSI_AWAY_THRESHOLD=-10
RSSI_STALE_SECONDS=15
POLL_SECONDS=5
AWAY_CONFIRM_SECONDS=30
RETURN_CONFIRM_SECONDS=5
IDLE_AFTER_SECONDS=1
# LOCK_CMD=loginctl lock-session
```

- Near and away thresholds use Classic connection RSSI. Away must be lower than near. Tune only from your own near/away measurements; do not copy discovery dBm thresholds.
- `RSSI_STALE_SECONDS` (10–60) expires evidence to **unknown**, never to departure. It must be at least twice `POLL_SECONDS` (2–10).
- `AWAY_CONFIRM_SECONDS` (10–300) and `RETURN_CONFIRM_SECONDS` (1–60) require continuous qualifying observations. Faults and the threshold gap cancel timers.
- `IDLE_AFTER_SECONDS` (0–3600) uses GNOME idle time. The default is one second; `0` still requires the idle API to respond.
- `LOCK_CMD`, if set, is parsed into an executable and arguments without a shell. It has a one-second execution budget so sensor evidence stays fresh. GNOME’s explicit `Lock` method is always requested afterward, and its result and active state must both confirm success. Prefer the built-in GNOME method.
- `RSSI_DROP_DB` and older GSConnect settings are reported as obsolete and ignored; their units/values are **not converted**. Remove them yourself after reviewing the new defaults.

Config is data, never sourced or evaluated. Invalid values and duplicate settings fail with a diagnostic rather than silently activating different behavior. Restart an already enabled service after editing valid settings; restart clears all arming evidence.

## Commands

| Command | Purpose |
|---|---|
| `--setup` | Select a paired phone for the configured backend and save its identity privately; no locking. |
| `--doctor` | One connection reading, local controller health, GNOME API/settings checks; never locks. |
| `--probe` | 30-second measurement/arming dry-run; use `--dry-run` for a full departure cycle. |
| `--dry-run [--duration SECONDS]` | Full monitor with no lock actuator; omit duration to run until Ctrl+C. |
| `--enable` | Check readiness, enable login startup, and start automatic monitoring. |
| `--disable` | Stop the automatic service and disable login startup. |
| `--status` | Show activation plus fresh daemon/dry-run state, signal units, age, and inhibition reason. Historical state is not presented as live. |
| `--pause` / `--resume` | Signal only the running service's main process. Idempotent; resume requires new arming. |
| `--logs` | Last 50 service journal entries. Foreground diagnostics print directly to their terminal. |
| `--version` / `--help` | Version and usage. |

Commands are installed at `~/.local/bin/dynamic_lock.sh`. Pause lasts until resume or process restart; `--disable` persists across login. Configuration and pause are not auto-modified by a phone return.

For Bluetooth, status also reports `sdp_connection_attempts` and
`last_connection_attempt_age_seconds`. These count outbound SDP socket connection
calls, including opening a channel over an already existing Bluetooth link. They
are not counts of radio packets or proof that a fresh underlying link succeeded.
While a valid channel remains open, it is reused and the attempt count stays
constant. A powered-off or unreachable phone receives repeated attempts only
while the monitor is running and unpaused.

## Troubleshooting

- **Phone not found/unpaired:** use Ubuntu Bluetooth settings to check the existing pairing and the address in your private config. A powered local adapter does not establish that the configured phone is paired. Do not select a different device just to clear the diagnostic.
- **Phone reconnects only after tapping Connect:** first check that a daemon or dry-run is actually running. A completed doctor/probe cannot continue reconnecting. Watch the SDP attempt count while a continuous dry-run runs, and test a full phone Bluetooth off/on cycle without manually connecting. Successful channel opens on an existing link do not prove automatic reconnection after complete link loss. If attempts continue but the nearby paired phone only answers after a manual connection, this phone's app-free background reconnection remains unsupported until a device-specific cause is established. The monitor does not imitate earbuds by opening audio/call profiles. BlueZ's general `Connect()` can activate multiple profiles, so it is not used as an indiscriminate retry helper. [BlueZ Device API](https://github.com/bluez/bluez/blob/master/doc/org.bluez.Device.rst)
- **SDP refused, malformed replies, or unavailable connection RSSI:** bring the phone nearby, check pairing, and retry `--doctor`. If these persist with the screen off, this phone/controller is unsupported by this app-free sensor. Do not run the monitor as root to bypass it.
- **Always `0`, even in another room:** `0` is valid and may cover a wide signal range. Test farther away. This setup cannot guarantee a room boundary or metre distance; confirmed connection loss is the other supported departure signal.
- **Phone Bluetooth off does not lock:** first confirm the monitor had reached `NEAR_ARMED`. Inspect the reason shown in dry-run/status. Refusal or an unavailable measurement deliberately inhibits locking; only repeated remote timeouts with a healthy local controller establish absence. Record the actual behavior before enabling.
- **Bluetooth off on the laptop or BlueZ restart:** the monitor inhibits locking and retries automatically. It must obtain new nearby readings before re-arming.
- **Idle or lock API unavailable:** run from the GNOME graphical session. Check screen-lock settings, `--doctor`, and the journal. A successful command exit alone is not recorded as a successful lock.
- **Already running:** stop the service with `--disable`, or stop the existing foreground diagnostic. The application never opens competing sensor connections.
- **No service status after installation:** expected; run diagnostics first, then explicitly `--enable`.

For service history:

```bash
journalctl --user -u dynamic_lock.service -b
```

## Privacy, security, and service design

Identifiers stay in the private config and in-memory BlueZ/socket calls. Runtime status and diagnostics omit phone names, addresses, service records, and raw D-Bus error strings. There is no telemetry. Never publish raw `bluetoothctl` output or your configuration.

The sensor opens its own SDP channel and sends a small validated request. It does not start discovery, connect audio/network profiles, reset the controller, or disconnect other applications' connections. The SDP socket requires encryption, and each reading verifies the connection handle, paired peer and authenticated/encrypted controller flags. This does not establish physical presence or relay resistance. Keep normal GNOME idle locking and use **Super+L** when you need an immediate lock.

The user service retains read-only home/system access, a private runtime directory, `NoNewPrivileges`, a private temporary directory, and memory/CPU limits. Unix and Bluetooth sockets remain allowed for desktop integration and the sensor. No system-wide service or new capabilities are installed.

## Uninstall

```bash
./uninstall.sh
```

This stops/disables the service and removes installed program files. A running foreground diagnostic must be stopped first. Private configuration is preserved. The runtime lock inode may remain until logout to avoid racing another process; it contains no device data.

## Development and sources

```bash
/usr/bin/python3 -B -m unittest discover -s tests -v
bash -n dynamic_lock.sh install.sh uninstall.sh
systemd-analyze --user verify dynamic_lock.service
git diff --check
```

- `dynamic_lock_bluetooth.py`: encrypted SDP/HCI protocol validation, paired-phone setup selection, and fault classification.
- `dynamic_lock_state.py`: deterministic, bounded proximity state machine.
- `dynamic_lock_monitor.py`: one radio worker, recovery, status, signals, dry-run/doctor.
- `dynamic_lock_desktop.py`: asynchronous GNOME idle/lock calls and lock confirmation.
- `dynamic_lock_config.py`: strict, non-executing private config reader and private setup writes.
- `dynamic_lock_gsconnect.py`: optional GSConnect connection fallback; unused by the default Bluetooth backend.

AI assisted the research, implementation, tests, and documentation. Review the small commits in PR #1 and use the no-lock diagnostics to verify the behavior yourself. Automated tests simulate failure paths; they cannot replace phone and desktop acceptance tests. See [VERIFICATION.md](VERIFICATION.md) for evidence and limitations.

Independent implementation under this repository's [MIT license](LICENSE). Design references:

- [BlueProximity](https://github.com/tiktaalik-dev/blueproximity): connection RSSI, smoothing, and separate thresholds/timers. No GPL source was copied.
- [bluetooth_unlock RSSI example](https://github.com/dovidgef/bluetooth_unlock/blob/master/rssi.py): active L2CAP connection and HCI measurement approach.
- [BlueZ Device API](https://github.com/bluez/bluez/blob/master/doc/org.bluez.Device.rst): its `RSSI` property refers to inquiry/advertising, so it is not used as departure evidence here.
- [BlueZ HCI definitions](https://github.com/bluez/bluez/blob/master/lib/bluetooth/hci.h) and [Linux HCI socket implementation](https://github.com/torvalds/linux/blob/master/net/bluetooth/hci_sock.c): command layouts and unprivileged read restrictions.

A phone companion app, other desktop backends, and stronger presence authentication remain future ideas. No fixed-range, battery-life, or universal phone compatibility claims are made.
