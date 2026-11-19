import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import instance
from test_settings import sample
import zalo_setup


class ZaloSetupTests(unittest.TestCase):
    def test_actual_owner_helper_produces_expected_private_permissions(self):
        source = Path(__file__).resolve().parent.parent
        owner = source / "native/skills/tao-tro-ly-openclaw-windows-macos-linux/scripts/ensure_default_telegram_owner.py"
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {"HOME": temporary}):
            root = instance.initialize(sample(), Path(temporary).resolve(), 18789)
            subprocess.run([sys.executable, str(owner), "--openclaw-root", str(root), "--account-id", "member01",
                            "--agent-id", "main", "--apply", "--backup-dir", str(root / "backups/owner"),
                            "--owner-id", "12345", "--owner-id", "67890"], check=True, capture_output=True, timeout=60)
            subprocess.run([sys.executable, str(source / "native/finalize_permissions.py"), "--config", str(root / "openclaw.json"),
                            "--owners", "12345,67890"], check=True, capture_output=True, timeout=60)
            config = json.loads((root / "openclaw.json").read_text())
            zalo_setup._verify_permissions(config, "member01", ["12345", "67890"])
            config["channels"]["telegram"]["accounts"]["member01"]["groupAllowFrom"] = ["*"]
            with self.assertRaises(RuntimeError):
                zalo_setup._verify_permissions(config, "member01", ["12345", "67890"])


if __name__ == "__main__":
    unittest.main()
