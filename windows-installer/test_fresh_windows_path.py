import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROBE = Path(__file__).resolve().parent / 'verify-openclaw-command.ps1'
WINDOWS_CI = os.name == 'nt' and os.environ.get('GITHUB_ACTIONS') == 'true'


@unittest.skipUnless(WINDOWS_CI, 'Requires a disposable Windows GitHub Actions runner')
class FreshWindowsPathTests(unittest.TestCase):
    def setUp(self):
        import winreg

        self.winreg = winreg
        self.key = winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, 'Environment', 0,
                                      winreg.KEY_QUERY_VALUE | winreg.KEY_SET_VALUE)
        try:
            self.previous_path = winreg.QueryValueEx(self.key, 'Path')
        except FileNotFoundError:
            self.previous_path = None
        self.addCleanup(self.restore_path)
        self.temporary = tempfile.TemporaryDirectory(prefix='emtroly-path-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / 'Th\u1eed nghi\u1ec7m c\u00f3 d\u1ea5u' / 'openclaw'
        self.root.mkdir(parents=True)
        self.bin = self.root.parent / 'bin with spaces'
        self.bin.mkdir()
        self.command = self.bin / 'openclaw.cmd'
        self.write_command()
        self.write_info()

    def restore_path(self):
        if self.previous_path is None:
            try:
                self.winreg.DeleteValue(self.key, 'Path')
            except FileNotFoundError:
                pass
        else:
            self.winreg.SetValueEx(self.key, 'Path', 0, self.previous_path[1], self.previous_path[0])
        self.key.Close()

    def write_info(self, default=True):
        (self.root / 'windows-cli.json').write_text(json.dumps({
            'default': default, 'command': 'openclaw' if default else 'openclaw-member-0123456789ab',
            'path': str(self.command),
        }), encoding='utf-8')

    def write_command(self, version='2026.11.4', status=0):
        self.command.write_text(
            '@echo off\r\n'
            'if "%OPENCLAW_STATE_DIR%"=="should-not-inherit" exit /b 17\r\n'
            f'if "%1"=="--version" (echo {version}& exit /b 0)\r\n'
            f'if "%1"=="status" exit /b {status}\r\n'
            'exit /b 1\r\n', encoding='ascii')

    def run_probe(self, directories=None):
        if directories is not None:
            self.winreg.SetValueEx(self.key, 'Path', 0, self.winreg.REG_EXPAND_SZ,
                                   ';'.join(str(path) for path in directories))
        env = dict(os.environ, EMTROLY_PROBE_ROOT=str(self.root),
                   EMTROLY_PROBE_VERSION='2026.11.4', OPENCLAW_STATE_DIR='should-not-inherit')
        shell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        return subprocess.run([str(shell), '-NoLogo', '-NoProfile', '-NonInteractive',
                               '-ExecutionPolicy', 'Bypass', '-File', str(PROBE)],
                              env=env, capture_output=True, timeout=60,
                              creationflags=subprocess.CREATE_NO_WINDOW).returncode

    def test_fresh_shell_finds_expected_command_without_installer_environment(self):
        self.assertEqual(self.run_probe([self.bin]), 0)

    def test_existing_other_command_is_not_claimed(self):
        other = self.root.parent / 'existing'
        other.mkdir()
        (other / 'openclaw.cmd').write_text('@exit /b 0\r\n', encoding='ascii')
        self.assertEqual(self.run_probe([other, self.bin]), 12)

    def test_missing_command_and_nondefault_alias_fail(self):
        self.assertEqual(self.run_probe([]), 12)
        self.write_info(default=False)
        self.assertEqual(self.run_probe([self.bin]), 11)

    def test_wrong_version_and_failing_status_fail(self):
        self.write_command(version='0.0.0')
        self.assertEqual(self.run_probe([self.bin]), 13)
        self.write_command(status=1)
        self.assertEqual(self.run_probe([self.bin]), 14)

    def test_native_registration_and_status_in_windows_powershell_51(self):
        source = PROBE.parents[1] / 'install-native-windows.ps1'
        runtime = self.root / 'runtime'
        runtime.mkdir()
        entry = runtime / 'openclaw.mjs'
        entry.write_text("if (process.argv[2] === '--version') console.log('2026.11.4'); "
                         "else if (process.argv[2] !== 'status') process.exit(2);", encoding='ascii')
        (self.root / 'openclaw.json').write_text('{"gateway":{"port":18789}}', encoding='ascii')
        local_data = self.root.parent / 'local'
        local_data.mkdir()
        driver = self.root.parent / 'register.ps1'
        driver.write_text(r'''
param($Source, $Root, $Entry, $LocalData)
$ErrorActionPreference = 'Stop'
$env:LOCALAPPDATA = $LocalData
$runtime = Split-Path $Entry
$ast = [Management.Automation.Language.Parser]::ParseFile($Source, [ref]$null, [ref]$null)
$definition = $ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Install-UserOpenClawCli' }, $true)
$functionText = $definition.Extent.Text.Replace('$PSScriptRoot', '$sourceDir')
$sourceDir = Split-Path $Source
. ([ScriptBlock]::Create($functionText))
function Write-NativeInstallStatus([string]$Text) {}
try {
  Install-UserOpenClawCli -Root $Root -CliEntry $Entry -Port 18789 -Profile 'fixture' -ExpectedVersion '2026.11.4'
} catch {
  $helperDir = Join-Path $sourceDir 'native\skills\tao-tro-ly-openclaw-windows-macos-linux\scripts'
  & python.exe -c 'import sys; sys.path.insert(0,sys.argv[1]); from install_windows_cli import install; install(*sys.argv[2:6],18789)' $helperDir $Root ([Environment]::GetFolderPath('UserProfile')) (Get-Command node.exe).Source $Entry
  throw
}
''', encoding='ascii')
        shell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        result = subprocess.run([str(shell), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                                 '-File', str(driver), str(source), str(self.root), str(entry), str(local_data)],
                                capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        info = json.loads((self.root / 'windows-cli.json').read_text(encoding='utf-8'))
        self.assertTrue(info['default'])
        self.assertEqual(Path(info['path']).parent, local_data / 'OpenClaw/bin')
        self.assertEqual(self.run_probe(), 0)
