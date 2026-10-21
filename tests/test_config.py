from contextlib import redirect_stderr
import io
from pathlib import Path
import tempfile
import unittest
from dynamic_lock_config import ConfigError, read_config


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'config'

    def write(self, text):
        self.path.write_text('BACKEND=bluetooth\n' + text)
        self.path.chmod(0o600)

    def test_defaults_and_legacy_units_ignored(self):
        self.write('PHONE_ADDRESS=AA:BB:CC:DD:EE:FF\nRSSI_DROP_DB=25\n')
        with redirect_stderr(io.StringIO()) as warning:
            config = read_config(self.path)
        self.assertEqual(config['RSSI_NEAR_THRESHOLD'], -5)
        self.assertEqual(config['RSSI_AWAY_THRESHOLD'], -10)
        self.assertIn('obsolete', warning.getvalue())
        self.assertNotIn('AA:BB', warning.getvalue())

    def test_unsafe_shell_text_is_never_executed_or_printed(self):
        self.write('PHONE_ADDRESS=$(touch /tmp/dynamic-lock-never-execute)\n')
        with self.assertRaises(ConfigError) as error:
            read_config(self.path)
        self.assertNotIn('touch', str(error.exception))

    def test_invalid_settings_fail_instead_of_silently_activating(self):
        for line in ('RSSI_NEAR_THRESHOLD=-20\nRSSI_AWAY_THRESHOLD=-10', 'POLL_SECONDS=10\nRSSI_STALE_SECONDS=15',
                     'POLL_SECONDS=no', 'IDLE_AFTER_SECONDS=-1', 'POLL_SECONDS=5\nPOLL_SECONDS=2', 'not an assignment', 'LOCK_CMD="bad'):
            self.write('PHONE_ADDRESS=AA:BB:CC:DD:EE:FF\n' + line + '\n')
            with self.subTest(line=line), self.assertRaises(ConfigError):
                read_config(self.path)

    def test_blank_allowed_for_staged_install_only(self):
        self.write('PHONE_ADDRESS=\n')
        read_config(self.path, require_phone=False)
        with self.assertRaises(ConfigError):
            read_config(self.path)

    def test_public_permissions_rejected(self):
        self.write('PHONE_ADDRESS=AA:BB:CC:DD:EE:FF\n')
        self.path.chmod(0o644)
        with self.assertRaises(ConfigError):
            read_config(self.path)


class GSConnectConfigTests(unittest.TestCase):
    def test_default_backend_does_not_require_bluetooth_and_setup_pins_privately(self):
        from dynamic_lock_config import save_gsconnect_selection
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config'
            path.write_text('BACKEND=gsconnect\n# keep this comment\nPHONE_ADDRESS=old-unused-value\nAWAY_CONFIRM_SECONDS=45\n')
            path.chmod(0o600)
            config = read_config(path)
            self.assertEqual(config['BACKEND'], 'gsconnect')
            save_gsconnect_selection(path, 'test-phone-id')
            config = read_config(path)
            self.assertEqual(config['GSCONNECT_DEVICE_ID'], 'test-phone-id')
            self.assertEqual(config['AWAY_CONFIRM_SECONDS'], 45)
            self.assertIn('# keep this comment', path.read_text())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_setup_rejects_multiline_identity_without_changing_config(self):
        from dynamic_lock_config import save_gsconnect_selection
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config'
            path.write_text('BACKEND=gsconnect\n')
            path.chmod(0o600)
            original = path.read_bytes()
            with self.assertRaises(ConfigError):
                save_gsconnect_selection(path, 'test\nLOCK_CMD=bad')
            self.assertEqual(path.read_bytes(), original)


class BluetoothSetupConfigTests(unittest.TestCase):
    def test_bluetooth_setup_preserves_other_private_settings(self):
        from dynamic_lock_config import save_bluetooth_selection
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config'
            path.write_text('BACKEND=gsconnect\nGSCONNECT_DEVICE_ID=old-test-phone\nAWAY_CONFIRM_SECONDS=45\n')
            path.chmod(0o600)
            save_bluetooth_selection(path, 'aa:bb:cc:dd:ee:ff')
            config = read_config(path)
            self.assertEqual(config['BACKEND'], 'bluetooth')
            self.assertEqual(config['PHONE_ADDRESS'], 'AA:BB:CC:DD:EE:FF')
            self.assertEqual(config['GSCONNECT_DEVICE_ID'], 'old-test-phone')
            self.assertEqual(config['AWAY_CONFIRM_SECONDS'], 45)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            original = path.read_bytes()
            with self.assertRaises(ConfigError):
                save_bluetooth_selection(path, 'not-an-address')
            self.assertEqual(path.read_bytes(), original)
