import copy
import unittest
from unittest.mock import Mock
from gi.repository import GLib

from dynamic_lock_bluetooth import SensorError
from dynamic_lock_gsconnect import GSConnectSensor, DEVICE, select_phone
from dynamic_lock_state import PresenceMachine


PHONE = {'Id': 'test-phone', 'Name': 'Test phone', 'Type': 'phone', 'Paired': True, 'Connected': True}
OBJECTS = {'/test/phone': {DEVICE: PHONE}, '/test/tablet': {DEVICE: PHONE | {'Id': 'test-tablet', 'Type': 'tablet'}}}


class GSConnectSensorTests(unittest.TestCase):
    def setUp(self):
        self.objects = copy.deepcopy(OBJECTS)
        self.sensor = GSConnectSensor(Mock(), Mock())
        self.sensor._owner = Mock(return_value=':1.50')
        self.sensor._network = Mock(return_value=('/network/active',))
        self.sensor._call = Mock(side_effect=lambda *args: (self.objects,))

    def test_selects_phone_not_paired_tablet(self):
        self.assertEqual(select_phone(self.objects)[1]['Id'], 'test-phone')
        self.assertEqual(self.sensor.sample().kind, 'connected')
        self.objects['/test/phone'][DEVICE]['Connected'] = False
        sample = self.sensor.sample()
        self.assertEqual(sample.kind, 'disconnected')
        self.assertIsNone(sample.rssi)

    def test_no_phone_unpaired_or_ambiguous_is_unknown(self):
        self.objects['/test/phone'][DEVICE]['Paired'] = False
        self.assertEqual(self.sensor.sample().kind, 'unknown')
        self.objects['/test/phone'][DEVICE]['Paired'] = True
        self.objects['/test/second'] = {DEVICE: PHONE | {'Id': 'second-phone'}}
        self.assertEqual(self.sensor.sample().kind, 'unknown')
        self.sensor.device_id = 'test-phone'
        self.assertEqual(self.sensor.sample().kind, 'connected')

    def test_id_prevents_switch_to_another_single_phone(self):
        self.sensor.sample()
        self.objects['/test/phone'][DEVICE]['Id'] = 'other-phone'
        self.assertEqual(self.sensor.sample().kind, 'unknown')
        self.objects['/test/phone'][DEVICE]['Id'] = 'test-phone'
        self.objects['/test/phone'][DEVICE]['Name'] = 'Changed phone name'
        self.assertEqual(self.sensor.sample().kind, 'connected')

    def test_disconnected_property_is_strict_boolean(self):
        for value in (None, 'false', 0):
            self.objects['/test/phone'][DEVICE]['Connected'] = value
            self.assertEqual(self.sensor.sample().kind, 'unknown')

    def test_local_network_loss_does_not_report_departure(self):
        self.sensor._network.side_effect = SensorError('Laptop network unavailable.')
        self.objects['/test/phone'][DEVICE]['Connected'] = False
        self.assertEqual(self.sensor.sample().kind, 'unknown')

    def test_service_failure_redacts_raw_errors(self):
        self.sensor._owner.side_effect = GLib.Error('private device identity')
        sample = self.sensor.sample()
        self.assertEqual(sample.kind, 'unknown')
        self.assertNotIn('private device', sample.reason)

    def test_service_restart_and_network_replacement_require_rearming(self):
        self.sensor.sample()
        self.sensor._owner.return_value = ':1.51'
        self.assertEqual(self.sensor.sample().kind, 'unknown')
        self.assertEqual(self.sensor.sample().kind, 'connected')
        self.sensor._network.return_value = ('/network/new',)
        self.assertEqual(self.sensor.sample().kind, 'unknown')

    def test_network_change_during_check_is_unknown(self):
        self.sensor._network.side_effect = [('/old',), ('/new',)]
        self.assertEqual(self.sensor.sample().kind, 'unknown')

    def test_network_requires_local_connection_but_no_internet(self):
        sensor = GSConnectSensor(Mock(), Mock())
        props = {'NetworkingEnabled': True, 'State': 50, 'ActiveConnections': ['/network/active'], 'Connectivity': 1}
        sensor._call = Mock(side_effect=lambda *args: (props,))
        self.assertEqual(sensor._network(), ('/network/active',))
        for change in ({'NetworkingEnabled': False}, {'State': 20}, {'State': None}, {'ActiveConnections': []}):
            sensor._call.return_value = (props | change,)
            sensor._call.side_effect = None
            with self.assertRaises(SensorError):
                sensor._network()


class GSConnectDecisionTests(unittest.TestCase):
    def setUp(self):
        self.machine = PresenceMachine(connection_mode=True)

    def arm(self, start=0):
        for now in (start, start + 5000, start + 10000):
            self.machine.accept('connected', now)
        self.assertTrue(self.machine.armed)

    def test_continuous_disconnect_idle_gate_and_one_lock(self):
        self.arm()
        for now in range(15000, 45001, 5000):
            self.machine.accept('disconnected', now)
        self.assertFalse(self.machine.tick(45000, False)['should_lock'])
        self.assertTrue(self.machine.tick(45000, True)['should_lock'])
        self.machine.lock_succeeded()
        self.machine.accept('disconnected', 50000)
        self.assertFalse(self.machine.tick(50000, True)['should_lock'])

    def test_brief_drop_and_reconnect_cancel_lock_immediately(self):
        self.arm()
        for now in range(15000, 40001, 5000):
            self.machine.accept('disconnected', now)
        self.machine.accept('connected', 45000)
        self.assertIsNone(self.machine.away_since)
        self.assertFalse(self.machine.tick(45000, True)['should_lock'])

    def test_away_at_start_or_after_local_fault_never_locks(self):
        for now in range(0, 60001, 5000):
            self.machine.accept('disconnected', now)
        self.assertFalse(self.machine.armed)
        self.machine.reset()
        self.arm()
        self.machine.accept('unknown', 15000, reason='Laptop Wi-Fi off')
        for now in range(20000, 80001, 5000):
            self.machine.accept('disconnected', now)
        self.assertFalse(self.machine.tick(80000, True)['should_lock'])

    def test_three_cycles_with_return_and_interrupted_return(self):
        self.arm()
        now = 15000
        for _ in range(3):
            for _ in range(7):
                self.machine.accept('disconnected', now)
                now += 5000
            self.assertTrue(self.machine.tick(now - 5000, True)['should_lock'])
            self.machine.lock_succeeded()
            self.machine.accept('connected', now)
            self.machine.accept('disconnected', now + 5000)
            self.assertTrue(self.machine.locked_once)
            self.machine.accept('connected', now + 10000)
            self.machine.accept('connected', now + 15000)
            self.assertFalse(self.machine.locked_once)
            now += 20000

    def test_stale_or_rssi_observations_cannot_establish_network_absence(self):
        self.arm()
        self.assertFalse(self.machine.tick(30000, True)['should_lock'])
        self.assertFalse(self.machine.armed)
        self.machine.accept('measured', 35000, -50)
        self.assertEqual(self.machine.state, 'UNKNOWN')


class GSConnectMonitorTests(unittest.TestCase):
    def make_monitor(self):
        from unittest.mock import patch
        from dynamic_lock_config import SETTINGS
        from dynamic_lock_monitor import Monitor
        config = {key: value[0] for key, value in SETTINGS.items()} | {
            'BACKEND': 'gsconnect', 'GSCONNECT_DEVICE_ID': 'test-phone',
            'GSCONNECT_DEVICE_NAME': '', 'LOCK_CMD': ''}
        with patch('dynamic_lock_monitor.Gio.bus_get_sync'), patch('dynamic_lock_monitor.RadioWorker'):
            monitor = Monitor(config, dry_run=True)
        monitor.worker.generation = 0
        monitor.log = Mock()
        monitor.desktop = Mock()
        return monitor

    def test_full_monitor_cycle_never_calls_lock_in_dry_run(self):
        from unittest.mock import patch
        from dynamic_lock_bluetooth import Sample
        monitor = self.make_monitor()
        monitor.desktop.idle.side_effect = lambda callback: callback(2000)
        clock = [0]
        with patch('dynamic_lock_monitor.time.monotonic', side_effect=lambda: clock[0]), patch('dynamic_lock_monitor.lock_settings_problem', return_value=None):
            for cycle in range(3):
                for kind, count in (('connected', 3), ('disconnected', 8)):
                    for _ in range(count):
                        monitor._received(Sample(kind, 'simulated GSConnect'))
                        clock[0] += 5
                self.assertEqual(monitor.counts['lock_decisions'], cycle + 1)
            monitor.desktop.lock.assert_not_called()

    def test_reconnect_event_invalidates_pending_idle_result(self):
        from unittest.mock import patch
        from dynamic_lock_gsconnect import DEVICE
        from dynamic_lock_monitor import GSCONNECT
        monitor = self.make_monitor()
        for now in (0, 5000, 10000):
            monitor.machine.accept('connected', now)
        for now in range(15000, 45001, 5000):
            monitor.machine.accept('disconnected', now)
        monitor.health = 'disconnected'
        monitor.target.device_path = '/test/phone'
        monitor.dry_run = False
        def invalidate():
            monitor.worker.generation += 1
        monitor.worker.invalidate.side_effect = invalidate
        params = Mock()
        params.unpack.return_value = (DEVICE, {'Connected': True}, [])
        with patch('dynamic_lock_monitor.milliseconds', return_value=45000), patch('dynamic_lock_monitor.lock_settings_problem', return_value=None):
            monitor._decide()
            callback = monitor.desktop.idle.call_args.args[0]
            monitor._gsconnect_changed(None, None, '/test/phone', None, 'PropertiesChanged', params)
            callback(2000)
        monitor.desktop.lock.assert_not_called()
        self.assertEqual(monitor.health, 'unknown')
        self.assertTrue(monitor.machine.armed)

    def test_local_network_event_disarms_even_if_phone_disconnect_is_cached(self):
        from dynamic_lock_gsconnect import NM, NM_PATH
        monitor = self.make_monitor()
        for now in (0, 5000, 10000):
            monitor.machine.accept('connected', now)
        params = Mock()
        params.unpack.return_value = (NM, {'State': 20}, [])
        monitor._gsconnect_changed(None, None, NM_PATH, None, 'PropertiesChanged', params)
        self.assertFalse(monitor.machine.armed)
        self.assertEqual(monitor.health, 'unknown')

    def test_late_lock_confirmation_cannot_overwrite_local_fault(self):
        from unittest.mock import patch
        monitor = self.make_monitor()
        for now in (0, 5000, 10000):
            monitor.machine.accept('connected', now)
        for now in range(15000, 45001, 5000):
            monitor.machine.accept('disconnected', now)
        monitor.health = 'disconnected'
        monitor.dry_run = False
        monitor.desktop.idle.side_effect = lambda callback: callback(2000)
        with patch('dynamic_lock_monitor.milliseconds', return_value=45000), patch('dynamic_lock_monitor.lock_settings_problem', return_value=None):
            monitor._decide()
            callback = monitor.desktop.lock.call_args.args[2]
            monitor.invalidate('Network unavailable')
            callback(True)
        self.assertEqual(monitor.machine.state, 'UNKNOWN')
        self.assertEqual(monitor.counts['confirmed_locks'], 0)
