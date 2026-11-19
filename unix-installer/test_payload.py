from pathlib import Path
import tempfile
import unittest

import payload


class PayloadTests(unittest.TestCase):
    def test_real_bundle_installs_required_skills_into_temporary_instance(self):
        source = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / "openclaw.json").write_text("{}")
            payload.install(root, source)
            self.assertTrue((root / "workspace/skills/telegram-zalo-owner-login/SKILL.md").is_file())
            self.assertTrue((root / "workspace/skills/openclaw-zalo-reply-mention/SKILL.md").is_file())
            with self.assertRaises(FileExistsError):
                payload.install(root, source)


if __name__ == "__main__":
    unittest.main()
