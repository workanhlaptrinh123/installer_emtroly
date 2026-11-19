import json
import unittest
from unittest.mock import patch

import service


class ServiceTests(unittest.TestCase):
    def test_user_service_probe_handles_unavailable_manager(self):
        with patch.object(service.shutil, "which", return_value=None), self.assertRaisesRegex(RuntimeError, "linux-user-service-unavailable"):
            service.check_linux_user_service()
        with patch.object(service.shutil, "which", return_value="/usr/bin/systemctl"), \
                patch.object(service.subprocess, "run") as run:
            run.return_value.returncode = 1
            with self.assertRaisesRegex(RuntimeError, "linux-user-service-unavailable"):
                service.check_linux_user_service()
            run.return_value.returncode = 0
            service.check_linux_user_service()

    def test_gateway_success_requires_health_plugins_and_commands(self):
        calls = []
        def run(command, env, timeout, step):
            calls.append(command)
            if "health" in command:
                return json.dumps({"ok": True, "plugins": {"loaded": ["zalouser", "telegram-zalo-owner-login"]}})
            if "inspect" in command:
                return json.dumps({"plugin": {"status": "loaded", "enabled": True, "toolNames": ["telegram_zalo_login_qr"]}, "commands": ["zaloqr", "zalostatus"]})
            return "{}"
        with patch.object(service, "_run", side_effect=run):
            self.assertTrue(service.install_and_verify("node", "cli", {}, 18789)["ok"])
        self.assertEqual(calls[0][2:5], ["gateway", "install", "--port"])
        self.assertNotIn("--force", calls[0])

    def test_missing_command_is_failure(self):
        def run(command, env, timeout, step):
            if "health" in command:
                return json.dumps({"ok": True, "plugins": {"loaded": ["zalouser", "telegram-zalo-owner-login"]}})
            if "inspect" in command:
                return json.dumps({"plugin": {"status": "loaded"}, "commands": ["zaloqr"]})
            return "{}"
        with patch.object(service, "_run", side_effect=run), self.assertRaises(RuntimeError):
            service.install_and_verify("node", "cli", {}, 18789)

    def test_unhealthy_gateway_fails_without_reporting_success(self):
        with patch.object(service, "_run", return_value="{}"), self.assertRaises(RuntimeError):
            service.install_and_verify("node", "cli", {}, 18789, wait_seconds=0)


if __name__ == "__main__":
    unittest.main()
