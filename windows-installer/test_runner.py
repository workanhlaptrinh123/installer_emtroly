import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


RELEASE = Path(__file__).resolve().parents[1]
PWSH = os.environ.get("PWSH") or shutil.which("pwsh")
TOKEN = "123456:TEST_TELEGRAM_TOKEN_1234567890"
API_KEY = "unit-test-private-api-key"

DRIVER = r"""
param($Runner, $Settings, $Payload, $Log)
function global:Invoke-RestMethod {
    param([switch]$UseBasicParsing, $Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, $ContentType, $Body)
    if ($MaximumRedirection -ne 0) { throw 'unexpected-redirect-policy' }
    if ($Uri -eq 'https://provider.example/v1/models') {
        if ($env:TEST_MODE -eq 'missing-model') { return @{ data = @(@{ id = 'different-model' }) } }
        return @{ data = @(@{ id = 'GPT-6.1-SOL' }) }
    }
    if ($Uri -match '^https://api\.telegram\.org/bot') {
        if ($Uri -match '/getMe$') { return @{ ok = $true; result = @{ is_bot = $true } } }
        if ($Uri -match '/getMyCommands$') { return @{ ok = $true; result = @($script:TelegramCommands) } }
        if ($Uri -match '/setMyCommands$') {
            $script:TelegramCommands = @((($Body | ConvertFrom-Json).commands))
            return @{ ok = $true; result = $true }
        }
        throw 'unexpected-telegram-method'
    }
    throw 'unexpected-uri'
}
& $Runner -SettingsFile $Settings -PayloadRoot $Payload -LogFile $Log
exit $LASTEXITCODE
"""

FAKE_INSTALLER = r"""
param($Name, $OwnerIds, $GroupId, $AssistantName, $BaseUrl, $Model, $Profile,
      $Modules, $QrOwnerId, $OpenClawVersion, $InstallMode, $GatewayPort,
      $Audience, $Addressing, $Style, [switch]$UserInstall, $CredentialData)
if (-not $UserInstall -or $InstallMode -ne 'new' -or $Model -cne 'GPT-6.1-SOL') { throw 'invalid-installer-arguments' }
if ($OwnerIds -ne $CredentialData.owner_ids) { throw 'invalid-owner-arguments' }
if ([bool]$CredentialData.configure_zalo) {
    if ($Modules.Count -ne 1 -or $Modules[0] -ne 'zalo-personal' -or $QrOwnerId -ne $CredentialData.qr_owner_id) { throw 'invalid-zalo-arguments' }
} elseif ($Modules.Count -ne 0) { throw 'unexpected-zalo-module' }
if ($CredentialData.telegram_token -ne $env:TEST_TOKEN -or $CredentialData.ai_api_key -ne $env:TEST_API_KEY) { throw 'invalid-credential-handoff' }
if ($env:TEST_MODE -eq 'zalo-stage-error') {
    [IO.File]::WriteAllText($env:MEMBER_INSTALL_ZALO_STAGE_FILE, 'qr-install')
    throw 'fixture-private-error'
}
if ($env:TEST_MODE -eq 'zalo-detail-error') {
    [IO.File]::WriteAllText($env:MEMBER_INSTALL_ZALO_STAGE_FILE, 'plugin-enable')
    [IO.File]::WriteAllText(($env:MEMBER_INSTALL_ZALO_STAGE_FILE + '.detail'), 'approval-required')
    throw 'fixture-private-error'
}
if ($env:TEST_MODE -eq 'zalo-unsafe-detail') {
    [IO.File]::WriteAllText($env:MEMBER_INSTALL_ZALO_STAGE_FILE, 'plugin-enable')
    [IO.File]::WriteAllText(($env:MEMBER_INSTALL_ZALO_STAGE_FILE + '.detail'), 'fixture-private-error')
    throw 'fixture-private-error'
}
$root = Join-Path $env:USERPROFILE ('.openclaw-member-' + $Name)
foreach ($item in @('openclaw.json', 'installer-instance.json', 'openclaw-instance.ps1',
    'workspace\skills\openclaw-zalo-reply-mention\SKILL.md',
    'workspace\skills\openclaw-telegram-zalo-qr-delivery\SKILL.md',
    'workspace\skills\cap-full-quyen-telegram-openclaw\SKILL.md')) {
    $path = Join-Path $root $item
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllText($path, 'fixture')
}
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
switch ($env:TEST_MODE) {
    'missing-owner' { $config.commands.ownerAllowFrom = @("telegram:$($owners[0])") }
    'missing-approver' { $config.channels.telegram.accounts[$Name].execApprovals.approvers = @($owners[0]) }
    'missing-plugin-target' { $config.approvals.plugin.targets = @($targets[0]) }
    'bad-binding' { $config.bindings[0].agentId = 'other' }
    'bad-exec' { $config.agents.entries.main.tools.exec.mode = 'auto' }
}
[IO.File]::WriteAllText((Join-Path $root 'openclaw.json'), ($config | ConvertTo-Json -Depth 20))
$runtime = Join-Path $root 'runtime\2026.11.4\node_modules\openclaw'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $runtime 'openclaw.mjs'), @'
const args = process.argv.slice(2);
if (args[0] === '--version') console.log('OpenClaw 2026.11.4 (fixture)');
else if (args[0] === 'approvals') console.log(JSON.stringify({file:{agents:{main:{security:'full',ask:'off',askFallback:process.env.TEST_MODE === 'bad-fallback' ? 'deny' : 'full'}}}}));
else if (args[0] === 'gateway' && args[1] === 'health') console.log(JSON.stringify({ok:true,plugins:{loaded:[
  ...(process.env.TEST_MODE === 'gateway-missing-zalouser' ? [] : ['zalouser']),
  ...(process.env.TEST_MODE === 'gateway-missing-zaloqr' ? [] : ['telegram-zalo-owner-login'])
]}}));
else if (args[0] === 'plugins' && args[1] === 'list') console.log(JSON.stringify({plugins:[
  ...(process.env.TEST_MODE === 'missing-zalouser' ? [] : [{id:'zalouser',status:'loaded',enabled:true}]),
  ...(process.env.TEST_MODE === 'missing-zalo-plugin' ? [] : [{id:'telegram-zalo-owner-login',status:'loaded',enabled:true}])
]}));
else if (args[0] === 'plugins' && args[1] === 'inspect') console.log(JSON.stringify({plugin:{status:'loaded',enabled:true,toolNames:['telegram_zalo_login_qr']},commands:process.env.TEST_MODE === 'missing-zaloqr-command' ? [] : process.env.TEST_MODE === 'missing-zalostatus-command' ? ['zaloqr'] : ['zaloqr','zalostatus']}));
else process.exit(2);
'@)
$manifest = @{ profile = 'member-fixture' } | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $root 'installer-instance.json'), $manifest)
$global:LASTEXITCODE = 0
"""


@unittest.skipUnless(PWSH, "PowerShell is unavailable")
class RunnerTests(unittest.TestCase):
    def execute(self, mode="success", overrides=None):
        with tempfile.TemporaryDirectory(prefix="member-wizard-test-") as temporary:
            root = Path(temporary)
            payload = root / "payload"
            (payload / "windows-installer").mkdir(parents=True)
            shutil.copy2(RELEASE / "windows-installer/validation.ps1", payload / "windows-installer")
            (payload / "install-native-windows.ps1").write_text(FAKE_INSTALLER, encoding="utf-8")
            driver = root / "driver.ps1"
            driver.write_text(DRIVER, encoding="utf-8")
            settings = {
                "member": "fixture", "assistant_name": "Fixture", "base_url": "https://provider.example/v1",
                "model": "gpt-6.1-sol", "owner_ids": "123456789,987654321", "group_id": "-1001234567890",
                "gateway_port": "0", "audience": "", "addressing": "", "style": "",
                "accept_full_access": True, "configure_zalo": True, "qr_owner_id": "123456789",
                "telegram_token": TOKEN, "ai_api_key": API_KEY,
            }
            settings.update(overrides or {})
            secret_file = root / "settings.json"
            secret_file.write_text(json.dumps(settings), encoding="utf-8")
            log = root / "status.txt"
            user_home = root / "home"
            user_home.mkdir()
            environment = {**os.environ, "USERPROFILE": str(user_home), "TEST_MODE": mode,
                           "TEST_TOKEN": TOKEN, "TEST_API_KEY": API_KEY}
            process = subprocess.run(
                [PWSH, "-NoLogo", "-NoProfile", "-File", str(driver),
                 "-Runner", str(RELEASE / "windows-installer/run-native-install.ps1"),
                 "-Settings", str(secret_file), "-Payload", str(payload), "-Log", str(log)],
                env=environment, capture_output=True, text=True, timeout=30,
            )
            text = (log.read_text(encoding="utf-8") if log.exists() else "") + process.stdout + process.stderr
            self.assertNotIn(TOKEN, text)
            self.assertNotIn(API_KEY, text)
            self.assertFalse(secret_file.exists())
            return process.returncode, text, (user_home / ".openclaw-member-fixture").exists()

    def test_success_passes_credentials_in_memory_and_verifies_artifacts(self):
        code, text, created = self.execute()
        self.assertEqual(code, 0, text)
        self.assertTrue(created)
        self.assertIn("SUCCESS", text)

    def test_reports_only_safe_zalo_stage_on_failure(self):
        code, text, created = self.execute("zalo-stage-error")
        self.assertNotEqual(code, 0)
        self.assertFalse(created)
        self.assertIn("qr-install", text)
        self.assertNotIn("fixture-private-error", text)

    def test_zalo_detail_is_allowlisted_and_safe(self):
        code, text, created = self.execute("zalo-detail-error")
        self.assertNotEqual(code, 0)
        self.assertFalse(created)
        self.assertIn("plugin-enable", text)
        self.assertIn("approval-required", text)
        self.assertNotIn("fixture-private-error", text)
        code, text, _ = self.execute("zalo-unsafe-detail")
        self.assertNotEqual(code, 0)
        self.assertIn("plugin-enable", text)
        self.assertNotIn("fixture-private-error", text)

    def test_missing_zalo_plugin_does_not_report_success(self):
        code, text, created = self.execute("missing-zalo-plugin")
        self.assertNotEqual(code, 0)
        self.assertTrue(created)
        self.assertIn("/zaloqr", text)

    def test_missing_channel_or_command_never_reports_success(self):
        for mode in ("missing-zalouser", "missing-zaloqr-command", "missing-zalostatus-command", "gateway-missing-zalouser", "gateway-missing-zaloqr"):
            with self.subTest(mode=mode):
                code, text, created = self.execute(mode)
                self.assertNotEqual(code, 0)
                self.assertTrue(created)
                self.assertNotIn("SUCCESS", text)

    def test_native_dry_run_preserves_provider_model_case(self):
        with tempfile.TemporaryDirectory(prefix="member-native-test-") as temporary:
            environment = {**os.environ, "USERPROFILE": temporary}
            process = subprocess.run(
                [PWSH, "-NoLogo", "-NoProfile", "-File", str(RELEASE / "install-native-windows.ps1"),
                 "-Name", "fixture", "-OwnerIds", "123456789", "-GroupId", "-1001234567890",
                 "-InstallMode", "new", "-UserInstall", "-DryRun", "-Model", "GPT-6.1-SOL"],
                env=environment, capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            self.assertIn("model: GPT-6.1-SOL", process.stdout)
            self.assertFalse((Path(temporary) / ".openclaw-member-fixture").exists())

    def test_provider_must_advertise_selected_model(self):
        code, text, created = self.execute("missing-model")
        self.assertNotEqual(code, 0)
        self.assertFalse(created)
        self.assertIn("khong cong bo model", text.lower())

    def test_invalid_owner_rejected_before_network_and_install(self):
        code, text, created = self.execute(overrides={"owner_ids": "not-a-telegram-id"})
        self.assertNotEqual(code, 0)
        self.assertFalse(created)
        self.assertIn("owner ids", text.lower())

    def test_http_and_embedded_provider_credentials_rejected(self):
        for url in ("http://provider.example/v1", "https://name:password@provider.example/v1", "https://provider.example/v1?key=secret"):
            with self.subTest(url=url):
                code, text, created = self.execute(overrides={"base_url": url})
                self.assertNotEqual(code, 0)
                self.assertFalse(created)
                self.assertIn("url", text.lower())

    def test_full_access_requires_explicit_confirmation(self):
        code, text, created = self.execute(overrides={"accept_full_access": False})
        self.assertNotEqual(code, 0)
        self.assertFalse(created)
        self.assertIn("full exec", text.lower())

    def test_second_owner_can_receive_initial_qr(self):
        code, text, created = self.execute(overrides={"qr_owner_id": "987654321"})
        self.assertEqual(code, 0, text)
        self.assertTrue(created)

    def test_qr_recipient_must_be_a_configured_owner(self):
        code, text, created = self.execute(overrides={"qr_owner_id": "111111111"})
        self.assertNotEqual(code, 0)
        self.assertFalse(created)
        self.assertIn("qr owner", text.lower())

    def test_zalo_cannot_be_disabled(self):
        code, text, created = self.execute(overrides={"configure_zalo": False, "qr_owner_id": ""})
        self.assertNotEqual(code, 0)
        self.assertFalse(created)
        self.assertIn("plugin Zalo", text)

    def test_incomplete_owner_permissions_never_report_success(self):
        for mode in ("missing-owner", "missing-approver", "missing-plugin-target", "bad-binding"):
            with self.subTest(mode=mode):
                code, text, created = self.execute(mode)
                self.assertNotEqual(code, 0)
                self.assertTrue(created)
                self.assertNotIn("SUCCESS", text)
                self.assertIn("owner ids", text.lower())

    def test_incomplete_full_exec_never_reports_success(self):
        for mode in ("bad-exec", "bad-fallback"):
            with self.subTest(mode=mode):
                code, text, created = self.execute(mode)
                self.assertNotEqual(code, 0)
                self.assertTrue(created)
                self.assertNotIn("SUCCESS", text)
                self.assertIn("full exec", text.lower())

    def test_verifier_accepts_real_owner_and_permissions_helpers(self):
        helper_dir = RELEASE / "native/skills/tao-tro-ly-openclaw-windows-macos-linux/scripts"
        sys.path.insert(0, str(helper_dir))
        try:
            spec = importlib.util.spec_from_file_location("ensure_owner_fixture", helper_dir / "ensure_default_telegram_owner.py")
            helper = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(helper)
        finally:
            sys.path.pop(0)
        owners = ["123456789", "987654321"]
        config = {
            "channels": {"telegram": {"accounts": {"fixture": {"allowFrom": owners.copy()}}}},
            "commands": {}, "tools": {},
            "agents": {"entries": {"main": {"tools": {"exec": {}}}}},
            "bindings": [{"agentId": "main", "match": {"channel": "telegram", "accountId": "fixture"}}],
        }
        helper.merge_config(config, "fixture", ["main"], owners)
        with tempfile.TemporaryDirectory(prefix="member-real-owner-test-") as temporary:
            root = Path(temporary)
            config_path = root / "openclaw.json"
            config_path.write_text(json.dumps(config), encoding="utf-8")
            finalize = subprocess.run(
                [sys.executable, str(RELEASE / "native/finalize_permissions.py"),
                 "--config", str(config_path), "--owners", ",".join(owners)],
                capture_output=True, text=True, timeout=20,
            )
            self.assertEqual(finalize.returncode, 0, finalize.stderr)
            driver = root / "verify.ps1"
            driver.write_text(r'''
param($Validation, $ConfigPath)
. $Validation
$settings = [pscustomobject]@{ member = 'fixture'; owner_ids = '123456789,987654321' }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$approval = [pscustomobject]@{ file = @{ agents = @{ main = @{ security = 'full'; ask = 'off'; askFallback = 'full' } } } }
Test-MemberInstallerPermissions -Settings $settings -Config $config -ApprovalState $approval
''', encoding="utf-8")
            process = subprocess.run(
                [PWSH, "-NoLogo", "-NoProfile", "-File", str(driver),
                 "-Validation", str(RELEASE / "windows-installer/validation.ps1"),
                 "-ConfigPath", str(config_path)],
                capture_output=True, text=True, timeout=20,
            )
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)


if __name__ == "__main__":
    unittest.main()
