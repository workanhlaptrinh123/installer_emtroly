import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch


RELEASE = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("native_owner_qr", RELEASE / "native/skills/telegram-zalo-owner-login/scripts/deploy-native.py")
NATIVE = importlib.util.module_from_spec(SPEC)
sys.path.insert(0, str(Path(SPEC.origin).parent))
SPEC.loader.exec_module(NATIVE)
sys.path.insert(0, str(RELEASE.parents[1] / "installer-web"))
from local_prompt import skill_install_guide
import app


class OwnerQrTests(unittest.TestCase):
    def config(self):
        return {"commands": {"ownerAllowFrom": ["telegram:123456789"]},
                "agents": {"entries": {"main": {}}},
                "channels": {"telegram": {"accounts": {"fixture": {}}}, "zalouser": {"accounts": {"default": {}}}},
                "bindings": [{"agentId": "main", "match": {"channel": channel, "accountId": account}}
                             for channel, account in [("telegram", "fixture"), ("zalouser", "default")]]}

    def settings(self, config):
        return NATIVE.selected_settings(config, Path("/state"), Path("/home"), Path("/node"), Path("/cli.mjs"), "fixture", "default", "main")

    def test_settings_preserve_config_and_use_explicit_node(self):
        config = self.config()
        original = json.dumps(config)
        settings = self.settings(config)
        self.assertEqual(settings["cliPrefix"], ["/cli.mjs"])
        self.assertEqual(json.dumps(config), original)

    def test_public_allow_from_is_not_owner(self):
        config = self.config()
        config["commands"]["ownerAllowFrom"] = ["*", "zalouser:123456789"]
        with self.assertRaises(ValueError):
            self.settings(config)

    def test_mismatched_agent_rejected(self):
        config = self.config()
        config["bindings"][0]["agentId"] = "other"
        with self.assertRaises(ValueError):
            self.settings(config)

    def test_web_prompt_has_native_helper_and_receipt_gates(self):
        guide = skill_install_guide({"modules": ["zalo-personal"]}, None, RELEASE, "https://installer.example")
        self.assertEqual(guide["prompt_revision"], "20261023-telegram-group-allowlist")
        for phrase in ("deploy-native.py", "/zaloqr", "qr_owner_command", "pending_live_test", "không gửi group"):
            self.assertIn(phrase, guide["antigravity_prompt"])
        modules = json.loads((RELEASE / "native/module-skills.json").read_text())
        self.assertIn("telegram-zalo-owner-login", modules["zalo-personal"])

    def test_web_qr_refuses_missing_owner_tool_without_sending(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(app, "JOB_DIR", Path(directory)):
            job_id = "job-20261016-000000-abcdef"
            app.update_job(job_id, config={"name": "fixture"}, zalo_protection="verified")
            with patch.object(app, "run_command", side_effect=AssertionError("No QR must run")):
                app.execute_zalo_qr(job_id)
            job = app.read_json(app.job_path(job_id), {})
            self.assertEqual(job["qr_status"], "failed")
            self.assertIn("owner Telegram", job["error"])

    def test_web_never_equates_qr_send_with_login_success(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(app, "JOB_DIR", Path(directory)):
            job_id = "job-20261016-000000-abcdef"
            app.update_job(job_id, config={"name": "fixture", "owner_ids": "123456789", "qr_owner_id": "123456789"},
                           zalo_protection="verified", telegram_owner_qr="verified_pending_live_test")
            with patch.object(app, "run_command", return_value=(0, json.dumps({"ok": True, "qrMessageId": "synthetic"}))):
                app.execute_zalo_qr(job_id)
            job = app.read_json(app.job_path(job_id), {})
            self.assertEqual(job["status"], "failed")
            self.assertNotEqual(job.get("qr_status"), "logged_in")

    def test_native_ensure_skips_reinstall_only_for_exact_enabled_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_path = root / "openclaw.json"
            config_path.write_text(json.dumps(self.config()))
            node, entry = root / "node", root / "openclaw.mjs"
            node.touch()
            entry.touch()
            arguments = ["deploy-native.py", "--root", str(root), "--home", str(root), "--node", str(node),
                         "--cli-entry", str(entry), "--telegram-account", "fixture", "--ensure"]

            def cli(command, **kwargs):
                if "enable" in command:
                    config = json.loads(config_path.read_text())
                    config["plugins"] = {"entries": {"telegram-zalo-owner-login": {"enabled": True}}}
                    config_path.write_text(json.dumps(config))
                plugin = {"id": "telegram-zalo-owner-login", "status": "loaded", "enabled": True,
                          "toolNames": ["telegram_zalo_login_qr"]}
                if "list" in command:
                    output = json.dumps({"plugins": [plugin]})
                elif "inspect" in command:
                    output = json.dumps({"plugin": plugin, "commands": ["zaloqr"]})
                else:
                    output = "OpenClaw 2026.11.4" if "--version" in command else "{}"
                return SimpleNamespace(returncode=0, stdout=output)

            with patch.object(sys, "argv", arguments), patch.object(NATIVE.subprocess, "run", side_effect=cli) as invoked, patch("sys.stdout", new_callable=io.StringIO):
                NATIVE.main()
                self.assertEqual(invoked.call_count, 8)
                invoked.reset_mock()
                NATIVE.main()
                self.assertEqual(invoked.call_count, 3)
                package_path = root / "tools/telegram-zalo-owner-login/package.json"
                package = json.loads(package_path.read_text())
                package["openclaw"]["compat"]["pluginApi"] = "2026.9.9"
                package_path.write_text(json.dumps(package))
                invoked.reset_mock()
                NATIVE.main()
                self.assertEqual(invoked.call_count, 8)
                self.assertEqual(json.loads(package_path.read_text())["openclaw"]["compat"]["pluginApi"], ">=2026.9.9 <=2026.11.4")


if __name__ == "__main__":
    unittest.main()
