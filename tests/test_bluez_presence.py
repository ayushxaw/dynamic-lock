import unittest

from dynamic_lock_monitor import BluezPresence


class FakeParameters:
    def __init__(self, value):
        self.value = value

    def unpack(self):
        return self.value


class BluezPresenceTests(unittest.TestCase):
    def test_only_selected_device_rssi_is_forwarded(self):
        samples = []
        failures = []
        presence = BluezPresence(object(), "AA:BB:CC:DD:EE:FF", samples.append, failures.append)
        presence.device_path = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
        presence.adapter_path = "/org/bluez/hci0"

        presence._properties_changed(
            None, None, presence.device_path, None, None,
            FakeParameters(("org.bluez.Device1", {"RSSI": -62}, [])),
        )
        presence._properties_changed(
            None, None, "/org/bluez/hci0/dev_00_00_00_00_00_00", None, None,
            FakeParameters(("org.bluez.Device1", {"RSSI": -20}, [])),
        )

        self.assertEqual(samples, [-62])
        self.assertEqual(failures, [])

    def test_adapter_power_off_is_a_monitor_failure(self):
        failures = []
        presence = BluezPresence(object(), "AA:BB:CC:DD:EE:FF", lambda _rssi: None, failures.append)
        presence.adapter_path = "/org/bluez/hci0"

        presence._properties_changed(
            None, None, presence.adapter_path, None, None,
            FakeParameters(("org.bluez.Adapter1", {"Powered": False}, [])),
        )

        self.assertEqual(len(failures), 1)
        self.assertIn("powered off", failures[0])


if __name__ == "__main__":
    unittest.main()
