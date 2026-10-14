import unittest

from dynamic_lock_state import PresenceMachine


class PresenceMachineTests(unittest.TestCase):
    def setUp(self):
        self.machine = PresenceMachine(away_seconds=30, return_seconds=5, stale_seconds=15)

    def arm_near(self):
        for now in (0, 5000, 10000):
            self.machine.observe(-50, now)
        self.assertEqual(self.machine.state, "NEAR_ARMED")

    def test_requires_multiple_rssi_samples_before_arming(self):
        self.machine.observe(-50, 0)
        self.machine.observe(-51, 5000)
        self.assertEqual(self.machine.state, "WAITING_FOR_NEAR")
        self.machine.observe(-49, 10000)
        self.assertEqual(self.machine.state, "NEAR_ARMED")

    def test_weak_rssi_must_persist_and_session_must_be_idle(self):
        self.arm_near()
        for now in (15000, 20000, 25000, 30000, 35000, 40000, 45000):
            self.machine.observe(-65, now)
        self.assertEqual(self.machine.tick(54000, True)["state"], "AWAY_PENDING")
        self.assertFalse(self.machine.tick(55000, False)["should_lock"])
        self.assertEqual(self.machine.state, "AWAY_WAITING_FOR_IDLE")
        self.assertTrue(self.machine.tick(56000, True)["should_lock"])

    def test_stale_rssi_waits_for_stale_and_away_grace(self):
        self.arm_near()
        self.assertFalse(self.machine.tick(24999, True)["should_lock"])
        self.assertFalse(self.machine.tick(54999, True)["should_lock"])
        self.assertTrue(self.machine.tick(55001, True)["should_lock"])

    def test_return_cancels_departure_and_rearms_without_unlocking(self):
        self.arm_near()
        for now in (15000, 20000, 25000, 30000, 35000, 40000, 45000):
            self.machine.observe(-65, now)
        self.machine.observe(-50, 50000)
        self.machine.observe(-50, 55000)
        self.machine.observe(-50, 60000)
        self.assertEqual(self.machine.state, "RETURN_PENDING")
        self.machine.observe(-50, 65000)
        self.assertEqual(self.machine.state, "NEAR_ARMED")
        self.assertIsNone(self.machine.away_since)
        self.assertFalse(self.machine.locked_once)

    def test_failed_lock_retries_with_backoff(self):
        self.arm_near()
        for now in (15000, 20000, 25000, 30000, 35000, 40000, 45000):
            self.machine.observe(-65, now)
        self.assertFalse(self.machine.tick(54999, True)["should_lock"])
        self.assertTrue(self.machine.tick(55000, True)["should_lock"])
        self.machine.lock_failed(55000)
        self.machine.observe(-65, 60000)
        self.assertFalse(self.machine.tick(64999, True)["should_lock"])
        self.machine.observe(-65, 65000)
        self.assertTrue(self.machine.tick(65000, True)["should_lock"])

    def test_one_lock_per_departure(self):
        self.arm_near()
        for now in (15000, 20000, 25000, 30000, 35000, 40000, 45000):
            self.machine.observe(-65, now)
        self.assertTrue(self.machine.tick(55000, True)["should_lock"])
        self.assertFalse(self.machine.tick(56000, False)["should_lock"])
        self.assertEqual(self.machine.state, "LOCKED_AWAY")


if __name__ == "__main__":
    unittest.main()
