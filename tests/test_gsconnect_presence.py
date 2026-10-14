import unittest

from dynamic_lock_monitor import GSConnectPresence, MonitorError


def device(path, *, name, device_id, kind="phone", paired=True, connected=True):
    return path, {
        "Name": name,
        "Id": device_id,
        "Type": kind,
        "Paired": paired,
        "Connected": connected,
    }


class GSConnectPresenceTests(unittest.TestCase):
    def test_selects_the_only_paired_phone_and_reads_connection_state(self):
        presence = GSConnectPresence(session_bus=object())
        presence._devices = lambda: [
            device("/device/phone", name="My phone", device_id="phone-id"),
            device("/device/tablet", name="Tablet", device_id="tablet-id", kind="tablet"),
        ]

        self.assertTrue(presence.check())
        self.assertEqual(presence.object_path, "/device/phone")

        presence._devices = lambda: [
            device("/device/phone", name="My phone", device_id="phone-id", connected=False),
            device("/device/tablet", name="Tablet", device_id="tablet-id", kind="tablet"),
        ]
        self.assertFalse(presence.check())

    def test_requires_explicit_name_if_multiple_paired_phones_exist(self):
        presence = GSConnectPresence(session_bus=object())
        presence._devices = lambda: [
            device("/device/one", name="Phone one", device_id="one"),
            device("/device/two", name="Phone two", device_id="two"),
        ]

        with self.assertRaisesRegex(MonitorError, "exactly one paired GSConnect phone"):
            presence.check()

    def test_configured_name_selects_exact_paired_phone(self):
        presence = GSConnectPresence(session_bus=object(), device_name="PHONE TWO")
        presence._devices = lambda: [
            device("/device/one", name="Phone one", device_id="one"),
            device("/device/two", name="Phone two", device_id="two", connected=False),
        ]

        self.assertFalse(presence.check())
        self.assertEqual(presence.object_path, "/device/two")

    def test_ignores_unpaired_phones(self):
        presence = GSConnectPresence(session_bus=object())
        presence._devices = lambda: [
            device("/device/phone", name="My phone", device_id="phone-id", paired=False),
        ]

        with self.assertRaisesRegex(MonitorError, "exactly one paired GSConnect phone"):
            presence.check()


if __name__ == "__main__":
    unittest.main()
