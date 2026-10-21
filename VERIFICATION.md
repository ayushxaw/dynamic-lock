# Verification record — 2026-10-21

Bluetooth is the primary prototype. It measures an encrypted Classic connection;
Wi-Fi/GSConnect is not used by that backend. The optional GSConnect fallback
measures connection loss, not physical distance.

## Automated checks actually run

`/usr/bin/python3 -B -m unittest discover -s tests -q`: **92 tests passed**.
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
- Outbound SDP retry after consecutive timeouts without any phone-side event,
  automatic channel replacement after remote closure or measurement failure,
  redacted connection-attempt count/age, and live diagnostic versus stopped-monitor
  status, including a new diagnostic holding the lock over an earlier run's state.
  Socket/controller boundaries are mocked for these regression tests.
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
| Final readiness recheck | Doctor reported remote connection timeout with a responding local controller. A subsequent 96.3-second dry-run received 13 absence observations, no measurements and zero lock decisions; it stayed unarmed. BlueZ still reported the configured phone paired/bonded and the adapter powered. | The phone was not reachable at handoff. Its physical location, radio toggle and screen state were not independently known, so this is not a verified physical departure test or current readiness pass. |

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

### Reconnection investigation after the final recheck

The phone subsequently became reachable again, following a user report that they
had to connect from its Bluetooth settings. Inspection confirmed that the current
underlying ACL link was phone-initiated. No daemon or diagnostic was running after
the previous checks ended, so no continuing background reconnects were being made.
A continuous no-lock diagnostic was started and reached `NEAR_ARMED`.
Its subsequent 462.8-second run obtained 83 encrypted readings, no unknown/absence
observations and zero lock decisions. This run used the earlier runtime while
the reconnection diagnostics were being developed; it did not verify phone screen
state or a fresh underlying-link reconnection.

Three separate automatic opens of the program's own encrypted SDP channel returned
valid RSSI `0` (0.922, 0.408 and 0.482 seconds). However, BlueZ stayed connected
between these channel opens. They prove channel re-establishment on this existing
link, **not** creation of a fresh laptop-initiated ACL link after full loss. The
program did not connect audio/network profiles or globally disconnect the phone.
A fresh local power-cycle test was skipped because an unrelated Bluetooth mouse
was connected. A BlueZ restart attempt was denied without interactive authorization;
no restart occurred. Physical phone off/on and automatic cold reconnection are
still required.

The new status counters distinguish actual outbound SDP connection calls from a
stopped monitor. They cannot prove that a phone accepts those calls in the
background. The later reconnection investigation supersedes the earlier
unreachable-at-handoff observation as a description of current reachability, while
both observations remain part of this record.

Runtime commit `ef00885` was then installed, with private configuration unchanged
and installed modules checked against source. A new bounded one-hour no-lock
diagnostic was started. Its status uses the current lock owner's PID, avoiding
stale readiness from another process. This diagnostic is separate from the
disabled automatic-lock service and does not enable login startup.

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

AI assisted research, implementation, tests and documentation. The current tracked
files were checked against the private configured identities and contain none of
them; no GitHub-token-shaped credentials were found in the inspected patch history.
This current-file check does not certify that older Git history contains no
identifiers. Private configuration remains outside the repository.
