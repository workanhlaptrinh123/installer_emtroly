import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import MagicMock, patch


ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import local_install
import install_native_launcher
import install_windows_cli


class LocalNativeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.payloads = {"first/SKILL.md": b"first", "first/data.txt": b"payload", "second/SKILL.md": b"second"}
        self.manifest = {"count": 2, "skills": [
            {"name": name, "files": [{"path": key.split("/", 1)[1], "sha256": hashlib.sha256(value).hexdigest()}
                                      for key, value in self.payloads.items() if key.startswith(name + "/")]}
            for name in ("first", "second")]}
        self.requests = []
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                fixture.requests.append(self.path)
                body = json.dumps(fixture.manifest).encode() if self.path == "/manifest" else fixture.payloads[self.path.removeprefix("/files/")]
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = "http://127.0.0.1:" + str(self.server.server_port)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temporary.cleanup()

    def sync(self, workspace=None):
        return local_install.sync_skills(self.url + "/manifest", self.url + "/files", workspace or self.root / "workspace", self.root / "cache", 2)

    def test_full_sync_resume_and_cache_verify_every_hash(self):
        first = self.sync()
        self.assertEqual(first["downloaded"], 3)
        self.assertTrue(first["hashes_verified"])
        count = len(self.requests)
        again = self.sync()
        self.assertEqual(again["unchanged"], 3)
        self.assertEqual(len(self.requests) - count, 1)
        cached = self.sync(self.root / "another-workspace")
        self.assertEqual(cached["cached"], 3)
        self.assertEqual(cached["downloaded"], 0)

    def test_modified_customer_file_is_backed_up(self):
        self.sync()
        target = self.root / "workspace/skills/first/data.txt"
        target.write_text("customer-modification")
        self.sync()
        saved = list((self.root / "workspace/skill-backups").glob("*/first/data.txt"))
        self.assertEqual(len(saved), 1)
        self.assertEqual(saved[0].read_text(), "customer-modification")
        self.assertEqual(target.read_bytes(), b"payload")

    def test_bad_hash_not_installed(self):
        self.manifest["skills"][0]["files"][0]["sha256"] = "a" * 64
        with self.assertRaises(ValueError):
            self.sync()
        self.assertFalse((self.root / "workspace/skills/first/SKILL.md").exists())

    def test_path_traversal_and_duplicate_paths_fail_before_write(self):
        self.manifest["skills"][0]["files"].append({"path": "../escape", "sha256": "a" * 64})
        with self.assertRaises(ValueError):
            self.sync()
        self.assertFalse((self.root / "workspace").exists())

    def test_symlink_escape_refused(self):
        workspace = self.root / "workspace"
        workspace.mkdir()
        external = self.root / "outside"
        external.mkdir()
        (workspace / "skills").symlink_to(external, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.sync()
        self.assertEqual(list(external.iterdir()), [])

    def test_timings_do_not_store_argv_or_child_output(self):
        record = local_install.timed_step(self.root, "runtime", [sys.executable, "-c", "print('synthetic-private-output')"], 5)
        self.assertEqual(record["status"], "passed")
        self.assertNotIn("synthetic-private-output", (self.root / "install-timings.json").read_text())
        self.assertNotIn("-c", (self.root / "install-timings.json").read_text())
        failed = local_install.timed_step(self.root, "probe", [sys.executable, "-c", "raise SystemExit(7)"], 5)
        self.assertEqual(failed["exit_code"], 7)

    def test_timeout_bounded(self):
        record = local_install.timed_step(self.root, "probe", [sys.executable, "-c", "import time; time.sleep(5)"], 0.02)
        self.assertEqual(record["status"], "timeout")

    def test_verified_manifest_reused_without_another_request(self):
        saved = self.root / "manifest.json"
        saved.write_text(json.dumps(self.manifest))
        result = local_install.sync_skills(self.url + "/manifest", self.url + "/files", self.root / "workspace", self.root / "cache", 2, manifest_file=saved)
        self.assertEqual(result["file_count"], 3)
        self.assertNotIn("/manifest", self.requests)

    def test_windows_launcher_registers_user_startup_no_powershell(self):
        state = self.root / "instance with spaces"
        state.mkdir()
        (state / "openclaw.json").write_text(json.dumps({"gateway": {"port": 23456}}))
        node, entry, appdata = self.root / "node.exe", self.root / "openclaw.mjs", self.root / "AppData"
        node.write_text("synthetic executable")
        entry.write_text("synthetic cli")
        appdata.mkdir()
        with patch.object(install_native_launcher.platform, "system", return_value="Windows"), patch.dict(os.environ, {"APPDATA": str(appdata)}):
            installed = install_native_launcher.install(state, self.root, node, entry, 23456)
        startup = next(appdata.rglob("*.vbs")).read_text(encoding="utf-16")
        self.assertNotIn("powershell", startup.lower())
        self.assertIn("WScript.Shell", startup)
        self.assertTrue(installed["startup_registered"])
        settings = json.loads(Path(installed["settings"]).read_text())
        self.assertEqual(settings["root"], str(state))
        self.assertEqual(settings["port"], 23456)

    def test_startup_templates_use_current_user_scope(self):
        payload = install_native_launcher.startup_payload("Linux", Path("/node with spaces"), Path("/launcher.cjs"), Path("/instance.json"))
        self.assertIn(b"WantedBy=default.target", payload)
        self.assertNotIn(b"multi-user.target", payload)
        payload = install_native_launcher.startup_payload("Darwin", Path("/node"), Path("/launcher.cjs"), Path("/instance.json"))
        self.assertIn(b"RunAtLoad", payload)

    def test_wrong_customer_os_stops_before_any_writes(self):
        with patch.object(install_native_launcher.platform, "system", return_value="Linux"):
            with self.assertRaises(ValueError):
                install_native_launcher.install(self.root, self.root, self.root / "node", self.root / "entry", 23456, "windows")
        self.assertEqual(list(self.root.iterdir()), [])


class WindowsCliTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name) / "Minh Vương & 100%!"
        self.state = self.home / ".openclaw-member-fixture"
        self.state.mkdir(parents=True)
        self.localappdata = self.home / "AppData/Local"
        self.localappdata.mkdir(parents=True)
        self.node = self.home / "Node JS/node.exe"
        self.node.parent.mkdir()
        self.node.write_text("fixture")
        self.entry = self.state / "openclaw.mjs"
        self.entry.write_text("fixture")
        (self.state / "openclaw.json").write_text(json.dumps({"gateway": {"port": 23456}}))
        self.registry = MagicMock()
        self.registry.REG_SZ, self.registry.REG_EXPAND_SZ = 1, 2
        self.registry.KEY_QUERY_VALUE, self.registry.KEY_SET_VALUE = 1, 2
        self.registry.QueryValueEx.return_value = (r"C:\Existing;%APPDATA%\npm", 2)
        patches = (
            patch.object(install_windows_cli.platform, "system", return_value="Windows"),
            patch.dict(os.environ, {"USERPROFILE": str(self.home), "LOCALAPPDATA": str(self.localappdata), "PATH": r"C:\Existing"}),
            patch.dict(sys.modules, {"winreg": self.registry}),
            patch.object(install_windows_cli.shutil, "which", return_value=None),
            patch.object(install_windows_cli, "broadcast_environment", return_value=True),
            patch.object(install_windows_cli.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "OpenClaw 2026.11.4 (fixture)\n", "")),
        )
        self.mocks = []
        for patched in patches:
            self.mocks.append(patched.start())
            self.addCleanup(patched.stop)

    def install(self, **kwargs):
        return install_windows_cli.install(self.state, self.home, self.node, self.entry, 23456, **kwargs)

    def test_private_runtime_gets_default_cli_absolute_paths_and_scoped_env(self):
        result = self.install()
        self.assertTrue(result["default_cli"])
        body = Path(result["cli_path"]).read_bytes().decode("utf-8")
        self.assertIn('"%SystemRoot%\\System32\\chcp.com" 65001', body)
        self.assertIn("setlocal DisableDelayedExpansion", body)
        self.assertIn(str(self.node).replace("%", "%%"), body)
        self.assertIn(str(self.entry).replace("%", "%%"), body)
        self.assertIn("%*", body)
        self.assertIn("exit /b %errorlevel%", body)
        self.assertEqual(result["environment"]["OPENCLAW_STATE_DIR"], str(self.state))
        self.assertTrue(result["environment"]["OPENCLAW_PROFILE"].startswith("member-"))
        self.assertFalse(result["gateway_installed"])
        self.assertEqual(self.mocks[-1].call_args.args[0], [str(self.node), str(self.entry), "--version"])

    def test_user_path_preserves_other_entries_and_has_backup(self):
        result = self.install()
        self.assertTrue(result["user_path_updated"])
        value = self.registry.SetValueEx.call_args.args[-1]
        self.assertEqual(value, r"C:\Existing;%APPDATA%\npm;" + result["user_bin"])
        saved = next((self.state / "backups").glob("*/user-path.json"))
        self.assertEqual(json.loads(saved.read_text())["value"], r"C:\Existing;%APPDATA%\npm")

    def test_path_merge_is_case_insensitive_and_expands_variables(self):
        with patch.dict(os.environ, {"APPDATA": r"C:\Users\Admin\AppData\Roaming"}):
            current = r"C:\Existing;%APPDATA%\npm"
            self.assertEqual(install_windows_cli.merge_path(current, ["c:\\existing\\", r"C:\Users\Admin\AppData\Roaming\npm"]), current)

    def test_resume_does_not_rewrite_same_shim_or_duplicate_path(self):
        first = self.install()
        before = Path(first["cli_path"]).stat().st_mtime_ns
        self.registry.QueryValueEx.return_value = (self.registry.SetValueEx.call_args.args[-1], 2)
        self.registry.SetValueEx.reset_mock()
        again = self.install()
        self.assertFalse(again["user_path_updated"])
        self.assertEqual(before, Path(first["cli_path"]).stat().st_mtime_ns)
        self.registry.SetValueEx.assert_not_called()

    def test_foreign_global_command_is_preserved_and_alias_is_provided(self):
        self.mocks[3].return_value = str(self.home / "other-openclaw.cmd")
        result = self.install()
        self.assertFalse(result["default_cli"])
        self.assertFalse((Path(result["user_bin"]) / "openclaw.cmd").exists())
        self.assertTrue(Path(result["cli_path"]).is_file())

    def test_other_instance_keeps_generic_command(self):
        first = self.install()
        original = Path(first["cli_path"]).read_bytes()
        other = self.home / ".openclaw-member-another"
        other.mkdir()
        (other / "openclaw.json").write_text(json.dumps({"gateway": {"port": 23576}}))
        result = install_windows_cli.install(other, self.home, self.node, self.entry, 23576)
        self.assertFalse(result["default_cli"])
        self.assertNotEqual(first["cli_alias"], result["cli_alias"])
        self.assertEqual(Path(first["cli_path"]).read_bytes(), original)

    def test_wrong_version_fails_before_path_or_shim_writes(self):
        for version in ("2026.9.4", "OpenClaw 2026.11.99", "2026.11.4 followed by junk"):
            self.mocks[-1].return_value = subprocess.CompletedProcess([], 0, version, "")
            with self.assertRaises(ValueError):
                self.install()
        self.assertFalse((self.localappdata / "OpenClaw").exists())
        self.registry.SetValueEx.assert_not_called()

    def test_cli_failure_does_not_change_path(self):
        self.mocks[-1].return_value = subprocess.CompletedProcess([], 1, "2026.11.4", "fixture-private-output")
        with self.assertRaises(ValueError):
            self.install()
        self.registry.SetValueEx.assert_not_called()

    def test_wrong_user_or_os_fails_before_mutations(self):
        with patch.dict(os.environ, {"USERPROFILE": str(self.home / "another-user")}):
            with self.assertRaises(ValueError):
                self.install()
        with patch.object(install_windows_cli.platform, "system", return_value="Linux"):
            with self.assertRaises(ValueError):
                self.install()
        self.mocks[-1].assert_not_called()
        self.registry.SetValueEx.assert_not_called()

    def test_config_port_mismatch_rejected(self):
        (self.state / "openclaw.json").write_text(json.dumps({"gateway": {"port": 20000}}))
        with self.assertRaises(ValueError):
            self.install()
        self.registry.SetValueEx.assert_not_called()

    def test_upgrade_can_keep_verified_existing_standard_profile(self):
        result = self.install(profile="default")
        self.assertEqual(result["environment"]["OPENCLAW_PROFILE"], "default")
        with self.assertRaises(ValueError):
            self.install(profile="bad\nprofile")

    def test_redirected_cli_directory_rejected(self):
        outside = self.home / "outside"
        outside.mkdir()
        (self.localappdata / "OpenClaw").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(list(outside.iterdir()), [])
        self.registry.SetValueEx.assert_not_called()


if __name__ == "__main__":
    unittest.main()
