import unittest

from dynamic_lock_state import PresenceMachine


class PresenceMachineTests(unittest.TestCase):
    def setUp(self):
        self.machine = PresenceMachine()

    def arm(self):
        for now in (0, 5000, 10000):
            self.machine.observe(0, now)
        self.assertEqual(self.machine.state, 'NEAR_ARMED')

    def away(self):
        for now in range(15000, 55001, 5000):
            self.machine.observe(-15, now)

    def test_three_fresh_near_readings_over_ten_seconds(self):
        for now in (0, 1, 2):
            self.machine.observe(0, now)
        self.assertFalse(self.machine.armed)
        self.machine.observe(0, 10000)
        self.assertTrue(self.machine.armed)

    def test_hour_separated_readings_never_arm(self):
        for now in (0, 3600000, 7200000):
            self.machine.observe(0, now)
        self.assertFalse(self.machine.armed)

    def test_silence_never_causes_lock(self):
        self.arm()
        for now in (25001, 60000, 3600000):
            self.assertFalse(self.machine.tick(now, True)['should_lock'])
        self.assertEqual(self.machine.state, 'UNKNOWN')

    def test_starting_away_never_arms(self):
        for now in range(0, 120000, 5000):
            self.machine.accept('absent', now)
            self.assertFalse(self.machine.tick(now, True)['should_lock'])
        self.assertFalse(self.machine.armed)

    def test_zero_valid_unavailable_invalid(self):
        self.arm()
        self.machine.observe(0, 12000)
        self.assertEqual(self.machine.state, 'NEAR_ARMED')
        self.machine.observe(127, 15000)
        self.assertFalse(self.machine.armed)

    def test_weak_signal_and_idle_both_required(self):
        self.arm()
        self.away()
        self.assertFalse(self.machine.tick(55000, False)['should_lock'])
        self.assertEqual(self.machine.state, 'AWAY_WAITING_FOR_IDLE')
        self.assertTrue(self.machine.tick(55000, True)['should_lock'])
        self.machine.lock_succeeded()
        self.assertFalse(self.machine.tick(56000, True)['should_lock'])

    def test_no_drifting_baseline_after_moving_closer(self):
        self.arm()
        for now in range(15000, 50000, 5000):
            self.machine.observe(10, now)
        for now in range(50000, 100000, 5000):
            self.machine.observe(0, now)
            self.assertFalse(self.machine.tick(now, True)['should_lock'])

    def test_unknown_cancels_absence_and_requires_fresh_near(self):
        self.arm()
        for now in (15000, 25000, 35000):
            self.machine.accept('absent', now)
        self.machine.accept('unknown', 40000, reason='Adapter off')
        for now in range(45000, 100000, 5000):
            self.machine.accept('absent', now)
        self.assertFalse(self.machine.tick(100000, True)['should_lock'])

    def test_timeouts_require_repeated_fresh_evidence_spanning_confirmation(self):
        self.arm()
        self.machine.accept('absent', 15000)
        self.assertFalse(self.machine.tick(45000, True)['should_lock'])
        self.arm()
        for now in (15000, 25000, 35000):
            self.machine.accept('absent', now)
        self.assertFalse(self.machine.tick(45000, True)['should_lock'])
        self.machine.accept('absent', 45000)
        self.assertTrue(self.machine.tick(45000, True)['should_lock'])

    def test_band_and_single_near_sample_cancel_away_immediately(self):
        for value in (-7, 0):
            self.machine.reset()
            self.arm()
            self.away()
            self.machine.observe(value, 60000)
            self.assertIsNone(self.machine.away_since)
            self.assertFalse(self.machine.tick(60000, True)['should_lock'])

    def test_interrupted_return_does_not_rearm(self):
        self.arm()
        self.away()
        self.machine.tick(55000, True)
        self.machine.lock_succeeded()
        self.machine.observe(0, 60000)
        self.machine.observe(0, 65000)
        self.machine.observe(-7, 70000)
        self.assertTrue(self.machine.locked_once)
        for now in (75000, 80000, 85000):
            self.machine.observe(0, now)
        self.assertFalse(self.machine.locked_once)
        self.assertEqual(self.machine.state, 'NEAR_ARMED')

    def test_bounded_lock_retry_and_no_duplicates_in_flight(self):
        self.arm()
        self.away()
        self.assertTrue(self.machine.tick(55000, True)['should_lock'])
        self.assertFalse(self.machine.tick(55001, True)['should_lock'])
        self.machine.lock_failed(55000)
        self.machine.observe(-15, 60000)
        self.assertFalse(self.machine.tick(60000, True)['should_lock'])
        self.machine.observe(-15, 65000)
        self.assertTrue(self.machine.tick(65000, True)['should_lock'])
        for _ in range(1000):
            self.machine.lock_failed(65000)
        self.assertEqual(self.machine.next_lock_retry_at, 365000)

    def test_suspend_or_pause_reset_clears_all_evidence(self):
        self.arm()
        self.away()
        self.machine.reset()
        self.assertFalse(self.machine.tick(60000, True)['should_lock'])
        self.assertEqual(len(self.machine.history), 0)

    def test_bounded_history_and_duplicate_timestamps(self):
        for now in range(0, 1000000, 2000):
            self.machine.observe(0, now)
        self.assertEqual(len(self.machine.history), 3)
        self.machine.observe(-15, 998000)
        self.assertEqual(self.machine.state, 'UNKNOWN')


if __name__ == '__main__':
    unittest.main()
