#!/usr/bin/env python3
"""GNOME user monitor using GSConnect device connection state."""

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


GSCONNECT = "org.gnome.Shell.Extensions.GSConnect"
GSCONNECT_PATH = "/org/gnome/Shell/Extensions/GSConnect"
GSCONNECT_DEVICE_IFACE = "org.gnome.Shell.Extensions.GSConnect.Device"
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
        "GSCONNECT_DEVICE_NAME",
        "AWAY_CONFIRM_SECONDS",
        "RETURN_CONFIRM_SECONDS",
        "IDLE_AFTER_SECONDS",
        "POLL_SECONDS",
        "LOCK_CMD",
    }
    legacy = {"PHONE_ADDRESS", "RSSI_DROP_DB", "RSSI_STALE_SECONDS"}
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
            print(f"WARN: {key} is obsolete; this monitor uses GSConnect device status.", file=sys.stderr)
            continue
        if key not in allowed:
            print(f"WARN: ignoring unknown config key {key}", file=sys.stderr)
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value

    settings = {
        "AWAY_CONFIRM_SECONDS": (30, 5, 300),
        "RETURN_CONFIRM_SECONDS": (5, 1, 60),
        "IDLE_AFTER_SECONDS": (1, 0, 3600),
        "POLL_SECONDS": (5, 2, 30),
    }
    config = {
        "GSCONNECT_DEVICE_NAME": values.get("GSCONNECT_DEVICE_NAME", ""),
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


def lock_session(custom_command):
    if custom_command:
        try:
            argv = shlex.split(custom_command)
        except ValueError:
            argv = []
            print("ERROR: LOCK_CMD could not be parsed; trying GNOME lock methods.", file=sys.stderr)
        if argv and run_command(argv):
            return True

    methods = (
        ("loginctl", "lock-session"),
        (
            "gdbus", "call", "--session", "--dest", "org.gnome.ScreenSaver",
            "--object-path", "/org/gnome/ScreenSaver", "--method",
            "org.gnome.ScreenSaver.Lock",
        ),
        ("xdg-screensaver", "lock"),
    )
    return any(run_command(method) for method in methods)


class GSConnectPresence:
    """Read a paired phone's Connected property from GSConnect's D-Bus API."""

    def __init__(self, session_bus, device_name=""):
        self.session_bus = session_bus
        self.device_name = device_name.casefold()
        self.object_path = None
        self.device_id = None

    @staticmethod
    def _unpack(value):
        return value.unpack() if isinstance(value, GLib.Variant) else value

    def _devices(self):
        try:
            objects = self.session_bus.call_sync(
                GSCONNECT,
                GSCONNECT_PATH,
                OBJECT_MANAGER,
                "GetManagedObjects",
                None,
                None,
                Gio.DBusCallFlags.NONE,
                3000,
                None,
            ).unpack()[0]
        except GLib.Error as error:
            raise MonitorError(
                f"cannot read GSConnect devices; make sure GSConnect is enabled and running ({error.message})"
            ) from error
        result = []
        for path, interfaces in objects.items():
            properties = interfaces.get(GSCONNECT_DEVICE_IFACE)
            if properties is None:
                continue
            result.append((path, {key: self._unpack(value) for key, value in properties.items()}))
        return result

    def _select_device(self):
        devices = [
            (path, props)
            for path, props in self._devices()
            if props.get("Paired") and props.get("Type") == "phone"
        ]
        if self.device_name:
            matches = [(path, props) for path, props in devices if props.get("Name", "").casefold() == self.device_name]
            if len(matches) != 1:
                raise MonitorError("GSCONNECT_DEVICE_NAME must exactly match one paired GSConnect phone")
            return matches[0]
        if len(devices) != 1:
            raise MonitorError(
                "expected exactly one paired GSConnect phone; set GSCONNECT_DEVICE_NAME in the private config to choose one"
            )
        return devices[0]

    def check(self):
        path, properties = self._select_device()
        if self.object_path is None:
            self.object_path = path
            self.device_id = properties.get("Id")
        elif path != self.object_path or properties.get("Id") != self.device_id:
            raise MonitorError("the selected GSConnect phone changed; restart after checking the private config")
        return bool(properties.get("Connected"))


class Monitor:
    def __init__(self, config, state_path=None, probe=False):
        self.config = config
        self.state_path = state_path
        self.probe = probe
        self.loop = GLib.MainLoop()
        self.system_bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self.session_bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.presence = GSConnectPresence(
            self.session_bus, config["GSCONNECT_DEVICE_NAME"]
        )
        self.machine = PresenceMachine(
            away_seconds=config["AWAY_CONFIRM_SECONDS"],
            return_seconds=config["RETURN_CONFIRM_SECONDS"],
        )
        self.previous_state = ""
        self.paused = False
        self.sleeping = False
        self.fatal = False
        self.next_check = 0.0
        self.idle_warning_shown = False
        self._signal_ids = []

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
            "WAITING_FOR_NEAR": "Waiting for a stable GSConnect connection before arming",
            "NEAR_ARMED": "Phone is connected in GSConnect; monitor armed",
            "AWAY_PENDING": "GSConnect phone is disconnected; confirming departure",
            "AWAY_WAITING_FOR_IDLE": "Phone away; waiting for GNOME idle state",
            "LOCK_REQUESTED": "Screen lock requested",
            "LOCKED_AWAY": "Lock requested; waiting for phone return to re-arm",
            "LOCK_FAILED": "Screen lock failed; see service logs",
            "PAUSED": "Paused by user",
            "SUSPENDED": "System is suspending; monitor will re-arm after wake",
            "UNKNOWN": "GSConnect status unavailable; no lock will be triggered",
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
        self.next_check = time.monotonic() + self.config["POLL_SECONDS"]
        changed = state != self.previous_state
        self.previous_state = state
        self._write_state(state, self._description(state))
        if changed and not self.probe:
            self._log(message)

    def _prepare_for_sleep(self, _connection, _sender, _path, _iface, _signal, parameters):
        preparing = parameters.unpack()[0]
        self.sleeping = bool(preparing)
        if preparing:
            self._reset_for_rearm("SUSPENDED", "Suspend detected; cleared GSConnect presence state.")
        else:
            self._reset_for_rearm("WAITING_FOR_NEAR", "Resume detected; waiting for fresh GSConnect status.")

    def _pause(self):
        self.paused = True
        self._reset_for_rearm("PAUSED", "Paused; monitoring will require fresh GSConnect status when resumed.")
        return GLib.SOURCE_CONTINUE

    def _resume(self):
        self.paused = False
        self._reset_for_rearm("WAITING_FOR_NEAR", "Resumed; waiting for a fresh GSConnect connection before arming.")
        return GLib.SOURCE_CONTINUE

    def _shutdown(self):
        self.loop.quit()
        return GLib.SOURCE_REMOVE

    def start(self):
        if self.probe:
            try:
                present = self.presence.check()
            except MonitorError as error:
                print(f"ERROR: {error}", file=sys.stderr)
                return 1
            idle = self._idle_milliseconds()
            print("GSConnect phone is connected." if present else "GSConnect phone is disconnected.")
            if idle is not None:
                print(f"GNOME idle: {idle / 1000:.1f}s")
            return 0

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
        print("Monitor active: waiting for a stable GSConnect phone connection before arming.", flush=True)
        GLib.timeout_add_seconds(1, self._tick)
        self.loop.run()
        return 1 if self.fatal else 0

    def _tick(self):
        if self.paused or self.sleeping:
            return GLib.SOURCE_CONTINUE

        now = time.monotonic()
        if now >= self.next_check:
            self.next_check = now + self.config["POLL_SECONDS"]
            try:
                present = self.presence.check()
            except MonitorError as error:
                self._reset_for_rearm("UNKNOWN", f"ERROR: GSConnect status unavailable; refusing to lock ({error}).")
                return GLib.SOURCE_CONTINUE
            self.machine.observe(present, now * 1000)
            if self.probe:
                print("GSConnect phone connected." if present else "GSConnect phone disconnected.", flush=True)

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
