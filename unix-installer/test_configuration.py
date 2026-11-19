import json
from pathlib import Path
import unittest

import configuration
import settings
from test_settings import sample


class ConfigurationTests(unittest.TestCase):
    def test_config_uses_private_files_and_owner_allowlists(self):
        data = settings.validate(sample())
        config = configuration.create_config(data, Path("/home/user/.openclaw-member-member01"), 18789)
        rendered = json.dumps(config)
        self.assertNotIn(data["telegram_token"], rendered)
        self.assertNotIn(data["ai_api_key"], rendered)
        account = config["channels"]["telegram"]["accounts"]["member01"]
        self.assertEqual(account["allowFrom"], ["12345", "67890"])
        self.assertEqual(account["groupAllowFrom"], ["12345", "67890"])
        self.assertEqual(config["commands"]["ownerAllowFrom"], ["telegram:12345", "telegram:67890"])
        self.assertEqual(config["gateway"]["bind"], "loopback")

    def test_gateway_token_is_unique_and_port_is_validated(self):
        data = settings.validate(sample())
        first = configuration.create_config(data, "/home/user/.openclaw-member-member01", 18789)
        second = configuration.create_config(data, "/home/user/.openclaw-member-member01", 18789)
        self.assertNotEqual(first["gateway"]["auth"]["token"], second["gateway"]["auth"]["token"])
        with self.assertRaises(ValueError):
            configuration.create_config(data, "/home/user/.openclaw-member-member01", 0)


if __name__ == "__main__":
    unittest.main()
