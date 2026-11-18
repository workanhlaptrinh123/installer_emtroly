import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "native/skills/tao-tro-ly-openclaw-windows-macos-linux/scripts"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("windows_cli_tested", SCRIPTS / "install_windows_cli.py")
CLI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLI)


@unittest.skipUnless(os.name == "nt", "Windows cmd.exe required")
class CliShimWindowsTests(unittest.TestCase):
    def test_status_and_other_arguments_reach_the_selected_private_cli(self):
        with tempfile.TemporaryDirectory(prefix="openclaw-shim-") as temporary:
            home = Path(temporary) / "Minh Vuong & 100%!"
            root = home / ".openclaw-member-fixture"
            root.mkdir(parents=True)
            entry = root / "fixture.py"
            entry.write_text(
                "import json, os, sys\n"
                "print(json.dumps({'args': sys.argv[1:], 'root': os.environ['OPENCLAW_STATE_DIR']}))\n",
                encoding="utf-8",
            )
            shim = home / "openclaw.cmd"
            environment = CLI.instance_environment(root, home, "fixture", "member-fixture")
            shim.write_bytes(CLI.shim_payload(Path(sys.executable), entry, environment, "fixture"))
            shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
            process_environment = {**os.environ, "PATH": str(home) + os.pathsep + os.environ["PATH"]}
            cases = (("status", "--json"), ("--version",))
            for arguments in cases:
                result = subprocess.run(
                    [str(shell), "-NoProfile", "-NonInteractive", "-Command", "openclaw " + " ".join(arguments)],
                    env=process_environment, capture_output=True, text=True, encoding="utf-8", timeout=30, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = json.loads(result.stdout)
                self.assertEqual(payload["args"], list(arguments))
                self.assertEqual(payload["root"], str(root))


if __name__ == "__main__":
    unittest.main()
