"""End-to-end unit & component tests for the 8 real-world customer failure modes on Windows."""

from __future__ import annotations

import base64
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SHELL = (
    shutil.which("powershell.exe")
    or (str(Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/WindowsPowerShell/v1.0/powershell.exe"))
)
NODE = shutil.which("node.exe") or shutil.which("node")

TINY_PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="


def run_ps(command: str, env: dict | None = None, timeout: int = 45) -> subprocess.CompletedProcess:
    return subprocess.run(
        [SHELL, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command],
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
    )


@unittest.skipUnless(os.name == "nt" and Path(SHELL).is_file(), "Requires Windows PowerShell")
class WindowsCustomerScenarioTests(unittest.TestCase):
    def test_item1_dirty_customer_inputs_normalized_and_pass_strict_validation(self):
        helpers = ROOT / "windows-installer/wizard-helpers.ps1"
        validation = ROOT / "windows-installer/validation.ps1"
        res = run_ps(
            f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{helpers}", [Text.Encoding]::UTF8)))\n'
            f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{validation}", [Text.Encoding]::UTF8)))\n'
            "$ErrorActionPreference = 'Stop'\n"
            "$dirty = [pscustomobject]@{\n"
            "  member = \"\u200b  EmTroLy  \ufeff\"\n"
            "  assistant_name = \"\u200b Trợ Lý Của Anh \u00a0\"\n"
            "  telegram_token = \"\u200bbot12345678:ABCDEFGHIJKLMNOPQRSTUVWX_12345\ufeff \"\n"
            "  ai_api_key = \"  sk-live-customer-key-99999\u200b \"\n"
            "  owner_ids = \" 8764883034 ; 8342048167,`r`n8764883034 \"\n"
            "  group_id = \" \u2013100 987 654 321 \"\n"
            "  base_url = '[Router](https://codex.anhlaptrinh.vn/v1/)'\n"
            "  model = ' gpt-6.2-sol '\n"
            "  gateway_port = '  '\n"
            "  qr_owner_id = ''\n"
            "  configure_zalo = $true\n"
            "  accept_full_access = $true\n"
            "}\n"
            "$clean = Normalize-EmTroLyCustomerInputs -Inputs $dirty\n"
            "if ($clean.telegram_token -cne '12345678:ABCDEFGHIJKLMNOPQRSTUVWX_12345') { throw ('bad-tok:' + $clean.telegram_token) }\n"
            "if ($clean.owner_ids -cne '8764883034,8342048167') { throw ('bad-owners:' + $clean.owner_ids) }\n"
            "if ($clean.group_id -cne '-100987654321') { throw ('bad-group:' + $clean.group_id) }\n"
            "if ($clean.base_url -cne 'https://codex.anhlaptrinh.vn/v1') { throw ('bad-url:' + $clean.base_url) }\n"
            "if ($clean.qr_owner_id -cne '8764883034') { throw ('bad-qr:' + $clean.qr_owner_id) }\n"
            "if ($clean.gateway_port -cne '0') { throw ('bad-port:' + $clean.gateway_port) }\n"
            "Test-MemberInstallerSettings -Settings $clean\n"
            "Write-Output 'ITEM1_NORMALIZE_OK'\n"
        )
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("ITEM1_NORMALIZE_OK", res.stdout)

    def test_item2_telegram_privacy_warning_and_qr_dm_not_started_hint(self):
        helpers = ROOT / "windows-installer/wizard-helpers.ps1"
        res = run_ps(
            f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{helpers}", [Text.Encoding]::UTF8)))\n'
            "$ErrorActionPreference = 'Stop'\n"
            "function Invoke-RestMethod { param($Uri, $Method, $Headers, $TimeoutSec, $MaximumRedirection, [switch]$UseBasicParsing)\n"
            "  if ($Uri -like '*/getMe') {\n"
            "    return [pscustomobject]@{ ok = $true; result = [pscustomobject]@{ is_bot = $true; username = 'test_priv_bot'; can_read_all_group_messages = $false } }\n"
            "  }\n"
            "  if ($Uri -like '*/getUpdates*') {\n"
            "    return [pscustomobject]@{ ok = $true; result = @([pscustomobject]@{ message = [pscustomobject]@{ from = [pscustomobject]@{ id = 8764883034; is_bot = $false; first_name = 'Anh' }; chat = [pscustomobject]@{ id = -100112233; type = 'supergroup'; title = 'Team' } } }) }\n"
            "  }\n"
            "  if ($Uri -like '*/models') {\n"
            "    return [pscustomobject]@{ data = @([pscustomobject]@{ id = 'gpt-6.2-sol' }) }\n"
            "  }\n"
            "}\n"
            "$ids = Get-TelegramIdsFromBotUpdates -TelegramToken 'bot12345678:ABCDEFGHIJKLMNOPQRSTUVWX_12345'\n"
            "if (-not $ids.Ok -or $ids.CanReadAllGroupMessages -ne $false) { throw 'expected-privacy-false' }\n"
            "if ($ids.PrivacyWarning -notmatch '/setprivacy' -or $ids.Message -notmatch 'Disable') { throw ('missing-privacy-note:' + $ids.Message) }\n"
            "$live = Test-EmTroLyLiveCredentials -TelegramToken 'bot12345678:ABCDEFGHIJKLMNOPQRSTUVWX_12345' -ApiKey 'sk-test' -Model 'gpt-6.2-sol'\n"
            "if (-not $live.AllOk -or $live.Summary -notmatch '/setprivacy') { throw ('missing-live-privacy:' + $live.Summary) }\n"
            "Write-Output 'ITEM2_PS_PRIVACY_OK'\n"
        )
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("ITEM2_PS_PRIVACY_OK", res.stdout)

        if NODE:
            # Verify index.mjs formatTelegramSendFailureHint & zalo-qr-session.mjs 400 chat not found handling
            with tempfile.TemporaryDirectory(prefix="emtroly-qr-dm-") as td:
                temp = Path(td)
                oc_root = temp / "openclaw"
                (oc_root / "runtime/2026.11.4/node_modules/openclaw").mkdir(parents=True)
                cli_mjs = oc_root / "runtime/2026.11.4/node_modules/openclaw/openclaw.mjs"
                cli_mjs.write_text(
                    'const args = process.argv.slice(2);\n'
                    'if (args[0] === "gateway" && args[1] === "call") {\n'
                    '  const method = args[2];\n'
                    '  if (method === "channels.status") { console.log(JSON.stringify({channels:{zalouser:{running:false}}})); process.exit(0); }\n'
                    f'  if (method === "web.login.start") {{ console.log(JSON.stringify({{qrDataUrl:"data:image/png;base64,{TINY_PNG_B64}"}})); process.exit(0); }}\n'
                    '  if (method === "web.login.wait") { console.log(JSON.stringify({connected:false, message:"expired"})); process.exit(0); }\n'
                    '}\n'
                    'process.exit(0);\n',
                    encoding="utf-8",
                )
                (oc_root / "openclaw.json").write_text(
                    json.dumps({"commands": {"ownerAllowFrom": ["telegram:8764883034"]}}),
                    encoding="utf-8",
                )
                (oc_root / "telegram.token").write_text("12345678:ABCDEFGHIJKLMNOPQRSTUVWX_12345\n", encoding="utf-8")

                class Tg400Handler(http.server.BaseHTTPRequestHandler):
                    def do_POST(self):
                        length = int(self.headers.get("Content-Length", "0"))
                        if length > 0:
                            _ = self.rfile.read(length)
                        body = json.dumps({"ok": False, "error_code": 400, "description": "Bad Request: chat not found"}).encode("utf-8")
                        self.send_response(400)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)

                    def log_message(self, *args):
                        pass

                server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Tg400Handler)
                port = server.server_address[1]
                t = threading.Thread(target=server.serve_forever, daemon=True)
                t.start()
                try:
                    state_file = temp / "state.json"
                    qr_png = temp / "qr.png"
                    env = {**os.environ, "EMTROLY_TELEGRAM_API_BASE": f"http://127.0.0.1:{port}"}
                    proc = subprocess.run(
                        [
                            NODE,
                            str(ROOT / "windows-installer/zalo-qr-session.mjs"),
                            "--root", str(oc_root),
                            "--state-file", str(state_file),
                            "--qr-out", str(qr_png),
                            "--force",
                            "--timeout-seconds", "8",
                        ],
                        env=env,
                        capture_output=True,
                        text=True,
                        timeout=20,
                    )
                    self.assertTrue(qr_png.is_file())
                    st = json.loads(state_file.read_text(encoding="utf-8"))
                    self.assertIn("/start", st.get("telegramNote", ""))
                    self.assertFalse(st.get("telegramSent", True))
                finally:
                    server.shutdown()
                    server.server_close()

                # Also verify index.mjs exported formatTelegramSendFailureHint
                skill_stage = temp / "skill"
                skill_stage.mkdir()
                shutil.copy2(ROOT / "native/skills/telegram-zalo-owner-login/assets/index.mjs", skill_stage / "index.mjs")
                (skill_stage / "settings.json").write_text(
                    json.dumps({"pluginId": "telegram-zalo-owner-login", "runtimeRoot": str(oc_root), "runtimeHome": str(temp), "telegramAccount": "emtroly", "zaloAccount": "default", "agentId": "main"}),
                    encoding="utf-8",
                )
                hint_proc = subprocess.run(
                    [
                        NODE,
                        "--input-type=module",
                        "-e",
                        f'import {{ formatTelegramSendFailureHint }} from {(skill_stage / "index.mjs").as_uri()!r};'
                        'const h = formatTelegramSendFailureHint("Forbidden: bot was blocked by the user", "8764883034");'
                        'if (!h.includes("/start")) process.exit(1);'
                        'console.log("HINT_OK");',
                    ],
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                self.assertEqual(hint_proc.returncode, 0, hint_proc.stdout + hint_proc.stderr)
                self.assertIn("HINT_OK", hint_proc.stdout)

    def test_item3_incomplete_recovery_detection_and_1click_uninstall_instance(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-uninst-") as td:
            temp = Path(td)
            home = temp / "home"
            local = temp / "local"
            startup = temp / "startup"
            for d in (home, local, startup):
                d.mkdir(parents=True)

            # 1. Verify recoverable vs protected openclaw directories
            oc = home / "openclaw"
            oc.mkdir()
            (oc / "user-data.txt").write_text("protect-me", encoding="utf-8")

            runner_txt = (ROOT / "windows-installer/run-native-install.ps1").read_text(encoding="utf-8-sig")
            fn_end = runner_txt.index("try {\n  try {") if "try {\n  try {" in runner_txt else runner_txt.index("try {\r\n  try {")
            # Extract Test-IsRecoverableIncompleteOpenClawDir directly
            fn_start = runner_txt.index("function Test-IsRecoverableIncompleteOpenClawDir")
            extracted_fns = runner_txt[fn_start:fn_end]
            fn_file = temp / "recover-fns.ps1"
            fn_file.write_text(extracted_fns, encoding="utf-8-sig")

            probe_res = run_ps(
                f'. "{fn_file}"\n'
                "$ErrorActionPreference = 'Stop'\n"
                f"if (Test-IsRecoverableIncompleteOpenClawDir '{oc}') {{ throw 'user-file-marked-recoverable' }}\n"
                f"Remove-Item -LiteralPath '{oc / 'user-data.txt'}' -Force\n"
                f"[void][IO.Directory]::CreateDirectory('{oc / 'runtime'}')\n"
                f"if (-not (Test-IsRecoverableIncompleteOpenClawDir '{oc}')) {{ throw 'partial-runtime-not-recoverable' }}\n"
                f"[IO.File]::WriteAllText('{oc / 'openclaw.json'}', '{{}}')\n"
                f"if (Test-IsRecoverableIncompleteOpenClawDir '{oc}') {{ throw 'complete-instance-marked-recoverable' }}\n"
                f"[IO.File]::WriteAllText('{oc / '.emtroly-installing.json'}', '{{}}')\n"
                f"if (-not (Test-IsRecoverableIncompleteOpenClawDir '{oc}')) {{ throw 'marker-instance-not-recoverable' }}\n"
                "Write-Output 'RECOVER_LOGIC_OK'\n"
            )
            self.assertEqual(probe_res.returncode, 0, probe_res.stdout + probe_res.stderr)
            self.assertIn("RECOVER_LOGIC_OK", probe_res.stdout)

            # 2. Verify 1-click uninstall-instance in manage-instance.ps1
            (oc / ".emtroly-installing.json").unlink()
            (oc / "workspace").mkdir(exist_ok=True)
            (oc / "openclaw.json").write_text('{"gateway":{"port":19789}}\n', encoding="utf-8")
            (oc / "workspace/CUSTOMER_PROFILE.md").write_text("Ten tro ly: Test\n", encoding="utf-8")
            (oc / "openclaw-instance.ps1").write_text("exit 0\n", encoding="utf-8-sig")
            vbs = startup / "OpenClaw-member-emtroly.vbs"
            vbs.write_text(f'CreateObject("WScript.Shell").Run "{oc}\\openclaw-instance.ps1", 0, False', encoding="utf-16")
            oc_bin = local / "OpenClaw/bin"
            oc_bin.mkdir(parents=True)
            (oc_bin / "openclaw.cmd").write_text(f'@echo off\r\nset "OPENCLAW_STATE_DIR={oc}"\r\n', encoding="utf-8")
            em_keep = local / "EmTroLy/Codex"
            em_keep.mkdir(parents=True)
            (em_keep / "config.toml").write_text('model = "gpt-6.2-sol"\n', encoding="utf-8")

            req_file = temp / "uninstall-req.json"
            status_file = temp / "uninstall-status.txt"
            req_file.write_text(json.dumps({"action": "uninstall-instance"}), encoding="utf-8")
            env = {
                **os.environ,
                "USERPROFILE": str(home),
                "LOCALAPPDATA": str(local),
                "EMTROLY_TEST_STARTUP_DIR": str(startup),
            }
            un_res = subprocess.run(
                [
                    SHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", str(ROOT / "windows-installer/manage-instance.ps1"),
                    "-RunManageWorker",
                    "-WorkerRequestFile", str(req_file),
                    "-WorkerPayloadRoot", str(ROOT),
                    "-WorkerLogFile", str(status_file),
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
            )
            status_txt = status_file.read_text(encoding="utf-8") if status_file.exists() else ""
            self.assertEqual(un_res.returncode, 0, status_txt + un_res.stdout + un_res.stderr)
            self.assertIn("Hoàn tất:", status_txt)
            self.assertFalse(oc.exists())
            self.assertFalse(vbs.exists())
            self.assertFalse((oc_bin / "openclaw.cmd").exists())
            # Antigravity/Codex preserved & config backed up!
            self.assertTrue((em_keep / "config.toml").is_file())
            backups = list((local / "AnhLapTrinh/EmTroLy/backups").glob("uninstall-*/openclaw.json"))
            self.assertEqual(len(backups), 1)

    def test_item4_and_item6_emtroly_reuse_shortcut_fallback_and_disk_space_preflight(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-item46-") as td:
            temp = Path(td)
            home = temp / "home"
            local = temp / "local"
            programs_dir = temp / "StartMenuPrograms"
            missing_desktop = temp / "MissingOneDriveDesktop"
            for d in (home, local, programs_dir):
                d.mkdir(parents=True)

            # A. Low disk space preflight in run-native-install.ps1
            settings_path = temp / "settings.json"
            log_path = temp / "status.txt"
            settings_path.write_text(
                json.dumps({
                    "member": "emtroly",
                    "assistant_name": "Trợ lý",
                    "owner_ids": "8764883034",
                    "group_id": "-100123456",
                    "telegram_token": "12345678:" + ("A" * 30),
                    "ai_api_key": "sk-test-123456",
                    "model": "gpt-6.2-sol",
                    "base_url": "https://codex.anhlaptrinh.vn/v1",
                    "gateway_port": "0",
                    "qr_owner_id": "8764883034",
                    "configure_zalo": True,
                    "skip_editor": False,
                    "accept_full_access": True,
                }),
                encoding="utf-8",
            )
            low_disk_env = {
                **os.environ,
                "USERPROFILE": str(home),
                "LOCALAPPDATA": str(local),
                "EMTROLY_MIN_FREE_BYTES": "3000000000",
                "EMTROLY_SIMULATE_FREE_BYTES": "100000000",
            }
            disk_res = subprocess.run(
                [
                    SHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", str(ROOT / "windows-installer/run-native-install.ps1"),
                    "-SettingsFile", str(settings_path),
                    "-PayloadRoot", str(ROOT),
                    "-LogFile", str(log_path),
                ],
                env=low_disk_env,
                capture_output=True,
                text=True,
                timeout=25,
            )
            self.assertEqual(disk_res.returncode, 1)
            self.assertIn("insufficient-disk-space", log_path.read_text(encoding="utf-8"))

            # B. Completed %LOCALAPPDATA%\EmTroLy + Missing Desktop -> Start Menu fallback in repair-antigravity-shortcut.ps1
            job_id = "a" * 32
            em_base = local / "EmTroLy"
            (em_base / "Codex").mkdir(parents=True)
            (em_base / "Antigravity/UserData/User").mkdir(parents=True)
            ext_dir = em_base / "Antigravity/Extensions/openai.chatgpt-26.51111.21308/bin/windows-x86_64"
            ext_dir.mkdir(parents=True)
            (em_base / "installer-job.txt").write_text(job_id, encoding="utf-8")
            (em_base / "Codex/config.toml").write_text(
                'model_provider = "router"\nmodel = "gpt-6.2-sol"\n[model_providers.router]\nbase_url = "https://codex.anhlaptrinh.vn/v1"\nrequires_openai_auth = true\n',
                encoding="utf-8",
            )
            (em_base / "Codex/auth.json").write_text('{"OPENAI_API_KEY":"sk-old"}', encoding="utf-8")
            (em_base / "Antigravity/UserData/User/settings.json").write_text('{"update.mode":"none"}', encoding="utf-8")
            (em_base / "Antigravity/Extensions/openai.chatgpt-26.51111.21308/package.json").write_text(
                '{"publisher":"openai","name":"chatgpt","version":"26.51111.21308"}',
                encoding="utf-8",
            )
            (ext_dir / "codex.exe").write_text("bin", encoding="utf-8")

            app_dir = local / f"Programs/EmTroLy-Antigravity-IDE-{job_id}"
            (app_dir / "bin").mkdir(parents=True)
            (app_dir / "resources/app").mkdir(parents=True)
            (app_dir / "Antigravity IDE.exe").write_text("exe", encoding="utf-8")
            (app_dir / "bin/antigravity-ide.cmd").write_text("@echo off\r\n", encoding="utf-8")
            (app_dir / "resources/app/product.json").write_text(
                '{"applicationName":"antigravity-ide","version":"1.107.0"}',
                encoding="utf-8",
            )
            (em_base / "editor-app-path.txt").write_text(str(app_dir), encoding="utf-8")

            # Run repair-antigravity-shortcut.ps1 with Desktop redirected to non-existent OneDrive folder -> falls back to Start Menu!
            repair_src = (ROOT / "windows-installer/repair-antigravity-shortcut.ps1").read_text(encoding="utf-8-sig")
            patched_repair = repair_src.replace("[Environment]::GetFolderPath('Desktop')", "$env:TEST_MISSING_DESKTOP")
            staged_repair = temp / "repair-test.ps1"
            staged_repair.write_text(patched_repair, encoding="utf-8-sig")
            fb_env = {
                **os.environ,
                "USERPROFILE": str(home),
                "LOCALAPPDATA": str(local),
                "TEST_MISSING_DESKTOP": str(missing_desktop),
                "EMTROLY_TEST_PROGRAMS_DIR": str(programs_dir),
            }
            rep_proc = subprocess.run(
                [SHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(staged_repair)],
                env=fb_env,
                capture_output=True,
                text=True,
                timeout=25,
            )
            self.assertEqual(rep_proc.returncode, 0, rep_proc.stdout + rep_proc.stderr)
            self.assertTrue((programs_dir / "EmTroLy - Antigravity.lnk").is_file())

    def test_item7_cmd_shims_execute_cleanly_with_vietnamese_spaces_ampersand_and_parentheses(self):
        sys.path.insert(0, str(ROOT / "native/skills/tao-tro-ly-openclaw-windows-macos-linux/scripts"))
        try:
            import install_windows_cli
        finally:
            sys.path.pop(0)

        with tempfile.TemporaryDirectory(prefix="emtroly-shim-") as td:
            tricky_base = Path(td) / "Nguyễn Văn Ánh (Kế Toán & Nhân Sự)"
            home = tricky_base / "Profile"
            local = tricky_base / "LocalAppData"
            em_codex = local / "EmTroLy/Codex"
            ext_bin = local / "EmTroLy/Antigravity/Extensions/openai.chatgpt-26.51111.21308/bin/windows-x86_64"
            for d in (home, local, em_codex, ext_bin):
                d.mkdir(parents=True, exist_ok=True)

            (em_codex / "config.toml").write_text('model = "gpt-6.2-sol"\n', encoding="utf-8")
            (em_codex / "auth.json").write_text('{"OPENAI_API_KEY":"sk-tricky"}', encoding="utf-8")

            if NODE:
                real_node = Path(NODE)
                fake_node = ext_bin / "node.exe"
                shutil.copy2(real_node, fake_node)
                cli_entry = tricky_base / "cli_echo.mjs"
                cli_entry.write_text(
                    'console.log(JSON.stringify({args: process.argv.slice(2), state: process.env.OPENCLAW_STATE_DIR}));\n',
                    encoding="utf-8",
                )
                env_map = install_windows_cli.instance_environment(tricky_base, home, "abc123def456", "member-emtroly")
                shim_bytes = install_windows_cli.shim_payload(fake_node, cli_entry, env_map, "abc123def456")
                self.assertFalse(shim_bytes.startswith(b"\xef\xbb\xbf"), "CMD shim must NOT start with UTF-8 BOM")
                oc_cmd = local / "openclaw-tricky.cmd"
                oc_cmd.write_bytes(shim_bytes)

                cmd_exe = str(Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/cmd.exe")
                cmdline = f'{cmd_exe} /d /s /c ""{oc_cmd}" --hello "Xin chào & Kiểm tra (OK)""'
                exec_res = subprocess.run(
                    cmdline,
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=20,
                )
                self.assertEqual(exec_res.returncode, 0, exec_res.stdout + exec_res.stderr)
                parsed = json.loads(exec_res.stdout.strip().splitlines()[-1])
                self.assertEqual(parsed["state"], str(tricky_base))
                self.assertEqual(parsed["args"], ["--hello", "Xin chào & Kiểm tra (OK)"])

            # Also verify Register-EmTroLyCodexCli succeeds with '&' and '()' in LOCALAPPDATA!
            (ext_bin / "codex.exe").write_text("dummy", encoding="utf-8")
            codex_ps1 = ROOT / "windows-installer/codex-cli.ps1"
            ps_env = {**os.environ, "USERPROFILE": str(home), "LOCALAPPDATA": str(local)}
            reg_res = run_ps(
                f'. "{codex_ps1}"\n'
                "$ErrorActionPreference = 'Stop'\n"
                "$r = Register-EmTroLyCodexCli\n"
                "if (-not $r.Registered) { throw 'codex-shim-not-registered' }\n"
                "$txt = [IO.File]::ReadAllText($r.Path, [Text.Encoding]::UTF8)\n"
                "if ($txt -notmatch 'DisableDelayedExpansion') { throw 'missing-disable-delayed-expansion' }\n"
                "Write-Output 'TRICKY_CODEX_SHIM_OK'\n",
                env=ps_env,
            )
            self.assertEqual(reg_res.returncode, 0, reg_res.stdout + reg_res.stderr)
            self.assertIn("TRICKY_CODEX_SHIM_OK", reg_res.stdout)

    @unittest.skipUnless(bool(NODE), "Requires Node.js")
    def test_item8_windows_gateway_watchdog_supervisor_auto_restarts_crash_and_stops_cleanly(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-watchdog-") as td:
            root = Path(td)
            shutil.copy2(ROOT / "native/user-gateway.cjs", root / "user-gateway.cjs")
            shutil.copy2(ROOT / "native/user-gateway.ps1", root / "user-gateway.ps1")

            crash_marker = root / "crashed-once.txt"
            cli_entry = root / "mock-openclaw.mjs"
            cli_entry.write_text(
                'import fs from "node:fs";\n'
                'import path from "node:path";\n'
                'const args = process.argv.slice(2);\n'
                'if (args[0] === "gateway" && args[1] === "health") {\n'
                '  console.log(JSON.stringify({ok: true}));\n'
                '  process.exit(0);\n'
                '}\n'
                'if (args[0] === "gateway" && args[1] === "run") {\n'
                f'  const marker = {str(crash_marker)!r};\n'
                '  if (!fs.existsSync(marker)) {\n'
                '    fs.writeFileSync(marker, String(process.pid));\n'
                '    setTimeout(() => process.exit(1), 250);\n'
                '  } else {\n'
                '    setInterval(() => {}, 1000);\n'
                '  }\n'
                '}\n',
                encoding="utf-8",
            )
            (root / "installer-instance.json").write_text(
                json.dumps({
                    "root": str(root),
                    "profile": "member-watchdog",
                    "cli_entry": str(cli_entry),
                    "port": 19991,
                    "node": NODE,
                    "home": str(root),
                    "path": os.environ.get("PATH", ""),
                }),
                encoding="utf-8",
            )

            env = {**os.environ, "EMTROLY_SUPERVISOR_BACKOFF_MS": "200"}
            try:
                start_res = subprocess.run(
                    [NODE, str(root / "user-gateway.cjs"), "start"],
                    cwd=str(root),
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(start_res.returncode, 0, start_res.stdout + start_res.stderr)

                # Wait for 1st child to crash (250ms) + supervisor backoff (200ms) + respawn
                deadline = time.time() + 8.0
                respawned_pid = None
                first_pid = None
                while time.time() < deadline:
                    if crash_marker.is_file() and (root / "user-gateway.pid.json").is_file():
                        first_pid = int(crash_marker.read_text(encoding="utf-8").strip())
                        rec = json.loads((root / "user-gateway.pid.json").read_text(encoding="utf-8"))
                        if rec.get("pid") and int(rec["pid"]) != first_pid:
                            respawned_pid = int(rec["pid"])
                            break
                    time.sleep(0.15)

                self.assertIsNotNone(first_pid, "First gateway child never ran")
                self.assertIsNotNone(respawned_pid, "Watchdog supervisor did not auto-restart crashed gateway!")
                self.assertNotEqual(first_pid, respawned_pid)
                gw_log = (root / "user-gateway.log").read_text(encoding="utf-8", errors="replace")
                self.assertIn("[emtroly-supervisor] gateway exited", gw_log)

                # Now invoke clean stop via user-gateway.ps1 and confirm supervisor does NOT respawn
                stop_res = run_ps(
                    f'. "{root / "user-gateway.ps1"}"\n'
                    "$ErrorActionPreference = 'Stop'\n"
                    f"Invoke-InstanceCli -Root '{root}' -CliEntry '{cli_entry}' -Arguments @('gateway', 'stop')\n"
                    "Write-Output 'CLEAN_STOP_OK'\n",
                    env=env,
                )
                self.assertEqual(stop_res.returncode, 0, stop_res.stdout + stop_res.stderr)
                self.assertIn("CLEAN_STOP_OK", stop_res.stdout)
                time.sleep(0.5)
                self.assertFalse((root / "user-gateway.pid.json").exists())
            finally:
                # Safety cleanup in case of assertion failure
                if (root / "user-gateway.pid.json").is_file():
                    try:
                        rec = json.loads((root / "user-gateway.pid.json").read_text(encoding="utf-8"))
                        for k in ("supervisorPid", "pid"):
                            if rec.get(k):
                                subprocess.run(["taskkill", "/PID", str(rec[k]), "/F"], capture_output=True)
                    except Exception:
                        pass


if __name__ == "__main__":
    unittest.main()
