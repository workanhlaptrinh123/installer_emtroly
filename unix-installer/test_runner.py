import socket
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import runner
from test_settings import sample


class RunnerTests(unittest.TestCase):
    def test_choose_port_rejects_occupied_explicit_port(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
            with self.assertRaises(RuntimeError):
                runner.choose_port(port)

    def test_validation_happens_before_network_or_changes(self):
        data = sample()
        data["accept_full_access"] = False
        with patch.object(runner.telegram, "verify_bot") as remote, self.assertRaises(ValueError):
            runner.install(data, ".")
        remote.assert_not_called()

    def test_root_user_is_rejected(self):
        with patch.object(runner.os, "geteuid", return_value=0), self.assertRaises(RuntimeError):
            runner.install(sample(), ".")

    def test_failure_after_gateway_attempt_reports_possible_partial_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            root = home / ".openclaw-member-member01"
            def create_instance(*args):
                root.mkdir()
                return root
            with patch.object(runner.os, "geteuid", return_value=1000), \
                    patch.object(runner.platform, "system", return_value="Linux"), \
                    patch.object(runner.service, "check_linux_user_service"), \
                    patch.object(runner.Path, "home", return_value=home), \
                    patch.object(runner.telegram, "verify_bot"), \
                    patch.object(runner.provider, "verify", return_value="gpt-6.1-sol"), \
                    patch.object(runner, "choose_port", return_value=19789), \
                    patch.object(runner.dependencies, "install_node", return_value=(home / "node", home / "npm")), \
                    patch.object(runner.python_runtime, "install", return_value=home / "python3"), \
                    patch.object(runner.ffmpeg, "install", return_value=home / "ffmpeg"), \
                    patch.object(runner.instance, "initialize", side_effect=create_instance), \
                    patch.object(runner.runtime, "install", return_value=(home / "cli", {})), \
                    patch.object(runner.payload, "install"), \
                    patch.object(runner.zalo_setup, "configure"), \
                    patch.object(runner.service, "install_and_verify", side_effect=RuntimeError("health check failed")):
                with self.assertRaises(RuntimeError) as error:
                    runner.install(sample(), ".")
            self.assertIn("Gateway có thể đã chạy", str(error.exception))
            self.assertIn(str(root), str(error.exception))

    def test_missing_systemd_stops_before_network_and_instance_creation(self):
        with patch.object(runner.os, "geteuid", return_value=1000), \
                patch.object(runner.platform, "system", return_value="Linux"), \
                patch.object(runner.service, "check_linux_user_service", side_effect=RuntimeError("linux-user-service-unavailable")), \
                patch.object(runner.telegram, "verify_bot") as remote, \
                patch.object(runner.instance, "initialize") as create:
            with self.assertRaisesRegex(RuntimeError, "linux-user-service-unavailable"):
                runner.install(sample(), ".")
            remote.assert_not_called()
            create.assert_not_called()


if __name__ == "__main__":
    unittest.main()
