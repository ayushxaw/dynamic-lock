"""Nonblocking GNOME idle and verified lock requests on the user's session bus."""

import shlex
import time

from gi.repository import Gio, GLib

MUTTER_IDLE = 'org.gnome.Mutter.IdleMonitor'
MUTTER_PATH = '/org/gnome/Mutter/IdleMonitor/Core'
SAVER = 'org.gnome.ScreenSaver'
SAVER_PATH = '/org/gnome/ScreenSaver'


def lock_settings_problem():
    source = Gio.SettingsSchemaSource.get_default()
    for schema, key, required in (
            ('org.gnome.desktop.screensaver', 'lock-enabled', True),
            ('org.gnome.desktop.lockdown', 'disable-lock-screen', False)):
        found = source.lookup(schema, True) if source else None
        if found is None or not found.has_key(key):
            return 'GNOME lock settings unavailable; use an Ubuntu GNOME session.'
        settings = Gio.Settings.new_full(found, None, None)
        if settings.get_boolean(key) != required:
            return 'GNOME screen locking is disabled in Settings or by policy; enable it before activation.'
    return None


class Desktop:
    def __init__(self, bus):
        self.bus = bus

    def call(self, destination, path, interface, method, callback, parameters=None):
        def done(connection, result):
            try:
                value = connection.call_finish(result).unpack()
            except GLib.Error:
                value = None
            callback(value)
        self.bus.call(destination, path, interface, method, parameters, None,
                      Gio.DBusCallFlags.NO_AUTO_START, 1500, None, done)

    def idle(self, callback):
        def done(value):
            # Mutter GetIdletime is already in milliseconds (not microseconds).
            callback(float(value[0]) if value and type(value[0]) is int else None)
        self.call(MUTTER_IDLE, MUTTER_PATH, MUTTER_IDLE, 'GetIdletime', done)

    def active(self, callback):
        self.call(SAVER, SAVER_PATH, SAVER, 'GetActive',
                  lambda value: callback(value[0] if value and type(value[0]) is bool else None))

    def lock(self, command, guard, callback):
        """Invoke once, then require GetActive=true. Guard is rechecked before effects."""
        completed = False

        def finish(success):
            nonlocal completed
            if not completed:
                completed = True
                callback(success)

        def verify():
            deadline = time.monotonic() + 3

            def check():
                if completed:
                    return GLib.SOURCE_REMOVE

                def result(active):
                    if active is True:
                        finish(True)
                    elif time.monotonic() >= deadline or not guard():
                        finish(False)
                    else:
                        GLib.timeout_add(200, check)
                self.active(result)
                return GLib.SOURCE_REMOVE
            check()

        def gnome():
            if not guard() or lock_settings_problem():
                finish(False)
                return
            # GetActive alone can mean idle blanking. Require the explicit Lock
            # method to succeed before accepting its subsequent active state.
            self.call(SAVER, SAVER_PATH, SAVER, 'Lock',
                      lambda value: finish(False) if value is None else verify())

        if not guard() or lock_settings_problem():
            finish(False)
        elif command:
            try:
                process = Gio.Subprocess.new(shlex.split(command),
                    Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE)
            except (GLib.Error, ValueError):
                gnome()
                return
            timed_out = False

            def timeout():
                nonlocal timed_out
                timed_out = True
                process.force_exit()
                return GLib.SOURCE_REMOVE
            # Keep enough of the monitor's three-second evidence freshness
            # budget for the GNOME request, even if the helper hangs.
            timer = GLib.timeout_add(1000, timeout)

            def exited(child, result):
                if not timed_out:
                    GLib.source_remove(timer)
                try:
                    child.wait_check_finish(result)
                except GLib.Error:
                    pass
                # A custom command's exit status/blank screen is not proof of
                # credential locking. GNOME Lock is always requested as well.
                gnome()
            process.wait_check_async(None, exited)
        else:
            gnome()
