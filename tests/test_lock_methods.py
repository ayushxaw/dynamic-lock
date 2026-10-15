import unittest
from unittest.mock import Mock, patch

from dynamic_lock_desktop import Desktop


class DesktopTests(unittest.TestCase):
    def test_mutter_idle_is_milliseconds(self):
        desktop = Desktop(Mock())
        desktop.call = lambda dest, path, interface, method, callback: callback((1250,))
        received = Mock()
        desktop.idle(received)
        received.assert_called_once_with(1250.0)

    def test_confirmation_required_not_just_successful_method_call(self):
        desktop = Desktop(Mock())
        desktop.call = Mock(side_effect=lambda dest, path, interface, method, callback: callback(()))
        desktop.active = Mock(side_effect=lambda callback: callback(False))
        result = Mock()
        with patch('dynamic_lock_desktop.lock_settings_problem', return_value=None), patch('dynamic_lock_desktop.time.monotonic', side_effect=[0, 4]):
            desktop.lock('', lambda: True, result)
        result.assert_called_once_with(False)
        self.assertEqual(desktop.call.call_args.args[3], 'Lock')

    def test_reports_success_only_when_screen_saver_active(self):
        desktop = Desktop(Mock())
        desktop.call = Mock(side_effect=lambda dest, path, interface, method, callback: callback(()))
        desktop.active = Mock(side_effect=lambda callback: callback(True))
        result = Mock()
        with patch('dynamic_lock_desktop.lock_settings_problem', return_value=None):
            desktop.lock('', lambda: True, result)
        result.assert_called_once_with(True)

    def test_cancelled_guard_or_disabled_lock_never_invokes_method(self):
        for guard, problem in ((False, None), (True, 'disabled')):
            desktop = Desktop(Mock())
            desktop.call = Mock()
            with patch('dynamic_lock_desktop.lock_settings_problem', return_value=problem):
                desktop.lock('', lambda: guard, Mock())
            desktop.call.assert_not_called()

    def test_custom_command_has_bounded_timeout_and_no_shell(self):
        desktop = Desktop(Mock())
        child = Mock()
        result = Mock()
        with patch('dynamic_lock_desktop.lock_settings_problem', return_value=None), patch('dynamic_lock_desktop.Gio.Subprocess.new', return_value=child) as spawn, patch('dynamic_lock_desktop.GLib.timeout_add_seconds', return_value=8) as timer:
            desktop.lock('my-lock "two words"', lambda: True, result)
            self.assertEqual(spawn.call_args.args[0], ['my-lock', 'two words'])
            self.assertEqual(timer.call_args.args[0], 3)
            timer.call_args.args[1]()
        child.force_exit.assert_called_once()


if __name__ == '__main__':
    unittest.main()
