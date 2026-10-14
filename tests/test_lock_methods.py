import unittest
from unittest.mock import call, patch

from dynamic_lock_monitor import lock_session, request_and_verify_lock


class LockMethodTests(unittest.TestCase):
    def test_only_accepts_success_after_screen_saver_reports_active(self):
        with (
            patch("dynamic_lock_monitor.run_command", return_value=True),
            patch("dynamic_lock_monitor.screen_is_locked", side_effect=(False, True)),
            patch("dynamic_lock_monitor.time.sleep"),
        ):
            self.assertTrue(request_and_verify_lock(("example-lock",)))

    def test_gnome_lock_method_is_tried_before_loginctl(self):
        with patch("dynamic_lock_monitor.request_and_verify_lock", side_effect=(False, True)) as request:
            self.assertTrue(lock_session(""))

        self.assertEqual(
            request.call_args_list,
            [
                call((
                    "gdbus", "call", "--session", "--dest", "org.gnome.ScreenSaver",
                    "--object-path", "/org/gnome/ScreenSaver", "--method",
                    "org.gnome.ScreenSaver.Lock",
                )),
                call(("loginctl", "lock-session")),
            ],
        )

    def test_custom_lock_command_is_checked_first(self):
        with patch("dynamic_lock_monitor.request_and_verify_lock", return_value=True) as request:
            self.assertTrue(lock_session("my-lock --option"))
        request.assert_called_once_with(["my-lock", "--option"])


if __name__ == "__main__":
    unittest.main()
