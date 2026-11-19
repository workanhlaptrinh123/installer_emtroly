import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import runtime


class RuntimeTests(unittest.TestCase):
    def test_instance_environment_clears_unrelated_gateway_values(self):
        with patch.dict(os.environ, {"OPENCLAW_GATEWAY_TOKEN": "secret", "OPENCLAW_HOME": "/old",
                                     "OPENCLAW_SYSTEMD_UNIT": "other-instance"}):
            env = runtime.instance_environment("/home/user/.openclaw-member-member01", "/home/user", "/tmp/node/bin/node")
        self.assertNotIn("OPENCLAW_GATEWAY_TOKEN", env)
        self.assertNotIn("OPENCLAW_HOME", env)
        self.assertNotIn("OPENCLAW_SYSTEMD_UNIT", env)
        self.assertEqual(env["OPENCLAW_STATE_DIR"], "/home/user/.openclaw-member-member01")
        self.assertEqual(env["OPENCLAW_PROFILE"], "member-member01")

    def test_instance_environment_rejects_noncanonical_state_dir(self):
        with self.assertRaises(ValueError):
            runtime.instance_environment("/home/user/unrelated", "/home/user", "/tmp/node/bin/node")
        with self.assertRaises(ValueError):
            runtime.instance_environment("/other/.openclaw-member-test", "/home/user", "/tmp/node/bin/node")

    def test_existing_runtime_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            root = home / ".openclaw-member-member01"
            root.mkdir()
            (root / "openclaw.json").touch()
            directory = root / "runtime" / runtime.OPENCLAW_VERSION
            directory.mkdir(parents=True)
            marker = directory / "keep"
            marker.write_text("keep")
            node = root / "node"
            npm = root / "npm"
            node.touch()
            npm.touch()
            with self.assertRaises(FileExistsError):
                runtime.install(root, home, node, npm)
            self.assertEqual(marker.read_text(), "keep")

    def test_external_command_failure_does_not_leak_output(self):
        with self.assertRaises(RuntimeError) as error:
            runtime._run(["/not-a-real-command", "private"], {}, 1, "test")
        self.assertNotIn("private", str(error.exception))

    def test_private_node_precedes_other_dependency_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            root = home / ".openclaw-member-member01"
            root.mkdir()
            (root / "openclaw.json").touch()
            node_dir = root / "node-bin"
            node_dir.mkdir()
            node = node_dir / "node"
            npm = node_dir / "npm"
            node.touch()
            npm.touch()
            extra = root / "python-bin"
            extra.mkdir()
            def fake_run(command, env, timeout, step):
                if step == "OpenClaw installation":
                    package = root / "runtime" / runtime.OPENCLAW_VERSION / "node_modules" / "openclaw"
                    (package / "scripts").mkdir(parents=True)
                    (package / "scripts" / "postinstall-bundled-plugins.mjs").touch()
                    (package / "openclaw.mjs").touch()
                return "OpenClaw 2026.11.4"
            with patch.object(runtime, "_run", side_effect=fake_run):
                _, env = runtime.install(root, home, node, npm, extra_bins=(extra,))
            self.assertEqual(env["PATH"].split(os.pathsep)[:2], [str(node_dir), str(extra)])


if __name__ == "__main__":
    unittest.main()
