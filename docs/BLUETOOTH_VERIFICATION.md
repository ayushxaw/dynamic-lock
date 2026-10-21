> Historical snapshot from 2026-10-17. Current results are in [VERIFICATION.md](../VERIFICATION.md).

# Verification record

This file separates implemented behavior, automated evidence, and hardware evidence. No private device identifiers are recorded.

## Implemented

Live Classic SDP connection plus native Linux HCI RSSI; explicit thresholds; bounded and fresh evidence; UNKNOWN fault handling; remote timeout classification with local controller checks; idle-gated GNOME lock confirmation; bounded retries; one radio worker; pause/resume and suspend invalidation; private config; staged installation; doctor and full dry-run; hardened user service.

## Automated evidence — 2026-10-17

`/usr/bin/python3 -B -m unittest discover -s tests -q` passes **57 tests**. Coverage includes:

- SDP lengths, transaction IDs, response types, handle counts, continuation bounds, socket cleanup.
- HCI event lengths, status, opcode, connection identity/handles, deadline, delayed/wrong-handle responses, zero RSSI and unavailable RSSI.
- Remote timeout versus local fault, including Linux HCI page timeout (`EHOSTDOWN`), service refusal, malformed replies, adapter replacement.
- Stale samples, hour-separated arming regression, fixed thresholds after a stronger nearby signal, jitter, interrupted return, startup while absent, one lock per departure, retry backoff.
- Pausing, repeated resume, pause across suspend, worker generation changes, delayed results, one outstanding job, discarded sleep-interrupted measurements.
- GNOME idle milliseconds, missing/active idle gate, disabled locks, lock confirmation, bounded custom command, dry-run never invoking the actuator.
- Three **simulated** departure/return cycles through the production monitor loop, including weak signal and remote absence, with decisions within 60 simulated seconds and fresh arming after a local fault.
- Private config parsing/permissions and obsolete settings; install, upgrade, config preservation, activation refusal, controls, status freshness, logs, uninstall and running-process protection in an **isolated temporary home** with fake systemctl/journalctl.
- Service configuration preserves the instance-lock inode across service stops/failures and permits the Unix/Bluetooth sockets needed for desktop integration.

`bash -n dynamic_lock.sh install.sh uninstall.sh` passes.
`systemd-analyze --user verify dynamic_lock.service` exits successfully; this host reports an unrelated warning in its installed `spice-vdagent.service`.

These tests do not establish physical range, phone background compatibility, actual password requirements, real suspend behavior, battery impact, or resistance to radio interference.

## Hardware/runtime observations

| Observation | Evidence and limit |
|---|---|
| Initial feasibility, 2026-10-15 | Six validated SDP queries and six connection RSSI readings of `0` without administrator privileges during the audit. Establishes an available measurement path only. |
| New implementation doctor, 2026-10-15 | One validated live connection RSSI reading of `0`; GNOME idle and lock-state APIs available. No lock was sent. |
| Current pairing checks, 2026-10-16 and 2026-10-17 | Local BlueZ adapter powered, but the configured phone is no longer among its known devices. The program reports an actionable error and does not silently select another phone. |
| 30-second full dry-run, 2026-10-16 | Three UNKNOWN observations, zero lock decisions, zero real locks; exited with nonzero diagnostic result because no measured samples were obtained. This is **not** a nearby stability pass. |
| Hardened transient user-service check, 2026-10-16 | The no-lock fault-recovery run completed: 1,799.8 seconds in the monitor, 60 UNKNOWN observations, zero measured samples, zero lock decisions, zero real locks. Its diagnostic exit status was 1 because it obtained no measurements. This is **not** a nearby stability or range pass. |
| Fault-recovery resource use | The journal reports 2.520 seconds CPU over 30 minutes 4.236 seconds wall time, and 20.8M memory peak. This measures the missing-pairing workload only; healthy-link resource use and battery impact remain untested. |
| Local controller health under hardening, 2026-10-16 | An unprivileged HCI Read Local Version command succeeded with Unix/Bluetooth socket restrictions, read-only home/system, NoNewPrivileges, and private temporary storage. No phone connection or lock was requested. |
| Pause/resume signals, 2026-10-16 | Repeated SIGUSR1/SIGUSR2 on the running dry-run changed status to PAUSED and back to UNKNOWN recovery without duplicate monitoring. Real suspend remains pending. |
| Final installation, 2026-10-17 | Installed modules, CLI and user unit matched the worktree; existing private config contents were compared byte-for-byte and preserved. Automatic service stayed inactive/disabled. |
| Live instance-lock lifecycle, 2026-10-17 | A foreground dry-run held the lock while a second service with the final hardening attempted startup. The service and a subsequent doctor were refused; the lock inode remained the same and the first dry-run completed its 12-second run without real locking. |

The installed automatic service remains **disabled and inactive**. The 30-minute temporary diagnostic has finished; it did not enable login startup. GitHub Actions also passed the preceding 56-test revision; subsequent commits rerun the checks on the PR.

## Hardware acceptance checklist

Run these on each intended phone/controller combination. They are **pending** until recorded with actual observations. A pairing that disappears or UNKNOWN-only run cannot satisfy them.

1. Restore/check the configured pairing locally. `--doctor` must obtain a valid connection measurement and local controller health response, and reach both GNOME APIs.
2. Keep the phone beside the laptop, close Bluetooth settings, turn its screen off. Run `--dry-run --duration 1800`. Require 30 minutes of useful measurements, stable arming, and no false departure decision. Record UNKNOWN/reconnect events separately.
3. Keep both devices on the **same Wi-Fi** and run three actual departure/return cycles. Wait for `NEAR_ARMED`, move beyond the useful Bluetooth range, and leave the laptop idle. Require a dry-run decision within 60 seconds of sustained weak signal or confirmed connection loss. Bring the phone back and confirm fresh re-arming each time. Record times from observed signal/loss, not estimated metres.
4. After arming, turn phone Bluetooth off. Require repeated remote timeouts with a responsive local controller, followed by a decision; record refusal/UNKNOWN as an unsuccessful compatibility test, not a pass.
5. Turn laptop Bluetooth off/on, restart BlueZ, suspend/resume, and try brief interference. Local failures must inhibit locking; restoration must re-arm from fresh near readings. Pause before one suspend and confirm pause survives. Coordinate these disruptive actions with the person using the laptop.
6. Only after these checks, `--enable`. Perform a real departure, confirm GNOME lock state **and that a password is actually required**. Confirm phone return never unlocks, and a second departure can lock again after manual unlock.
7. Measure memory/CPU during both a healthy connection and fault recovery. Report elapsed time and workload. Battery impact requires a separate controlled test.

## Known limits and next actions

- The configured pairing currently needs attention before background/range acceptance can proceed.
- The program's six-second connection deadline is chosen to exceed the usual Classic page timeout; actual remote-off behavior still depends on the phone and controller.
- Classic RSSI zero spans a hardware-dependent preferred range. A room boundary may not produce weak RSSI; test actual separation before tuning.
- GNOME `GetActive` confirmation is implemented, but physical password verification remains a human acceptance step.
- Android/iPhone background support, real fault recovery, three physical cycles, and battery life remain unverified. A companion app is a future fallback if the app-free sensor fails these checks.
