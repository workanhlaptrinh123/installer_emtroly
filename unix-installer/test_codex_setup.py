"""Unit and integration tests for macOS & Linux Codex CLI priority setup and Auto-Heal."""

import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

import codex_setup
import runner
import service
import telegram
from test_settings import sample


class UnixCodexSetupTests(unittest.TestCase):
    def test_secret_scrubbing_removes_tokens_keys_and_gateway_secrets(self):
        tok = "123456789:ABCDEF_SECRET_TELEGRAM_TOKEN_XYZ123"
        key = "sk-proj-super-secret-router-key-99887766"
        custom = "custom-member-secret-key-abcdef"
        raw = f'Error with {tok}, key={key}, custom={custom}, and "token": "abcdef0123456789abcdef0123456789"'
        cleaned = codex_setup.scrub_secrets(raw, (tok, custom))
        self.assertNotIn(tok, cleaned)
        self.assertNotIn(key, cleaned)
        self.assertNotIn(custom, cleaned)
        self.assertNotIn("abcdef0123456789abcdef0123456789", cleaned)
        self.assertIn("[REDACTED_", cleaned)

    def test_write_codex_home_creates_isolated_config_and_auth(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            c_home = codex_setup.write_codex_home(home, "sk-test-123456", "gpt-6.2-sol", "https://codex.anhlaptrinh.vn/v1")
            self.assertTrue((c_home / "config.toml").is_file())
            self.assertTrue((c_home / "auth.json").is_file())
            cfg = (c_home / "config.toml").read_text(encoding="utf-8")
            self.assertIn('model = "gpt-6.2-sol"', cfg)
            self.assertIn('base_url = "https://codex.anhlaptrinh.vn/v1"', cfg)
            auth = json.loads((c_home / "auth.json").read_text(encoding="utf-8"))
            self.assertEqual(auth["OPENAI_API_KEY"], "sk-test-123456")

    def test_auto_heal_step_repairs_transient_failure_and_logs_audit(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td).resolve()
            source = Path(__file__).resolve().parent.parent
            fake_bin_dir = home / "fake-bin"
            fake_bin_dir.mkdir()

            if os.name == "nt":
                fake_py = fake_bin_dir / "fake_codex.py"
                fake_py.write_text(
                    "import os, pathlib, sys\n"
                    "args = sys.argv[1:]\n"
                    "_ = sys.stdin.read()\n"
                    "assert 'OPENAI_API_KEY' not in os.environ\n"
                    "assert pathlib.Path(os.environ['CODEX_HOME'], 'auth.json').is_file()\n"
                    "pathlib.Path(os.environ['TEST_HEAL_MARKER']).write_text('fixed', encoding='utf-8')\n"
                    "if '-o' in args:\n"
                    "    pathlib.Path(args[args.index('-o') + 1]).write_text('Đã tự động sửa lỗi cấu hình Gateway.', encoding='utf-8')\n",
                    encoding="utf-8",
                )
                fake_codex = fake_bin_dir / "codex.cmd"
                fake_codex.write_text(f'@echo off\r\n"{sys.executable}" "{fake_py}" %*\r\n', encoding="ascii")
            else:
                fake_codex = fake_bin_dir / "codex"
                fake_codex.write_text(
                    f"#!{sys.executable}\n"
                    "import os, pathlib, sys\n"
                    "args = sys.argv[1:]\n"
                    "_ = sys.stdin.read()\n"
                    "assert 'OPENAI_API_KEY' not in os.environ\n"
                    "assert pathlib.Path(os.environ['CODEX_HOME'], 'auth.json').is_file()\n"
                    "pathlib.Path(os.environ['TEST_HEAL_MARKER']).write_text('fixed', encoding='utf-8')\n"
                    "if '-o' in args:\n"
                    "    pathlib.Path(args[args.index('-o') + 1]).write_text('Đã tự động sửa lỗi cấu hình Gateway.', encoding='utf-8')\n",
                    encoding="utf-8",
                )
                fake_codex.chmod(fake_codex.stat().st_mode | stat.S_IEXEC)

            marker = home / "repaired.marker"
            vals = sample()

            def flaky_step():
                if not marker.is_file():
                    raise RuntimeError("Gateway health check failed with " + vals["ai_api_key"])
                return "REPAIRED_OK"

            with patch.dict(os.environ, {"EMTROLY_AUTOHEAL_BIN": str(fake_codex), "TEST_HEAL_MARKER": str(marker)}):
                result = codex_setup.run_step_with_auto_heal(
                    "gateway-verify",
                    flaky_step,
                    values=vals,
                    home=home,
                    root_getter=lambda: None,
                    source=source,
                )
            self.assertEqual(result, "REPAIRED_OK")
            audit_file = codex_setup.data_root(home) / "logs/codex-autoheal.log"
            self.assertTrue(audit_file.is_file())
            audit_text = audit_file.read_text(encoding="utf-8")
            self.assertIn("stage=gateway-verify attempt=1 exit=0", audit_text)
            self.assertNotIn(vals["ai_api_key"], audit_text)

    def test_service_install_and_verify_supports_disable_zalo(self):
        def run(command, env, timeout, step):
            if "health" in command:
                return json.dumps({"ok": True, "plugins": {"loaded": []}})
            if "inspect" in command:
                raise AssertionError("inspect must not be called when enable_zalo=False")
            return "{}"

        with patch.object(service, "_run", side_effect=run):
            health = service.install_and_verify("node", "cli", {}, 19789, enable_zalo=False)
        self.assertTrue(health["ok"])

    def test_telegram_fetch_ids_from_updates_extracts_owner_and_group(self):
        fake_me = {"is_bot": True, "username": "emtroly_test_bot"}
        fake_updates = [
            {"message": {"from": {"id": 6980864856, "is_bot": False}, "chat": {"id": 6980864856, "type": "private"}}},
            {"message": {"from": {"id": 6980864856, "is_bot": False}, "chat": {"id": -1001234567890, "type": "supergroup"}}},
        ]

        def fake_api(token, method, body=None):
            if method == "getMe":
                return fake_me
            if method == "getUpdates":
                return fake_updates
            raise AssertionError(method)

        with patch.object(telegram, "api", side_effect=fake_api):
            info = telegram.fetch_ids_from_updates("123456:" + "A" * 30)
        self.assertEqual(info["bot_username"], "@emtroly_test_bot")
        self.assertEqual(info["owner_id"], "6980864856")
        self.assertEqual(info["group_id"], "-1001234567890")

    def test_runner_runs_codex_cli_and_antigravity_before_openclaw(self):
        order = []
        with tempfile.TemporaryDirectory() as td:
            home = Path(td).resolve()
            root = home / ".openclaw-member-member01"

            def fake_codex_first(*args, **kwargs):
                order.append("codex-cli")
                return {"installed": True}

            def fake_editor(*args, **kwargs):
                order.append("antigravity-editor")
                return {"configured": True}

            def fake_init(*args, **kwargs):
                order.append("openclaw-init")
                root.mkdir()
                (root / "openclaw.json").write_text("{}", encoding="utf-8")
                return root

            with (
                patch.object(runner.os, "geteuid", return_value=1000, create=True),
                patch.object(runner.platform, "system", return_value="Darwin"),
                patch.object(runner.Path, "home", return_value=home),
                patch.object(runner.telegram, "verify_bot"),
                patch.object(runner.provider, "verify", return_value="gpt-6.2-sol"),
                patch.object(runner, "choose_port", return_value=19789),
                patch.object(runner.dependencies, "install_node", return_value=(home / "node", home / "npm")),
                patch.object(runner.codex_setup, "install_codex_cli_first", side_effect=fake_codex_first),
                patch.object(runner.codex_setup, "install_antigravity_and_extension", side_effect=fake_editor),
                patch.object(runner.python_runtime, "install", return_value=home / "bin/python3"),
                patch.object(runner.ffmpeg, "install", return_value=home / "bin/ffmpeg"),
                patch.object(runner.instance, "initialize", side_effect=fake_init),
                patch.object(runner.runtime, "install", return_value=(root / "cli.mjs", {"OPENCLAW_PROFILE": "member-member01"})),
                patch.object(runner.payload, "install"),
                patch.object(runner.zalo_setup, "configure"),
                patch.object(runner.service, "install_and_verify"),
                patch.object(runner.telegram, "ensure_menu"),
            ):
                source = Path(__file__).resolve().parent.parent
                with patch("importlib.util.module_from_spec") as mod_spec:
                    fake_mod = type("M", (), {"install": staticmethod(lambda *a, **k: {"command": "openclaw", "directory": str(home), "path_present": True, "shell_path": {"updated": True}})})()
                    mod_spec.return_value = fake_mod
                    with patch("importlib.util.spec_from_file_location") as spec_fn:
                        spec_fn.return_value.loader.exec_module = lambda m: None
                        res = runner.install(sample(), source)

        self.assertEqual(order, ["codex-cli", "antigravity-editor", "openclaw-init"])
        self.assertEqual(res["gateway_port"], 19789)


if __name__ == "__main__":
    unittest.main()
