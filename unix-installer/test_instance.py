import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

import instance
from test_settings import sample


class InstanceTests(unittest.TestCase):
    def test_creates_private_files_without_overwriting_instance(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            with patch.dict(os.environ, {"HOME": str(home)}):
                root = instance.initialize(sample(), home, 18789)
                self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
                for name in ("telegram.token", "member-provider.secret", "openclaw.json"):
                    self.assertEqual(stat.S_IMODE((root / name).stat().st_mode), 0o600)
                original = (root / "openclaw.json").read_bytes()
                with self.assertRaises(FileExistsError):
                    instance.initialize(sample(), home, 18789)
                self.assertEqual((root / "openclaw.json").read_bytes(), original)

    def test_invalid_configuration_does_not_create_instance(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            values = sample()
            values["accept_full_access"] = False
            with patch.dict(os.environ, {"HOME": str(home)}), self.assertRaises(ValueError):
                instance.initialize(values, home, 18789)
            self.assertEqual(list(home.iterdir()), [])

    def test_does_not_install_into_a_different_user_home(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            with patch.dict(os.environ, {"HOME": "/"}), self.assertRaises(ValueError):
                instance.initialize(sample(), home, 18789)
            self.assertEqual(list(home.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
