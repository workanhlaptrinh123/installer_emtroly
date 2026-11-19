from pathlib import Path
import tempfile
import unittest

import stage_payload


class StagingTests(unittest.TestCase):
    def test_only_current_tracked_payload_and_explicit_cli_are_staged(self):
        source = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary).resolve() / "payload"
            self.assertGreater(stage_payload.stage(source, destination), 100)
            self.assertTrue((destination / "native/install_unix_cli.py").is_file())
            self.assertTrue((destination / "native/skills/telegram-zalo-owner-login/SKILL.md").is_file())
            self.assertEqual(list(destination.rglob("*.bak-*")), [])
            with self.assertRaises(ValueError):
                stage_payload.stage(source, destination)


if __name__ == "__main__":
    unittest.main()
