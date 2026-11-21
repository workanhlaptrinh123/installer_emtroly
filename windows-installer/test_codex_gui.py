import json
import os
from pathlib import Path
import py_compile
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WIZARD = ROOT / "windows-installer/wizard.ps1"
CODEX_CLI = ROOT / "windows-installer/codex-cli.ps1"
BUILD_SH = ROOT / "build-windows-installer.sh"
UNIX_GUI = ROOT / "unix-installer/gui.py"
WIN_POWERSHELL = (
    Path(os.environ.get("SystemRoot", r"C:\Windows"))
    / "System32/WindowsPowerShell/v1.0/powershell.exe"
)
SHELL = str(WIN_POWERSHELL) if WIN_POWERSHELL.is_file() else (os.environ.get("PWSH") or shutil.which("pwsh"))


class CodexGuiContractTests(unittest.TestCase):
    def test_codex_helper_is_packaged_and_sourced_by_wizard(self):
        build = BUILD_SH.read_text(encoding="utf-8")
        wizard = WIZARD.read_text(encoding="utf-8")
        nsi = (ROOT / "windows-installer/member-vps-installer.nsi").read_text(encoding="utf-8")
        core_profile = json.loads((ROOT / "profiles/installer-core.json").read_text(encoding="utf-8"))
        self.assertTrue((ROOT / "alt.png").is_file(), "alt.png brand logo must exist at repository root")
        self.assertTrue((ROOT / "windows-installer/alt.ico").is_file(), "alt.ico brand icon must exist")
        self.assertIn('cp "$BASE/alt.png" "$payload/"', build)
        self.assertIn('cp "$BASE/windows-installer/alt.ico" "$payload/windows-installer/"', build)
        self.assertIn('-D"ICON_FILE=$BASE/windows-installer/alt.ico"', build)
        self.assertIn('Icon "${ICON_FILE}"', nsi)
        self.assertIn('VIAddVersionKey "FileDescription" "Anh Lap Trinh - Em Tro Ly"', nsi)
        self.assertIn('cp "$BASE/windows-installer/codex-cli.ps1" "$payload/windows-installer/"', build)
        self.assertIn("alt.png", wizard)
        self.assertIn("alt.ico", wizard)
        self.assertIn("$window.Icon =", wizard)
        self.assertIn("$zaloCheck.Enabled = $true", wizard)
        self.assertNotIn("zalo-qr-basic", core_profile["modules"])
        self.assertIn("codex-cli.ps1", wizard)
        self.assertIn("wizard-helpers.ps1", wizard)
        self.assertIn('cp "$BASE/windows-installer/wizard-helpers.ps1" "$payload/windows-installer/"', build)
        self.assertIn('cp "$BASE/MANIFEST.txt" "$payload/"', build)
        self.assertIn("Chỉnh sửa nhanh bằng Codex CLI", wizard)
        self.assertIn("Thực hiện bằng Codex", wizard)
        self.assertIn("Lấy ID tự động", wizard)
        self.assertIn("Kiểm tra kết nối", wizard)
        self.assertIn("Xuất báo cáo hỗ trợ", wizard)
        self.assertIn("FolderBrowserDialog", wizard)
        self.assertNotIn("OpenFileDialog", wizard)

    def test_wizard_uses_single_uniform_font_family_across_all_controls(self):
        wizard = WIZARD.read_text(encoding="utf-8")
        self.assertIn("$uiFontFamily  = 'Segoe UI'", wizard)
        self.assertIn('FontFamily="Segoe UI"', wizard)
        self.assertIn('UseLayoutRounding="True"', wizard)
        self.assertIn("SetProcessDpiAwarenessContext", (ROOT / "windows-installer/EmTroLyHost.cs").read_text(encoding="utf-8"))
        for disallowed in ("Consolas", "Courier New", "Microsoft Sans Serif", "Tahoma"):
            self.assertNotIn(disallowed, wizard)

    def test_unix_gui_compiles_and_includes_uniform_font_and_codex_tab(self):
        py_compile.compile(str(UNIX_GUI), doraise=True)
        unix_text = UNIX_GUI.read_text(encoding="utf-8")
        self.assertIn("--run-python-script", unix_text)
        self.assertIn("pick_uniform_font_family", unix_text)
        self.assertIn('text="Codex CLI"', unix_text)
        self.assertIn("Thực hiện bằng Codex", unix_text)
        self.assertIn("workspace-write", unix_text)


@unittest.skipUnless(SHELL, "PowerShell is unavailable")
class CodexCliPowerShellTests(unittest.TestCase):
    def test_powershell_scripts_parse_without_syntax_errors(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-parse-") as temporary:
            temp = Path(temporary)
            staged_wizard = temp / "wizard.ps1"
            staged_codex = temp / "codex-cli.ps1"
            staged_wizard.write_text(WIZARD.read_text(encoding="utf-8-sig"), encoding="utf-8-sig")
            staged_codex.write_text(CODEX_CLI.read_text(encoding="utf-8-sig"), encoding="utf-8-sig")
            driver = temp / "parse.ps1"
            driver.write_text(
                "param($WizardPath, $CodexPath)\n"
                "$ErrorActionPreference = 'Stop'\n"
                "foreach ($f in @($WizardPath, $CodexPath)) {\n"
                "  $t = $null; $e = $null\n"
                "  [void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$t, [ref]$e)\n"
                "  if ($e.Count -gt 0) { throw ($e | Out-String) }\n"
                "}\n",
                encoding="utf-8-sig",
            )
            cmd = [SHELL, "-NoLogo", "-NoProfile"]
            if os.name == "nt":
                cmd += ["-ExecutionPolicy", "Bypass"]
            cmd += ["-File", str(driver), "-WizardPath", str(staged_wizard), "-CodexPath", str(staged_codex)]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_discovery_prefers_emtroly_isolated_codex_and_skips_ps1_shim(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-codex-find-") as temporary:
            temp = Path(temporary)
            staged_codex = temp / "codex-cli.ps1"
            staged_codex.write_text(CODEX_CLI.read_text(encoding="utf-8-sig"), encoding="utf-8-sig")
            driver = temp / "driver.ps1"
            driver.write_text(
                r"""
param($ModulePath, $Directory)
$ErrorActionPreference = 'Stop'
. $ModulePath

$env:LOCALAPPDATA = Join-Path $Directory 'local'
$env:USERPROFILE = Join-Path $Directory 'profile'
$binDir = Join-Path $Directory 'path-bin'
New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA, $env:USERPROFILE, $binDir | Out-Null
[IO.File]::WriteAllText((Join-Path $binDir 'codex.ps1'), 'throw "unsafe-ps1"')
$env:Path = $binDir

$none = Find-EmTroLyCodexCli
if ($none.Available) { throw 'ps1-shim-should-not-be-selected' }

[IO.File]::WriteAllText((Join-Path $binDir 'codex.cmd'), '@echo off')
$pathFound = Find-EmTroLyCodexCli
if (-not $pathFound.Available -or $pathFound.Source -ne 'path') { throw 'cmd-shim-not-found' }

$emBase = Join-Path $env:LOCALAPPDATA 'EmTroLy'
$emCodex = Join-Path $emBase 'Codex'
$emExt = Join-Path $emBase 'Antigravity\Extensions\openai.chatgpt-26.51111.21308\bin\windows-x86_64'
New-Item -ItemType Directory -Force -Path $emCodex, $emExt | Out-Null
[IO.File]::WriteAllText((Join-Path $emCodex 'config.toml'), 'model = "gpt-6.2-sol"')
[IO.File]::WriteAllText((Join-Path $emCodex 'auth.json'), '{"OPENAI_API_KEY":"secret"}')
[IO.File]::WriteAllText((Join-Path $emExt 'codex.exe'), 'fixture')

$isolated = Find-EmTroLyCodexCli
if (-not $isolated.Available -or $isolated.Source -ne 'emtroly' -or $isolated.CodexHome -ne $emCodex) {
  throw 'emtroly-isolated-codex-not-prioritized'
}

$writeArgs = New-CodexExecArgumentString -WorkspaceDir 'C:\Users\Test User\openclaw' -AllowEdit $true -Model 'gpt-6.2-sol'
if ($writeArgs -notmatch '--sandbox danger-full-access' -or $writeArgs -notmatch '--skip-git-repo-check' -or -not $writeArgs.EndsWith(' -')) {
  throw "unexpected-write-args: $writeArgs"
}
$readArgs = New-CodexExecArgumentString -WorkspaceDir 'C:\Users\Test User\openclaw' -AllowEdit $false
if ($readArgs -notmatch '--sandbox read-only') { throw 'unexpected-read-args' }

$esc = [char]27
$masked = Protect-CodexOutputText -Text "$esc[32mXin chào sk-secret-123456$esc[0m" -SecretKey 'sk-secret-123456'
if ($masked -ne 'Xin chào [ĐÃ ẨN KHÓA BÍ MẬT]') { throw "mask-failed: $masked" }

$regConflict = Register-EmTroLyCodexCli
if (-not $regConflict.Registered -or $regConflict.Command -ne 'codex-emtroly') { throw 'codex-conflict-not-preserved' }
$env:Path = ''
$reg = Register-EmTroLyCodexCli
if (-not $reg.Registered -or $reg.Command -ne 'codex') { throw 'codex-shim-not-registered' }
$shimFile = Join-Path $env:LOCALAPPDATA 'OpenClaw\bin\codex.cmd'
$aliasFile = Join-Path $env:LOCALAPPDATA 'OpenClaw\bin\codex-emtroly.cmd'
if (-not (Test-Path -LiteralPath $shimFile -PathType Leaf) -or -not (Test-Path -LiteralPath $aliasFile -PathType Leaf)) {
  throw 'codex-shim-files-missing'
}
$shimContent = [IO.File]::ReadAllText($shimFile)
if ($shimContent -notmatch 'CODEX_HOME=' -or $shimContent -notmatch 'codex\.exe') {
  throw 'codex-shim-content-invalid'
}
""",
                encoding="utf-8-sig",
            )
            cmd = [SHELL, "-NoLogo", "-NoProfile"]
            if os.name == "nt":
                cmd += ["-ExecutionPolicy", "Bypass"]
            cmd += ["-File", str(driver), "-ModulePath", str(staged_codex), "-Directory", str(temp)]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(os.name == "nt", "Requires Windows cmd/PowerShell execution")
    def test_worker_executes_edit_command_via_stdin_and_cleans_secrets(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-codex-worker-") as temporary:
            temp = Path(temporary)
            workspace = temp / "workspace"
            workspace.mkdir()
            target_file = workspace / "greeting.txt"
            target_file.write_text("ban-dau", encoding="utf-8")

            fake_codex = temp / "fake-codex.cmd"
            fake_runner = temp / "fake-codex.py"
            fake_runner.write_text(
                "import os, pathlib, sys\n"
                "args = sys.argv[1:]\n"
                "prompt = sys.stdin.buffer.read().decode('utf-8').strip()\n"
                "assert 'exec' in args and '--sandbox' in args\n"
                "mode = args[args.index('--sandbox') + 1]\n"
                "cwd = pathlib.Path(args[args.index('-C') + 1])\n"
                "if mode in ('workspace-write', 'danger-full-access'):\n"
                "    (cwd / 'greeting.txt').write_text('da-sua: ' + prompt, encoding='utf-8')\n"
                "if '-o' in args:\n"
                "    pathlib.Path(args[args.index('-o') + 1]).write_text('Đã chỉnh sửa tệp greeting.txt xong.', encoding='utf-8')\n"
                "print('\\x1b[32mĐã nhận yêu cầu: ' + prompt + '\\x1b[0m')\n",
                encoding="utf-8",
            )
            py_exe = shutil.which("python") or "python"
            fake_codex.write_text(f'@echo off\r\n"{py_exe}" "{fake_runner}" %*\r\n', encoding="ascii")

            req_file = temp / "request.json"
            out_file = temp / "output.txt"
            secret = "private-key-do-not-print-999"
            prompt = 'Đổi lời chào thành "Xin chào anh!" & giữ 100% dấu tiếng Việt'
            req_file.write_text(
                json.dumps(
                    {
                        "executable": str(fake_codex),
                        "workspace": str(workspace),
                        "prompt": prompt,
                        "allow_edit": True,
                        "codex_home": "",
                        "model": "gpt-6.2-sol",
                        "base_url": "https://codex.anhlaptrinh.vn/v1",
                        "api_key": secret,
                    }
                ),
                encoding="utf-8",
            )

            staged_codex = temp / "codex-cli.ps1"
            staged_codex.write_text(CODEX_CLI.read_text(encoding="utf-8-sig"), encoding="utf-8-sig")
            cmd = [
                SHELL,
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(staged_codex),
                "-RunWorker",
                "-RequestFile",
                str(req_file),
                "-OutputFile",
                str(out_file),
            ]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(req_file.exists())
            self.assertEqual(target_file.read_text(encoding="utf-8"), "da-sua: " + prompt)
            log_text = out_file.read_text(encoding="utf-8")
            self.assertIn("Đã chỉnh sửa tệp greeting.txt xong.", log_text)
            self.assertIn("Hoàn tất yêu cầu Codex CLI thành công.", log_text)
            self.assertNotIn("\x1b[", log_text)
            self.assertNotIn(secret, log_text)

    @unittest.skipUnless(os.name == "nt", "Requires Windows WPF runtime")
    def test_wpf_wizard_constructs_all_views_uniform_segoe_ui_and_stop_exit(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-wpf-smoke-") as temporary:
            temp = Path(temporary)
            for helper_name in ("codex-cli.ps1", "manage-instance.ps1", "auto-heal-codex.ps1", "wizard-helpers.ps1"):
                src = (ROOT / "windows-installer" / helper_name).read_text(encoding="utf-8-sig")
                (temp / helper_name).write_text(src, encoding="utf-8-sig")
            wizard_src = WIZARD.read_text(encoding="utf-8-sig")
            check_snippet = (
                "function Assert-WpfUniformFont($node) {\n"
                "  if ($node -is [System.Windows.Controls.Control] -or $node -is [System.Windows.Controls.TextBlock]) {\n"
                "    if ($node.FontFamily -and $node.FontFamily.Source -ne 'Segoe UI') { throw ('non-uniform-font:' + $node.FontFamily.Source) }\n"
                "  }\n"
                "  foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($node)) {\n"
                "    if ($child -is [System.Windows.DependencyObject]) { Assert-WpfUniformFont $child }\n"
                "  }\n"
                "}\n"
                "if (-not $logoImage.Source) { throw 'logo-not-loaded' }\n"
                "if (-not $window.Icon) { throw 'window-icon-not-loaded' }\n"
                "if (-not $cancelButton.IsEnabled -or $cancelButton.Content -cne 'Thoát') { throw 'exit-button-not-ready' }\n"
                "Assert-WpfUniformFont $window\n"
                "Set-NavActive 'codex'\n"
                "if ($viewCodex.Visibility -ne [System.Windows.Visibility]::Visible) { throw 'codex-view-hidden' }\n"
                "Set-NavActive 'diag'\n"
                "if ($viewDiagnostics.Visibility -ne [System.Windows.Visibility]::Visible) { throw 'diag-view-hidden' }\n"
                "Update-ProgressFromStatus 'Đang cài đặt OpenClaw 2026.11.4...'\n"
                "if ([int]$installProgressBar.Value -lt 50) { throw 'progress-bar-not-updated' }\n"
                "$dummyPsi = New-Object Diagnostics.ProcessStartInfo\n"
                "$dummyPsi.FileName = (Join-Path $PSHOME 'powershell.exe')\n"
                "$dummyPsi.Arguments = '-NoLogo -NoProfile -WindowStyle Hidden -Command Start-Sleep -Seconds 30'\n"
                "$dummyPsi.UseShellExecute = $false\n"
                "$dummyPsi.CreateNoWindow = $true\n"
                "$dummyPsi.RedirectStandardOutput = $true\n"
                "$dummyPsi.RedirectStandardError = $true\n"
                "$script:runnerProcess = [Diagnostics.Process]::Start($dummyPsi)\n"
                "try {\n"
                "  $script:installRunning = $true\n"
                "  Set-NavActive 'progress'\n"
                "  if (-not $cancelButton.IsEnabled -or $cancelButton.Content -cne 'Dừng & Thoát') { throw 'running-exit-button-disabled' }\n"
                "  if ($stopTaskButton.Visibility -ne [System.Windows.Visibility]::Visible -or -not $stopTaskButton.IsEnabled) { throw 'stop-task-button-missing' }\n"
                "  Stop-ActiveRunner 'Đã dừng kiểm thử.'\n"
                "  if ($script:installRunning -or $stopTaskButton.Visibility -eq [System.Windows.Visibility]::Visible -or $cancelButton.Content -cne 'Thoát') { throw 'stop-runner-did-not-reset' }\n"
                "} finally {\n"
                "  if ($script:runnerProcess -and -not $script:runnerProcess.HasExited) { try { $script:runnerProcess.Kill() } catch {} }\n"
                "  $window.Close()\n"
                "}\n"
            )
            self.assertIn("[void]$window.ShowDialog()", wizard_src)
            (temp / "wizard-smoke.ps1").write_text(
                wizard_src.replace("[void]$window.ShowDialog()", check_snippet),
                encoding="utf-8-sig",
            )
            cmd = [
                SHELL,
                "-NoLogo",
                "-NoProfile",
                "-STA",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(temp / "wizard-smoke.ps1"),
                "-PayloadRoot",
                str(ROOT),
            ]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            self.assertIn(result.returncode, (0, 1, 2), result.stdout + result.stderr)
            self.assertEqual(result.stderr.strip(), "", result.stderr)

    @unittest.skipUnless(os.name == "nt", "Requires Windows PowerShell")
    def test_wizard_helpers_telegram_autofetch_and_scrubbed_support_report(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-helpers-") as temporary:
            temp = Path(temporary)
            home = temp / "home"
            oc = home / "openclaw"
            oc.mkdir(parents=True)
            secret_tok = "123456:SECRET_TELEGRAM_TOKEN_DO_NOT_EXPORT_12345"
            secret_key = "sk-super-secret-api-key-do-not-export-99999"
            (oc / "telegram.token").write_text(secret_tok + "\n", encoding="utf-8")
            (oc / "member-provider.secret").write_text(secret_key + "\n", encoding="utf-8")
            (oc / "user-gateway.log").write_text(f"Leaked {secret_tok} and {secret_key}\n", encoding="utf-8")

            report_file = temp / "support-report.txt"
            driver = temp / "driver.ps1"
            driver.write_text(
                f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{ROOT / "windows-installer/auto-heal-codex.ps1"}", [Text.Encoding]::UTF8)))\n'
                f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{ROOT / "windows-installer/wizard-helpers.ps1"}", [Text.Encoding]::UTF8)))\n'
                "function global:Invoke-RestMethod {\n"
                "  param([switch]$UseBasicParsing, $Method, $Uri, $TimeoutSec, $MaximumRedirection)\n"
                "  if ($Uri -match '/getMe$') { return @{ ok = $true; result = @{ is_bot = $true; username = 'anhlaptrinh_bot' } } }\n"
                "  if ($Uri -match '/getUpdates') {\n"
                "    return @{ ok = $true; result = @(\n"
                "      @{ message = @{ from = @{ id = 698000111; is_bot = $false; first_name = 'Anh'; username = 'anhdev' }; chat = @{ id = 698000111; type = 'private' } } },\n"
                "      @{ message = @{ from = @{ id = 698000111; is_bot = $false; first_name = 'Anh' }; chat = @{ id = -10099887766; type = 'supergroup'; title = 'Nhom Tro Ly' } } }\n"
                "    ) }\n"
                "  }\n"
                "  throw \"unexpected:$Uri\"\n"
                "}\n"
                f"$ids = Get-TelegramIdsFromBotUpdates -TelegramToken '{secret_tok}'\n"
                "if (-not $ids.Ok -or $ids.SuggestedOwnerId -ne '698000111' -or $ids.SuggestedGroupId -ne '-10099887766') { throw 'autofetch-failed' }\n"
                f"$ver = Get-EmTroLyAppVersion -PayloadRoot '{ROOT}'\n"
                "if ($ver.Display -notmatch '2026\\.11') { throw 'version-read-failed' }\n"
                f"$out = Export-EmTroLySupportReport -OutputPath '{report_file}' -PayloadRoot '{ROOT}'\n"
                "if (-not (Test-Path -LiteralPath $out -PathType Leaf)) { throw 'report-not-created' }\n",
                encoding="utf-8-sig",
            )
            env = {**os.environ, "USERPROFILE": str(home)}
            res = subprocess.run(
                [SHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(driver)],
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            report_text = report_file.read_text(encoding="utf-8")
            self.assertIn("BAO CAO HO TRO KY THUAT", report_text)
            self.assertNotIn(secret_tok, report_text)
            self.assertNotIn(secret_key, report_text)
            self.assertIn("[REDACTED_", report_text)

    @unittest.skipUnless(os.name == "nt", "Requires .NET Framework csc.exe on Windows")
    def test_emtroly_native_host_compiles_with_brand_icon_and_passes_smoke_launch(self):
        csc = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "Microsoft.NET/Framework64/v4.0.30319/csc.exe"
        if not csc.is_file():
            self.skipTest("csc.exe unavailable")
        with tempfile.TemporaryDirectory(prefix="emtroly-host-smoke-") as temporary:
            out_exe = Path(temporary) / "EmTroLyHost.exe"
            sma_probe = subprocess.run(
                [SHELL, "-NoLogo", "-NoProfile", "-Command", "[PSObject].Assembly.Location"],
                capture_output=True,
                text=True,
                timeout=15,
            )
            sma_dll = sma_probe.stdout.strip()
            compile_res = subprocess.run(
                [
                    str(csc),
                    "/nologo",
                    "/target:winexe",
                    "/utf8output",
                    f'/win32icon:{ROOT / "windows-installer/alt.ico"}',
                    f"/r:{sma_dll}",
                    "/r:System.dll",
                    "/r:System.Windows.Forms.dll",
                    "/r:System.Drawing.dll",
                    f"/out:{out_exe}",
                    str(ROOT / "windows-installer/EmTroLyHost.cs"),
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(compile_res.returncode, 0, compile_res.stdout + compile_res.stderr)
            smoke_res = subprocess.run(
                [str(out_exe), "-PayloadRoot", str(ROOT), "-SmokeTest"],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(smoke_res.returncode, 0, smoke_res.stdout + smoke_res.stderr)


if __name__ == "__main__":
    unittest.main()
