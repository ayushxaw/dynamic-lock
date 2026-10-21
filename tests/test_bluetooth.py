import errno
import socket
import struct
import unittest
from dataclasses import replace
from unittest.mock import Mock, patch

from dynamic_lock_bluetooth import (
    ConnectionSensor, Sample, SensorError, Target, command_response,
    select_target, select_paired_phone, validate_sdp,
)


# Synthetic addresses only; never use real hardware identifiers in fixtures.
TARGET = Target('AA:BB:CC:DD:EE:FF', '00:11:22:33:44:55', 2, '/phone', '/org/bluez/hci2')


def complete(opcode, body):
    return b'\x04\x0e' + bytes([len(body) + 3, 1]) + struct.pack('<H', opcode) + body


class PacketTests(unittest.TestCase):
    def test_valid_sdp_including_empty_and_continuation(self):
        for body in (b'\x00\x00\x00\x00\x00', b'\x00\x02\x00\x01' + b'abcd' + b'\x01x'):
            validate_sdp(struct.pack('>BHH', 3, 42, len(body)) + body, 42)

    def test_rejects_malformed_sdp(self):
        packets = [b'', b'\x03\x00', b'\x03\x00\x02\x00\x05' + b'\0' * 5,
                   b'\x03\x00\x01\x00\x04' + b'\0' * 5,
                   b'\x01\x00\x01\x00\x02\x00\x03',
                   b'\x03\x00\x01\x00\x05\x00\x02\x00\x02\x00',
                   b'\x03\x00\x01\x00\x05\x00\x00\x00\x00\x10']
        for packet in packets:
            with self.subTest(packet=packet), self.assertRaises(SensorError):
                validate_sdp(packet, 1)

    def test_hci_status_and_lengths(self):
        self.assertEqual(command_response(complete(0x1405, b'\x00\x01\x00\x00'), 0x1405), b'\x00\x01\x00\x00')
        self.assertIsNone(command_response(complete(0x1001, b'\x00'), 0x1405))
        self.assertIsNone(command_response(b'\x04\x0f\x04\x00\x01\x05\x14', 0x1405))
        for packet in (b'', b'\x04\x0e\x05', complete(0x1405, b'\x02'),
                       b'\x04\x0f\x04\x01\x01\x05\x14'):
            with self.subTest(packet=packet), self.assertRaises(SensorError):
                command_response(packet, 0x1405)

    def test_delayed_wrong_handle_is_not_reused(self):
        hci = Mock()
        hci.send.side_effect = len
        hci.recv.side_effect = [complete(0x1405, b'\x00\x02\x00\x05'), complete(0x1405, b'\x00\x01\x00\x00')]
        result = ConnectionSensor(lambda: TARGET)._command(hci, 0x1405, b'\x01\x00', 4, 1)
        self.assertEqual(result[-1], 0)
        self.assertEqual(hci.recv.call_count, 2)

    def test_controller_read_has_deadline(self):
        hci = Mock()
        hci.send.side_effect = len
        with patch('dynamic_lock_bluetooth.time.monotonic', side_effect=[0, 2]):
            with self.assertRaises(SensorError):
                ConnectionSensor(lambda: TARGET)._command(hci, 0x1405, b'', 4)
        hci.recv.assert_not_called()


class SensorTests(unittest.TestCase):
    def setUp(self):
        self.sensor = ConnectionSensor(lambda: TARGET)
        self.sensor._ping = Mock()
        self.sensor._connect = Mock()
        self.sensor._rssi = Mock(return_value=0)
        self.sensor._healthy = Mock()

    def test_zero_is_valid_and_connection_is_kept(self):
        self.sensor.link = Mock()
        self.sensor.target = TARGET
        self.assertEqual(self.sensor.sample().rssi, 0)
        self.sensor._connect.assert_not_called()

    def test_remote_timeout_requires_local_health(self):
        self.sensor._connect.side_effect = TimeoutError()
        self.assertEqual(self.sensor.sample().kind, 'absent')
        self.sensor._healthy.assert_called_once()
        self.sensor._healthy.side_effect = SensorError('Local controller unavailable.')
        self.assertEqual(self.sensor.sample().kind, 'unknown')

    def test_linux_page_timeout_is_absence_only_with_local_health(self):
        self.sensor._connect.side_effect = OSError(errno.EHOSTDOWN, 'redacted')
        self.assertEqual(self.sensor.sample().kind, 'absent')
        self.sensor._healthy.side_effect = SensorError('Adapter unavailable.')
        self.assertEqual(self.sensor.sample().kind, 'unknown')

    def test_unknown_network_errors_are_not_remote_timeout_evidence(self):
        for code in (errno.ENETDOWN, errno.EHOSTUNREACH, errno.EBUSY, errno.EIO):
            self.sensor._connect.side_effect = OSError(code, 'redacted')
            self.assertEqual(self.sensor.sample().kind, 'unknown')

    def test_refusal_permission_and_service_timeout_are_unknown(self):
        for error in (OSError(errno.ECONNREFUSED, 'private'), PermissionError('private')):
            self.sensor._connect.side_effect = error
            result = self.sensor.sample()
            self.assertEqual(result.kind, 'unknown')
            self.assertNotIn('private', result.reason)
        self.sensor._connect.side_effect = None
        self.sensor._ping.side_effect = TimeoutError()
        self.assertEqual(self.sensor.sample().kind, 'unknown')

    def test_remote_disconnect_reconnects_before_classifying(self):
        self.sensor.target = TARGET
        self.sensor.link = Mock()
        self.sensor._ping.side_effect = ConnectionResetError()
        self.sensor._connect.side_effect = TimeoutError()
        self.assertEqual(self.sensor.sample().kind, 'absent')

    def test_malformed_reply_disarms_instead_of_becoming_absence(self):
        self.sensor._ping.side_effect = SensorError('Malformed response.')
        self.assertEqual(self.sensor.sample().kind, 'unknown')
        self.sensor._healthy.assert_not_called()

    def test_rssi_unavailable_and_handle_changes(self):
        sensor = ConnectionSensor(lambda: TARGET)
        hci = Mock()
        context = Mock()
        context.__enter__ = Mock(return_value=hci)
        context.__exit__ = Mock(return_value=False)
        sensor._hci = Mock(return_value=context)
        sensor._handle = Mock(return_value=1)
        sensor._command = Mock(return_value=b'\x00\x01\x00\x00')
        self.assertEqual(sensor._rssi(), 0)
        sensor._command.return_value = b'\x00\x01\x00\x7f'
        with self.assertRaises(SensorError):
            sensor._rssi()
        sensor._handle.side_effect = [1, 2]
        with self.assertRaises(SensorError):
            sensor._rssi()

    def test_sockets_closed_on_failed_connect_and_repeated_close(self):
        sensor = ConnectionSensor(lambda: TARGET)
        sensor.target = TARGET
        link = Mock()
        link.connect.side_effect = TimeoutError()
        with patch('dynamic_lock_bluetooth.socket.socket', return_value=link):
            with self.assertRaises(TimeoutError):
                sensor._connect()
        link.close.assert_called_once()
        sensor.link = link
        sensor.close()
        sensor.close()
        self.assertEqual(link.close.call_count, 2)

    def test_selects_paired_device_and_exact_adapter(self):
        objects = {'/phone': {'org.bluez.Device1': {'Address': TARGET.address, 'Paired': True, 'Adapter': TARGET.adapter_path}},
                   TARGET.adapter_path: {'org.bluez.Adapter1': {'Address': TARGET.local_address, 'Powered': True}}}
        self.assertEqual(select_target(objects, TARGET.address), TARGET)
        objects[TARGET.adapter_path]['org.bluez.Adapter1']['Powered'] = False
        with self.assertRaises(SensorError):
            select_target(objects, TARGET.address)
        objects[TARGET.adapter_path]['org.bluez.Adapter1']['Powered'] = True
        objects['/phone']['org.bluez.Device1']['Paired'] = False
        with self.assertRaises(SensorError):
            select_target(objects, TARGET.address)
        objects['/phone']['org.bluez.Device1']['Paired'] = True
        objects['/phone']['org.bluez.Device1']['Blocked'] = True
        with self.assertRaisesRegex(SensorError, 'blocked locally'):
            select_target(objects, TARGET.address)

    def test_adapter_replacement_requires_new_arming_even_without_dbus_signal(self):
        self.sensor.target = TARGET
        self.sensor.target_provider = lambda: replace(TARGET, index=3, adapter_path='/org/bluez/hci3')
        self.assertEqual(self.sensor.sample().kind, 'unknown')
        self.sensor._connect.assert_not_called()
        self.assertEqual(self.sensor.sample().kind, 'measured')

    def test_hci_connection_info_checks_peer_and_handle(self):
        sensor = ConnectionSensor(lambda: TARGET)
        sensor.target = TARGET
        peer = bytes.fromhex(TARGET.address.replace(':', ''))[::-1]
        def reply(_fd, _request, buffer, _mutate):
            buffer[8:] = struct.pack('=H6sBBHI', 7, peer, 1, 1, 1, 6)
        with patch('dynamic_lock_bluetooth.fcntl.ioctl', side_effect=reply):
            self.assertEqual(sensor._handle(Mock()), 7)
        def wrong_peer(_fd, _request, buffer, _mutate):
            buffer[8:] = struct.pack('=H6sBBHI', 7, b'\0' * 6, 1, 1, 1, 6)
        with patch('dynamic_lock_bluetooth.fcntl.ioctl', side_effect=wrong_peer), self.assertRaises(SensorError):
            sensor._handle(Mock())


if __name__ == '__main__':
    unittest.main()


class BluetoothSetupAndSecurityTests(unittest.TestCase):
    def objects(self):
        return {'/phone': {'org.bluez.Device1': {'Address': TARGET.address, 'Paired': True, 'Icon': 'phone', 'Adapter': TARGET.adapter_path}},
                TARGET.adapter_path: {'org.bluez.Adapter1': {'Address': TARGET.local_address, 'Powered': True}},
                '/headset': {'org.bluez.Device1': {'Address': '11:22:33:44:55:66', 'Paired': True, 'Icon': 'audio-headset', 'Adapter': TARGET.adapter_path}}}

    def test_setup_selects_only_paired_phone_or_explicit_target(self):
        objects = self.objects()
        self.assertEqual(select_paired_phone(objects), TARGET)
        self.assertEqual(select_paired_phone(objects, TARGET.address), TARGET)
        objects['/second'] = {'org.bluez.Device1': {'Address': '22:33:44:55:66:77', 'Paired': True, 'Class': 0x0200, 'Adapter': TARGET.adapter_path}}
        with self.assertRaises(SensorError):
            select_paired_phone(objects)
        self.assertEqual(select_paired_phone(objects, TARGET.address), TARGET)
        objects['/phone']['org.bluez.Device1']['Paired'] = False
        del objects['/second']
        with self.assertRaises(SensorError):
            select_paired_phone(objects)

    def test_connect_requires_encryption_and_closes_on_security_failure(self):
        sensor = ConnectionSensor(lambda: TARGET)
        sensor.target = TARGET
        link = Mock()
        with patch('dynamic_lock_bluetooth.socket.socket', return_value=link):
            sensor._connect()
        link.setsockopt.assert_called_once_with(274, 4, b'\x02\x00')
        sensor.close()
        link.setsockopt.side_effect = PermissionError()
        with patch('dynamic_lock_bluetooth.socket.socket', return_value=link), self.assertRaises(PermissionError):
            sensor._connect()
        self.assertEqual(link.close.call_count, 2)

    def test_controller_link_must_be_authenticated_and_encrypted(self):
        sensor = ConnectionSensor(lambda: TARGET)
        sensor.target = TARGET
        peer = bytes.fromhex(TARGET.address.replace(':', ''))[::-1]
        for mode in (0, 2, 4, 6):
            def reply(_fd, _request, buffer, _mutate):
                buffer[8:] = struct.pack('=H6sBBHI', 7, peer, 1, 1, 1, mode)
            with patch('dynamic_lock_bluetooth.fcntl.ioctl', side_effect=reply):
                if mode == 6:
                    self.assertEqual(sensor._handle(Mock()), 7)
                else:
                    with self.assertRaises(SensorError):
                        sensor._handle(Mock())

    def test_unsupported_sockets_and_security_are_actionable(self):
        from types import SimpleNamespace
        sensor = ConnectionSensor(lambda: TARGET)
        with patch('dynamic_lock_bluetooth.socket', SimpleNamespace()):
            self.assertIn('unsupported', sensor.sample().reason)
        sensor._connect = Mock(side_effect=OSError(errno.EPROTONOSUPPORT, 'private'))
        result = sensor.sample()
        self.assertEqual(result.kind, 'unknown')
        self.assertIn('unsupported', result.reason)
        self.assertNotIn('private', result.reason)
