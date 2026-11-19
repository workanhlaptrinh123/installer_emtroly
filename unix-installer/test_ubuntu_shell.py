import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parent.parent / "install-ubuntu.sh"


class UbuntuShellTests(unittest.TestCase):
    def test_sourcing_success_updates_parent_path_only_for_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, body in {"id": "echo 1000", "uname": "echo Linux", "systemctl": "exit 0",
                               "python3": "exit 0"}.items():
                program = root / name
                program.write_text("#!/bin/sh\n" + body + "\n")
                program.chmod(0o755)
            environment = dict(os.environ, HOME=str(root), PATH=str(root) + ":/usr/bin:/bin")
            shell = 'script=$1; argument=$2; set --; source "$script" "$argument" || exit $?; printf "\\nPATH_RESULT=%s\\n" "$PATH"'
            for argument in ("--check", ""):
                command = shell if argument else 'script=$1; set --; source "$script" || exit $?; printf "\\nPATH_RESULT=%s\\n" "$PATH"'
                result = subprocess.run(["/bin/bash", "-c", command, "test", str(SCRIPT), argument],
                                        env=environment, capture_output=True, text=True, check=True)
                path_line = next(line for line in result.stdout.splitlines() if line.startswith("PATH_RESULT="))
                self.assertEqual(str(root / ".local/bin") in path_line.split("=", 1)[1].split(":"), not argument)

    def test_sourcing_failure_preserves_parent_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment = dict(os.environ, HOME=temporary)
            command = 'before=$PATH; source "$1" --invalid; result=$?; [[ "$PATH" == "$before" ]] && echo "UNCHANGED"; echo "RESULT=$result"'
            result = subprocess.run(["/bin/bash", "-c", command, "test", str(SCRIPT)],
                                    env=environment, capture_output=True, text=True, check=True)
            self.assertIn("UNCHANGED", result.stdout)
            self.assertIn("RESULT=2", result.stdout)

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
