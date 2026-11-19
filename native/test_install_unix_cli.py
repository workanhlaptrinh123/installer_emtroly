import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import install_unix_cli


class UnixCliTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cli test ")
        self.home = Path(self.temporary.name).resolve()
        self.root = self.home / ".openclaw-member-test"
        self.root.mkdir()
        (self.root / "openclaw.json").write_text("{}")
        self.node = self.home / "fake node"
        self.node.write_text('#!/bin/sh\nif [ "$2" = "--version" ]; then echo "OpenClaw 2026.11.4"; exit; fi\n'
                             'if [ "$2" = "pathcheck" ]; then printf "%s" "$PATH"; exit; fi\n'
                             'printf "%s\\n" "$OPENCLAW_STATE_DIR" "$OPENCLAW_PROFILE" "$2" "$3"\n')
        self.node.chmod(0o700)
        self.entry = self.root / "openclaw.mjs"
        self.entry.touch()
        self.environment = patch.dict(os.environ, {"PATH": str(self.home), "HOME": str(self.home)}, clear=False)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.addCleanup(self.temporary.cleanup)

    def install(self):
        return install_unix_cli.install(self.root, self.home, self.node, self.entry, "member-test", "2026.11.4")

    def test_command_passes_arguments_and_instance_environment(self):
        result = self.install()
        command = Path(result["directory"]) / result["command"]
        output = subprocess.check_output([str(command), "status", "a b & %"], text=True).splitlines()
        self.assertEqual(output, [str(self.root), "member-test", "status", "a b & %"])
        self.assertEqual(result["command"], "openclaw")
        self.assertFalse(result["path_present"])

    def test_existing_openclaw_is_not_overwritten(self):
        existing_bin = self.home / "existing"
        existing_bin.mkdir()
        existing = existing_bin / "openclaw"
        existing.write_text("untouched")
        existing.chmod(0o700)
        with patch.dict(os.environ, {"PATH": str(existing_bin)}):
            result = self.install()
        self.assertEqual(result["command"], result["alias"])
        self.assertEqual(existing.read_text(), "untouched")

    def test_command_prepends_private_dependency_paths(self):
        dependency = self.home / "python tools"
        dependency.mkdir()
        result = install_unix_cli.install(self.root, self.home, self.node, self.entry,
                                          "member-test", "2026.11.4", (dependency,))
        command = Path(result["directory"]) / result["command"]
        output = subprocess.check_output([str(command), "pathcheck"], text=True)
        self.assertEqual(output.split(":")[:2], [str(self.node.parent), str(dependency)])

    def test_conflicting_alias_is_not_overwritten(self):
        result = self.install()
        alias = Path(result["directory"]) / result["alias"]
        alias.write_text("different")
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(alias.read_text(), "different")

    def test_wrong_version_refuses_before_creating_command(self):
        with self.assertRaises(ValueError):
            install_unix_cli.install(self.root, self.home, self.node, self.entry, "member-test", "2026.11.5")
        self.assertFalse((self.home / ".local").exists())

    def test_symlinked_command_directory_is_rejected(self):
        external = self.home / "external"
        external.mkdir()
        (self.home / ".local").symlink_to(external, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.install()
        self.assertFalse((external / "bin").exists())

    def test_shell_path_is_backed_up_and_idempotent(self):
        config = self.home / ".bashrc"
        config.write_text("export EXAMPLE=1\n")
        result = install_unix_cli.configure_shell_path(self.root, self.home, "/bin/bash")
        self.assertTrue(result["updated"])
        self.assertIn(install_unix_cli.PATH_START, config.read_text())
        backups = list((self.root / "backups" / "shell").iterdir())
        self.assertEqual(backups[0].read_text(), "export EXAMPLE=1\n")
        self.assertFalse(install_unix_cli.configure_shell_path(self.root, self.home, "/bin/bash")["updated"])
        self.assertEqual(len(list((self.root / "backups" / "shell").iterdir())), 1)

    def test_shell_symlink_is_not_modified(self):
        target = self.home / "other"
        target.write_text("keep")
        (self.home / ".zshrc").symlink_to(target)
        result = install_unix_cli.configure_shell_path(self.root, self.home, "/bin/zsh")
        self.assertEqual(result["reason"], "unsafe-shell-config")
        self.assertEqual(target.read_text(), "keep")

    def test_modified_path_markers_are_not_treated_as_configured(self):
        config = self.home / ".bashrc"
        text = install_unix_cli.PATH_START + "\n# changed\n" + install_unix_cli.PATH_END + "\n"
        config.write_text(text)
        result = install_unix_cli.configure_shell_path(self.root, self.home, "/bin/bash")
        self.assertEqual(result["reason"], "invalid-existing-markers")
        self.assertEqual(config.read_text(), text)


if __name__ == "__main__":
    unittest.main()
