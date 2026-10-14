import unittest
from unittest.mock import patch

from dynamic_lock_monitor import Monitor


class IdleMonitorUnitTests(unittest.TestCase):
    def test_mutter_idle_time_remains_in_milliseconds(self):
        class Result:
            def unpack(self):
                return (1250,)

        class Proxy:
            def call_sync(self, *_args):
                return Result()

        monitor = Monitor.__new__(Monitor)
        monitor.session_bus = object()
        monitor.idle_warning_shown = False
        monitor._log = lambda _message: None

        with patch("dynamic_lock_monitor.Gio.DBusProxy.new_sync", return_value=Proxy()):
            self.assertEqual(monitor._idle_milliseconds(), 1250.0)


if __name__ == "__main__":
    unittest.main()
