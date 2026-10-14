#!/usr/bin/env python3
"""GNOME user monitor using an active Bluetooth SDP presence check."""

import errno
import os
import select
import shlex
import signal
import socket
import subprocess
import sys
import time

import gi

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib, GLibUnix

from dynamic_lock_state import PresenceMachine


BLUEZ = "org.bluez"
DEVICE_IFACE = "org.bluez.Device1"
ADAPTER_IFACE = "org.bluez.Adapter1"
PROPERTIES_IFACE = "org.freedesktop.DBus.Properties"
MUTTER_IDLE = "org.gnome.Mutter.IdleMonitor"
MUTTER_PATH = "/org/gnome/Mutter/IdleMonitor/Core"
SDP_PSM = 1
SDP_KEEPALIVE = bytes((0x02, 0, 1, 0, 8, 0x35, 3, 0x19, 0x01, 0, 0, 1, 0))


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
        "AWAY_CONFIRM_SECONDS",
        "RETURN_CONFIRM_SECONDS",
        "IDLE_AFTER_SECONDS",
        "POLL_SECONDS",
        "LOCK_CMD",
    }
    legacy = {"RSSI_DROP_DB", "RSSI_STALE_SECONDS"}
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
            print(f"WARN: {key} is obsolete; this monitor checks Bluetooth link presence.", file=sys.stderr)
            continue
        if key not in allowed:
            print(f"WARN: ignoring unknown config key {key}", file=sys.stderr)
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value

    address = values.get("PHONE_ADDRESS", "")
    if not address:
        raise MonitorError(f"set PHONE_ADDRESS in {path} to the paired phone's Bluetooth address")
    if len(address) != 17 or any(
        len(part) != 2 or any(char not in "0123456789abcdefABCDEF" for char in part)
        for part in address.split(":")
    ) or len(address.split(":")) != 6:
        raise MonitorError("PHONE_ADDRESS must be a Bluetooth address like AA:BB:CC:DD:EE:FF")

    settings = {
        "AWAY_CONFIRM_SECONDS": (30, 5, 300),
        "RETURN_CONFIRM_SECONDS": (5, 1, 60),
        "IDLE_AFTER_SECONDS": (1, 0, 3600),
        "POLL_SECONDS": (5, 2, 30),
    }
    config = {"PHONE_ADDRESS": address.upper(), "LOCK_CMD": values.get("LOCK_CMD", "")}
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


def variant_value(value):
    return value.unpack() if isinstance(value, GLib.Variant) else value


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


class BluetoothPresence:
    """Hold a Classic Bluetooth SDP channel and verify it with a request."""

    def __init__(self, address):
        if not all(hasattr(socket, name) for name in ("AF_BLUETOOTH", "BTPROTO_L2CAP")):
            raise MonitorError("Python Bluetooth L2CAP sockets are unavailable; use the system python3 with Bluetooth support")
        self.address = address
        self.sock = None

    @staticmethod
    def _is_remote_absence(error):
        return error.errno in {
            errno.EHOSTDOWN,
            errno.EHOSTUNREACH,
            errno.ENETUNREACH,
            errno.ETIMEDOUT,
            errno.ENOTCONN,
            errno.ECONNRESET,
            errno.EPIPE,
        }

    def check(self):
        if self.sock is None:
            sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
            sock.settimeout(2)
            try:
                sock.connect((self.address, SDP_PSM))
            except ConnectionRefusedError:
                # A remote refusal is still proof that the paired radio answered.
                sock.close()
                return True
            except OSError as error:
                sock.close()
                if error.errno in (errno.EAFNOSUPPORT, errno.EPROTONOSUPPORT, errno.EINVAL, errno.EPERM):
                    raise MonitorError(f"Bluetooth L2CAP connection failed locally: {error}") from error
                if self._is_remote_absence(error) or isinstance(error, TimeoutError):
                    return False
                raise MonitorError(f"Bluetooth connection failed for a local or unknown reason: {error}") from error
            sock.setblocking(False)
            self.sock = sock

        try:
            self.sock.send(SDP_KEEPALIVE)
            readable, _, errored = select.select([self.sock], [], [self.sock], 2)
            if errored or not readable:
                self.close()
                return False
            if not self.sock.recv(1024):
                self.close()
                return False
            return True
        except OSError as error:
            self.close()
            if error.errno in (errno.EAFNOSUPPORT, errno.EPROTONOSUPPORT, errno.EINVAL, errno.EPERM):
                raise MonitorError(f"Bluetooth SDP check failed locally: {error}") from error
            if self._is_remote_absence(error):
                return False
            raise MonitorError(f"Bluetooth SDP check failed for a local or unknown reason: {error}") from error

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            finally:
                self.sock = None


class Monitor:
    def __init__(self, config, state_path=None, probe=False):
        self.config = config
        self.state_path = state_path
        self.probe = probe
        self.loop = GLib.MainLoop()
        self.system_bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self.session_bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.bluez_manager = Gio.DBusProxy.new_sync(
            self.system_bus,
            Gio.DBusProxyFlags.DO_NOT_AUTO_START,
            None,
            BLUEZ,
            "/",
            "org.freedesktop.DBus.ObjectManager",
            None,
        )
        self.adapter_path = self._find_device()
        self.adapter = Gio.DBusProxy.new_sync(
            self.system_bus,
            Gio.DBusProxyFlags.DO_NOT_AUTO_START,
            None,
            BLUEZ,
            self.adapter_path,
            ADAPTER_IFACE,
            None,
        )
        self.presence = BluetoothPresence(config["PHONE_ADDRESS"])
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

    def _find_device(self):
        try:
            objects = self.bluez_manager.call_sync(
                "GetManagedObjects", None, Gio.DBusCallFlags.NONE, 5000, None
            ).unpack()[0]
        except GLib.Error as error:
            raise MonitorError(f"cannot read BlueZ devices: {error.message}") from error
        for path, interfaces in objects.items():
            device = interfaces.get(DEVICE_IFACE)
            if not device:
                continue
            address = variant_value(device.get("Address"))
            if str(address).upper() == self.config["PHONE_ADDRESS"]:
                if not variant_value(device.get("Paired")):
                    raise MonitorError("configured phone is not paired in BlueZ; pair it in GNOME Bluetooth settings")
                return variant_value(device.get("Adapter"))
        raise MonitorError("configured phone is not known to BlueZ; pair it in GNOME Bluetooth settings")

    def _adapter_powered(self):
        powered = self.adapter.get_cached_property("Powered")
        if powered is None:
            try:
                powered = self.adapter.call_sync(
                    "org.freedesktop.DBus.Properties.Get",
                    GLib.Variant("(ss)", (ADAPTER_IFACE, "Powered")),
                    Gio.DBusCallFlags.NONE,
                    2000,
                    None,
                ).unpack()[0]
            except GLib.Error as error:
                raise MonitorError(f"cannot read Bluetooth adapter state: {error.message}") from error
        return bool(variant_value(powered))

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
            return float(value) / 1000.0
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
            "WAITING_FOR_NEAR": "Waiting for stable Bluetooth replies before arming",
            "NEAR_ARMED": "Phone responds over Bluetooth; monitor armed",
            "AWAY_PENDING": "Bluetooth link did not answer; confirming departure",
            "AWAY_WAITING_FOR_IDLE": "Phone away; waiting for GNOME idle state",
            "LOCK_REQUESTED": "Screen lock requested",
            "LOCKED_AWAY": "Lock requested; waiting for phone return to re-arm",
            "LOCK_FAILED": "Screen lock failed; see service logs",
            "PAUSED": "Paused by user",
            "SUSPENDED": "System is suspending; monitor will re-arm after wake",
            "UNKNOWN": "Bluetooth monitor unavailable; no lock will be triggered",
        }.get(state, state)

    def _set_state(self, state):
        if state == self.previous_state:
            return
        self.previous_state = state
        self._write_state(state, self._description(state))
        if not self.probe:
            self._log(f"State: {state}")

    def _reset_for_rearm(self, state, message):
        self.presence.close()
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
            self._reset_for_rearm("SUSPENDED", "Suspend detected; cleared Bluetooth presence state.")
        else:
            self._reset_for_rearm("WAITING_FOR_NEAR", "Resume detected; waiting for fresh Bluetooth replies.")

    def _pause(self):
        self.paused = True
        self._reset_for_rearm("PAUSED", "Paused; monitoring will require fresh Bluetooth replies when resumed.")
        return GLib.SOURCE_CONTINUE

    def _resume(self):
        self.paused = False
        self._reset_for_rearm("WAITING_FOR_NEAR", "Resumed; waiting for fresh Bluetooth replies before arming.")
        return GLib.SOURCE_CONTINUE

    def _shutdown(self):
        self.presence.close()
        self.loop.quit()
        return GLib.SOURCE_REMOVE

    def start(self):
        if self.probe:
            if not self._adapter_powered():
                print("Bluetooth adapter is powered off.")
                return 1
            try:
                present = self.presence.check()
            except MonitorError as error:
                print(f"ERROR: {error}", file=sys.stderr)
                return 1
            idle = self._idle_milliseconds()
            print("Phone answered the Bluetooth SDP check." if present else "No Bluetooth SDP reply from the phone.")
            if idle is not None:
                print(f"GNOME idle: {idle / 1000:.1f}s")
            self.presence.close()
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
        print("Monitor active: waiting for stable Bluetooth replies before arming.", flush=True)
        GLib.timeout_add_seconds(1, self._tick)
        self.loop.run()
        self.presence.close()
        return 1 if self.fatal else 0

    def _tick(self):
        if self.paused or self.sleeping:
            return GLib.SOURCE_CONTINUE

        now = time.monotonic()
        if now >= self.next_check:
            self.next_check = now + self.config["POLL_SECONDS"]
            try:
                if not self._adapter_powered():
                    self._reset_for_rearm("UNKNOWN", "ERROR: local Bluetooth adapter is powered off; refusing to treat it as phone departure.")
                    return GLib.SOURCE_CONTINUE
                present = self.presence.check()
            except MonitorError as error:
                self._reset_for_rearm("UNKNOWN", f"ERROR: Bluetooth monitor unavailable; refusing to lock ({error}).")
                return GLib.SOURCE_CONTINUE
            self.machine.observe(present, now * 1000)
            if self.probe:
                print("Bluetooth reply present." if present else "Bluetooth reply absent.", flush=True)

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
