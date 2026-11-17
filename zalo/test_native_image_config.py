import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


RELEASE = Path(__file__).resolve().parents[1]


class NativeImageConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.settings = {
            "member": "nativefixture", "telegram_token": "unit-test-placeholder", "api_key": "unit-test-image-key",
            "base_url": "https://example.invalid/v1", "model": "chat-model-unchanged", "owner_ids": [123456789],
            "group_id": "-1001234567890",
        }
        path = self.root / "settings.json"
        path.write_text(json.dumps(self.settings))
        self.state = self.root / "state"
        subprocess.run([sys.executable, str(RELEASE / "configure.py"), "--settings", str(path), "--root", str(self.state)], check=True, capture_output=True)
        self.config = json.loads((self.state / "openclaw.json").read_text())

    def test_native_image_provider_reuses_customer_key_and_endpoint(self):
        providers = self.config["models"]["providers"]
        self.assertEqual(providers["openai"]["baseUrl"], providers["customer"]["baseUrl"])
        self.assertEqual(providers["openai"]["apiKey"], providers["customer"]["apiKey"])
        self.assertEqual(providers["openai"]["auth"], "api-key")
        self.assertEqual(providers["openai"]["models"][0]["id"], "cx/gpt-image-2")

    def test_native_media_model_is_selected_without_changing_chat_model(self):
        defaults = self.config["agents"]["defaults"]
        self.assertEqual(defaults["model"]["primary"], "customer/chat-model-unchanged")
        self.assertEqual(defaults["mediaModels"]["image"], {"primary": "openai/cx/gpt-image-2", "timeoutMs": 240000})

    def test_api_key_is_kept_in_original_private_secret_not_config_or_helper(self):
        self.assertNotIn(self.settings["api_key"], (self.state / "openclaw.json").read_text())
        secret = self.state / "member-provider.secret"
        self.assertEqual(secret.read_text().strip(), self.settings["api_key"])
        self.assertEqual(secret.stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.state / "workspace/skills/imagegen/scripts/member_image_api.py").exists())

    def test_windows_native_binding_matches_generated_config(self):
        installer = (RELEASE / "install-native-windows.ps1").read_text()
        self.assertIn("openai=@{ baseUrl=$BaseUrl; apiKey=@{ source='file'; provider='customer'; id='value' }; auth='api-key'", installer)
        self.assertIn("mediaModels=@{ image=@{ primary='openai/cx/gpt-image-2'; timeoutMs=240000 } }", installer)
        self.assertNotIn("member_image_api.py", installer)


if __name__ == "__main__":
    unittest.main()
