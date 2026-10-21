# Optional GSConnect disconnect backend

Automatically lock GNOME when your paired phone disconnects from **GSConnect**
for 30 seconds. Reconnection re-arms it; **it never unlocks your laptop**.

This optional backend uses GSConnect on the laptop and KDE Connect on the phone. It reads
GSConnect's actual D-Bus connection state, without `kdeconnect-cli`, a manually
configured IP address, or Bluetooth pairing. Use the integration already running
on GNOME; installing the KDE Connect desktop daemon alongside GSConnect is not
required.

**This is network-disconnect locking.** A phone can remain connected in another
room on the same Wi-Fi. It locks after the connection is lost, not at a measured
physical distance. The primary backend uses Bluetooth; see the [main README](../README.md).

## Requirements

- Ubuntu GNOME with systemd user services and NetworkManager.
- GSConnect enabled in GNOME and paired to the phone's KDE Connect app.
- `/usr/bin/python3`, `python3-gi`, and `gir1.2-glib-2.0`.
- GNOME idle/lock APIs and screen locking enabled.

Start with both devices on the same Wi-Fi/LAN. Internet access is not required.
On Android, allow KDE Connect to run in the background and review battery
restrictions if it disconnects when the screen turns off. Phone background
behavior and other platforms require actual testing; no universal compatibility
claim is made.

Target environment: Ubuntu 26.04.1 GNOME Wayland, BlueZ 5.85 for the optional
Bluetooth backend. Other desktops/distributions have not completed acceptance.

## Install and set up

```bash
git clone https://github.com/theayushlab/dynamic-lock.git
cd dynamic-lock
./install.sh
```

Until the changes are merged, use the branch attached to
[PR #1](https://github.com/theayushlab/dynamic-lock/pull/1).

Before setup, set `BACKEND=gsconnect` in `~/.config/dynamic_lock/config`.

1. Open **KDE Connect on the phone** and **GSConnect settings on the laptop**.
   Connect both to the same Wi-Fi/LAN. Select the laptop on the phone, request
   pairing and accept it on the laptop. Ubuntu's Bluetooth pairing is a separate
   system and does not configure GSConnect.
2. Select the paired phone and check readiness:

   ```bash
   ~/.local/bin/dynamic_lock.sh --setup
   ~/.local/bin/dynamic_lock.sh --doctor
   ```

   Setup saves the selected phone's identity only in your private configuration.
   Exactly one paired phone is selected automatically; paired tablets/headphones
   are ignored. With multiple phones, set `GSCONNECT_DEVICE_NAME` privately to the
   exact name before setup. The saved ID remains stable when the phone is renamed.
3. Test without sending a lock request:

   ```bash
   ~/.local/bin/dynamic_lock.sh --dry-run
   ```

   Wait for `NEAR_ARMED` (a legacy state name meaning **connected and armed** in
   GSConnect mode). Switch off the phone's Wi-Fi or leave the network, keeping
   the laptop connected and idle. After GSConnect reports a disconnect and the
   30-second grace expires, look for `DRY RUN: would lock now`. Restore the phone
   connection and confirm re-arming. Ctrl+C stops the test.
4. Activate explicitly after testing:

   ```bash
   ~/.local/bin/dynamic_lock.sh --enable
   ~/.local/bin/dynamic_lock.sh --status
   ```

   Verify one actual lock and that a password is required. Phone return must
   never unlock. Keep normal GNOME idle locking enabled too.

Installation, including an upgrade, leaves automatic locking disabled and
preserves existing configuration contents. `--setup` explicitly updates the
backend and selected phone ID. Old Bluetooth settings can remain in the file;
they are not connection observations in GSConnect mode.

Only one daemon/probe/doctor/setup may run at a time. Use `--disable` before a
foreground diagnostic, and stop the diagnostic before `--enable`.

## Behavior and recovery

| Situation | Result |
|---|---|
| Startup or recovery | Require three fresh connected checks spanning at least ten seconds to arm. A phone already disconnected at startup cannot cause a lock. |
| Brief disconnect | Start a grace period. Any confirmed reconnection cancels pending departure immediately. |
| Disconnect sustained for 30 seconds | Check the current paired-phone state, local network, service ownership, GNOME lock settings and idleness; then request a lock. |
| Reconnection | Confirm it for five seconds, then re-arm. No unlock command exists. |
| Laptop network loss, GSConnect/NetworkManager restart, removed pairing, API errors or stale observations | UNKNOWN; cancel pending locks, retry automatically and require fresh connected checks. |
| Suspend/resume or long scheduling gap | Discard earlier evidence and delayed work; pause survives suspend. |
| Failed lock | Require GNOME `GetActive=true`; retry with backoff capped at five minutes while disconnect evidence remains valid. |

The monitor reads local D-Bus properties about every five seconds and reacts to
connection changes immediately. It sends no IP pings or radio probes in GSConnect
mode. GSConnect owns its phone connection and detects its loss; that detection
time is **in addition to** the monitor's grace period. A local/site network is
enough; internet outages alone do not establish departure.

One bounded worker performs checks, and desktop calls are asynchronous. Missing
measurements never establish disconnection. The selected identity is retained
across pause/resume so another phone cannot silently replace it.

## Configuration and commands

Private file: `~/.config/dynamic_lock/config`, mode `600` in a mode `700` directory.
Never source it as shell code or publish its contents.

```ini
BACKEND=gsconnect
GSCONNECT_DEVICE_ID=
GSCONNECT_DEVICE_NAME=
AWAY_CONFIRM_SECONDS=30
RETURN_CONFIRM_SECONDS=5
IDLE_AFTER_SECONDS=1
POLL_SECONDS=5
STATUS_STALE_SECONDS=15
# LOCK_CMD=loginctl lock-session
```

Setup fills the device ID; no IP address is needed. `STATUS_STALE_SECONDS`
(10–60) must allow at least two polling intervals (2–10 seconds). Away confirmation
is 10–300 seconds, return confirmation 1–60, and GNOME idle threshold 0–3600.
The optional lock executable/arguments are parsed without a shell, run with a
one-second execution budget, and followed by an explicit, acknowledged GNOME Lock request and active-state confirmation. Prefer the
built-in GNOME lock method.

Invalid settings and duplicate keys fail with an actionable error. Missing values
use the defaults above. `RSSI_DROP_DB` and older generic device selector keys are
obsolete; their values are not reinterpreted. Restart an enabled service after
editing configuration; restarting requires fresh arming.

| Command | Purpose |
|---|---|
| `--setup` | Select one paired GSConnect phone and save its identity privately. Does not enable locking. |
| `--doctor` | Check phone connection, NetworkManager and GNOME APIs/settings. Never locks. |
| `--probe` | Run the production decision loop without locking for 30 seconds. |
| `--dry-run [--duration SECONDS]` | Run the full no-lock monitor; Ctrl+C to stop. |
| `--enable` / `--disable` | Validate/start automatic locking, or stop it and disable login startup. |
| `--status` | Activation, backend, fresh runtime state, observation age and inhibition reason. |
| `--pause` / `--resume` | Pause/resume the running service; resume needs fresh arming. Idempotent. |
| `--logs` | Last 50 service journal entries. Foreground diagnostics print directly. |
| `--version` / `--help` | Version and usage. |

Pause lasts until resume or process restart. Disable persists across login.
Historical state is not presented as fresh status when no monitor owns the lock.

## Troubleshooting

- **Only tablets or no paired phone listed:** pair in GSConnect/KDE Connect, not
  Ubuntu Bluetooth. Keep the phone app open during initial setup, use the same
  network, accept pairing on both devices, then repeat `--setup`.
- **Paired but disconnected:** open KDE Connect and select the laptop. Check
  that both are on the same LAN, background activity is allowed, and guest Wi-Fi,
  AP/client isolation, VPN or firewall is not blocking the connection. Follow
  [GSConnect's troubleshooting guide](https://github.com/GSConnect/gnome-shell-extension-gsconnect/wiki/Help)
  rather than installing a second desktop integration or disabling the firewall.
- **Locks after the phone screen turns off:** the phone app may be losing its
  background connection. Test with the screen off, review Android battery
  restrictions, and increase the grace if appropriate. Do not rely on it until
  the nearby screen-off test passes.
- **Still connected in another room:** expected while the same network connection
  survives; this backend does not measure room distance.
- **Network or service errors:** the monitor inhibits locks and retries. Recovery
  needs fresh connected checks before arming; `--status` explains the inhibition.
- **Pairing replaced or phone changed:** review the private device selector before
  setup. Clear an obsolete ID only when deliberately selecting a replacement.
- **Lock or idle errors:** check GNOME screen-lock settings and `--doctor`. A
  successful command exit alone is never recorded as a confirmed lock.
- **Another monitor running:** stop the service/foreground dry-run before setup,
  doctor, installation or uninstall.

Service history: `journalctl --user -u dynamic_lock.service -b`.

## Tests, privacy and uninstall

```bash
/usr/bin/python3 -B -m unittest discover -s tests -v
bash -n dynamic_lock.sh install.sh uninstall.sh
systemd-analyze --user verify dynamic_lock.service
git diff --check
./uninstall.sh
```

Uninstall stops/disables the user service and preserves private configuration.
The runtime lock inode remains until logout to prevent competing monitors from
acquiring different locks. The service uses a private runtime directory,
read-only home/system access, `NoNewPrivileges`, and memory/CPU limits. It installs
no root service, telemetry or extra phone background service.

Device IDs, addresses, names, network paths and raw D-Bus error strings are omitted
from diagnostics and runtime status. Keep raw GSConnect device lists/configuration
out of public bug reports. See [VERIFICATION.md](../VERIFICATION.md) for what actually
passed and what still needs a physical phone/desktop test.

AI assisted research, implementation, tests and documentation. The independent
implementation retains the repository's [MIT license](../LICENSE). Design sources:
[GSConnect API/source](https://github.com/GSConnect/gnome-shell-extension-gsconnect),
[GSConnect scripting](https://github.com/GSConnect/gnome-shell-extension-gsconnect/wiki/CLI-Scripting),
[NetworkManager D-Bus](https://networkmanager.dev/docs/api/latest/gdbus-org.freedesktop.NetworkManager.html),
and [Microsoft Dynamic Lock](https://learn.microsoft.com/en-us/windows/security/identity-protection/hello-for-business/hello-feature-dynamic-lock).
