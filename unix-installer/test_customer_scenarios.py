"""Unit tests for all customer failure-mode hardening items on macOS & Linux."""

from __future__ import annotations

import http.client
import io
import json
import os
from pathlib import Path
import ssl
import stat
import sys
import tempfile
import unittest
import urllib.error
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cli
import net_utils
import runner
import settings
import telegram
import uninstaller
from test_settings import sample


class UnixCustomerScenarioTests(unittest.TestCase):
    def test_item1_dirty_customer_inputs_normalized_before_validation(self):
        dirty = {
            "member": "\u200b  EmTroLy_01 \ufeff",
            "assistant_name": "\u200b  Trợ Lý Kế Toán  \u00a0",
            "owner_ids": " 8764883034 ; 8342048167,\n8764883034  \u200b",
            "group_id": " \u2013100 123 456 789 ",
            "telegram_token": "\u200bBot12345678:" + ("A" * 30) + "\ufeff ",
            "ai_api_key": "  sk-test-customer-key-123456 \u200b ",
            "model": " gpt-6.2-sol ",
            "base_url": "[Codex Router](https://codex.anhlaptrinh.vn/v1/)",
            "gateway_port": "  ",
            "qr_owner_id": "",
            "configure_zalo": True,
            "accept_full_access": True,
        }
        cleaned = settings.normalize(dirty)
        self.assertEqual(cleaned["member"], "emtroly_01")
        self.assertEqual(cleaned["telegram_token"], "12345678:" + ("A" * 30))
        self.assertEqual(cleaned["owner_ids"], "8764883034,8342048167")
        self.assertEqual(cleaned["group_id"], "-100123456789")
        self.assertEqual(cleaned["base_url"], "https://codex.anhlaptrinh.vn/v1")
        self.assertEqual(cleaned["gateway_port"], "0")
        self.assertEqual(cleaned["qr_owner_id"], "8764883034")

        validated = settings.validate(cleaned)
        self.assertEqual(validated["owner_ids"], ["8764883034", "8342048167"])
        self.assertEqual(validated["group_id"], "-100123456789")

        # Direct strict settings.validate contract remains unchanged
        strict_dup = sample()
        strict_dup["owner_ids"] = "12345,12345"
        with self.assertRaises(ValueError):
            settings.validate(strict_dup)

    def test_item2_telegram_privacy_mode_warning_and_bot_prefix_normalization(self):
        tok_with_prefix = "\u200bbot123456:" + ("x" * 30)

        def fake_api_privacy_on(token, method, body=None):
            self.assertEqual(token, "123456:" + ("x" * 30))
            if method == "getMe":
                return {
                    "is_bot": True,
                    "username": "emtroly_test_bot",
                    "can_read_all_group_messages": False,
                }
            if method == "getUpdates":
                return [
                    {
                        "message": {
                            "from": {"id": 8764883034, "is_bot": False, "first_name": "Anh"},
                            "chat": {"id": -10099887766, "type": "supergroup", "title": "Nhóm Công Việc"},
                        }
                    }
                ]
            return []

        with patch.object(telegram.net_utils, "urlopen_with_retry") as mock_open:
            def open_side_effect(req, **kwargs):
                url = req.full_url
                if url.endswith("/getMe"):
                    payload = {"ok": True, "result": fake_api_privacy_on("123456:" + ("x" * 30), "getMe")}
                else:
                    payload = {"ok": True, "result": fake_api_privacy_on("123456:" + ("x" * 30), "getUpdates")}
                resp = io.BytesIO(json.dumps(payload).encode("utf-8"))
                resp.__enter__ = lambda s=resp: s
                resp.__exit__ = lambda *a: False
                return resp

            mock_open.side_effect = open_side_effect
            info = telegram.fetch_ids_from_updates(tok_with_prefix)

        self.assertEqual(info["bot_username"], "@emtroly_test_bot")
        self.assertEqual(info["owner_id"], "8764883034")
        self.assertEqual(info["group_id"], "-10099887766")
        self.assertFalse(info["can_read_all_group_messages"])
        self.assertIn("/setprivacy", info["privacy_warning"])
        self.assertIn("Disable", info["privacy_warning"])
        self.assertEqual(telegram.privacy_warning({"is_bot": True, "can_read_all_group_messages": True}), "")

    def test_item3_incomplete_install_auto_recovery_and_safe_uninstall(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            member = "member01"
            root = home / f".openclaw-member-{member}"

            # 1. Arbitrary pre-existing user folder is NEVER treated as recoverable
            root.mkdir(mode=0o700)
            (root / "user-data.txt").write_text("keep-safe", encoding="utf-8")
            self.assertFalse(uninstaller.is_recoverable_incomplete_instance(root))

            # 2. Completed OpenClaw installation (openclaw.json without marker) is NEVER treated as recoverable
            (root / "user-data.txt").unlink()
            (root / "openclaw.json").write_text('{"gateway":{"port":19789}}\n', encoding="utf-8")
            self.assertFalse(uninstaller.is_recoverable_incomplete_instance(root))

            # 3. Interrupted installation with .emtroly-installing.json IS recoverable and archived safely
            uninstaller.write_installing_marker(root, member)
            self.assertTrue(uninstaller.is_recoverable_incomplete_instance(root))
            archived = uninstaller.archive_incomplete_instance(root, home)
            self.assertFalse(root.exists())
            self.assertTrue((archived / "openclaw.json").is_file())

            # 4. Partial runtime-only folder (no openclaw.json, only runtime/workspace) IS recoverable
            root.mkdir(mode=0o700)
            (root / "runtime").mkdir()
            (root / "workspace").mkdir()
            self.assertTrue(uninstaller.is_recoverable_incomplete_instance(root))

            # 5. Safe 1-click uninstall backs up config/profile, cleans shims & systemd unit, and removes root
            (root / "openclaw.json").write_text('{"gateway":{"port":19789}}\n', encoding="utf-8")
            (root / "workspace/CUSTOMER_PROFILE.md").write_text("# Ho so\n", encoding="utf-8")
            bin_dir = home / ".local/bin"
            bin_dir.mkdir(parents=True, exist_ok=True)
            (bin_dir / f"openclaw-member-{member}").write_text(f"#!/bin/sh\n# {root}\n", encoding="utf-8")
            (bin_dir / "openclaw").write_text(f"#!/bin/sh\nexport OPENCLAW_STATE_DIR={root}\n", encoding="utf-8")
            systemd_dir = home / ".config/systemd/user"
            systemd_dir.mkdir(parents=True, exist_ok=True)
            unit_file = systemd_dir / f"openclaw-gateway-member-{member}.service"
            unit_file.write_text("[Unit]\nDescription=Test\n", encoding="utf-8")

            with patch.object(uninstaller.platform, "system", return_value="Linux"), \
                    patch.object(uninstaller.shutil, "which", return_value=None):
                res = uninstaller.uninstall_instance(member, home=home)

            self.assertTrue(res["uninstalled"])
            self.assertFalse(root.exists())
            self.assertFalse((bin_dir / f"openclaw-member-{member}").exists())
            self.assertFalse((bin_dir / "openclaw").exists())
            self.assertFalse(unit_file.exists())
            backup_dir = Path(res["backup"])
            self.assertTrue((backup_dir / "openclaw.json").is_file())
            self.assertTrue((backup_dir / "CUSTOMER_PROFILE.md").is_file())
            if os.name != "nt":
                self.assertEqual(stat.S_IMODE((backup_dir / "openclaw.json").stat().st_mode), 0o600)

            # CLI --uninstall integration
            root.mkdir(mode=0o700)
            (root / "openclaw.json").write_text("{}\n", encoding="utf-8")
            with patch.object(cli, "preflight"), \
                    patch.object(uninstaller.Path, "home", return_value=home), \
                    patch.object(uninstaller.platform, "system", return_value="Darwin"), \
                    patch.object(uninstaller.shutil, "which", return_value=None):
                rc = cli.main(["--uninstall", member])
            self.assertEqual(rc, 0)
            self.assertFalse(root.exists())

    def test_item5_network_download_retry_backoff_and_ssl_ca_fallback(self):
        attempts = []

        def flaky_urlopen(url, timeout=60, context=None):
            attempts.append((url, context is not None))
            if len(attempts) == 1:
                raise urllib.error.URLError("temporary DNS failure")
            if len(attempts) == 2:
                raise urllib.error.HTTPError(url, 503, "Service Unavailable", hdrs=None, fp=None)
            return io.BytesIO(b"ok-payload")

        with patch.dict(os.environ, {"EMTROLY_RETRY_BACKOFF": "0"}), \
                patch.object(net_utils.urllib.request, "urlopen", side_effect=flaky_urlopen):
            resp = net_utils.urlopen_with_retry("https://nodejs.org/dist/test", timeout=15, retries=3, backoff=0)
            self.assertEqual(resp.read(), b"ok-payload")
        self.assertEqual(len(attempts), 3)

        # Non-retryable 404 fails immediately on attempt 1
        calls_404 = []

        def not_found(url, timeout=60):
            calls_404.append(url)
            raise urllib.error.HTTPError(url, 404, "Not Found", hdrs=None, fp=None)

        with patch.object(net_utils.urllib.request, "urlopen", side_effect=not_found):
            with self.assertRaises(urllib.error.HTTPError):
                net_utils.urlopen_with_retry("https://nodejs.org/dist/missing", timeout=15, retries=3, backoff=0)
        self.assertEqual(len(calls_404), 1)

        # SSL CERTIFICATE_VERIFY_FAILED falls back to system CA bundle automatically
        with tempfile.TemporaryDirectory() as td:
            fake_ca = Path(td) / "ca-certificates.crt"
            fake_ca.write_text("FAKE-CA", encoding="utf-8")
            ssl_calls = []

            def ssl_fallback_urlopen(url, timeout=60, context=None):
                ssl_calls.append(context)
                if context is None:
                    raise urllib.error.URLError(ssl.SSLCertVerificationError(1, "CERTIFICATE_VERIFY_FAILED"))
                return io.BytesIO(b"ssl-recovered")

            dummy_ctx = MagicMock(spec=ssl.SSLContext)
            with patch.dict(os.environ, {"SSL_CERT_FILE": str(fake_ca)}), \
                    patch.object(net_utils, "build_ssl_context", return_value=dummy_ctx), \
                    patch.object(net_utils.urllib.request, "urlopen", side_effect=ssl_fallback_urlopen):
                out = net_utils.urlopen_with_retry("https://pypi.org/pypi/imageio-ffmpeg/0.6.0/json", backoff=0)
                self.assertEqual(out.read(), b"ssl-recovered")
            self.assertEqual(len(ssl_calls), 2)
            self.assertIsNone(ssl_calls[0])
            self.assertIs(ssl_calls[1], dummy_ctx)

    def test_item6_disk_space_preflight_and_macos_quarantine_clearing(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td).resolve()
            with patch.dict(
                os.environ,
                {"EMTROLY_MIN_FREE_BYTES": "2000000000", "EMTROLY_SIMULATE_FREE_BYTES": "150000000"},
            ):
                with self.assertRaisesRegex(RuntimeError, "Ổ đĩa không đủ dung lượng trống"):
                    runner.check_disk_space(home)

            # macOS quarantine clearing invokes xattr -dr com.apple.quarantine on Darwin only
            binary = home / "ffmpeg"
            binary.write_text("bin", encoding="utf-8")
            with patch.object(net_utils.platform, "system", return_value="Darwin"), \
                    patch.object(net_utils.subprocess, "run") as mock_run:
                self.assertTrue(net_utils.clear_macos_quarantine(binary))
                mock_run.assert_called_once()
                self.assertEqual(mock_run.call_args[0][0][:3], ["xattr", "-dr", "com.apple.quarantine"])

            with patch.object(net_utils.platform, "system", return_value="Linux"), \
                    patch.object(net_utils.subprocess, "run") as mock_run_linux:
                self.assertFalse(net_utils.clear_macos_quarantine(binary))
                mock_run_linux.assert_not_called()

    def test_license_sign_out_locks_ui_only_and_forces_reentry_across_restarts(self):
        import codex_setup
        import license_gate

        with tempfile.TemporaryDirectory() as td:
            cfg_dir = Path(td) / "xdg"
            home = Path(td) / "home"
            cfg_dir.mkdir()
            home.mkdir()
            # Existing background OpenClaw & Codex secrets must stay untouched on UI sign-out
            oc_secret = home / ".openclaw-member-emtroly/member-provider.secret"
            oc_secret.parent.mkdir(parents=True)
            oc_secret.write_text("sk-running-bot-secret\n", encoding="utf-8")
            codex_auth = codex_setup.codex_home_dir(home) / "auth.json"
            codex_auth.parent.mkdir(parents=True)
            codex_auth.write_text('{"OPENAI_API_KEY":"sk-running-bot-secret"}\n', encoding="utf-8")

            with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(cfg_dir), "EMTROLY_TEST_MACHINE_ID": "mac-signout-1"}):
                license_gate.save_license_key("sk-codex-anhlaptrinh-key-1")
                license_gate.save_setup_draft(
                    {
                        "member": "emtroly",
                        "assistant_name": "Trợ Lý Của Anh",
                        "owner_ids": "8764883034",
                        "ai_api_key": "sk-codex-anhlaptrinh-key-1",
                    }
                )
                self.assertEqual(license_gate.get_saved_license_key(), "sk-codex-anhlaptrinh-key-1")
                self.assertFalse(license_gate.is_signed_out())

                # Sign out via CLI --logout-license
                rc = cli.main(["--logout-license"])
                self.assertEqual(rc, 0)
                self.assertTrue(license_gate.is_signed_out())
                self.assertEqual(license_gate.get_saved_license_key(), "")

                # Draft preserves non-secret fields but clears ai_api_key
                draft_after = license_gate.get_saved_setup_draft()
                self.assertIsNotNone(draft_after)
                self.assertEqual(draft_after["ai_api_key"], "")
                self.assertEqual(draft_after["owner_ids"], "8764883034")

                # Background OpenClaw & Codex CLI files remain 100% untouched
                self.assertEqual(oc_secret.read_text(encoding="utf-8").strip(), "sk-running-bot-secret")
                self.assertIn("sk-running-bot-secret", codex_auth.read_text(encoding="utf-8"))

                # Re-entering a new verified codex.anhlaptrinh.vn key clears signed-out flag
                license_gate.save_license_key("sk-codex-anhlaptrinh-key-2")
                self.assertFalse(license_gate.is_signed_out())
                self.assertEqual(license_gate.get_saved_license_key(), "sk-codex-anhlaptrinh-key-2")

    def test_modular_install_components_without_telegram_for_codex_and_antigravity(self):
        import codex_setup
        import license_gate

        with tempfile.TemporaryDirectory() as td:
            home = Path(td).resolve()
            cfg_dir = home / ".config"
            fake_node = home / "node"
            fake_npm = home / "npm"
            fake_codex = codex_setup.data_root(home) / "codex-cli/node_modules/.bin/codex"
            fake_ide = home / "antigravity-cli"
            for f in (fake_node, fake_npm, fake_ide):
                f.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                f.chmod(0o755)
            fake_codex.parent.mkdir(parents=True, exist_ok=True)
            fake_codex.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_codex.chmod(0o755)

            ai_only_values = {
                "ai_api_key": "sk-modular-codex-key",
                "model": "gpt-6.2-sol",
                "base_url": "https://codex.anhlaptrinh.vn/v1",
                # Notice: NO telegram_token, NO owner_ids, NO group_id!
            }
            source = Path(__file__).resolve().parent.parent
            with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(cfg_dir), "EMTROLY_ANTIGRAVITY_CLI": str(fake_ide)}), \
                    patch.object(runner.os, "geteuid", return_value=1000, create=True), \
                    patch.object(runner.platform, "system", return_value="Linux"), \
                    patch.object(runner.Path, "home", return_value=home), \
                    patch.object(runner.provider, "verify", return_value="gpt-6.2-sol"), \
                    patch.object(runner.dependencies, "install_node", return_value=(fake_node, fake_npm)), \
                    patch.object(codex_setup.subprocess, "run", return_value=MagicMock(returncode=0, stdout="", stderr="")):
                res = runner.install_components(
                    ["codex-cli", "antigravity-ide", "codex-extension"],
                    ai_only_values,
                    source,
                )

            self.assertEqual(res["components"], ["codex-cli", "antigravity-ide", "codex-extension"])
            self.assertTrue(res["codex"]["installed"])
            self.assertTrue(res["antigravity_ide"]["installed"])
            self.assertTrue(res["codex_extension"]["configured"])

            # Verify get_modular_status reflects installed state
            with patch.dict(os.environ, {"EMTROLY_ANTIGRAVITY_CLI": str(fake_ide)}):
                ext_marker = codex_setup.data_root(home) / "antigravity/Extensions/openai.chatgpt-26.51111.21308"
                ext_marker.mkdir(parents=True, exist_ok=True)
                st = codex_setup.get_modular_status(home)
                self.assertTrue(st["codex_cli"]["installed"])
                self.assertTrue(st["antigravity_ide"]["installed"])
                self.assertTrue(st["codex_extension"]["installed"])
                self.assertFalse(st["openclaw"]["installed"])

    def test_factory_reset_wipes_all_unix_state_and_preserves_non_emtroly_files(self):
        import codex_setup
        import license_gate

        with tempfile.TemporaryDirectory() as td:
            home = Path(td).resolve()
            cfg_dir = home / ".config"

            # Seed OpenClaw instance, Codex CLI, Antigravity profile/launcher, shims, .bashrc block, license & draft
            oc_root = home / ".openclaw-member-emtroly"
            (oc_root / "workspace").mkdir(parents=True)
            (oc_root / "openclaw.json").write_text('{"gateway":{"port":19789}}\n', encoding="utf-8")

            em_share = codex_setup.data_root(home)
            (em_share / "codex-home").mkdir(parents=True)
            (em_share / "codex-cli/node_modules/.bin").mkdir(parents=True)
            (em_share / "antigravity/Extensions/openai.chatgpt-26.51111.21308").mkdir(parents=True)
            (em_share / "dependencies/node-v24.21.0").mkdir(parents=True)
            (em_share / "codex-home/config.toml").write_text('model = "gpt-6.2-sol"\n', encoding="utf-8")
            (em_share / "codex-home/auth.json").write_text('{"OPENAI_API_KEY":"sk-unix-reset"}\n', encoding="utf-8")

            bin_dir = home / ".local/bin"
            bin_dir.mkdir(parents=True)
            (bin_dir / "openclaw-member-emtroly").write_text(f"#!/bin/sh\n# {oc_root}\n", encoding="utf-8")
            (bin_dir / "openclaw").write_text(f"#!/bin/sh\nexport OPENCLAW_STATE_DIR={oc_root}\n", encoding="utf-8")
            (bin_dir / "codex-emtroly").write_text("#!/bin/sh\nexport CODEX_HOME=...\n", encoding="utf-8")
            (bin_dir / "codex").write_text("#!/bin/sh\nexport CODEX_HOME=...\n", encoding="utf-8")
            (bin_dir / "my-personal-script").write_text("#!/bin/sh\necho keep\n", encoding="utf-8")

            bashrc = home / ".bashrc"
            bashrc.write_text(
                'export EDITOR=vim\n\n'
                '# >>> installer_emtroly PATH >>>\n'
                'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$PATH:$HOME/.local/bin" ;; esac\n'
                '# <<< installer_emtroly PATH <<<\n',
                encoding="utf-8",
            )

            mac_launcher = home / "Applications/EmTroLy - Antigravity.command"
            mac_launcher.parent.mkdir(parents=True)
            mac_launcher.write_text("#!/bin/sh\n", encoding="utf-8")
            linux_desktop = home / ".local/share/applications/emtroly-antigravity.desktop"
            linux_desktop.parent.mkdir(parents=True)
            linux_desktop.write_text("[Desktop Entry]\n", encoding="utf-8")

            with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(cfg_dir), "EMTROLY_TEST_MACHINE_ID": "unix-reset-1"}):
                license_gate.save_license_key("sk-unix-reset-key-123")
                license_gate.save_setup_draft({"member": "emtroly", "owner_ids": "8764883034", "ai_api_key": "sk-unix-reset-key-123"})
                self.assertTrue(uninstaller.has_any_emtroly_footprint(home=home, config_home=cfg_dir))

                with patch.object(cli.os, "geteuid", return_value=1000, create=True), \
                        patch.object(uninstaller.Path, "home", return_value=home), \
                        patch.object(uninstaller.platform, "system", return_value="Linux"), \
                        patch.object(uninstaller.shutil, "which", return_value=None):
                    rc = cli.main(["--reset-all"])

                self.assertEqual(rc, 0)
                self.assertFalse(uninstaller.has_any_emtroly_footprint(home=home, config_home=cfg_dir))
                self.assertEqual(license_gate.get_saved_license_key(), "")
                self.assertIsNone(license_gate.get_saved_setup_draft())
                self.assertFalse(oc_root.exists())
                self.assertFalse(em_share.exists())
                self.assertFalse(mac_launcher.exists())
                self.assertFalse(linux_desktop.exists())
                self.assertFalse((bin_dir / "openclaw").exists())
                self.assertFalse((bin_dir / "codex-emtroly").exists())
                self.assertFalse((bin_dir / "codex").exists())
                self.assertTrue((bin_dir / "my-personal-script").is_file())
                rc_after = bashrc.read_text(encoding="utf-8")
                self.assertIn("export EDITOR=vim", rc_after)
                self.assertNotIn("installer_emtroly PATH", rc_after)


if __name__ == "__main__":
    unittest.main()
