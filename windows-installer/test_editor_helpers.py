import hashlib
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'windows-installer/install-antigravity-codex.ps1'
REPAIR = ROOT / 'windows-installer/repair-antigravity-shortcut.ps1'
PWSH = os.environ.get('PWSH') or shutil.which('pwsh')


class EditorContractTests(unittest.TestCase):
    def test_component_is_packaged_and_required_for_success(self):
        build = (ROOT / 'build-windows-installer.sh').read_text(encoding='utf-8')
        runner = (ROOT / 'windows-installer/run-native-install.ps1').read_text(encoding='utf-8')
        wizard = (ROOT / 'windows-installer/wizard.ps1').read_text(encoding='utf-8')
        nsi = (ROOT / 'windows-installer/member-vps-installer.nsi').read_text(encoding='utf-8')
        self.assertIn('install-antigravity-codex.ps1', build)
        self.assertIn('repair-antigravity-shortcut.ps1', build)
        self.assertIn('activation-probe', build)
        self.assertIn('repair-antigravity-shortcut.ps1', nsi)
        self.assertIn('-EditorOnly', wizard)
        self.assertIn('$editorSettings', runner)
        self.assertIn('skip_editor = [bool]$existingEditorCheck.Checked', wizard)
        self.assertNotIn('OpenFileDialog', wizard)

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

    def test_shortcut_uses_ascii_name_and_repairs_existing_file(self):
        script = MODULE.read_text(encoding='utf-8')
        self.assertIn("'EmTroLy - Antigravity.lnk'", script)
        self.assertIn("if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }", script)
        self.assertIn('shell.CurrentDirectory', script)
        self.assertIn('command = Chr(34)', script)
        self.assertIn('shell.Run command, 1, False', script)
        self.assertIn('$saved.TargetPath -ieq', script)
        self.assertIn('$saved.WorkingDirectory -ieq $Root', script)
        self.assertNotIn("throw 'editor-shortcut-exists'", script)

    def test_shortcut_repair_requires_a_complete_install(self):
        script = REPAIR.read_text(encoding='utf-8')
        for item in ('installer-codex-pending.json', 'Codex\\config.toml', 'Codex\\auth.json',
                     'Antigravity\\UserData\\User\\settings.json', 'package.json',
                     'bin\\windows-x86_64\\codex.exe', 'shell.CurrentDirectory = "$($appRoot.Replace'):
            self.assertIn(item, script)

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
foreach ($name in @('Quote-Cmd', 'Get-VerifiedDownload', 'Get-EditorRegistryDirectories', 'Test-GoogleAuthenticodeSignature')) {
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
$registryDirectory = Join-Path $Directory 'directory with spaces'
$entry = [pscustomobject]@{ InstallLocation = $registryDirectory; DisplayIcon = ('"' + (Join-Path $registryDirectory 'Antigravity IDE.exe') + '",0'); UninstallString = ('"' + (Join-Path $registryDirectory 'unins000.exe') + '" /SILENT') }
$directories = @(Get-EditorRegistryDirectories $entry)
if ($directories.Count -ne 1 -or $directories[0] -cne $registryDirectory) { throw 'registry-paths-not-deduplicated' }
$empty = [pscustomobject]@{ InstallLocation = ''; DisplayIcon = ''; UninstallString = '' }
if (@(Get-EditorRegistryDirectories $empty).Count -ne 0) { throw 'empty-registry-not-ambiguous' }
function global:Get-AuthenticodeSignature {
  param($LiteralPath)
  if ($LiteralPath -match 'Antigravity IDE\.exe$') { return @{ Status = 'NotSigned'; SignerCertificate = $null } }
  return @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Google LLC' } }
}
if (-not (Test-GoogleAuthenticodeSignature -Path $source -ExpectedHash $hash)) { throw 'valid-signature-rejected' }
function global:Get-AuthenticodeSignature { param($LiteralPath) return @{ Status = 'Unknown'; SignerCertificate = @{ Subject = 'CN=Google LLC' } } }
if (-not (Test-GoogleAuthenticodeSignature -Path $source -ExpectedHash $hash)) { throw 'unknown-pinned-signature-rejected' }
if (Test-GoogleAuthenticodeSignature -Path $source -ExpectedHash ('0' * 64)) { throw 'unknown-wrong-hash-accepted' }
if (-not (Test-GoogleAuthenticodeSignature -Path $source -AllowUnknownWithGoogleSigner)) { throw 'unknown-installed-signature-rejected' }
function global:Get-AuthenticodeSignature { param($LiteralPath) return @{ Status = 'NotSigned'; SignerCertificate = $null } }
if (Test-GoogleAuthenticodeSignature -Path $source -ExpectedHash $hash) { throw 'unsigned-file-accepted' }
function global:Get-AuthenticodeSignature { param($LiteralPath) return @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Not Google' } } }
if (Test-GoogleAuthenticodeSignature -Path $source -ExpectedHash $hash) { throw 'non-google-file-accepted' }
''', encoding='utf-8')
            result = subprocess.run([PWSH, '-NoLogo', '-NoProfile', '-File', str(driver),
                                     '-ModulePath', str(MODULE), '-Directory', str(temp)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_new_editor_preflight_distinguishes_installed_from_stale(self):
        with tempfile.TemporaryDirectory(prefix='emtroly-preflight-') as temporary:
            temp = Path(temporary)
            module = temp / 'install-antigravity-codex.ps1'
            text = MODULE.read_text(encoding='utf-8')
            desktop = "([Environment]::GetFolderPath('Desktop'))"
            self.assertEqual(text.count(desktop), 1)
            module.write_text(text.replace(desktop, '$env:TEST_DESKTOP'), encoding='utf-8-sig')
            shutil.copytree(ROOT / 'windows-installer/activation-probe', temp / 'activation-probe')
            driver = temp / 'preflight.ps1'
            driver.write_text(r'''
param($ModulePath, $Directory)
$ErrorActionPreference = 'Stop'
$env:OS = 'Windows_NT'
$env:LOCALAPPDATA = Join-Path $Directory 'local'
$env:TEMP = $Directory
$env:SystemRoot = Join-Path $Directory 'windows'
$env:TEST_DESKTOP = Join-Path $Directory 'desktop'
$env:ProgramFiles = ''
${env:ProgramFiles(x86)} = ''
$old = Join-Path $env:LOCALAPPDATA 'Programs\Antigravity IDE'
$selected = Join-Path $Directory 'existing\Antigravity IDE'
foreach ($path in @($old, $env:TEST_DESKTOP, (Join-Path $env:SystemRoot 'System32'), (Join-Path $selected 'bin'), (Join-Path $selected 'resources\app'))) { [void](New-Item -ItemType Directory -Force -Path $path) }
[IO.File]::WriteAllText((Join-Path $old 'keep.txt'), 'keep')
[IO.File]::WriteAllText((Join-Path $env:SystemRoot 'System32\wscript.exe'), 'fixture')
[IO.File]::WriteAllText((Join-Path $selected 'Antigravity IDE.exe'), 'fixture')
[IO.File]::WriteAllText((Join-Path $selected 'bin\antigravity-ide.cmd'), 'fixture')
[IO.File]::WriteAllText((Join-Path $selected 'resources\app\product.json'), '{"applicationName":"antigravity-ide","version":"1.107.0"}')
function global:Get-AuthenticodeSignature { param($LiteralPath) return @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Google LLC' } } }
function global:Get-ItemProperty { param($Path, $ErrorAction) return $global:fixtureRegistry }
$settings = [pscustomobject]@{job_id='0123456789abcdef0123456789abcdef'; base_url='https://codex.anhlaptrinh.vn/v1'; ai_api_key='fixture'}
$status = Join-Path $Directory 'status.txt'
$global:fixtureRegistry = @([pscustomobject]@{DisplayName='Antigravity IDE'; InstallLocation=$old; DisplayIcon=''; UninstallString=''; PSChildName='fixture'})
& $ModulePath -Settings $settings -StatusFile $status -CheckOnly
if (-not (Test-Path -LiteralPath (Join-Path $old 'keep.txt'))) { throw 'old-files-changed' }
if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'EmTroLy')) { throw 'preflight-created-files' }
$global:fixtureRegistry = @([pscustomobject]@{DisplayName='Antigravity IDE'; InstallLocation=$selected; DisplayIcon=''; UninstallString=''; PSChildName='fixture'})
try { & $ModulePath -Settings $settings -StatusFile $status -CheckOnly; throw 'did-not-detect-existing' } catch { if ($_.Exception.Message -ne 'editor-select-existing') { throw } }
$global:fixtureRegistry = @([pscustomobject]@{DisplayName='Antigravity IDE'; InstallLocation=''; DisplayIcon=''; UninstallString=''; PSChildName='fixture'})
try { & $ModulePath -Settings $settings -StatusFile $status -CheckOnly; throw 'did-not-detect-ambiguous' } catch { if ($_.Exception.Message -ne 'editor-registry-ambiguous') { throw } }
''', encoding='utf-8-sig')
            result = subprocess.run([PWSH, '-NoLogo', '-NoProfile', '-File', str(driver),
                                     '-ModulePath', str(module), '-Directory', str(temp)],
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
            transport = 'Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path -TimeoutSec 900'
            self.assertEqual(module_source.count(transport), 1)
            module_source = module_source.replace(transport, "[IO.File]::WriteAllText($Path, 'fixture')")
            fixture_digest = hashlib.sha256(b'fixture').hexdigest()
            module_source, count = re.subn(r"(?m)^(\$(?:ide|extension)Hash = ')[0-9a-f]{64}'$",
                                           lambda match: match[1] + fixture_digest + "'", module_source)
            self.assertEqual(count, 2)
            staged_module.write_text(module_source, encoding='utf-8-sig')
            shutil.copytree(ROOT / 'windows-installer/activation-probe', temp / 'activation-probe')
            driver.write_text(r'''
param($ModulePath, $Directory)
$ErrorActionPreference = 'Stop'
$env:LOCALAPPDATA = Join-Path $Directory 'Local AppData'
$env:TEMP = Join-Path $Directory 'Temp Files'
[void](New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA, $env:TEMP)
$oldFolder = Join-Path $env:LOCALAPPDATA 'Programs\Antigravity IDE'
[void](New-Item -ItemType Directory -Force -Path $oldFolder)
[IO.File]::WriteAllText((Join-Path $oldFolder 'leftover.txt'), 'keep')
$editorFolder = Join-Path $env:LOCALAPPDATA 'Different Location\Antigravity IDE'
[void](New-Item -ItemType Directory -Force -Path (Join-Path $editorFolder 'bin'), (Join-Path $editorFolder 'resources\app'))
[IO.File]::WriteAllText((Join-Path $editorFolder 'Antigravity IDE.exe'), 'fixture')
[IO.File]::WriteAllText((Join-Path $editorFolder 'bin\antigravity-ide.cmd'), 'fixture')
[IO.File]::WriteAllText((Join-Path $editorFolder 'resources\app\product.json'), '{"applicationName":"antigravity-ide","version":"1.107.0"}')
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'EmTroLy - Antigravity.lnk'
if (Test-Path -LiteralPath $shortcutPath) { throw 'fixture-shortcut-already-exists' }
function global:Get-AuthenticodeSignature {
  param($LiteralPath)
  if ($LiteralPath -match 'Antigravity IDE\.exe$') { return @{ Status = 'NotSigned'; SignerCertificate = $null } }
  return @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Google LLC' } }
}
$global:fixtureRegistry = @()
function global:Get-ItemProperty { param($Path, $ErrorAction) return $global:fixtureRegistry }
function global:Start-Process {
  param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)
  if ($FilePath -match 'antigravity-ide-setup\.exe$') {
    if ($ArgumentList -notmatch '/DIR="([^"]+)"') { throw 'no-install-directory' }
    Copy-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'Different Location\Antigravity IDE') -Destination $Matches[1] -Recurse
  } elseif ($env:CODEX_HOME -ne (Join-Path $env:LOCALAPPDATA 'EmTroLy\Codex')) { throw 'codex-home-not-isolated' }
  if ($FilePath -match 'cmd\.exe$') {
    if (-not $ArgumentList.Contains((Join-Path $env:LOCALAPPDATA 'EmTroLy\Antigravity\Extensions'))) { throw 'wrong-extension-directory' }
    $extension = Join-Path $env:LOCALAPPDATA 'EmTroLy\Antigravity\Extensions\openai.chatgpt-fixture'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $extension 'bin\windows-x86_64'))
    [IO.File]::WriteAllText((Join-Path $extension 'package.json'), '{"publisher":"openai","name":"chatgpt","version":"26.51111.21308"}')
    [IO.File]::WriteAllText((Join-Path $extension 'bin\windows-x86_64\codex.exe'), 'fixture')
  }
  if ($FilePath -match 'Antigravity IDE\.exe$') { [IO.File]::WriteAllText($env:EMTROLY_CODEX_ACTIVATION_MARKER, 'ok') }
  $exitValue = if ($env:TEST_FAIL_CODEX -and $FilePath -match 'codex\.exe$') { 1 } else { 0 }
  $process = [pscustomobject]@{ ExitCode = $exitValue }
  $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $true }
  return $process
}
$settings = [pscustomobject]@{ job_id='0123456789abcdef0123456789abcdef'; base_url='https://codex.anhlaptrinh.vn/v1'; model='GPT-6.1-sol'; ai_api_key='fixture-secret-not-real' }
$status = Join-Path $Directory 'status.txt'
try {
  $global:fixtureRegistry = @([pscustomobject]@{ DisplayName='Antigravity IDE'; InstallLocation=$oldFolder; DisplayIcon=''; UninstallString=''; PSChildName='fixture' })
  & $ModulePath -Settings $settings -StatusFile $status -CheckOnly
  if (-not (Test-Path -LiteralPath (Join-Path $oldFolder 'leftover.txt'))) { throw 'deleted-old-files' }
  $global:fixtureRegistry = @([pscustomobject]@{ DisplayName='Antigravity IDE'; InstallLocation=$editorFolder; DisplayIcon=''; UninstallString=''; PSChildName='fixture' })
  try { & $ModulePath -Settings $settings -StatusFile $status -CheckOnly; throw 'existing-not-detected' } catch {
    if ($_.Exception.Message -ne 'editor-select-existing') { throw }
  }
  $global:fixtureRegistry = @([pscustomobject]@{ DisplayName='Antigravity IDE'; InstallLocation=''; DisplayIcon=''; UninstallString=''; PSChildName='fixture' })
  try { & $ModulePath -Settings $settings -StatusFile $status -CheckOnly; throw 'ambiguous-not-detected' } catch {
    if ($_.Exception.Message -ne 'editor-registry-ambiguous') { throw }
  }
  $global:fixtureRegistry = @()
$partial = Join-Path $env:LOCALAPPDATA 'EmTroLy'
[void](New-Item -ItemType Directory -Force -Path $partial)
[IO.File]::WriteAllText((Join-Path $partial 'stale.txt'), 'partial-install')
[IO.File]::WriteAllText((Join-Path $partial 'installer-job.txt'), 'fedcba9876543210fedcba9876543210')
[void](New-Item -ItemType Directory -Force -Path (Join-Path $partial 'Codex'), (Join-Path $partial 'Antigravity\UserData\User'), (Join-Path $partial 'Antigravity\Extensions\openai.chatgpt-fixture\bin\windows-x86_64'))
[IO.File]::WriteAllText((Join-Path $partial 'Codex\config.toml'), 'partial')
[IO.File]::WriteAllText((Join-Path $partial 'Codex\auth.json'), '{}')
[IO.File]::WriteAllText((Join-Path $partial 'Antigravity\UserData\User\settings.json'), '{}')
[IO.File]::WriteAllText((Join-Path $partial 'launch-antigravity.vbs'), 'partial')
[IO.File]::WriteAllText((Join-Path $partial 'Antigravity\Extensions\openai.chatgpt-fixture\package.json'), '{"publisher":"openai","name":"chatgpt","version":"26.51111.21308"}')
[IO.File]::WriteAllText((Join-Path $partial 'Antigravity\Extensions\openai.chatgpt-fixture\bin\windows-x86_64\codex.exe'), 'fixture')
$partialApp = Join-Path $env:LOCALAPPDATA 'Programs\EmTroLy-Antigravity-IDE-0123456789abcdef0123456789abcdef'
[void](New-Item -ItemType Directory -Force -Path $partialApp)
[IO.File]::WriteAllText((Join-Path $partialApp 'leftover.txt'), 'partial-app')
  $env:TEST_FAIL_CODEX = '1'
  try { & $ModulePath -Settings $settings -StatusFile $status; throw 'codex-failure-ignored' } catch {
    if ($_.Exception.Message -ne 'editor-codex-probe-failed') { throw }
  }
$backups = @(Get-ChildItem -LiteralPath $env:LOCALAPPDATA -Directory -Filter 'EmTroLy.failed-*')
if ($backups.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $backups[0].FullName 'stale.txt'))) { throw 'partial-editor-data-not-backed-up' }
if (-not (Test-Path -LiteralPath (Join-Path $backups[0].FullName 'Programs\EmTroLy-Antigravity-IDE-0123456789abcdef0123456789abcdef\leftover.txt'))) { throw 'partial-editor-app-not-backed-up' }
  $env:TEST_FAIL_CODEX = ''
  [IO.File]::WriteAllBytes($shortcutPath, [byte[]](0..7))
  & $ModulePath -Settings $settings -StatusFile $status
  $base = Join-Path $env:LOCALAPPDATA 'EmTroLy'
  $auth = Get-Content -LiteralPath (Join-Path $base 'Codex\auth.json') -Raw | ConvertFrom-Json
  if ($auth.OPENAI_API_KEY -cne $settings.ai_api_key) { throw 'wrong-auth' }
  if (-not (Test-Path -LiteralPath $shortcutPath)) { throw 'shortcut-missing' }
  $savedShortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
  if ($savedShortcut.TargetPath -ine (Join-Path $env:SystemRoot 'System32\wscript.exe') -or
      $savedShortcut.Arguments -notmatch [regex]::Escape('launch-antigravity.vbs') -or
      $savedShortcut.WorkingDirectory -ine (Join-Path $env:LOCALAPPDATA 'EmTroLy')) { throw 'shortcut-not-repaired' }
  $launch = [IO.File]::ReadAllText((Join-Path $base 'launch-antigravity.vbs'), [Text.Encoding]::Unicode)
  if ($launch -notmatch 'CODEX_HOME' -or $launch -notmatch '--extensions-dir') { throw 'bad-launcher' }
  $settings.job_id = '11111111111111111111111111111111'
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

    def test_existing_install_repair_recreates_a_working_shortcut(self):
        with tempfile.TemporaryDirectory(prefix='emtroly-repair ') as temporary:
            temp = Path(temporary)
            repair = temp / 'repair-antigravity-shortcut.ps1'
            repair.write_text(REPAIR.read_text(encoding='utf-8'), encoding='utf-8-sig')
            driver = temp / 'driver.ps1'
            driver.write_text(r'''
param($RepairPath, $Directory)
$ErrorActionPreference = 'Stop'
$env:LOCALAPPDATA = Join-Path $Directory 'Local AppData'
$env:TEMP = Join-Path $Directory 'Temp Files'
$env:USERPROFILE = Join-Path $Directory 'User Profile'
[void](New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA, $env:TEMP, $env:USERPROFILE)
$base = Join-Path $env:LOCALAPPDATA 'EmTroLy'
$app = Join-Path $env:LOCALAPPDATA 'Programs\EmTroLy-Antigravity-IDE-0123456789abcdef0123456789abcdef'
$desktop = [Environment]::GetFolderPath('Desktop')
[void](New-Item -ItemType Directory -Force -Path $desktop)
$shortcutPath = Join-Path $desktop 'EmTroLy - Antigravity.lnk'
if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
[void](New-Item -ItemType Directory -Force -Path (Join-Path $app 'bin'), (Join-Path $app 'resources\app'),
  (Join-Path $base 'Codex'), (Join-Path $base 'Antigravity\UserData\User'),
  (Join-Path $base 'Antigravity\Extensions\openai.chatgpt-fixture\bin\windows-x86_64'))
[IO.File]::WriteAllText((Join-Path $base 'installer-job.txt'), '0123456789abcdef0123456789abcdef')
[IO.File]::WriteAllText((Join-Path $base 'Codex\config.toml'), 'base_url = "https://codex.anhlaptrinh.vn/v1"`nrequires_openai_auth = true')
[IO.File]::WriteAllText((Join-Path $base 'Codex\auth.json'), '{"OPENAI_API_KEY":"fixture-secret-not-real"}')
[IO.File]::WriteAllText((Join-Path $base 'Antigravity\UserData\User\settings.json'), '{}')
[IO.File]::WriteAllText((Join-Path $base 'Antigravity\Extensions\openai.chatgpt-fixture\package.json'), '{"publisher":"openai","name":"chatgpt","version":"26.51111.21308"}')
[IO.File]::WriteAllText((Join-Path $base 'Antigravity\Extensions\openai.chatgpt-fixture\bin\windows-x86_64\codex.exe'), 'fixture')
[IO.File]::WriteAllText((Join-Path $app 'Antigravity IDE.exe'), 'fixture')
[IO.File]::WriteAllText((Join-Path $app 'bin\antigravity-ide.cmd'), 'fixture')
[IO.File]::WriteAllText((Join-Path $app 'resources\app\product.json'), '{"applicationName":"antigravity-ide","version":"1.107.0"}')
& $RepairPath
if ($LASTEXITCODE -ne 0) { throw "repair-failed-$LASTEXITCODE" }
$saved = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
if ($saved.TargetPath -ine $wscript -or $saved.Arguments -notmatch 'launch-antigravity\.vbs' -or
    $saved.WorkingDirectory -ine $base) { throw 'shortcut-not-repaired' }
$launch = [IO.File]::ReadAllText((Join-Path $base 'launch-antigravity.vbs'), [Text.Encoding]::Unicode)
if ($launch -notmatch [regex]::Escape((Join-Path $app 'Antigravity IDE.exe')) -or
    $launch -notmatch [regex]::Escape($app) -or $launch -notmatch 'command = Chr\(34\)') { throw 'launcher-not-repaired' }
''', encoding='utf-8-sig')
            shell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
            result = subprocess.run([str(shell), '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                                     '-File', str(driver), '-RepairPath', str(repair), '-Directory', str(temp)],
                                    capture_output=True, text=True, timeout=30,
                                    creationflags=subprocess.CREATE_NO_WINDOW)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
