"""Opt-in local network test; uses only fake credentials and no gateway service."""

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import dependencies
import instance
import payload
import runtime
import zalo_setup
from test_settings import sample


@unittest.skipUnless(os.environ.get("UNIX_INSTALLER_LIVE_TEST") == "1", "Explicit network test is not enabled")
class LiveIntegrationTests(unittest.TestCase):
    def test_openclaw_and_zalo_plugins_in_temporary_instance(self):
        with tempfile.TemporaryDirectory(prefix="unix-installer-test-") as temporary:
            home = Path(temporary).resolve()
            with patch.dict(os.environ, {"HOME": str(home)}):
                node, npm = dependencies.install_node(home / "dependencies")
                root = instance.initialize(sample(), home, 18799)
                entry, env = runtime.install(root, home, Path(node).resolve(), Path(npm))
                source = Path(__file__).resolve().parent.parent
                payload.install(root, source)
                zalo_setup.configure(root, home, Path(node).resolve(), entry, env,
                                     "member01", ["12345", "67890"], source)
                config = json.loads((root / "openclaw.json").read_text())
                self.assertTrue(config["plugins"]["entries"]["telegram-zalo-owner-login"]["enabled"])
                self.assertEqual(set(config["commands"]["ownerAllowFrom"]), {"telegram:12345", "telegram:67890"})
                self.assertNotIn("*", config["channels"]["telegram"]["accounts"]["member01"]["groupAllowFrom"])
                runtime._run([Path(node).resolve(), entry, "config", "validate", "--json"], env, 120, "Configuration validation")
