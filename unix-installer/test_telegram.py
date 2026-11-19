import unittest
from unittest.mock import patch

import telegram


class TelegramTests(unittest.TestCase):
    def test_menu_preserves_existing_commands(self):
        old = [{"command": "start", "description": "Start"}, {"command": "zaloqr", "description": "Old"}]
        calls = []
        def api(token, method, body=None):
            calls.append((method, body))
            if method == "getMyCommands":
                return old if len(calls) == 1 else [{"command": "zaloqr"}, {"command": "zalostatus"}]
            return True
        with patch.object(telegram, "api", side_effect=api):
            telegram.ensure_menu("fake")
        commands = calls[1][1]["commands"]
        self.assertEqual([item["command"] for item in commands], ["zaloqr", "zalostatus", "start"])

    def test_full_menu_does_not_modify_other_commands(self):
        old = [{"command": "cmd" + str(index), "description": "Test"} for index in range(100)]
        with patch.object(telegram, "api", return_value=old) as api:
            with self.assertRaises(RuntimeError):
                telegram.ensure_menu("fake")
            self.assertEqual(api.call_count, 1)

    def test_bot_verification_requires_bot_flag(self):
        with patch.object(telegram, "api", return_value={"is_bot": False}), self.assertRaises(RuntimeError):
            telegram.verify_bot("fake")


if __name__ == "__main__":
    unittest.main()
