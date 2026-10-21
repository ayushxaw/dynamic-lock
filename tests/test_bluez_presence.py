import unittest
from unittest.mock import Mock
from gi.repository import GLib
from dynamic_lock_bluetooth import SensorError
from dynamic_lock_monitor import BluezTarget


class BluezTargetTests(unittest.TestCase):
    def test_service_failure_is_actionable_and_redacted(self):
        bus = Mock()
        bus.call_sync.side_effect = GLib.Error('private device identity')
        with self.assertRaises(SensorError) as failure:
            BluezTarget(bus, 'AA:BB:CC:DD:EE:FF')()
        self.assertIn('BlueZ unavailable', str(failure.exception))
        self.assertNotIn('private', str(failure.exception))

    def test_does_not_request_discovery_or_connect_profiles(self):
        bus = Mock()
        bus.call_sync.return_value.unpack.return_value = ({},)
        with self.assertRaises(SensorError):
            BluezTarget(bus, 'AA:BB:CC:DD:EE:FF')()
        self.assertEqual(bus.call_sync.call_args.args[3], 'GetManagedObjects')
        self.assertEqual(bus.call_sync.call_count, 1)
