import unittest

from dynamic_lock_state import PresenceMachine


class PresenceMachineTests(unittest.TestCase):
    def setUp(self):
        self.machine = PresenceMachine(away_seconds=30, return_seconds=5)

    def arm(self):
        for now in (0, 5000, 10000):
            self.machine.observe(True, now)
        self.assertEqual(self.machine.state, "NEAR_ARMED")

    def test_requires_stable_near_before_arming(self):
        self.machine.observe(True, 0)
        self.machine.observe(False, 5000)
        self.machine.observe(True, 10000)
        self.assertEqual(self.machine.state, "WAITING_FOR_NEAR")
        self.assertFalse(self.machine.tick(10000, True)["should_lock"])

    def test_absence_must_be_confirmed_and_session_idle(self):
        self.arm()
        self.machine.observe(False, 15000)
        self.assertEqual(self.machine.tick(44000, True)["state"], "AWAY_PENDING")
        self.assertFalse(self.machine.tick(45000, False)["should_lock"])
        self.assertEqual(self.machine.state, "AWAY_WAITING_FOR_IDLE")
        self.assertTrue(self.machine.tick(46000, True)["should_lock"])

    def test_return_cancels_departure_and_rearms_without_unlocking(self):
        self.arm()
        self.machine.observe(False, 15000)
        self.assertFalse(self.machine.tick(44000, True)["should_lock"])
        self.machine.observe(True, 46000)
        self.assertEqual(self.machine.tick(47000, True)["state"], "RETURN_PENDING")
        self.machine.observe(True, 51000)
        self.assertEqual(self.machine.state, "NEAR_ARMED")
        self.assertIsNone(self.machine.away_since)
        self.assertFalse(self.machine.locked_once)

    def test_failed_lock_retries_with_backoff(self):
        self.arm()
        self.machine.observe(False, 15000)
        self.assertTrue(self.machine.tick(45000, True)["should_lock"])
        self.machine.lock_failed(45000)
        self.assertFalse(self.machine.tick(54999, True)["should_lock"])
        self.assertTrue(self.machine.tick(55000, True)["should_lock"])

    def test_one_lock_per_departure(self):
        self.arm()
        self.machine.observe(False, 15000)
        self.assertTrue(self.machine.tick(45000, True)["should_lock"])
        self.assertFalse(self.machine.tick(50000, False)["should_lock"])
        self.assertEqual(self.machine.state, "LOCKED_AWAY")


if __name__ == "__main__":
    unittest.main()
