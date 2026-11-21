import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
AUTO_HEAL = ROOT / "windows-installer/auto-heal-codex.ps1"
RUNNER = ROOT / "windows-installer/run-native-install.ps1"
MANAGE = ROOT / "windows-installer/manage-instance.ps1"
WIZARD = ROOT / "windows-installer/wizard.ps1"

WIN_POWERSHELL = (
    Path(os.environ.get("SystemRoot", r"C:\Windows"))
    / "System32/WindowsPowerShell/v1.0/powershell.exe"
)
SHELL = str(WIN_POWERSHELL) if WIN_POWERSHELL.is_file() else (os.environ.get("PWSH") or shutil.which("pwsh"))

TOKEN = "777888:SECRET_TELEGRAM_TOKEN_AUTOHEAL_1234567890"
API_KEY = "custom-router-secret-key-autoheal-998877"

SUBPROCESS_TEXT_KWARGS = {
    "text": True,
    "encoding": "utf-8",
    "errors": "replace",
}


FAKE_CODEX_PY = r"""
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
prompt = sys.stdin.read()

record_dir = Path(os.environ["FAKE_CODEX_RECORD_DIR"])
record_dir.mkdir(parents=True, exist_ok=True)
count_file = record_dir / "count.txt"
count = int(count_file.read_text(encoding="utf-8")) + 1 if count_file.exists() else 1
count_file.write_text(str(count), encoding="utf-8")
(record_dir / f"prompt_{count}.txt").write_text(prompt, encoding="utf-8")
(record_dir / f"args_{count}.json").write_text(json.dumps(args), encoding="utf-8")

codex_home = Path(os.environ.get("CODEX_HOME", ""))
auth_data = json.loads((codex_home / "auth.json").read_text(encoding="utf-8"))
(record_dir / f"auth_present_{count}.txt").write_text(
    "yes" if bool(auth_data.get("OPENAI_API_KEY")) else "no",
    encoding="utf-8",
)
(record_dir / f"env_key_leaked_{count}.txt").write_text(
    "yes" if "OPENAI_API_KEY" in os.environ else "no",
    encoding="utf-8",
)

out_file = None
for idx, item in enumerate(args):
    if item == "-o" and idx + 1 < len(args):
        out_file = Path(args[idx + 1])
        break

behavior = os.environ.get("FAKE_CODEX_BEHAVIOR", "fix-core")
oc_root = Path(os.environ["USERPROFILE"]) / "openclaw"

if behavior == "fix-core":
    skill_md = oc_root / "workspace/skills/imagegen/SKILL.md"
    skill_md.parent.mkdir(parents=True, exist_ok=True)
    skill_md.write_text("repaired-by-codex", encoding="utf-8")
    (oc_root / "gateway-repaired.marker").write_text("ok", encoding="utf-8")
    summary = "Đã khôi phục kỹ năng tạo ảnh và khởi động lại Gateway thành công."
elif behavior == "noop":
    summary = "Đã kiểm tra nhưng cổng mạng vẫn đang bị khóa bởi phần mềm khác."
elif behavior == "fix-manage":
    (oc_root / "manage-repaired.marker").write_text("ok", encoding="utf-8")
    summary = "Đã sửa cấu hình Gateway bị kẹt và làm sạch tiến trình cũ."
else:
    summary = "Không rõ kịch bản."

if out_file:
    out_file.write_text(summary, encoding="utf-8")
print(summary)
sys.exit(0)
"""


DRIVER_PS1 = r"""
param($Runner, $Settings, $Payload, $Log)
function global:Invoke-RestMethod {
  param([switch]$UseBasicParsing, $Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, $ContentType, $Body)
  if ($Uri -eq 'https://provider.example/v1/models') {
    return @{ data = @(@{ id = 'gpt-6.2-sol' }) }
  }
  if ($Uri -match '^https://api\.telegram\.org/bot') {
    if ($Uri -match '/getMe$') { return @{ ok = $true; result = @{ is_bot = $true } } }
    if ($Uri -match '/getMyCommands$') {
      return @{ ok = $true; result = @(
        @{ command = 'zaloqr'; description = 'QR' },
        @{ command = 'zalostatus'; description = 'Status' }
      ) }
    }
  }
  throw "unexpected-uri: $Uri"
}
& $Runner -SettingsFile $Settings -PayloadRoot $Payload -LogFile $Log
exit $LASTEXITCODE
"""


BROKEN_INSTALLER_PS1 = r"""
param($Name, $OwnerIds, $GroupId, $AssistantName, $BaseUrl, $Model, $Profile,
      $Modules, $QrOwnerId, $OpenClawVersion, $InstallMode, $InstallRoot, $GatewayPort,
      $Audience, $Addressing, $Style, [switch]$UserInstall, $CredentialData)

$root = Join-Path $env:USERPROFILE 'openclaw'
# Intentionally OMIT workspace\skills\imagegen\SKILL.md to simulate broken/interrupted install!
foreach ($item in @(
    'openclaw.json', 'installer-instance.json', 'openclaw-instance.ps1', 'windows-cli.json',
    'workspace\skills\core-openclaw-telegram\SKILL.md',
    'workspace\skills\cap-full-quyen-telegram-openclaw\SKILL.md',
    'workspace\skills\reliable-media-delivery\SKILL.md',
    'workspace\skills\core-openclaw-media\SKILL.md',
    'workspace\skills\openclaw-docx-reader\SKILL.md',
    'workspace\skills\openclaw-python-docx-telegram\SKILL.md'
)) {
  $p = Join-Path $root $item
  New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
  [IO.File]::WriteAllText($p, 'fixture')
}

# Write a log containing secrets to verify auto-heal scrubs secrets before sending to Codex!
$gwLog = "Gateway startup failed with token $($CredentialData.telegram_token) and key $($CredentialData.ai_api_key)"
[IO.File]::WriteAllText((Join-Path $root 'user-gateway.log'), $gwLog)

$owners = @($OwnerIds -split ',')
$exec = @{ host = 'gateway'; mode = 'full'; strictInlineEval = $false }
$targets = @($owners | ForEach-Object { @{ channel = 'telegram'; accountId = $Name; to = $_ } })
$config = @{
  commands = @{ ownerAllowFrom = @($owners | ForEach-Object { "telegram:$_" }) }
  channels = @{ telegram = @{
    allowFrom = $owners; execApprovals = @{ approvers = $owners }
    accounts = @{ $Name = @{ allowFrom = $owners; execApprovals = @{ approvers = $owners } } }
  } }
  approvals = @{
    exec = @{ enabled = $true; mode = 'targets'; agentFilter = @('main'); targets = $targets }
    plugin = @{ enabled = $true; mode = 'targets'; agentFilter = @('main'); targets = $targets }
  }
  tools = @{ exec = $exec }
  agents = @{ entries = @{ main = @{ tools = @{ exec = $exec.Clone() } } } }
  bindings = @(@{ agentId = 'main'; match = @{ channel = 'telegram'; accountId = $Name } })
}
[IO.File]::WriteAllText((Join-Path $root 'openclaw.json'), ($config | ConvertTo-Json -Depth 20))
[IO.File]::WriteAllText((Join-Path $root 'installer-instance.json'), '{"profile":"member-fixture"}')

$runtime = Join-Path $root 'runtime\2026.11.4\node_modules\openclaw'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $runtime 'openclaw.mjs'), @'
import fs from 'node:fs';
import path from 'node:path';
const args = process.argv.slice(2);
const root = process.env.OPENCLAW_STATE_DIR || '';
if (args[0] === '--version') console.log('OpenClaw 2026.11.4 (fixture)');
else if (args[0] === 'approvals') console.log(JSON.stringify({file:{agents:{main:{security:'full',ask:'off',askFallback:'full'}}}}));
else if (args[0] === 'gateway' && args[1] === 'health') {
  const repaired = fs.existsSync(path.join(root, 'gateway-repaired.marker'));
  if (!repaired) {
    console.log(JSON.stringify({ok:false}));
    process.exit(1);
  }
  console.log(JSON.stringify({ok:true,plugins:{loaded:[]}}));
}
else process.exit(2);
'@)
$global:LASTEXITCODE = 0
"""


class AutoHealStaticContractTests(unittest.TestCase):
    def test_build_script_stages_auto_heal_helper(self):
        build_sh = (ROOT / "build-windows-installer.sh").read_text(encoding="utf-8")
        self.assertIn("windows-installer/auto-heal-codex.ps1", build_sh)
        codex_ps = (ROOT / "windows-installer/codex-cli.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("auto-heal-codex.ps1", codex_ps)
        wizard_ps = WIZARD.read_text(encoding="utf-8-sig")
        self.assertIn("Start-ManageAction 'auto-heal'", wizard_ps)


@unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
class AutoHealRuntimeTests(unittest.TestCase):
    def _make_fake_codex_bin(self, temp: Path) -> tuple[Path, Path]:
        bin_dir = temp / "fake-bin"
        bin_dir.mkdir(parents=True, exist_ok=True)
        record_dir = temp / "codex-records"
        fake_py = bin_dir / "fake_codex.py"
        fake_py.write_text(FAKE_CODEX_PY, encoding="utf-8")
        codex_cmd = bin_dir / "codex.cmd"
        codex_cmd.write_text(
            f'@echo off\r\n"{sys.executable}" "{fake_py}" %*\r\n',
            encoding="ascii",
        )
        return bin_dir, record_dir

    def test_powershell_scripts_parse_cleanly_without_ast_errors(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-ast-") as temporary:
            check_ps = Path(temporary) / "ast-check.ps1"
            targets = [str(AUTO_HEAL), str(RUNNER), str(MANAGE), str(WIZARD)]
            check_ps.write_text(
                "$files = @(" + ",".join(f"'{p}'" for p in targets) + ")\n"
                "foreach ($f in $files) {\n"
                "  $src = [IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)\n"
                "  $tokens = $null; $errors = $null\n"
                "  $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errors)\n"
                "  if ($errors.Count -gt 0) { throw \"AST error in ${f}: $($errors[0].Message)\" }\n"
                "  if ($f -like '*auto-heal-codex.ps1' -and $null -ne $ast.ParamBlock) {\n"
                "    throw 'auto-heal-codex.ps1 must not define top-level param() block'\n"
                "  }\n"
                "}\n",
                encoding="utf-8-sig",
            )
            res = subprocess.run(
                [SHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(check_ps)],
                capture_output=True,
                **SUBPROCESS_TEXT_KWARGS,
                timeout=20,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

    def test_error_classification_and_secret_scrubbing(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-scrub-") as temporary:
            probe = Path(temporary) / "probe.ps1"
            staged = Path(temporary) / "auto-heal-codex.ps1"
            staged.write_text(AUTO_HEAL.read_text(encoding="utf-8-sig"), encoding="utf-8-sig")
            probe.write_text(
                f'. "{staged}"\n'
                "if (Test-IsAutoHealableError -ErrorCode 'invalid-telegram-token' -Stage 'input') { throw 'expected-false-1' }\n"
                "if (Test-IsAutoHealableError -ErrorCode 'provider-unavailable' -Stage 'provider') { throw 'expected-false-2' }\n"
                "if (Test-IsAutoHealableError -ErrorCode 'instance-exists' -Stage 'install') { throw 'expected-false-3' }\n"
                "if (Test-IsAutoHealableError -ErrorCode 'editor-download-checksum' -Stage 'editor') { throw 'expected-false-4' }\n"
                "if (-not (Test-IsAutoHealableError -ErrorCode 'gateway-health-failed' -Stage 'zalo-verify')) { throw 'expected-true-1' }\n"
                "if (-not (Test-IsAutoHealableError -ErrorCode 'cli-probe-path' -Stage 'command')) { throw 'expected-true-2' }\n"
                "if (-not (Test-IsAutoHealableError -ErrorCode 'incomplete-installation' -Stage 'install')) { throw 'expected-true-3' }\n"
                "if (-not (Test-IsAutoHealableError -ErrorCode 'editor-activation-failed' -Stage 'editor')) { throw 'expected-true-4' }\n"
                "$settings = [pscustomobject]@{ telegram_token = '" + TOKEN + "'; ai_api_key = '" + API_KEY + "'; owner_ids = '12345'; group_id = '-100123'; model = 'gpt-6.2-sol'; gateway_port = '0'; configure_zalo = $false }\n"
                "$raw = 'Failed with bot " + TOKEN + " and customKey=" + API_KEY + " and sk-proj-1234567890abcdef and \"token\": \"abcdef0123456789abcdef0123456789\"'\n"
                "$prompt = Build-SafeAutoHealPrompt -Stage 'install' -ErrorCode 'gateway-health-failed' -ErrorDetail $raw -OpenClawRoot 'C:\\openclaw' -PayloadRoot 'C:\\payload' -Settings $settings -Attempt 1\n"
                "Write-Output $prompt\n",
                encoding="utf-8-sig",
            )
            res = subprocess.run(
                [SHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(probe)],
                capture_output=True,
                **SUBPROCESS_TEXT_KWARGS,
                timeout=20,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertNotIn(TOKEN, res.stdout)
            self.assertNotIn(API_KEY, res.stdout)
            self.assertNotIn("sk-proj-1234567890abcdef", res.stdout)
            self.assertNotIn("abcdef0123456789abcdef0123456789", res.stdout)
            self.assertIn("[REDACTED_", res.stdout)

    def _run_install_with_autoheal(self, behavior: str):
        with tempfile.TemporaryDirectory(prefix="emtroly-heal-e2e-") as temporary:
            temp = Path(temporary)
            home = temp / "home"
            local_app = temp / "local"
            home.mkdir()
            local_app.mkdir()
            bin_dir, record_dir = self._make_fake_codex_bin(temp)

            payload = temp / "payload"
            win_dir = payload / "windows-installer"
            win_dir.mkdir(parents=True)
            for name in ("validation.ps1", "codex-cli.ps1", "auto-heal-codex.ps1"):
                src = (ROOT / "windows-installer" / name).read_text(encoding="utf-8-sig")
                (win_dir / name).write_text(src, encoding="utf-8-sig")

            (win_dir / "verify-openclaw-command.ps1").write_text("exit 0\n", encoding="utf-8-sig")
            (win_dir / "install-antigravity-codex.ps1").write_text(
                "param($Settings, $StatusFile)\n"
                "[IO.File]::WriteAllText((Join-Path $env:USERPROFILE 'editor-done.txt'), 'ok')\n",
                encoding="utf-8-sig",
            )
            (payload / "install-native-windows.ps1").write_text(BROKEN_INSTALLER_PS1, encoding="utf-8-sig")

            staged_runner = win_dir / "run-native-install.ps1"
            staged_runner.write_text(RUNNER.read_text(encoding="utf-8-sig"), encoding="utf-8-sig")

            driver = temp / "driver.ps1"
            driver.write_text(DRIVER_PS1, encoding="utf-8-sig")

            settings_file = temp / "settings.json"
            settings_file.write_text(
                json.dumps(
                    {
                        "member": "emtroly",
                        "assistant_name": "Em Trợ Lý",
                        "base_url": "https://provider.example/v1",
                        "model": "gpt-6.2-sol",
                        "owner_ids": "123456789",
                        "group_id": "-1001234567890",
                        "gateway_port": "0",
                        "audience": "",
                        "addressing": "",
                        "style": "",
                        "accept_full_access": True,
                        "configure_zalo": False,
                        "skip_editor": False,
                        "qr_owner_id": "",
                        "telegram_token": TOKEN,
                        "ai_api_key": API_KEY,
                    }
                ),
                encoding="utf-8",
            )
            log_file = temp / "status.txt"
            clean_path_entries = [
                p
                for p in os.environ.get("PATH", "").split(os.pathsep)
                if p
                and not (Path(p) / "openclaw.cmd").exists()
                and not (Path(p) / "openclaw.exe").exists()
                and not (Path(p) / "openclaw.ps1").exists()
            ]
            env = {
                **os.environ,
                "USERPROFILE": str(home),
                "LOCALAPPDATA": str(local_app),
                "PATH": os.pathsep.join([str(bin_dir), *clean_path_entries]),
                "FAKE_CODEX_RECORD_DIR": str(record_dir),
                "FAKE_CODEX_BEHAVIOR": behavior,
            }
            proc = subprocess.run(
                [
                    SHELL,
                    "-NoLogo",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(driver),
                    "-Runner",
                    str(staged_runner),
                    "-Settings",
                    str(settings_file),
                    "-Payload",
                    str(payload),
                    "-Log",
                    str(log_file),
                ],
                env=env,
                capture_output=True,
                **SUBPROCESS_TEXT_KWARGS,
                timeout=45,
            )
            status_text = log_file.read_text(encoding="utf-8") if log_file.exists() else ""
            count = int((record_dir / "count.txt").read_text(encoding="utf-8")) if (record_dir / "count.txt").exists() else 0
            prompts = [p.read_text(encoding="utf-8") for p in sorted(record_dir.glob("prompt_*.txt"))]
            audit_log = (
                (home / "openclaw/logs/codex-autoheal.log").read_text(encoding="utf-8")
                if (home / "openclaw/logs/codex-autoheal.log").exists()
                else ""
            )
            for idx in range(1, count + 1):
                self.assertEqual((record_dir / f"auth_present_{idx}.txt").read_text(encoding="utf-8"), "yes")
                self.assertEqual((record_dir / f"env_key_leaked_{idx}.txt").read_text(encoding="utf-8"), "no")
            combined_inspect = "\n".join(prompts) + "\n" + status_text + "\n" + audit_log + proc.stdout + proc.stderr
            self.assertNotIn(TOKEN, combined_inspect)
            self.assertNotIn(API_KEY, combined_inspect)
            return proc.returncode, status_text, count, audit_log

    def test_runner_auto_heals_broken_core_install_via_codex_and_verifies(self):
        code, status_text, count, audit_log = self._run_install_with_autoheal("fix-core")
        self.assertEqual(code, 0, status_text)
        self.assertEqual(count, 1)
        self.assertIn("Hoàn tất:", status_text)
        self.assertIn("incomplete-installation", audit_log)

    def test_runner_never_reports_success_when_codex_cannot_fix_issue(self):
        code, status_text, count, audit_log = self._run_install_with_autoheal("noop")
        self.assertNotEqual(code, 0)
        self.assertEqual(count, 2)
        self.assertNotIn("Hoàn tất", status_text)
        self.assertIn("Ghi chú từ Codex tự sửa lỗi:", status_text)
        self.assertIn("attempt=2", audit_log)

    def test_manage_instance_auto_heal_action_repairs_gateway_and_verifies_health(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-manage-heal-") as temporary:
            temp = Path(temporary)
            home = temp / "home"
            local_app = temp / "local"
            oc = home / "openclaw"
            oc.mkdir(parents=True)
            local_app.mkdir(parents=True)
            bin_dir, record_dir = self._make_fake_codex_bin(temp)

            (oc / "openclaw.json").write_text('{"gateway":{"port":19789}}', encoding="utf-8")
            (oc / "member-provider.secret").write_text(API_KEY + "\n", encoding="utf-8")
            (oc / "openclaw-instance.ps1").write_text(
                "if ($args[0] -eq 'gateway' -and $args[1] -eq 'restart') { exit 0 }\n"
                "if ($args[0] -eq 'gateway' -and $args[1] -eq 'status') {\n"
                "  if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'manage-repaired.marker')) {\n"
                "    Write-Output '{\"ok\":true,\"plugins\":{\"loaded\":[]}}'; exit 0\n"
                "  }\n"
                "  Write-Output '{\"ok\":false}'; exit 1\n"
                "}\n",
                encoding="utf-8-sig",
            )

            staged_manage = temp / "manage-instance.ps1"
            staged_manage.write_text(MANAGE.read_text(encoding="utf-8-sig"), encoding="utf-8-sig")
            req_file = temp / "req.json"
            status_file = temp / "status.txt"
            req_file.write_text(
                json.dumps(
                    {
                        "action": "auto-heal",
                        "model": "gpt-6.2-sol",
                        "base_url": "https://codex.anhlaptrinh.vn/v1",
                        "ai_api_key": "",
                        "telegram_token": "",
                        "error_detail": "Gateway không phản hồi.",
                    }
                ),
                encoding="utf-8",
            )
            env = {
                **os.environ,
                "USERPROFILE": str(home),
                "LOCALAPPDATA": str(local_app),
                "PATH": str(bin_dir) + os.pathsep + os.environ.get("PATH", ""),
                "FAKE_CODEX_RECORD_DIR": str(record_dir),
                "FAKE_CODEX_BEHAVIOR": "fix-manage",
            }
            res = subprocess.run(
                [
                    SHELL,
                    "-NoLogo",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(staged_manage),
                    "-RunManageWorker",
                    "-WorkerRequestFile",
                    str(req_file),
                    "-WorkerPayloadRoot",
                    str(ROOT),
                    "-WorkerLogFile",
                    str(status_file),
                ],
                env=env,
                capture_output=True,
                **SUBPROCESS_TEXT_KWARGS,
                timeout=30,
            )
            status_text = status_file.read_text(encoding="utf-8") if status_file.exists() else ""
            self.assertEqual(res.returncode, 0, status_text + res.stdout + res.stderr)
            self.assertIn("Hoàn tất: Codex CLI đã tự kiểm tra và sửa lỗi thành công!", status_text)
            self.assertNotIn(API_KEY, status_text + res.stdout + res.stderr)


if __name__ == "__main__":
    unittest.main()
