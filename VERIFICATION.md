# Verification record — 2026-10-21

Bluetooth is the primary prototype. It measures an encrypted Classic connection;
Wi-Fi/GSConnect is not used by that backend. The optional GSConnect fallback
measures connection loss, not physical distance.

## Automated checks actually run

`/usr/bin/python3 -B -m unittest discover -s tests -q`: **85 tests passed**.
The tests cover:

- SDP lengths, transaction IDs, record/continuation bounds; HCI event length,
  status/opcode/peer/handle checks; unavailable RSSI and valid zero; authenticated
  and encrypted link flags; connection cleanup and unsupported/permission errors.
- Remote page timeout (`EHOSTDOWN`) versus refusal, local failure and missing or
  locally blocked pairing. Local controller health is required for timeout-based
  absence evidence.
- Fresh arming, stale data, hour-separated readings, fixed thresholds without a
  drifting baseline, threshold jitter, interrupted returns, startup while away,
  one lock per departure, bounded lock retry, pause and suspend invalidation.
- One outstanding worker job, generation changes, stale/delayed results, and
  readings interrupted by a simulated suspend.
- GNOME idle units, explicit Lock acknowledgement plus active-state verification,
  failure when a screen is already blank but Lock fails, and bounded custom
  helpers. A real GLib/subprocess test kills a hanging helper within the evidence
  freshness budget, then follows the GNOME path using a mocked desktop endpoint.
- Private phone setup, config parsing/permissions/preservation, and installation,
  upgrade, activation/controls/status/logs/uninstall in isolated temporary homes.
- Distinct GSConnect connection observations, local NetworkManager health and
  service ownership, phone identity selection, and simulated disconnect/return
  cycles. These do not certify GSConnect phone background compatibility.

Shell syntax checks and `git diff --check` pass. `systemd-analyze --user verify dynamic_lock.service` exits successfully; the host reports an unrelated warning
in its installed `spice-vdagent.service`. PyGObject emits Python 3.14 asyncio
DeprecationWarnings in the GLib integration test; the test still passes.

## Live Bluetooth evidence

| Check | Observed result | Scope |
|---|---|---|
| Paired-phone setup | Saved the selected paired phone address in the private config; no identifier printed or committed. | Correct target selection on this laptop. |
| Six live samples | Six validated connection RSSI readings of `0`, without administrator privileges. | Establishes live measurement availability. |
| Link security | Controller flags showed authentication and encryption. Enforcing socket security and checking both flags still produced valid RSSI `0`. | Bonded encrypted link works on this configuration. |
| Installed doctor | GNOME idle/lock-state APIs and local HCI health read succeeded; encrypted RSSI available. | Current prerequisites work; doctor sends no lock. |
| Hardened 30-minute no-lock run | **1,800.6 seconds; 324 measured samples; RSSI −1 to +1; zero UNKNOWN samples; zero lock decisions.** | Sustained live measurement/state stability. Phone screen/settings state and physical location were not independently confirmed. |
| Resources during that run | Journal: **3.201 seconds CPU over 30 minutes 1.418 seconds wall time; 22.9M peak memory.** | Healthy-link workload on this laptop; no battery-life claim. |
| 20-second process scheduling stop | Status correctly became stale; old readings were invalidated; fresh readings re-armed without a lock decision. | Actual delayed-process recovery; not physical suspend. |
| Actual laptop Bluetooth off/on | Locking inhibited while the local adapter was off; encrypted measurements and fresh arming recovered after power returned; zero lock decisions. | Actual local controller interruption, avoiding other connected devices. |
| Pause across another 20-second scheduling stop | Remained PAUSED; resume required fresh arming; zero lock decisions. | Idempotent controls and pause preservation across a scheduling gap. |

The 30-minute run used presence engine commit `c1353f8`. Subsequent changes tighten
GNOME Lock acknowledgement/custom-helper handling and reject a locally blocked
phone. Those changes are covered separately; the no-lock run did not exercise a
lock actuator. It is not presented as an actual walk-away test or a confirmed
screen-off compatibility pass.

The real recovery checks also used a hardened user service, had no automatic
unlock path, and recorded zero real locks. Private config contents were preserved
through reinstallation, and installed modules were compared with source files.

## Controlled GNOME lock check

A separate controlled production-monitor check **passed** in 51.9 seconds:
three real encrypted nearby readings armed it, followed by seven explicitly
**simulated** absence observations. The actual GNOME Lock call was acknowledged,
GetActive confirmed the lock, and the monitor recorded exactly one lock decision
and one confirmed lock. No unlock was attempted. The phone did not physically
depart for this test, and actual password entry was not independently verified.

## Hardware acceptance checklist

These physical checks remain unproven unless explicitly recorded below. Automated
simulation and successful nearby readings do not replace them.

1. Confirm a 30-minute nearby run with phone Bluetooth settings closed and screen
   off, with stable arming and no false departure. The observed run above did not
   independently establish those physical conditions.
2. Perform three real departure/return cycles while both devices remain on the
   same Wi-Fi. Require a lock decision within 60 seconds of sustained weak signal
   or confirmed remote connection loss, then reliable fresh re-arming.
3. Turn the phone's Bluetooth off after arming. Require repeated remote timeouts
   with a healthy local controller followed by a decision; distinguish refusal,
   authentication faults and unavailable measurements from departure.
4. Test a real BlueZ restart and real suspend/resume, including pause across
   suspend, and brief interference. The actual adapter power-cycle/scheduler tests
   above cover related paths but do not establish all of these cases.
5. Verify an actual credential prompt/password requirement and that phone return
   never unlocks. GNOME Lock acknowledgement/GetActive is software evidence;
   password entry remains a distinct human observation.

The installed automatic service remains inactive and disabled, as required by
the approved activation gate while the physical acceptance checks remain pending. A finished prototype, successful automated tests, and live measurement
stability are not a universal phone/range guarantee.

## Support and history

Target inspected: Ubuntu 26.04.1 GNOME Wayland, system Python 3.14.4, BlueZ 5.85.
Other phone/controller combinations and Android/iPhone background behavior require
field testing. Severe radio interference and genuine range loss cannot always be
distinguished; detected local faults inhibit locking and brief drops receive grace.

The [October 17 Bluetooth record](docs/BLUETOOTH_VERIFICATION.md) documents an older
UNKNOWN-only run when the pairing was missing. It was not a proximity success.
The optional [GSConnect guide](docs/GSCONNECT.md) describes the separate fallback;
its earlier historical lock result does not certify Bluetooth range behavior.

AI assisted research, implementation, tests and documentation. No private device
IDs, addresses, tokens or machine-specific private configuration are published.
