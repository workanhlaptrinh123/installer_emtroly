import base64
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
QR_BRIDGE = ROOT / "windows-installer/zalo-qr-session.mjs"
VALIDATION = ROOT / "windows-installer/validation.ps1"
NODE = shutil.which("node")
WIN_POWERSHELL = (
    Path(os.environ.get("SystemRoot", r"C:\Windows"))
    / "System32/WindowsPowerShell/v1.0/powershell.exe"
)
SHELL = str(WIN_POWERSHELL) if WIN_POWERSHELL.is_file() else (os.environ.get("PWSH") or shutil.which("pwsh"))

# Minimal valid 1x1 PNG bytes
VALID_1X1_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
)


@unittest.skipUnless(NODE, "Node.js is required")
class ZaloQrDualDeliveryTests(unittest.TestCase):
    def test_zalo_qr_bridge_renders_gui_png_sends_telegram_photo_and_notifies_on_scan(self):
        received = {"photos": [], "messages": []}

        class MockTelegramHandler(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                if self.path.endswith("/sendPhoto"):
                    received["photos"].append(body)
                    resp = {"ok": True, "result": {"message_id": 101}}
                elif self.path.endswith("/sendMessage"):
                    received["messages"].append(json.loads(body.decode("utf-8")))
                    resp = {"ok": True, "result": {"message_id": 102}}
                else:
                    resp = {"ok": False, "description": "unknown"}
                raw = json.dumps(resp).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def log_message(self, format, *args):
                return

        server = HTTPServer(("127.0.0.1", 0), MockTelegramHandler)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        try:
            with tempfile.TemporaryDirectory(prefix="emtroly-zaloqr-test-") as temporary:
                temp = Path(temporary)
                oc_root = temp / "openclaw"
                runtime_dir = oc_root / "runtime/2026.11.4/node_modules/openclaw"
                runtime_dir.mkdir(parents=True)

                src_qr = temp / "generated-zalouser-qr.png"
                src_qr.write_bytes(VALID_1X1_PNG)

                fake_cli = runtime_dir / "openclaw.mjs"
                fake_cli.write_text(
                    "const args = process.argv.slice(2);\n"
                    "if (args[0] === 'gateway' && args[1] === 'call') {\n"
                    "  const method = args[2];\n"
                    "  if (method === 'channels.status') console.log(JSON.stringify({channels:{zalouser:{running:true}}}));\n"
                    "  else console.log(JSON.stringify({ok:true}));\n"
                    "  process.exit(0);\n"
                    "}\n"
                    "if (args[0] === 'channels' && args[1] === 'login') {\n"
                    f"  console.log('Scan QR image: {str(src_qr).replace(chr(92), chr(92)*2)}');\n"
                    "  setTimeout(() => {\n"
                    "    console.log('Login successful.');\n"
                    "    process.exit(0);\n"
                    "  }, 500);\n"
                    "}\n",
                    encoding="utf-8",
                )

                secret_token = "888999:SECRET_BOT_TOKEN_ZALOQR_TEST_123456"
                owner_id = "6980864856"
                (oc_root / "telegram.token").write_text(secret_token + "\n", encoding="utf-8")
                (oc_root / "openclaw.json").write_text(
                    json.dumps({"commands": {"ownerAllowFrom": [f"telegram:{owner_id}"]}}),
                    encoding="utf-8",
                )
                (oc_root / "installer-instance.json").write_text(
                    json.dumps({"cli_entry": str(fake_cli)}),
                    encoding="utf-8",
                )

                state_file = temp / "state.json"
                qr_out = temp / "gui-qr.png"
                env = {
                    **os.environ,
                    "EMTROLY_TELEGRAM_API_BASE": f"http://127.0.0.1:{port}",
                }
                proc = subprocess.run(
                    [
                        NODE,
                        str(QR_BRIDGE),
                        "--root",
                        str(oc_root),
                        "--state-file",
                        str(state_file),
                        "--qr-out",
                        str(qr_out),
                        "--owner-id",
                        owner_id,
                        "--timeout-seconds",
                        "20",
                    ],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertTrue(qr_out.is_file(), "QR PNG must be written for WPF GUI display")
                self.assertEqual(qr_out.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")

                state = json.loads(state_file.read_text(encoding="utf-8"))
                self.assertEqual(state["phase"], "connected")
                self.assertTrue(state["connected"])
                self.assertTrue(state["telegramSent"])

                # Verify persistent Zalo connected status cache written for instant GUI connected badge
                persisted_status = json.loads((oc_root / "state/emtroly-zalo-status.json").read_text(encoding="utf-8"))
                self.assertTrue(persisted_status["linked"])
                self.assertTrue(persisted_status["connected"])

                # Verify QR image AND completion notification were both sent to Telegram Owner ID
                self.assertEqual(len(received["photos"]), 1)
                self.assertIn(owner_id.encode("ascii"), received["photos"][0])
                self.assertIn(b"\x89PNG\r\n\x1a\n", received["photos"][0])
                self.assertEqual(len(received["messages"]), 1)
                self.assertEqual(received["messages"][0]["chat_id"], owner_id)
                self.assertIn("thành công", received["messages"][0]["text"])

                # Verify zero token leak
                combined = state_file.read_text(encoding="utf-8") + proc.stdout + proc.stderr
                self.assertNotIn(secret_token, combined)
        finally:
            server.shutdown()
            server.server_close()

    def test_sync_status_mode_updates_dashboard_connected_state(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-zalosync-test-") as temporary:
            temp = Path(temporary)
            oc_root = temp / "openclaw"
            runtime_dir = oc_root / "runtime/2026.11.4/node_modules/openclaw"
            runtime_dir.mkdir(parents=True)
            (oc_root / "workspace/skills/telegram-zalo-owner-login").mkdir(parents=True)
            (oc_root / "workspace/skills/telegram-zalo-owner-login/SKILL.md").write_text("# skill\n", encoding="utf-8")

            fake_cli = runtime_dir / "openclaw.mjs"
            fake_cli.write_text(
                "const args = process.argv.slice(2);\n"
                "if (args[0] === 'gateway' && args[1] === 'health') {\n"
                "  console.log(JSON.stringify({\n"
                "    ok: true,\n"
                "    channels: {\n"
                "      telegram: { running: true },\n"
                "      zalouser: { linked: true, running: true, connected: true, accounts: { default: { linked: true, connected: true, running: true } } }\n"
                "    }\n"
                "  }));\n"
                "  process.exit(0);\n"
                "}\n",
                encoding="utf-8",
            )
            (oc_root / "openclaw.json").write_text(
                json.dumps({"commands": {"ownerAllowFrom": ["telegram:123456789"]}, "gateway": {"port": 19789}}),
                encoding="utf-8",
            )
            (oc_root / "installer-instance.json").write_text(
                json.dumps({"cli_entry": str(fake_cli)}),
                encoding="utf-8",
            )

            proc = subprocess.run(
                [NODE, str(QR_BRIDGE), "--sync-status", "--root", str(oc_root)],
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            synced = json.loads((oc_root / "state/emtroly-zalo-status.json").read_text(encoding="utf-8"))
            self.assertTrue(synced["linked"])
            self.assertTrue(synced["connected"])

            if SHELL and os.name == "nt":
                probe = temp / "check-dash.ps1"
                manage_ps1 = ROOT / "windows-installer/manage-instance.ps1"
                helpers_ps1 = ROOT / "windows-installer/wizard-helpers.ps1"
                probe.write_text(
                    f'$env:USERPROFILE = "{temp}"\n'
                    f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{manage_ps1}", [Text.Encoding]::UTF8)))\n'
                    f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{helpers_ps1}", [Text.Encoding]::UTF8)))\n'
                    "$d = Get-EmTroLyLiveDashboardStatus\n"
                    "if (-not $d.ZaloLinked -or -not $d.ZaloConnected) { throw 'zalo-not-detected-connected' }\n",
                    encoding="utf-8-sig",
                )
                ps_res = subprocess.run(
                    [SHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(probe)],
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                self.assertEqual(ps_res.returncode, 0, ps_res.stdout + ps_res.stderr)


class LicenseAuthorityGateTests(unittest.TestCase):
    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_license_gate_accepts_valid_codex_key_and_locks_down_on_revocation(self):
        state = {"revoked": False}

        class MockProviderHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                auth = self.headers.get("Authorization", "")
                if state["revoked"] or auth != "Bearer sk-valid-anhlaptrinh-customer":
                    raw = json.dumps({"error": {"message": "Invalid API Key"}}).encode("utf-8")
                    self.send_response(401)
                else:
                    raw = json.dumps({"data": [{"id": "gpt-6.2-sol"}, {"id": "gpt-6.2-astra"}]}).encode("utf-8")
                    self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def log_message(self, format, *args):
                return

        server = HTTPServer(("127.0.0.1", 0), MockProviderHandler)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix="emtroly-lic-test-") as temporary:
                temp = Path(temporary)
                helpers_ps1 = ROOT / "windows-installer/wizard-helpers.ps1"
                probe = temp / "lic-probe.ps1"
                probe.write_text(
                    f'$env:USERPROFILE = "{temp / "home"}"\n'
                    f'$env:LOCALAPPDATA = "{temp / "local"}"\n'
                    f'$env:EMTROLY_LICENSE_API_BASE = "http://127.0.0.1:{port}/v1"\n'
                    f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{helpers_ps1}", [Text.Encoding]::UTF8)))\n'
                    "$badDomain = Test-EmTroLyLicenseKey -ApiKey 'sk-valid-anhlaptrinh-customer' -AuthorityBaseUrl 'https://api.openai.com/v1'\n"
                    "if ($badDomain.Valid) { throw 'external-domain-must-be-rejected' }\n"
                    "$ok = Test-EmTroLyLicenseKey -ApiKey 'sk-valid-anhlaptrinh-customer'\n"
                    "if (-not $ok.Valid -or $ok.Revoked) { throw ('valid-key-rejected:' + $ok.Message) }\n"
                    "Save-EmTroLyLicenseKey -ApiKey 'sk-valid-anhlaptrinh-customer'\n"
                    "if ((Get-EmTroLySavedLicenseKey) -cne 'sk-valid-anhlaptrinh-customer') { throw 'saved-key-mismatch' }\n"
                    "$bad = Test-EmTroLyLicenseKey -ApiKey 'sk-wrong-key'\n"
                    "if ($bad.Valid -or -not $bad.Revoked) { throw 'wrong-key-not-flagged-revoked' }\n"
                    "Invoke-EmTroLyRevokeLockdown\n"
                    "if ((Get-EmTroLySavedLicenseKey) -ne '') { throw 'revoked-key-not-cleared' }\n",
                    encoding="utf-8-sig",
                )
                res = subprocess.run(
                    [SHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(probe)],
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        finally:
            server.shutdown()
            server.server_close()


class LatestModelsValidationTests(unittest.TestCase):
    def test_unix_settings_accept_three_latest_models_only(self):
        sys.path.insert(0, str(ROOT / "unix-installer"))
        try:
            import settings as unix_settings

            for valid_model in ("gpt-6.2-sol", "GPT-6.1-terra", "gpt-6.2-astra"):
                cfg = {
                    "member": "emtroly",
                    "assistant_name": "Em Trợ Lý",
                    "owner_ids": "123456789",
                    "group_id": "-100123456",
                    "telegram_token": "123456:ABCDEFGHIJKLMNOPQRSTUVWXYZ12345",
                    "ai_api_key": "sk-test-key-123456",
                    "model": valid_model,
                    "base_url": "https://codex.anhlaptrinh.vn/v1",
                    "gateway_port": "0",
                    "accept_full_access": True,
                    "configure_zalo": False,
                }
                checked = unix_settings.validate(cfg)
                self.assertEqual(checked["model"], valid_model)

            old_cfg = dict(cfg, model="gpt-6.1-sol")
            with self.assertRaises(ValueError):
                unix_settings.validate(old_cfg)
        finally:
            sys.path.pop(0)

    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_windows_validation_accepts_three_latest_models(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-models-ps-") as temporary:
            probe = Path(temporary) / "probe.ps1"
            probe.write_text(
                f'. "{VALIDATION}"\n'
                "foreach ($m in @('gpt-6.2-sol', 'GPT-6.1-terra', 'gpt-6.2-astra')) {\n"
                "  $s = [pscustomobject]@{\n"
                "    member = 'emtroly'; assistant_name = 'Em Trợ Lý'; owner_ids = '123456789'; group_id = '-100123456';\n"
                "    telegram_token = '123456:ABCDEFGHIJKLMNOPQRSTUVWXYZ12345'; ai_api_key = 'sk-test';\n"
                "    model = $m; base_url = 'https://codex.anhlaptrinh.vn/v1'; gateway_port = '0';\n"
                "    accept_full_access = $true; configure_zalo = $false; qr_owner_id = ''\n"
                "  }\n"
                "  Test-MemberInstallerSettings $s\n"
                "}\n",
                encoding="utf-8-sig",
            )
            res = subprocess.run(
                [SHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(probe)],
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)


if __name__ == "__main__":
    unittest.main()
