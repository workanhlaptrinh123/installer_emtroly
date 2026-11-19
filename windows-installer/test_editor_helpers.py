import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'windows-installer/install-antigravity-codex.ps1'
PWSH = os.environ.get('PWSH') or shutil.which('pwsh')


class EditorContractTests(unittest.TestCase):
    def test_component_is_packaged_and_required_for_success(self):
        build = (ROOT / 'build-windows-installer.sh').read_text(encoding='utf-8')
        runner = (ROOT / 'windows-installer/run-native-install.ps1').read_text(encoding='utf-8')
        wizard = (ROOT / 'windows-installer/wizard.ps1').read_text(encoding='utf-8')
        self.assertIn('install-antigravity-codex.ps1', build)
        self.assertIn('activation-probe', build)
        self.assertIn('-CheckOnly', runner)
        self.assertLess(runner.index('& $editorInstaller -Settings $settings -StatusFile $LogFile *> $null'),
                        runner.index("Write-SafeStatus 'SUCCESS:"))
        self.assertIn('Em Trợ Lý - Antigravity', wizard)

    def test_isolation_and_auth_are_explicit(self):
        script = MODULE.read_text(encoding='utf-8')
        for item in ('Antigravity\\UserData', 'Antigravity\\Extensions', "Join-Path $base 'Codex'",
                     'CODEX_HOME', '--user-data-dir', '--extensions-dir',
                     "'chatgpt.runCodexInWindowsSubsystemForLinux' = $false", 'requires_openai_auth = true',
                     'Get-FileHash', 'Get-AuthenticodeSignature', "'editor-codex-probe-failed'",
                     "'editor-activation-failed'"):
            self.assertIn(item, script)
        self.assertNotIn('SetEnvironmentVariable(', script)
        self.assertNotIn('~/.codex', script)

    @unittest.skipUnless(shutil.which('node'), 'Node.js is unavailable')
    def test_activation_marker_requires_an_active_codex_sidebar(self):
        probe = ROOT / 'windows-installer/activation-probe/test.js'
        with tempfile.TemporaryDirectory(prefix='emtroly-activation-') as temporary:
            temp = Path(temporary)
            mock = temp / 'node_modules/vscode'
            mock.mkdir(parents=True)
            (mock / 'index.js').write_text(
                "exports.extensions={getExtension:()=>({activate:async()=>{}})};"
                "exports.commands={getCommands:async()=>process.env.TEST_MISSING ? [] : ['chatgpt.openSidebar']};",
                encoding='utf-8')
            marker = temp / 'success.txt'
            environment = dict(os.environ, NODE_PATH=str(temp / 'node_modules'),
                               EMTROLY_CODEX_ACTIVATION_MARKER=str(marker), TEST_MISSING='1')
            command = ['node', '-e', "require(process.argv[1]).run().catch(()=>process.exit(1))", str(probe)]
            failed = subprocess.run(command, env=environment, capture_output=True, timeout=30)
            self.assertNotEqual(failed.returncode, 0)
            self.assertFalse(marker.exists())
            environment.pop('TEST_MISSING')
            passed = subprocess.run(command, env=environment, capture_output=True, timeout=30)
            self.assertEqual(passed.returncode, 0)
            self.assertEqual(marker.read_text(encoding='utf-8'), 'ok')


@unittest.skipUnless(PWSH, 'PowerShell is unavailable')
class EditorPowerShellTests(unittest.TestCase):
    def test_download_verification_and_argument_quoting(self):
        with tempfile.TemporaryDirectory(prefix='emtroly-editor-unit-') as temporary:
            temp = Path(temporary)
            driver = temp / 'driver.ps1'
            driver.write_text(r'''
param($ModulePath, $Directory)
$ErrorActionPreference = 'Stop'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($ModulePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'parse-failed' }
foreach ($name in @('Quote-Cmd', 'Get-VerifiedDownload')) {
  $node = @($ast.FindAll({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name }, $true))
  if ($node.Count -ne 1) { throw 'function-not-found' }
  Invoke-Expression $node[0].Extent.Text
}
if ((Quote-Cmd 'C:\Users\Test User\file.exe') -ne '"C:\Users\Test User\file.exe"') { throw 'quote-failed' }
try { Quote-Cmd 'C:\bad%name' | Out-Null; throw 'unsafe-path-accepted' } catch {
  if ($_.Exception.Message -ne 'editor-invalid-path') { throw }
}
$source = Join-Path $Directory 'source.bin'
$target = Join-Path $Directory 'target.bin'
[IO.File]::WriteAllText($source, 'fixture')
function Invoke-WebRequest { param([switch]$UseBasicParsing, $Uri, $OutFile, $TimeoutSec) Copy-Item -LiteralPath $Uri -Destination $OutFile -Force }
$hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
Get-VerifiedDownload -Url $source -Path $target -Hash $hash
try { Get-VerifiedDownload -Url $source -Path $target -Hash ('0' * 64); throw 'bad-hash-accepted' } catch {
  if ($_.Exception.Message -ne 'editor-download-checksum') { throw }
}
''', encoding='utf-8')
            result = subprocess.run([PWSH, '-NoLogo', '-NoProfile', '-File', str(driver),
                                     '-ModulePath', str(MODULE), '-Directory', str(temp)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


@unittest.skipUnless(os.name == 'nt' and os.environ.get('GITHUB_ACTIONS') == 'true',
                     'Requires a disposable Windows GitHub Actions runner')
class EditorWindowsFixtureTests(unittest.TestCase):
    def test_private_editor_install_with_mocked_downloads_and_processes(self):
        with tempfile.TemporaryDirectory(prefix='emtroly editor ') as temporary:
            temp = Path(temporary)
            driver = temp / 'driver.ps1'
            staged_module = temp / 'install-antigravity-codex.ps1'
            module_source = MODULE.read_text(encoding='utf-8')
            download = '  Get-VerifiedDownload -Url $extensionUrl -Path $vsix -Hash $extensionHash'
            self.assertEqual(module_source.count(download), 1)
            module_source = module_source.replace(download, "  [IO.File]::WriteAllText($vsix, 'fixture')")
            staged_module.write_text(module_source, encoding='utf-8-sig')
            shutil.copytree(ROOT / 'windows-installer/activation-probe', temp / 'activation-probe')
            driver.write_text(r'''
param($ModulePath, $Directory)
$ErrorActionPreference = 'Stop'
$env:LOCALAPPDATA = Join-Path $Directory 'Local AppData'
$env:TEMP = Join-Path $Directory 'Temp Files'
[void](New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA, $env:TEMP)
$editorFolder = Join-Path $env:LOCALAPPDATA 'Programs\Antigravity IDE'
[void](New-Item -ItemType Directory -Force -Path (Join-Path $editorFolder 'bin'), (Join-Path $editorFolder 'resources\app'))
[IO.File]::WriteAllText((Join-Path $editorFolder 'Antigravity IDE.exe'), 'fixture')
[IO.File]::WriteAllText((Join-Path $editorFolder 'bin\antigravity-ide.cmd'), 'fixture')
[IO.File]::WriteAllText((Join-Path $editorFolder 'resources\app\product.json'), '{"applicationName":"antigravity-ide","version":"1.107.0"}')
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Em Trợ Lý - Antigravity.lnk'
if (Test-Path -LiteralPath $shortcutPath) { throw 'fixture-shortcut-already-exists' }
function global:Get-AuthenticodeSignature { param($LiteralPath) return @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Google LLC' } } }
function global:Invoke-WebRequest { param([switch]$UseBasicParsing, $Uri, $OutFile, $TimeoutSec) [IO.File]::WriteAllText($OutFile, 'fixture') }
function global:Get-FileHash { param($LiteralPath, $Algorithm) return @{ Hash = '5abdd18242a77e85e60b8b727231924c4cdf048fdf5c39079e5d811390c3fca8' } }
function global:Start-Process {
  param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)
  if ($FilePath -match 'cmd\.exe$') {
    $extension = Join-Path $env:LOCALAPPDATA 'EmTroLy\Antigravity\Extensions\openai.chatgpt-fixture'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $extension 'bin\windows-x86_64'))
    [IO.File]::WriteAllText((Join-Path $extension 'package.json'), '{"publisher":"openai","name":"chatgpt","version":"26.51111.21308"}')
    [IO.File]::WriteAllText((Join-Path $extension 'bin\windows-x86_64\codex.exe'), 'fixture')
  }
  if ($FilePath -match 'Antigravity IDE\.exe$') { [IO.File]::WriteAllText($env:EMTROLY_CODEX_ACTIVATION_MARKER, 'ok') }
  $process = [pscustomobject]@{ ExitCode = 0 }
  $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $true }
  return $process
}
$settings = [pscustomobject]@{ base_url='https://codex.anhlaptrinh.vn/v1'; model='GPT-6.1-sol'; ai_api_key='fixture-secret-not-real' }
$status = Join-Path $Directory 'status.txt'
try {
  & $ModulePath -Settings $settings -StatusFile $status -CheckOnly
  if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'EmTroLy')) { throw 'preflight-wrote-files' }
  & $ModulePath -Settings $settings -StatusFile $status
  $base = Join-Path $env:LOCALAPPDATA 'EmTroLy'
  $auth = Get-Content -LiteralPath (Join-Path $base 'Codex\auth.json') -Raw | ConvertFrom-Json
  if ($auth.OPENAI_API_KEY -cne $settings.ai_api_key) { throw 'wrong-auth' }
  if (-not (Test-Path -LiteralPath $shortcutPath)) { throw 'shortcut-missing' }
  $launch = [IO.File]::ReadAllText((Join-Path $base 'launch-antigravity.vbs'), [Text.Encoding]::Unicode)
  if ($launch -notmatch 'CODEX_HOME' -or $launch -notmatch '--extensions-dir') { throw 'bad-launcher' }
  try { & $ModulePath -Settings $settings -StatusFile $status -CheckOnly; throw 'overwrite-accepted' } catch {
    if ($_.Exception.Message -ne 'editor-data-exists') { throw }
  }
} finally {
  if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
}
''', encoding='utf-8-sig')
            shell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
            result = subprocess.run([str(shell), '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                                     '-File', str(driver), '-ModulePath', str(staged_module), '-Directory', str(temp)],
                                    capture_output=True, text=True, timeout=60,
                                    creationflags=subprocess.CREATE_NO_WINDOW)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
