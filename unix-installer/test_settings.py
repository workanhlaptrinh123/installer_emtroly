import tempfile
import unittest
from pathlib import Path

import configuration
import settings


def sample():
    return {"member": "member01", "assistant_name": "Assistant", "owner_ids": "12345,67890",
            "group_id": "-12345", "telegram_token": "123456:" + "x" * 30,
            "ai_api_key": "test-only-key", "model": "gpt-6.2-sol",
            "base_url": "https://example.com/v1", "gateway_port": "0",
            "qr_owner_id": "12345", "accept_full_access": True}


class SettingsTests(unittest.TestCase):
    def test_valid_settings(self):
        result = settings.validate(sample())
        self.assertEqual(result["owner_ids"], ["12345", "67890"])
        self.assertEqual(result["gateway_port"], 0)

    def test_optional_empty_group_id_is_valid_and_omits_empty_group_key(self):
        for raw_grp in ("", "   "):
            data = sample()
            data["group_id"] = raw_grp
            normalized = settings.normalize(data)
            self.assertEqual(normalized["group_id"], "")
            validated = settings.validate(normalized)
            self.assertEqual(validated["group_id"], "")
            cfg_root = Path(tempfile.gettempdir()).resolve() / "emtroly-test"
            cfg = configuration.create_config(validated, cfg_root, 19789)
            groups_map = cfg["channels"]["telegram"]["accounts"]["member01"]["groups"]
            self.assertEqual(groups_map, {})
            self.assertNotIn("", groups_map)

    def test_each_unsafe_setting_is_rejected(self):
        cases = {"member": "../x", "assistant_name": "", "owner_ids": "*",
                 "group_id": "123", "telegram_token": "bad", "ai_api_key": "",
                 "model": "latest", "base_url": "http://example.com",
                 "gateway_port": "22", "qr_owner_id": "9999", "accept_full_access": False}
        for name, value in cases.items():
            with self.subTest(name=name):
                data = sample()
                data[name] = value
                with self.assertRaises(ValueError):
                    settings.validate(data)

    def test_untrusted_url_and_duplicate_owners_rejected(self):
        for url in ("https://user:pass@example.com", "https://example.com/?token=x", "https://exam\nple.com",
                    "https://example.com:bad", "https://example.com/#frag"):
            data = sample()
            data["base_url"] = url
            with self.subTest(url=url), self.assertRaises(ValueError):
                settings.validate(data)
        data = sample()
        data["owner_ids"] = "12345,12345"
        with self.assertRaises(ValueError):
            settings.validate(data)
        data = sample()
        data["member"] = "a" * 58
        with self.assertRaises(ValueError):
            settings.validate(data)

    def test_secrets_not_in_validation_errors(self):
        data = sample()
        data["telegram_token"] = "invalid secret token"
        with self.assertRaises(ValueError) as error:
            settings.validate(data)
        self.assertNotIn("invalid secret token", str(error.exception))


if __name__ == "__main__":
    unittest.main()
