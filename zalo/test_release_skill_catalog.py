import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


RELEASE = Path(__file__).resolve().parents[1]
SKILLS = RELEASE / "native/skills"
REQUESTED = {
    "telegram-basic": {
        "cap-full-quyen-telegram-openclaw",
        "cap-quyen-telegram-admin-openclaw",
        "unify-openclaw-bot-workspace",
        "set-openclaw-agent-full-exec",
    },
    "zalo-personal": {
        "openclaw-zalo-reply-mention",
        "openclaw-telegram-zalo-qr-delivery",
        "telegram-zalo-owner-login",
    },
}


class ReleaseSkillCatalogTests(unittest.TestCase):
    def test_requested_skills_and_dependencies_are_mapped(self):
        mapping = json.loads((RELEASE / "native/module-skills.json").read_text())
        for module, required in REQUESTED.items():
            self.assertTrue(required.issubset(mapping[module]))
            for skill in mapping[module]:
                self.assertTrue((SKILLS / skill / "SKILL.md").is_file(), skill)

    def test_requested_module_payloads_match_native_sources(self):
        for module, skill in (
            ("telegram-basic", "cap-full-quyen-telegram-openclaw"),
            ("zalo-personal", "openclaw-zalo-reply-mention"),
            ("zalo-personal", "openclaw-telegram-zalo-qr-delivery"),
        ):
            native = SKILLS / skill
            payload = RELEASE / "modules" / module / "skills" / skill
            for source in native.rglob("*"):
                if source.is_file() and "__pycache__" not in source.parts and ".bak-" not in source.name and source.suffix != ".pyc":
                    self.assertEqual(source.read_bytes(), (payload / source.relative_to(native)).read_bytes(), str(source))

    def test_native_default_profile_installs_requested_skills(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            catalog = temporary / "catalog"
            catalog.mkdir()
            (catalog / "modules").symlink_to(RELEASE / "modules", target_is_directory=True)
            (catalog / "profiles").symlink_to(RELEASE / "profiles", target_is_directory=True)
            (catalog / "module-skills.json").symlink_to(RELEASE / "native/module-skills.json")
            root = temporary / "state"
            subprocess.run(
                [sys.executable, "-B", str(RELEASE / "native/module-manager.py"), "install",
                 "--openclaw-root", str(root), "--catalog-root", str(catalog),
                 "--skills-source", str(SKILLS)],
                check=True, capture_output=True, text=True,
            )
            for module, required in REQUESTED.items():
                installed = json.loads((root / "module-state" / f"{module}.json").read_text())
                self.assertTrue(required.issubset(installed["skills"]))
                for skill in required:
                    self.assertTrue((root / "workspace/skills" / skill / "SKILL.md").is_file(), skill)


if __name__ == "__main__":
    unittest.main()
