import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
FAKE_SYSTEMCTL = '''#!/usr/bin/python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['HOME'])
path = root / 'systemctl-state.json'
state = json.loads(path.read_text()) if path.exists() else {'active': False, 'enabled': False, 'calls': []}
args = sys.argv[1:]
state['calls'].append(args)
result = 0
if 'is-active' in args: result = 0 if state['active'] else 3
elif 'is-enabled' in args: result = 0 if state['enabled'] else 1
elif 'enable' in args:
    state['enabled'] = True
    if '--now' in args: state['active'] = True
elif 'disable' in args:
    state['enabled'] = False
    if '--now' in args: state['active'] = False
elif 'stop' in args: state['active'] = False
path.write_text(json.dumps(state))
sys.exit(result)
'''


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dynamic-lock-test-')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / 'fake-bin'
        self.bin.mkdir()
        self.runtime = self.home / 'run'
        self.runtime.mkdir(mode=0o700)
        (self.bin / 'systemctl').write_text(FAKE_SYSTEMCTL)
        (self.bin / 'systemctl').chmod(0o755)
        (self.bin / 'journalctl').write_text('#!/bin/sh\nprintf "fake journal\\n"\n')
        (self.bin / 'journalctl').chmod(0o755)
        self.env = os.environ | {'HOME': str(self.home), 'PATH': str(self.bin) + ':' + os.environ['PATH'], 'XDG_RUNTIME_DIR': str(self.runtime)}
        self.cli = self.home / '.local/bin/dynamic_lock.sh'
        self.config = self.home / '.config/dynamic_lock/config'
        self.monitor = self.home / '.local/lib/dynamic-lock/dynamic_lock_monitor.py'

    def run_cmd(self, *argv, code=0):
        result = subprocess.run(argv, env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def service_state(self):
        return json.loads((self.home / 'systemctl-state.json').read_text())

    def test_service_preserves_instance_lock_inode_and_desktop_sockets(self):
        unit = (REPO / 'dynamic_lock.service').read_text()
        self.assertIn('RuntimeDirectoryPreserve=yes', unit)
        self.assertIn('RestrictAddressFamilies=AF_UNIX AF_BLUETOOTH', unit)
        self.assertIn('NoNewPrivileges=true', unit)
        self.assertNotIn('PrivateNetwork=true', unit)

    def test_install_upgrade_config_permissions_and_uninstall(self):
        self.run_cmd(str(REPO / 'install.sh'))
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.config.parent.stat().st_mode & 0o777, 0o700)
        self.assertFalse(self.service_state()['enabled'])
        self.run_cmd(str(self.cli), '--enable', code=1)  # blank address never activates
        original = '# preserve comments and obsolete settings\nPHONE_ADDRESS=AA:BB:CC:DD:EE:FF\nRSSI_DROP_DB=12\n'
        self.config.write_text(original)
        self.config.chmod(0o644)
        self.run_cmd(str(REPO / 'install.sh'))
        self.assertEqual(self.config.read_text(), original)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.service_state()['active'])
        self.run_cmd(str(REPO / 'uninstall.sh'))
        self.assertFalse(self.cli.exists())
        self.assertFalse(self.monitor.exists())
        self.assertEqual(self.config.read_text(), original)
        self.run_cmd(str(REPO / 'uninstall.sh'))  # idempotent

    def test_activation_controls_logs_and_status(self):
        self.run_cmd(str(REPO / 'install.sh'))
        self.run_cmd(str(self.cli), '--pause', code=1)
        # Stub ONLY the isolated installed doctor, not the real desktop/radio.
        self.monitor.write_text('import sys\nprint("mock doctor ready")\nsys.exit(0)\n')
        self.run_cmd(str(self.cli), '--enable')
        self.assertTrue(self.service_state()['active'])
        self.assertTrue(self.service_state()['enabled'])
        self.run_cmd(str(self.cli), '--pause')
        self.run_cmd(str(self.cli), '--resume')
        calls = self.service_state()['calls']
        signals = [args for args in calls if 'kill' in args]
        self.assertTrue(all('--kill-whom=main' in args for args in signals))
        self.assertIn('Service: active', self.run_cmd(str(self.cli), '--status'))
        self.assertIn('fake journal', self.run_cmd(str(self.cli), '--logs'))
        self.run_cmd(str(self.cli), '--disable')
        self.assertFalse(self.service_state()['active'])
        self.assertFalse(self.service_state()['enabled'])
        self.monitor.write_text('import sys\nsys.exit(1)\n')
        self.run_cmd(str(self.cli), '--enable', code=1)
        self.assertFalse(self.service_state()['enabled'])

    def test_install_and_uninstall_refuse_running_foreground_monitor(self):
        self.run_cmd(str(REPO / 'install.sh'))
        runtime = self.runtime / 'dynamic-lock'
        runtime.mkdir(mode=0o700)
        with (runtime / 'monitor.lock').open('w') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            self.run_cmd(str(REPO / 'install.sh'), code=1)
            self.run_cmd(str(REPO / 'uninstall.sh'), code=1)
            self.assertTrue(self.monitor.exists())
        self.run_cmd(str(REPO / 'uninstall.sh'))

    def test_status_rejects_stale_state_and_bad_arguments(self):
        self.run_cmd(str(REPO / 'install.sh'))
        runtime = self.runtime / 'dynamic-lock'
        runtime.mkdir(mode=0o700)
        (runtime / 'state').write_text('{"updated_at": 0, "state": "NEAR_ARMED"}')
        self.assertIn('No fresh live', self.run_cmd(str(self.cli), '--status'))
        self.run_cmd(str(self.cli), '--enable', 'extra', code=2)
        self.run_cmd(str(self.cli), '--unknown', code=2)
        self.assertIn('2.2.0', self.run_cmd(str(self.cli), '--version'))

    def test_status_distinguishes_live_diagnostic_from_no_monitor(self):
        self.run_cmd(str(REPO / 'install.sh'))
        self.assertIn('Pairing alone does not start background reconnects', self.run_cmd(str(self.cli), '--status'))
        runtime = self.runtime / 'dynamic-lock'
        runtime.mkdir(mode=0o700, exist_ok=True)
        (runtime / 'state').write_text(json.dumps({'updated_at': time.time(), 'mode': 'dry-run', 'backend': 'bluetooth', 'state': 'NEAR_ARMED'}))
        with (runtime / 'monitor.lock').open('a') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            status = self.run_cmd(str(self.cli), '--status')
        self.assertIn('Service: inactive', status)
        self.assertIn('Diagnostic: active;', status)
        self.assertIn('connection monitoring/retries continue with locking disabled', status)
        status = self.run_cmd(str(self.cli), '--status')
        self.assertIn('No live background reconnects confirmed', status)
