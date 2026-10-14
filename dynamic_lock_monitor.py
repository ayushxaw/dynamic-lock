#!/usr/bin/env python3
"""GNOME user monitor using paired-phone Bluetooth signal strength."""

import os
import shlex
import signal
import subprocess
import sys
import time

import gi

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib, GLibUnix

from dynamic_lock_state import PresenceMachine


BLUEZ = "org.bluez"
BLUEZ_DEVICE_IFACE = "org.bluez.Device1"
BLUEZ_ADAPTER_IFACE = "org.bluez.Adapter1"
PROPERTIES_IFACE = "org.freedesktop.DBus.Properties"
OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager"
MUTTER_IDLE = "org.gnome.Mutter.IdleMonitor"
MUTTER_PATH = "/org/gnome/Mutter/IdleMonitor/Core"


class MonitorError(Exception):
    pass


def read_config(path):
    try:
        with open(path, encoding="utf-8") as config_file:
            lines = config_file.readlines()
    except OSError as error:
        raise MonitorError(f"cannot read config {path}: {error}") from error

    allowed = {
        "PHONE_ADDRESS",
        "RSSI_DROP_DB",
        "RSSI_STALE_SECONDS",
        "AWAY_CONFIRM_SECONDS",
        "RETURN_CONFIRM_SECONDS",
        "IDLE_AFTER_SECONDS",
        "POLL_SECONDS",
        "LOCK_CMD",
    }
    legacy = {"GSCONNECT_DEVICE_NAME"}
    values = {}
    for number, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            print(f"WARN: ignoring malformed config line {number}", file=sys.stderr)
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if key in legacy:
            print(f"WARN: {key} is obsolete; this monitor uses Bluetooth RSSI.", file=sys.stderr)
            continue
        if key not in allowed:
            print(f"WARN: ignoring unknown config key {key}", file=sys.stderr)
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value

    settings = {
        "RSSI_DROP_DB": (10, 3, 30),
        "RSSI_STALE_SECONDS": (15, 5, 120),
        "AWAY_CONFIRM_SECONDS": (30, 5, 300),
        "RETURN_CONFIRM_SECONDS": (5, 1, 60),
        "IDLE_AFTER_SECONDS": (1, 0, 3600),
        "POLL_SECONDS": (5, 2, 30),
    }
    config = {
        "PHONE_ADDRESS": values.get("PHONE_ADDRESS", "").upper(),
        "LOCK_CMD": values.get("LOCK_CMD", ""),
    }
    for key, (fallback, minimum, maximum) in settings.items():
        raw = values.get(key, str(fallback))
        try:
            number = int(raw)
        except ValueError:
            number = fallback
            print(f"WARN: {key} is not an integer; using {fallback}", file=sys.stderr)
        if number < minimum or number > maximum:
            number = fallback
            print(f"WARN: {key} must be {minimum}–{maximum}; using {fallback}", file=sys.stderr)
        config[key] = number
    address = config["PHONE_ADDRESS"]
    if address and len(address) != 17:
        raise MonitorError("PHONE_ADDRESS must be the paired phone's Bluetooth address (for example AA:BB:CC:DD:EE:FF)")
    if address and any(
        (index % 3 == 2 and char != ":") or (index % 3 != 2 and char not in "0123456789ABCDEF")
        for index, char in enumerate(address)
    ):
        raise MonitorError("PHONE_ADDRESS must be a Bluetooth address like AA:BB:CC:DD:EE:FF")
    return config


def run_command(argv):
    try:
        completed = subprocess.run(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=5,
        )
        return completed.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def screen_is_locked():
    try:
        result = subprocess.run(
            (
                "gdbus", "call", "--session", "--dest", "org.gnome.ScreenSaver",
                "--object-path", "/org/gnome/ScreenSaver", "--method",
                "org.gnome.ScreenSaver.GetActive",
            ),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
            timeout=3,
        )
        return result.returncode == 0 and "(true,)" in result.stdout
    except (OSError, subprocess.TimeoutExpired):
        return False


def request_and_verify_lock(argv):
    if not run_command(argv):
        return False
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if screen_is_locked():
            return True
        time.sleep(0.2)
    return screen_is_locked()


def lock_session(custom_command):

    if custom_command:
        try:
            argv = shlex.split(custom_command)
        except ValueError:
            argv = []
            print("ERROR: LOCK_CMD could not be parsed; trying GNOME lock methods.", file=sys.stderr)
        if argv and request_and_verify_lock(argv):
            return True

    methods = (
        (
            "gdbus", "call", "--session", "--dest", "org.gnome.ScreenSaver",
            "--object-path", "/org/gnome/ScreenSaver", "--method",
            "org.gnome.ScreenSaver.Lock",
        ),
        ("loginctl", "lock-session"),
        ("xdg-screensaver", "lock"),
    )
    return any(request_and_verify_lock(method) for method in methods)


class BluezPresence:
    """Stream RSSI updates for one explicitly selected, paired BlueZ phone."""

    def __init__(self, system_bus, address, on_rssi, on_failure):
        self.system_bus = system_bus
        self.address = address.replace(":", "").casefold()
        self.on_rssi = on_rssi
        self.on_failure = on_failure
        self.device_path = None
        self.adapter_path = None
        self.owns_discovery = False
        self.subscriptions = []

    @staticmethod
    def _plain(value):
        return value.unpack() if isinstance(value, GLib.Variant) else value

    def _objects(self):
        try:
            return self.system_bus.call_sync(
                BLUEZ, "/", OBJECT_MANAGER, "GetManagedObjects", None, None,
                Gio.DBusCallFlags.NONE, 3000, None,
            ).unpack()[0]
        except GLib.Error as error:
            raise MonitorError(
                f"cannot read BlueZ; check that Bluetooth is enabled and the bluetooth service is running ({error.message})"
            ) from error

    def _select_device(self):
        if not self.address:
            raise MonitorError(
                "set PHONE_ADDRESS in ~/.config/dynamic_lock/config after pairing your phone in Ubuntu Settings → Bluetooth"
            )
        matches = []
        for path, interfaces in self._objects().items():
            props = interfaces.get(BLUEZ_DEVICE_IFACE)
            if not props:
                continue
            address = str(self._plain(props.get("Address", ""))).replace(":", "").casefold()
            if address == self.address:
                matches.append((path, props))
        if not matches:
            raise MonitorError(
                "the configured phone is not known to BlueZ; pair it in Ubuntu Settings → Bluetooth and check PHONE_ADDRESS"
            )
        path, props = matches[0]
        if not self._plain(props.get("Paired", False)):
            raise MonitorError("the configured Bluetooth device is not paired; pair the phone in Ubuntu Settings → Bluetooth")
        self.device_path = path
        self.adapter_path = self._plain(props.get("Adapter"))
        if not self.adapter_path:
            raise MonitorError("BlueZ did not report an adapter for the configured phone")

    def _subscribe(self):
        self.subscriptions.append(self.system_bus.signal_subscribe(
            BLUEZ, PROPERTIES_IFACE, "PropertiesChanged", None, None,
            Gio.DBusSignalFlags.NONE, self._properties_changed,
        ))
        self.subscriptions.append(self.system_bus.signal_subscribe(
            "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
            "/org/freedesktop/DBus", None, Gio.DBusSignalFlags.NONE,
            self._name_owner_changed,
        ))

    def _properties_changed(self, _connection, _sender, path, _iface, _signal, parameters):
        interface, changed, _invalidated = parameters.unpack()
        if interface == BLUEZ_DEVICE_IFACE and path == self.device_path:
            value = changed.get("RSSI")
            if value is not None:
                rssi = self._plain(value)
                if isinstance(rssi, int):
                    self.on_rssi(rssi)
        elif interface == BLUEZ_ADAPTER_IFACE and path == self.adapter_path:
            if self._plain(changed.get("Powered", True)) is False:
                self.on_failure("Bluetooth adapter was powered off; monitor stopped without locking.")
            elif self._plain(changed.get("Discovering", True)) is False:
                self.on_failure("Bluetooth discovery stopped unexpectedly; monitor stopped without locking.")

    def _name_owner_changed(self, _connection, _sender, _path, _iface, _signal, parameters):
        name, old_owner, new_owner = parameters.unpack()
        if name == BLUEZ and old_owner and not new_owner:
            self.on_failure("BlueZ stopped; monitor stopped without locking. Restart after Bluetooth returns.")

    def start(self):
        self._select_device()
        adapter = self._objects().get(self.adapter_path, {}).get(BLUEZ_ADAPTER_IFACE, {})
        if self._plain(adapter.get("Powered", False)) is not True:
            raise MonitorError("Bluetooth adapter is powered off; enable Bluetooth and retry")
        self._subscribe()
        try:
            proxy = Gio.DBusProxy.new_sync(
                self.system_bus, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None,
                BLUEZ, self.adapter_path, BLUEZ_ADAPTER_IFACE, None,
            )
            filter_value = {"RSSI": GLib.Variant("n", -127)}
            proxy.call_sync(
                "SetDiscoveryFilter", GLib.Variant("(a{sv})", (filter_value,)),
                Gio.DBusCallFlags.NONE, 5000, None,
            )
            proxy.call_sync("StartDiscovery", None, Gio.DBusCallFlags.NONE, 5000, None)
            self.owns_discovery = True
        except GLib.Error as error:
            self.stop()
            raise MonitorError(f"cannot start Bluetooth RSSI scanning ({error.message}); check Bluetooth permissions and retry") from error

    def stop(self):
        if self.owns_discovery and self.adapter_path:
            try:
                proxy = Gio.DBusProxy.new_sync(
                    self.system_bus, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None,
                    BLUEZ, self.adapter_path, BLUEZ_ADAPTER_IFACE, None,
                )
                proxy.call_sync("StopDiscovery", None, Gio.DBusCallFlags.NONE, 2000, None)
            except GLib.Error:
                pass
            self.owns_discovery = False
        for subscription in self.subscriptions:
            self.system_bus.signal_unsubscribe(subscription)
        self.subscriptions.clear()


class Monitor:
    def __init__(self, config, state_path=None, probe=False):
        self.config = config
        self.state_path = state_path
        self.probe = probe
        self.loop = GLib.MainLoop()
        self.system_bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self.session_bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.presence = BluezPresence(
            self.system_bus, config["PHONE_ADDRESS"], self._rssi_received, self._bluetooth_failed
        )
        self.machine = PresenceMachine(
            drop_db=config["RSSI_DROP_DB"],
            stale_seconds=config["RSSI_STALE_SECONDS"],
            away_seconds=config["AWAY_CONFIRM_SECONDS"],
            return_seconds=config["RETURN_CONFIRM_SECONDS"],
        )
        self.previous_state = ""
        self.paused = False
        self.sleeping = False
        self.fatal = False
        self.idle_warning_shown = False
        self._signal_ids = []
        self.probe_samples = []
        self.last_tick = time.monotonic()

    def _rssi_received(self, rssi):
        now_ms = time.monotonic() * 1000
        self.machine.observe(rssi, now_ms)
        self.probe_samples.append(rssi)
        if self.probe:
            self._log(f"Bluetooth RSSI: {rssi} dBm; proximity state: {self.machine.state}")

    def _bluetooth_failed(self, message):
        if self.fatal:
            return
        self.fatal = True
        self._log(f"ERROR: {message}")
        self.machine.reset()
        self._write_state("UNKNOWN", message)
        self.loop.quit()

    def _idle_milliseconds(self):
        try:
            proxy = Gio.DBusProxy.new_sync(
                self.session_bus,
                Gio.DBusProxyFlags.DO_NOT_AUTO_START,
                None,
                MUTTER_IDLE,
                MUTTER_PATH,
                MUTTER_IDLE,
                None,
            )
            value = proxy.call_sync("GetIdletime", None, Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
            # Mutter's GetIdletime returns milliseconds; keep this unit for
            # comparison with IDLE_AFTER_SECONDS * 1000 in the state loop.
            return float(value)
        except GLib.Error as error:
            if not self.idle_warning_shown:
                self.idle_warning_shown = True
                self._log(f"ERROR: GNOME idle monitor unavailable; refusing to lock without idle confirmation ({error.message}).")
            return None

    def _write_state(self, state, description):
        if not self.state_path or self.probe:
            return
        temporary = f"{self.state_path}.tmp"
        try:
            with open(temporary, "w", encoding="utf-8") as state_file:
                state_file.write(f"State: {state}\n{description}\n")
            os.replace(temporary, self.state_path)
        except OSError as error:
            self._log(f"WARN: could not update runtime status: {error}")

    def _log(self, message):
        print(f"[dynamic_lock] {message}", flush=True)

    def _description(self, state):
        return {
            "WAITING_FOR_NEAR": "Waiting for stable nearby Bluetooth RSSI readings before arming",
            "NEAR_ARMED": "Phone is nearby by Bluetooth signal strength; monitor armed",
            "AWAY_PENDING": "Bluetooth signal is weak or stale; confirming departure",
            "AWAY_WAITING_FOR_IDLE": "Phone appears away; waiting for GNOME idle state",
            "LOCK_REQUESTED": "Screen lock requested",
            "LOCKED_AWAY": "Lock requested; waiting for phone return to re-arm",
            "LOCK_FAILED": "Screen lock failed; see service logs",
            "PAUSED": "Paused by user",
            "SUSPENDED": "System is suspending; monitor will re-arm after wake",
            "UNKNOWN": "Bluetooth status unavailable; no lock will be triggered",
        }.get(state, state)

    def _set_state(self, state):
        if state == self.previous_state:
            return
        self.previous_state = state
        self._write_state(state, self._description(state))
        if not self.probe:
            self._log(f"State: {state}")

    def _reset_for_rearm(self, state, message):
        self.machine.reset()
        changed = state != self.previous_state
        self.previous_state = state
        self._write_state(state, self._description(state))
        if changed and not self.probe:
            self._log(message)

    def _prepare_for_sleep(self, _connection, _sender, _path, _iface, _signal, parameters):
        preparing = parameters.unpack()[0]
        self.sleeping = bool(preparing)
        if preparing:
            self._reset_for_rearm("SUSPENDED", "Suspend detected; cleared Bluetooth readings.")
            self.presence.stop()
        else:
            self._reset_for_rearm("WAITING_FOR_NEAR", "Resume detected; waiting for fresh Bluetooth readings.")
            self._resume_discovery()

    def _pause(self):
        self.paused = True
        self._reset_for_rearm("PAUSED", "Paused; monitoring will require fresh Bluetooth readings when resumed.")
        self.presence.stop()
        return GLib.SOURCE_CONTINUE

    def _resume(self):
        self.paused = False
        self._reset_for_rearm("WAITING_FOR_NEAR", "Resumed; waiting for fresh Bluetooth readings before arming.")
        try:
            self.presence.start()
        except MonitorError as error:
            self._bluetooth_failed(f"Could not resume Bluetooth scanning: {error}")
        return GLib.SOURCE_CONTINUE

    def _resume_discovery(self):
        attempts = 0

        def retry():
            nonlocal attempts
            if self.paused or self.sleeping:
                return GLib.SOURCE_REMOVE
            attempts += 1
            try:
                self.presence.start()
                self._log("Bluetooth scanning resumed; waiting for fresh nearby readings.")
                return GLib.SOURCE_REMOVE
            except MonitorError as error:
                if attempts >= 6:
                    self._bluetooth_failed(f"Bluetooth did not recover after resume: {error}")
                    return GLib.SOURCE_REMOVE
                return GLib.SOURCE_CONTINUE

        GLib.timeout_add_seconds(2, retry)

    def _shutdown(self):
        self.loop.quit()
        return GLib.SOURCE_REMOVE

    def start(self):
        try:
            self.presence.start()
        except MonitorError as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 1

        if self.probe:
            print("Bluetooth RSSI probe active for 20 seconds; it cannot lock the screen.", flush=True)
            GLib.timeout_add_seconds(20, self._finish_probe)
            self.loop.run()
            return 1 if self.fatal else 0

        self.system_bus.signal_subscribe(
            "org.freedesktop.login1",
            "org.freedesktop.login1.Manager",
            "PrepareForSleep",
            "/org/freedesktop/login1",
            None,
            Gio.DBusSignalFlags.NONE,
            self._prepare_for_sleep,
        )
        GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, self._pause)
        GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR2, self._resume)
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, sig, self._shutdown)

        self._write_state("WAITING_FOR_NEAR", self._description("WAITING_FOR_NEAR"))
        print("Monitor active: waiting for stable nearby Bluetooth RSSI readings before arming.", flush=True)
        GLib.timeout_add_seconds(self.config["POLL_SECONDS"], self._tick)
        self.loop.run()
        self.presence.stop()
        return 1 if self.fatal else 0

    def _finish_probe(self):
        if self.probe_samples:
            samples = sorted(self.probe_samples)
            median = samples[len(samples) // 2]
            print(f"Probe summary: {len(samples)} RSSI readings; median {median} dBm.", flush=True)
        else:
            print("Probe summary: no RSSI readings received. Confirm the phone is paired in Ubuntu Bluetooth settings, Bluetooth is on, and it is advertising/discoverable.", flush=True)
        idle = self._idle_milliseconds()
        if idle is not None:
            print(f"GNOME idle: {idle / 1000:.1f}s", flush=True)
        self.loop.quit()
        self.presence.stop()
        return GLib.SOURCE_REMOVE

    def _tick(self):
        if self.paused or self.sleeping:
            return GLib.SOURCE_CONTINUE

        now = time.monotonic()
        if now - self.last_tick > 30:
            self.machine.reset()
            self._log("Wake or scheduler gap detected; waiting for fresh near readings before re-arming.")
        self.last_tick = now

        result = self.machine.tick(time.monotonic() * 1000, False)
        if result["state"] == "AWAY_WAITING_FOR_IDLE":
            idle_ms = self._idle_milliseconds()
            if idle_ms is not None:
                result = self.machine.tick(
                    time.monotonic() * 1000,
                    idle_ms >= self.config["IDLE_AFTER_SECONDS"] * 1000,
                )

        self._set_state(result["state"])
        if result["should_lock"]:
            self._log("Phone stayed away and GNOME reports idle; requesting screen lock.")
            if lock_session(self.config["LOCK_CMD"]):
                self._log("Screen lock command completed. Phone return will re-arm; it will not unlock.")
                self._set_state("LOCKED_AWAY")
            else:
                self.machine.lock_failed(time.monotonic() * 1000)
                self._write_state("LOCK_FAILED", self._description("LOCK_FAILED"))
                self._set_state("LOCK_FAILED")
                self._log("ERROR: GNOME lock methods failed. Test `loginctl lock-session` from this session and check the journal.")
        return GLib.SOURCE_CONTINUE


def main():
    config_path = os.path.join(os.path.expanduser("~"), ".config", "dynamic_lock", "config")
    state_path = None
    probe = False
    args = sys.argv[1:]
    index = 0
    while index < len(args):
        if args[index] == "--config" and index + 1 < len(args):
            config_path = args[index + 1]
            index += 2
        elif args[index] == "--state" and index + 1 < len(args):
            state_path = args[index + 1]
            index += 2
        elif args[index] == "--probe":
            probe = True
            index += 1
        else:
            print(f"ERROR: unknown monitor option {args[index]}", file=sys.stderr)
            return 2

    try:
        config = read_config(config_path)
        monitor = Monitor(config, state_path=state_path, probe=probe)
        return monitor.start()
    except (MonitorError, GLib.Error, OSError) as error:
        print(f"ERROR: monitor startup failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
