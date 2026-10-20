from concurrent.futures import Future
import unittest
from unittest.mock import Mock, patch

from dynamic_lock_bluetooth import Sample
from dynamic_lock_config import SETTINGS
from dynamic_lock_monitor import Monitor, RadioWorker


CONFIG = {key: values[0] for key, values in SETTINGS.items()} | {'BACKEND': 'bluetooth', 'PHONE_ADDRESS': 'AA:BB:CC:DD:EE:FF', 'LOCK_CMD': ''}


class MonitorTests(unittest.TestCase):
    def setUp(self):
        with patch('dynamic_lock_monitor.Gio.bus_get_sync'), patch('dynamic_lock_monitor.RadioWorker') as worker:
            self.monitor = Monitor(CONFIG, dry_run=True)
            self.monitor.worker.generation = 0
        self.monitor.log = Mock()
        self.monitor.desktop = Mock()

    def arm_and_depart(self):
        self.monitor.machine.reset()
        for now in (0, 5000, 10000):
            self.monitor.machine.observe(0, now)
        for now in range(15000, 55001, 5000):
            self.monitor.machine.observe(-15, now)
        self.monitor.health = 'measured'

    def test_pause_resume_idempotent_and_suspend_preserves_pause(self):
        m = self.monitor
        m._pause()
        m._pause()
        self.assertEqual(m.worker.invalidate.call_count, 1)
        parameters = Mock()
        parameters.unpack.return_value = (True,)
        m._prepare_for_sleep(None, None, None, None, None, parameters)
        parameters.unpack.return_value = (False,)
        m._prepare_for_sleep(None, None, None, None, None, parameters)
        self.assertTrue(m.paused)
        m._resume()
        calls = m.worker.invalidate.call_count
        m._resume()
        self.assertEqual(m.worker.invalidate.call_count, calls)
        self.assertFalse(m.machine.armed)

    def test_dry_run_uses_production_decision_but_never_lock_actuator(self):
        self.arm_and_depart()
        self.monitor.desktop.idle.side_effect = lambda callback: callback(1250)
        with patch('dynamic_lock_monitor.milliseconds', return_value=55000), patch('dynamic_lock_monitor.lock_settings_problem', return_value=None):
            self.monitor._decide()
        self.assertEqual(self.monitor.counts['lock_decisions'], 1)
        self.monitor.desktop.lock.assert_not_called()
        self.assertTrue(self.monitor.machine.locked_once)

    def test_late_idle_result_after_adapter_loss_cannot_lock(self):
        self.arm_and_depart()
        m = self.monitor
        m.dry_run = False
        with patch('dynamic_lock_monitor.milliseconds', return_value=55000), patch('dynamic_lock_monitor.lock_settings_problem', return_value=None):
            m._decide()
            callback = m.desktop.idle.call_args.args[0]
            m.worker.generation += 1
            m.invalidate('Adapter powered off')
            callback(2000)
        m.desktop.lock.assert_not_called()

    def test_idle_unknown_or_active_and_lock_disabled_inhibit(self):
        for value in (None, 0):
            self.arm_and_depart()
            m = self.monitor
            m.desktop.idle.side_effect = lambda callback: callback(value)
            with patch('dynamic_lock_monitor.milliseconds', return_value=55000), patch('dynamic_lock_monitor.lock_settings_problem', return_value=None):
                m._decide()
            self.assertEqual(m.counts['lock_decisions'], 0)
        with patch('dynamic_lock_monitor.milliseconds', return_value=55000), patch('dynamic_lock_monitor.lock_settings_problem', return_value='Lock disabled'):
            m._decide()
            self.assertEqual(m.inhibited, 'Lock disabled')

    def test_bluez_restart_and_pair_removal_reset(self):
        self.arm_and_depart()
        params = Mock()
        params.unpack.return_value = ('org.bluez', ':1.2', ':1.3')
        self.monitor._bluez_changed(None, None, '/', None, 'NameOwnerChanged', params)
        self.assertFalse(self.monitor.machine.armed)
        self.assertEqual(self.monitor.health, 'unknown')

    def test_full_dry_run_three_departures_and_returns_with_local_fault(self):
        m = self.monitor
        clock = [0]
        m.desktop.idle.side_effect = lambda callback: callback(2000)
        with patch('dynamic_lock_monitor.time.monotonic', side_effect=lambda: clock[0]), patch('dynamic_lock_monitor.lock_settings_problem', return_value=None):
            def observe(kind, rssi=None):
                m._received(Sample(kind, 'simulated input', rssi))
                clock[0] += 5
            for _ in range(3):
                observe('measured', 0)
            self.assertTrue(m.machine.armed)
            for cycle in range(3):
                departure = clock[0]
                for _ in range(10):
                    observe('measured', -15) if cycle != 1 else observe('absent')
                self.assertLessEqual(clock[0] - departure, 60)
                self.assertEqual(m.counts['lock_decisions'], cycle + 1)
                for _ in range(4):
                    observe('measured', 0)
                self.assertFalse(m.machine.locked_once)
                self.assertTrue(m.machine.armed)
            observe('unknown')  # adapter/service fault while previously armed
            for _ in range(20):
                observe('absent')
            self.assertEqual(m.counts['lock_decisions'], 3)
            for _ in range(3):
                observe('measured', 0)
            self.assertTrue(m.machine.armed)
        m.desktop.lock.assert_not_called()

    def test_actual_lock_success_and_failure_callbacks(self):
        m = self.monitor
        m.dry_run = False
        m.desktop.idle.side_effect = lambda callback: callback(2000)
        for success in (False, True):
            self.arm_and_depart()
            m.desktop.lock.side_effect = lambda command, guard, callback: callback(success)
            with patch('dynamic_lock_monitor.milliseconds', return_value=55000), patch('dynamic_lock_monitor.lock_settings_problem', return_value=None):
                m._decide()
            self.assertEqual(m.machine.state, 'LOCKED_AWAY' if success else 'LOCK_FAILED')
        self.assertEqual(m.counts['confirmed_locks'], 1)


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.callbacks = []
        self.jobs = []
        self.executor = Mock()
        def submit(work):
            future = Future()
            self.jobs.append((work, future))
            return future
        self.executor.submit.side_effect = submit
        with patch('dynamic_lock_monitor.ThreadPoolExecutor', return_value=self.executor):
            self.worker = RadioWorker(Mock())
        self.worker.sensor.sample.return_value = Sample('measured', 'okay', 0)

    def complete(self):
        work, future = self.jobs.pop(0)
        with patch('dynamic_lock_monitor.GLib.idle_add', side_effect=lambda fn, *args: self.callbacks.append((fn, args))):
            future.set_result(work())
        fn, args = self.callbacks.pop(0)
        fn(*args)

    def test_only_one_outstanding_job_and_obsolete_results_discarded(self):
        received = Mock()
        self.assertTrue(self.worker.submit(received))
        self.assertFalse(self.worker.submit(received))
        self.worker.invalidate()
        self.complete()
        received.assert_not_called()
        self.assertFalse(self.worker.busy)
        self.worker.submit(received)
        self.complete()
        received.assert_called_once()
        self.assertEqual(self.worker.sensor.close.call_count, 2)

    def test_delayed_result_and_sleeping_worker_are_unknown(self):
        received = Mock()
        self.worker.submit(received)
        work, future = self.jobs.pop(0)
        with patch('dynamic_lock_monitor.GLib.idle_add', side_effect=lambda fn, *args: self.callbacks.append((fn, args))):
            future.set_result((Sample('measured', 'okay', 0), 0, 0))
        fn, args = self.callbacks.pop(0)
        with patch('dynamic_lock_monitor.time.monotonic', return_value=20), patch('dynamic_lock_monitor.sleep_offset', return_value=0):
            fn(*args)
        self.assertEqual(received.call_args.args[0].kind, 'unknown')
        self.worker.submit(received)
        work, _ = self.jobs.pop(0)
        with patch('dynamic_lock_monitor.sleep_offset', side_effect=[0, 10, 10]):
            result, _, _ = work()
        self.assertEqual(result.kind, 'unknown')


if __name__ == '__main__':
    unittest.main()
