from pathlib import Path
import json
import sys
import unittest


RELEASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RELEASE.parents[1] / "installer-web"))
from local_prompt import skill_install_guide


class LocalPromptTests(unittest.TestCase):
    def guide(self, modules):
        return skill_install_guide({"name": "fixture", "modules": modules}, None, RELEASE, "https://installer.example")

    def test_unselected_zalo_not_in_execution_plan_but_skills_remain(self):
        guide = self.guide([])
        prompt = guide["antigravity_prompt"]
        self.assertLess(len(prompt), 9500)
        self.assertNotIn("telegram_zalo_login_qr", prompt)
        self.assertNotIn("openclaw-zalo-context-rotation-70k", prompt)
        self.assertNotIn("zalo_guard_source", guide["skill_sources"])
        self.assertIn("openclaw-zalo-context-rotation-70k", guide["skill_sources"]["names"])
        self.assertEqual(guide["skill_sources"]["count"], 189)

    def test_selected_zalo_before_first_gateway_start(self):
        guide = self.guide(["zalo-personal"])
        prompt = guide["antigravity_prompt"]
        self.assertLess(len(prompt), 12000)
        self.assertIn("--ensure", prompt)
        self.assertIn("expectedSessionId", prompt)
        self.assertIn("pending_live_test", prompt)
        self.assertLess(prompt.index("ZALO ĐÃ CHỌN"), prompt.index("CHẠY NỀN:"))

    def test_primary_entry_is_native_and_no_legacy_slash_invocation(self):
        guide = self.guide([])
        self.assertFalse(guide["antigravity_prompt"].startswith("/tao-tro-ly"))
        self.assertTrue(guide["skill_sources"]["primary_skill"].endswith("references/local-native-install.md"))
        for key in ("primary_skill", "sync_timing_helper", "launcher_installer", "launcher_runtime", "windows_cli_installer"):
            relative = guide["skill_sources"][key].split("/api/v6-skills/", 1)[1]
            self.assertTrue((RELEASE / "native/skills" / relative).is_file())

    def test_reuse_timing_and_safety_are_retained(self):
        prompt = self.guide([])["antigravity_prompt"]
        for phrase in ("--workers 6", "SHA256", "install-timings.json", "--prefer-offline", "không system service/UAC",
                       "Không gỡ bản global", "acceptance.json", "Telegram DM allowFrom", "KHÔNG mở wildcard Telegram group"):
            self.assertIn(phrase, prompt)

    def test_native_image_api_key_binding_is_required_without_helper(self):
        prompt = self.guide([])["antigravity_prompt"]
        self.assertIn("image_generate gốc, không helper", prompt)
        self.assertIn("models.providers.openai lấy baseUrl và apiKey/SecretRef của customer", prompt)
        self.assertIn("mediaModels.image.primary='openai/cx/gpt-image-2'", prompt)
        skill = (RELEASE / "native/skills/imagegen/SKILL.md").read_text()
        self.assertIn("cx/gpt-image-2", skill)
        self.assertIn("image_generate", skill)
        self.assertNotIn("member_image_api.py", skill)

    def test_absolute_cli_before_config_and_no_path_reinstall(self):
        for modules in ([], ["zalo-personal"]):
            guide = self.guide(modules)
            prompt = guide["antigravity_prompt"]
            self.assertEqual(guide["prompt_revision"], "20261023-telegram-group-allowlist")
            for phrase in ("KHÔNG có nghĩa chưa cài", "npm prefix -g", "npm.cmd tuyệt đối",
                           "shell=False", "Minh Vuong", "Không gọi openclaw trần",
                           "openclaw gateway install --force", "absolute_cli_verified"):
                self.assertIn(phrase, prompt)
            self.assertNotIn("KHÔNG chạy openclaw gateway install --force", prompt)
            self.assertLess(prompt.index("CLI/PATH:"), prompt.index("5. Tạo config"))
            self.assertLess(prompt.index("CLI/PATH:"), prompt.index("3. Dùng lại"))

    def test_windows_cli_standard_service_and_migration_gates(self):
        prompt = self.guide([])["antigravity_prompt"]
        for phrase in ("windows_cli_installer", "openclaw.cmd", "User PATH", "default_cli=false", "cli_alias",
                       "environment", "--profile", "không tạo native_launcher/Startup VBS riêng",
                       "openclaw gateway start", "where.exe openclaw", "Gateway status --json",
                       "gateway_service_installed", "single_gateway_verified", "gateway_restart_verified",
                       "409 polling conflict", "stop bằng API", "backup", "trước rollback"):
            self.assertIn(phrase.lower(), prompt.lower())
        self.assertIn("pending_live_test", prompt)

    def test_downloaded_reference_does_not_reintroduce_windows_prohibition(self):
        reference = (RELEASE / "native/skills/tao-tro-ly-openclaw-windows-macos-linux/references/local-native-install.md").read_text()
        self.assertIn("install_windows_cli.py", reference)
        self.assertIn("allowed and required on Windows", reference)
        self.assertNotIn("Do not run\n   `openclaw gateway install --force`", reference)

    def test_host_and_container_source_and_cache_revision_agree(self):
        source = RELEASE.parents[1] / "installer-web"
        controller = RELEASE.parents[1] / "installer-control-giang/installer-web"
        for filename in ("local_prompt.py", "static/local-install.js", "README.md"):
            self.assertEqual((source / filename).read_bytes(), (controller / filename).read_bytes())
        self.assertIn("20261023-telegram-group-allowlist", (source / "static/local-install.js").read_text())

    def test_public_example_matches_current_generator_without_secrets(self):
        sample = (RELEASE / "PROMPT-LOCAL-ANTIGRAVITY-V6.md").read_text()
        config = json.loads(sample.split("KHÁCH HÀNG:\n```json\n", 1)[1].split("\n```", 1)[0])
        self.assertTrue(config["name"].startswith("["))
        self.assertTrue(config["owner_ids"].startswith("["))
        expected = skill_install_guide(config, None, RELEASE, "https://installer.emtroly.online")
        self.assertTrue(sample.endswith(expected["antigravity_prompt"] + "\n"))
        self.assertNotIn("Bearer ", sample)


if __name__ == "__main__":
    unittest.main()
