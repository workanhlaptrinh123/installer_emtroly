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
            env = runtime.instance_environment("/home/user/member", "/home/user", "/tmp/node/bin/node")
        self.assertNotIn("OPENCLAW_GATEWAY_TOKEN", env)
        self.assertNotIn("OPENCLAW_HOME", env)
        self.assertNotIn("OPENCLAW_SYSTEMD_UNIT", env)
        self.assertEqual(env["OPENCLAW_STATE_DIR"], "/home/user/member")
        self.assertTrue(env["OPENCLAW_PROFILE"].startswith("member-"))

    def test_existing_runtime_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
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
                runtime.install(root, root, node, npm)
            self.assertEqual(marker.read_text(), "keep")

    def test_external_command_failure_does_not_leak_output(self):
        with self.assertRaises(RuntimeError) as error:
            runtime._run(["/not-a-real-command", "private"], {}, 1, "test")
        self.assertNotIn("private", str(error.exception))

    def test_private_node_precedes_other_dependency_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
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
                _, env = runtime.install(root, root, node, npm, extra_bins=(extra,))
            self.assertEqual(env["PATH"].split(os.pathsep)[:2], [str(node_dir), str(extra)])


if __name__ == "__main__":
    unittest.main()
