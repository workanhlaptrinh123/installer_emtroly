import contextlib
import copy
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


RELEASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RELEASE.parents[1] / "installer-web"))
import app as installer_web
from local_prompt import skill_install_guide
from telegram_automation import POLICY_READ_SCRIPT


class TelegramGroupAllowlistTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.settings = {
            "member": "groupfixture", "owner_ids": [123456789], "group_id": "-1001234567890",
            "telegram_token": "unit-test-token", "api_key": "unit-test-key",
            "base_url": "https://example.invalid/v1", "model": "unit-test-model",
        }

    def generate(self, settings=None):
        settings_path = self.root / "settings.json"
        settings_path.write_text(json.dumps(self.settings if settings is None else settings))
        result = subprocess.run(
            [sys.executable, str(RELEASE / "configure.py"), "--settings", str(settings_path),
             "--root", str(self.root / "state")], capture_output=True, text=True,
        )
        return result

    def generated_config(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads((self.root / "state/openclaw.json").read_text())

    def read_policy(self, document):
        def read_text(path):
            if path.name == "openclaw.json":
                return json.dumps(document)
            if path.name == "telegram.token":
                return self.settings["telegram_token"]
            raise AssertionError("Unexpected policy file")

        output = io.StringIO()
        with mock.patch.object(Path, "read_text", read_text), contextlib.redirect_stdout(output):
            exec(POLICY_READ_SCRIPT, {})
        return json.loads(output.getvalue())

    def healthcheck(self, document):
        policy = self.read_policy(document)
        bot = {"id": 987654321, "username": "unit_test_bot", "is_bot": True}

        def telegram_api(token, method, params=None):
            return {"getMe": bot, "getWebhookInfo": {}, "getChat": {"title": "Unit test group"},
                    "getChatMember": {"status": "administrator"}}[method]

        commands = [(0, "valid"), (0, json.dumps(policy)),
                    (0, "Telegram groupfixture: configured, running, connected")]
        config = {"owner_ids": "123456789", "group_id": self.settings["group_id"]}
        with mock.patch.object(installer_web, "telegram_api", side_effect=telegram_api), \
                mock.patch.object(installer_web, "run_command", side_effect=commands):
            return installer_web.telegram_healthcheck("groupfixture", config, self.settings)

    def test_generated_config_limits_group_ids_but_keeps_member_tools_and_owner_dm(self):
        document = self.generated_config()
        telegram = document["channels"]["telegram"]
        account = telegram["accounts"]["groupfixture"]
        self.assertEqual(telegram["groupPolicy"], "allowlist")
        self.assertEqual(account["groupPolicy"], "allowlist")
        self.assertEqual(account["groupAllowFrom"], ["*"])
        self.assertEqual(list(account["groups"]), [self.settings["group_id"]])
        group = account["groups"][self.settings["group_id"]]
        self.assertEqual(group["groupPolicy"], "allowlist")
        self.assertFalse(group["requireMention"])
        self.assertEqual(group["tools"]["allow"], ["*"])
        self.assertEqual(account["dmPolicy"], "allowlist")
        self.assertEqual(account["allowFrom"], ["123456789"])
        checks, message = self.healthcheck(document)
        check = next(item for item in checks if item["name"] == "telegram_group_allowlist_full_tools")
        self.assertEqual(check["group_ids"], [self.settings["group_id"]])

    def test_missing_group_is_rejected_before_credentials_are_written(self):
        settings = dict(self.settings)
        settings.pop("group_id")
        result = self.generate(settings)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("group allowlist", result.stderr)
        self.assertFalse((self.root / "state/telegram.token").exists())

    def test_invalid_group_ids_cannot_enable_wildcard_or_sender_id(self):
        for group_id in ("", "*", "123456789", "-0", "-1001234567890,*"):
            with self.subTest(group_id=group_id):
                result = self.generate(dict(self.settings, group_id=group_id))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("group allowlist", result.stderr)

    def test_healthcheck_rejects_legacy_open_wildcard_and_undeclared_groups(self):
        original = self.generated_config()
        for mutation in ("open", "wildcard", "extra", "missing", "restricted"):
            with self.subTest(mutation=mutation):
                document = copy.deepcopy(original)
                account = document["channels"]["telegram"]["accounts"]["groupfixture"]
                group = account["groups"][self.settings["group_id"]]
                if mutation == "open":
                    account["groupPolicy"] = "open"
                elif mutation == "wildcard":
                    account["groups"]["*"] = copy.deepcopy(group)
                elif mutation == "extra":
                    account["groups"]["-1009999999999"] = copy.deepcopy(group)
                elif mutation == "missing":
                    account["groups"] = {}
                else:
                    group["allowFrom"] = ["123456789"]
                with self.assertRaises(RuntimeError):
                    self.healthcheck(document)

    def test_local_prompt_keeps_zalo_policy_separate_and_requires_rejection_checks(self):
        guide = skill_install_guide(dict(self.settings, modules=["zalo-personal"]), None,
                                   RELEASE, "https://installer.example")
        prompt = guide["antigravity_prompt"]
        self.assertIn('"group_access_policy": "configured-groups-allowlist"', prompt)
        for phrase in ("groupPolicy=allowlist", "không có key '*'", "nhóm ngoài danh sách bị chặn",
                       "telegram_group_allowlist", "unlisted_telegram_groups_blocked",
                       "Telegram DM allowFrom chỉ owners", "Zalo dmPolicy=open"):
            self.assertIn(phrase, prompt)
        self.assertNotIn("all_groups_full_tools", prompt)
        self.assertNotIn("KHÔNG tự khóa wildcard group lại", prompt)

    def test_windows_installer_does_not_fall_back_to_any_group(self):
        installer = (RELEASE / "install-native-windows.ps1").read_text()
        self.assertIn("$targetGroup = $GroupId", installer)
        self.assertIn("groupPolicy='allowlist'; groupAllowFrom=@('*')", installer)
        self.assertNotIn("else { '*' }", installer)
        self.assertNotIn("groupPolicy='open'", installer)


if __name__ == "__main__":
    unittest.main()
