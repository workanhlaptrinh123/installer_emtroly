import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parent.parent / "install-ubuntu.sh"


class UbuntuShellTests(unittest.TestCase):
    def test_help_does_not_require_root_or_systemd(self):
        result = subprocess.run(["/bin/bash", str(SCRIPT), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--check", result.stdout)

    def test_missing_systemd_fails_before_python_or_apt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / "python-called"
            programs = {"id": "echo 1000", "uname": "echo Linux", "systemctl": "exit 1",
                        "python3": 'touch "$MARKER"'}
            for name, body in programs.items():
                path = root / name
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            environment = dict(os.environ, PATH=str(root) + ":/usr/bin:/bin", MARKER=str(marker))
            result = subprocess.run(["/bin/bash", str(SCRIPT), "--check"], env=environment,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("systemd user service", result.stderr)
            self.assertFalse(marker.exists())

    def test_missing_python_does_not_run_apt_noninteractively(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / "sudo-called"
            programs = {"id": "echo 1000", "uname": "echo Linux", "systemctl": "exit 0",
                        "python3": "exit 1", "sudo": 'touch "$MARKER"', "apt-get": "exit 0"}
            for name, body in programs.items():
                path = root / name
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            environment = dict(os.environ, PATH=str(root) + ":/usr/bin:/bin", MARKER=str(marker))
            result = subprocess.run(["/bin/bash", str(SCRIPT), "--check"], env=environment,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Python 3", result.stderr)
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
