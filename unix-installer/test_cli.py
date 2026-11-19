import io
from pathlib import Path
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

import cli
from test_settings import sample


class TerminalInstallerTests(unittest.TestCase):
    def test_collect_uses_hidden_input_and_explicit_consent(self):
        inputs = iter(["member01", "Assistant", "12345,67890", "", "-12345", "",
                       "gpt-6.1-sol", "0", "", "", "", "DONGY"])
        with patch("builtins.input", side_effect=lambda _: next(inputs)), \
                patch.object(cli, "secret", side_effect=["123456:" + "x" * 30, "test-only-key"]) as hidden, \
                redirect_stdout(io.StringIO()):
            values = cli.collect()
        self.assertEqual(hidden.call_count, 2)
        self.assertEqual(values["qr_owner_id"], "12345")
        self.assertTrue(values["accept_full_access"])
        cli.settings.validate(values)

    def test_user_must_explicitly_accept_full_exec(self):
        values = sample()
        values["accept_full_access"] = False
        output = io.StringIO()
        with patch.object(cli, "preflight"), patch.object(cli, "bootstrap_python"), \
                patch.object(cli, "collect", return_value=values), \
                patch.object(cli.runner, "install") as install, redirect_stderr(output):
            self.assertEqual(cli.main([]), 1)
        install.assert_not_called()
        self.assertIn("Chưa đồng ý", output.getvalue())

    def test_check_does_not_download_or_install(self):
        with patch.object(cli, "preflight") as preflight, patch.object(cli, "bootstrap_python") as bootstrap, \
                patch.object(cli.runner, "install") as install, redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(["--check"]), 0)
        preflight.assert_called_once_with(interactive=False)
        bootstrap.assert_not_called()
        install.assert_not_called()

    def test_root_or_missing_user_service_fails_before_prompts(self):
        with patch.object(cli.platform, "system", return_value="Linux"), \
                patch.object(cli.os, "geteuid", return_value=0), \
                patch.object(cli, "collect") as collect, redirect_stderr(io.StringIO()):
            self.assertEqual(cli.main([]), 1)
        collect.assert_not_called()

        with patch.object(cli.platform, "system", return_value="Linux"), \
                patch.object(cli.os, "geteuid", return_value=1000), \
                patch.object(cli.service, "check_linux_user_service", side_effect=RuntimeError()), \
                redirect_stderr(io.StringIO()):
            self.assertEqual(cli.main(["--check"]), 1)

    def test_error_redacts_both_credentials(self):
        values = sample()
        error = RuntimeError("bad " + values["telegram_token"] + " " + values["ai_api_key"])
        with patch.object(cli, "preflight"), patch.object(cli, "bootstrap_python"), \
                patch.object(cli, "collect", return_value=values), \
                patch.object(cli.runner, "install", side_effect=error), \
                redirect_stderr(io.StringIO()) as output:
            self.assertEqual(cli.main([]), 1)
        self.assertNotIn(values["telegram_token"], output.getvalue())
        self.assertNotIn(values["ai_api_key"], output.getvalue())

    def test_success_calls_shared_installer_and_reports_cli(self):
        result = {"root": "/home/test/.openclaw-member-member01", "gateway_port": 19789,
                  "cli": {"command": "openclaw"}}
        with patch.object(cli, "preflight"), patch.object(cli, "bootstrap_python"), \
                patch.object(cli, "collect", return_value=sample()), \
                patch.object(cli.runner, "install", return_value=result) as install, \
                redirect_stdout(io.StringIO()) as output:
            self.assertEqual(cli.main([]), 0)
        self.assertEqual(install.call_args.args[1], Path(cli.__file__).resolve().parent.parent)
        self.assertIn("openclaw status", output.getvalue())
        self.assertIn("/zaloqr", output.getvalue())

    def test_old_python_is_reexecuted_using_private_runtime(self):
        target = Path("/home/test/dependencies/python/bin/python3")
        with patch.object(cli.python_runtime, "_verify", return_value=False), \
                patch.object(cli.python_runtime, "install", return_value=target), \
                patch.object(cli.os, "execve", side_effect=RuntimeError("exec called")) as execute, \
                redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "exec called"):
                cli.bootstrap_python()
        self.assertEqual(execute.call_args.args[0], str(target))
        self.assertTrue(execute.call_args.args[2]["PATH"].startswith(str(target.parent) + ":"))


if __name__ == "__main__":
    unittest.main()
