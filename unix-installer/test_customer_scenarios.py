"""Unit tests for all customer failure-mode hardening items on macOS & Linux."""

from __future__ import annotations

import http.client
import io
import json
import os
from pathlib import Path
import ssl
import stat
import tempfile
import unittest
import urllib.error
from unittest.mock import MagicMock, patch

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


if __name__ == "__main__":
    unittest.main()
