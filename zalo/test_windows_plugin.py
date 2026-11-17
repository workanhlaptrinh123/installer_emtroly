import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


RELEASE = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('PWSH') or shutil.which('pwsh')
NODE = shutil.which('node')
PRIVATE_MARKER = 'fixture-private-error-DO-NOT-LOG'

FAKE_CLI = r'''
const fs = require('fs');
const path = require('path');
const args = process.argv.slice(2);
const directory = process.env.FIXTURE_ROOT;
const mode = process.env.FIXTURE_MODE;
const statePath = path.join(directory, 'plugin-state.json');
const logPath = path.join(directory, 'calls.log');
fs.appendFileSync(logPath, JSON.stringify(args) + '\n');
const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
const save = () => fs.writeFileSync(statePath, JSON.stringify(state));
if (mode === 'stderr-warning') process.stderr.write(process.env.PRIVATE_MARKER + '\n');
if (mode === 'large-stderr') process.stderr.write('warning '.repeat(30000));
if (args[0] === '--version') {
  console.log('OpenClaw 2026.11.4');
} else if (args[0] === 'plugins' && args[1] === 'info') {
  if (mode === 'inspect-error') {
    console.error('permission denied ' + process.env.PRIVATE_MARKER);
    process.exit(1);
  }
  if (mode === 'invalid-json') {
    console.log('not json');
    process.exit(0);
  }
  if (state.status === 'absent') {
    console.log(JSON.stringify({ok:false,error:{type:'cli_error',message:'Plugin not found: zalouser. Run the list command.'}}));
    process.exit(1);
  }
  console.log(JSON.stringify({plugin:{id:'zalouser',packageName:mode === 'wrong-package' ? 'unexpected' : '@openclaw/zalouser',
    version:mode === 'wrong-version' ? '2026.9.9' : '2026.11.4',enabled:state.status === 'enabled',
    status:state.status === 'enabled' ? 'loaded' : 'disabled', source:mode === 'missing-source' ? '' : path.join(directory, 'plugin.js')}}));
} else if (args[0] === 'plugins' && args[1] === 'install') {
  if (mode === 'install-failure') {
    console.error('permission denied ' + process.env.PRIVATE_MARKER);
    process.exit(1);
  }
  state.status = 'enabled';
  save();
} else if (args[0] === 'plugins' && args[1] === 'enable') {
  if (mode === 'enable-failure') {
    console.error('capability consent required ' + process.env.PRIVATE_MARKER);
    process.exit(1);
  }
  if (mode !== 'enable-ineffective') state.status = 'enabled';
  save();
} else if (args[0] === 'plugins' && args[1] === 'doctor') {
  if (mode === 'doctor-failure') {
    console.error('gateway unavailable ' + process.env.PRIVATE_MARKER);
    process.exit(1);
  }
} else if (args[0] === 'gateway' && args[1] === 'stop') {
  process.exit(1);
} else if (args[0] === 'gateway' && args[1] === 'health') {
  console.log(JSON.stringify({ok:true,plugins:{loaded:['zalouser']}}));
} else {
  process.exit(2);
}
'''

DRIVER = r'''
param($Onboarding, $FixtureRoot, $CliEntry, $StageFile)
$ErrorActionPreference = 'Stop'
$env:USERPROFILE = $FixtureRoot
$env:OPENCLAW_CLI_ENTRY = $CliEntry
$env:MEMBER_INSTALL_ZALO_STAGE_FILE = $StageFile
try {
  & $Onboarding -Root $FixtureRoot -TelegramAccount 'fixture' -OwnerId '123456789' -ConfigureScript 'unused' -QrScript 'unused'
  exit 0
} catch {
  Write-Output ([string]$_.Exception.Message)
  exit 1
}
'''


@unittest.skipUnless(PWSH and NODE, 'PowerShell and Node.js are required')
class WindowsPluginTests(unittest.TestCase):
    def execute(self, mode, initial='enabled'):
        with tempfile.TemporaryDirectory(prefix='member plugin fixture ') as temporary:
            root = Path(temporary)
            (root / 'openclaw.json').write_text('{}', encoding='utf-8')
            (root / 'plugin-state.json').write_text(json.dumps({'status': initial}), encoding='utf-8')
            cli = root / 'fixture cli.cjs'
            cli.write_text(FAKE_CLI, encoding='utf-8')
            driver = root / 'driver.ps1'
            driver.write_text(DRIVER, encoding='utf-8')
            stage_file = root / 'stage.txt'
            env = {**os.environ, 'FIXTURE_ROOT': str(root), 'FIXTURE_MODE': mode,
                   'PRIVATE_MARKER': PRIVATE_MARKER}
            result = subprocess.run(
                [PWSH, '-NoLogo', '-NoProfile', '-File', str(driver),
                 str(RELEASE / 'zalo/onboard-zalouser-windows.ps1'), str(root), str(cli), str(stage_file)],
                env=env, capture_output=True, text=True, timeout=40,
            )
            calls_file = root / 'calls.log'
            calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
            stage = stage_file.read_text() if stage_file.exists() else ''
            detail_file = root / 'stage.txt.detail'
            detail = detail_file.read_text() if detail_file.exists() else ''
            self.assertNotIn(PRIVATE_MARKER, result.stdout + result.stderr + stage + detail)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            return stage, detail, calls

    def test_already_enabled_plugin_is_not_reinstalled_or_reenabled(self):
        stage, detail, calls = self.execute('success')
        self.assertEqual(stage, 'gateway-stop')
        self.assertEqual(detail, '')
        self.assertNotIn(['plugins', 'enable', 'zalouser'], calls)
        self.assertFalse(any(call[:2] == ['plugins', 'install'] for call in calls))
        self.assertIn(['plugins', 'doctor'], calls)

    def test_fresh_install_that_enables_plugin_is_not_enabled_again(self):
        stage, detail, calls = self.execute('success', initial='absent')
        self.assertEqual((stage, detail), ('gateway-stop', ''))
        self.assertIn(['plugins', 'install', '--pin', '@openclaw/zalouser@2026.11.4'], calls)
        self.assertNotIn(['plugins', 'enable', 'zalouser'], calls)

    def test_disabled_plugin_is_enabled_and_inspected_again(self):
        stage, detail, calls = self.execute('success', initial='disabled')
        self.assertEqual((stage, detail), ('gateway-stop', ''))
        self.assertEqual(calls.count(['plugins', 'enable', 'zalouser']), 1)
        self.assertEqual(calls.count(['plugins', 'info', 'zalouser', '--json']), 2)
        self.assertFalse(any(call[:2] == ['plugins', 'install'] for call in calls))

    def test_stderr_warnings_do_not_break_success_or_leak(self):
        for mode in ('stderr-warning', 'large-stderr'):
            with self.subTest(mode=mode):
                stage, detail, calls = self.execute(mode)
                self.assertEqual((stage, detail), ('gateway-stop', ''))
                self.assertIn(['plugins', 'doctor'], calls)

    def test_real_failures_are_reported_without_private_output(self):
        for mode, initial, expected in (
            ('inspect-error', 'enabled', ('plugin-inspect', 'permission-denied')),
            ('invalid-json', 'enabled', ('plugin-inspect', 'invalid-response')),
            ('install-failure', 'absent', ('plugin-install', 'permission-denied')),
            ('enable-failure', 'disabled', ('plugin-enable', 'approval-required')),
            ('enable-ineffective', 'disabled', ('plugin-inspect', 'plugin-not-loaded')),
            ('doctor-failure', 'enabled', ('plugin-doctor', 'gateway-unavailable')),
            ('wrong-package', 'enabled', ('plugin-inspect', 'plugin-version-mismatch')),
            ('wrong-version', 'enabled', ('plugin-inspect', 'plugin-version-mismatch')),
            ('missing-source', 'enabled', ('plugin-source', 'invalid-response')),
        ):
            with self.subTest(mode=mode):
                stage, detail, calls = self.execute(mode, initial=initial)
                self.assertEqual((stage, detail), expected)
                if mode in ('inspect-error', 'invalid-json', 'wrong-package', 'wrong-version'):
                    self.assertFalse(any(call[:2] == ['plugins', 'install'] for call in calls))

    def test_diagnostic_reports_only_safe_status_without_changing_config(self):
        with tempfile.TemporaryDirectory(prefix='member diagnostic fixture ') as temporary:
            home = Path(temporary)
            root = home / '.openclaw-member-fixture'
            root.mkdir()
            config = root / 'openclaw.json'
            original = json.dumps({'channels': {'telegram': {'token': PRIVATE_MARKER}}})
            config.write_text(original, encoding='utf-8')
            (root / 'plugin-state.json').write_text(json.dumps({'status': 'enabled'}), encoding='utf-8')
            cli = root / 'fixture cli.cjs'
            cli.write_text(FAKE_CLI, encoding='utf-8')
            manifest = {'root': str(root), 'profile': 'member-fixture', 'cli_entry': str(cli),
                        'node': NODE, 'path': os.environ.get('PATH', '')}
            (root / 'installer-instance.json').write_text(json.dumps(manifest), encoding='utf-8')
            env = {**os.environ, 'USERPROFILE': str(home), 'FIXTURE_ROOT': str(root),
                   'FIXTURE_MODE': 'stderr-warning', 'PRIVATE_MARKER': PRIVATE_MARKER}
            result = subprocess.run(
                [PWSH, '-NoLogo', '-NoProfile', '-File', str(RELEASE / 'zalo/diagnose-zalo-windows.ps1'),
                 '-Member', 'fixture'], env=env, capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('RESULT=diagnostic-complete', result.stdout)
            self.assertIn('PLUGIN=enabled-loaded', result.stdout)
            self.assertIn('ZALO_CHANNEL=not-configured', result.stdout)
            self.assertIn('GATEWAY=healthy', result.stdout)
            self.assertIn('GATEWAY_ZALO=loaded', result.stdout)
            self.assertIn('GATEWAY_QR=not-loaded', result.stdout)
            self.assertNotIn(PRIVATE_MARKER, result.stdout + result.stderr)
            self.assertEqual(config.read_text(encoding='utf-8'), original)

    def test_diagnostic_rejects_wrong_instance_root(self):
        with tempfile.TemporaryDirectory(prefix='member diagnostic fixture ') as temporary:
            home = Path(temporary)
            root = home / '.openclaw-member-fixture'
            root.mkdir()
            (root / 'openclaw.json').write_text('{}', encoding='utf-8')
            (root / 'installer-instance.json').write_text(json.dumps({
                'root': str(home), 'profile': 'member-fixture', 'cli_entry': str(root / 'cli.cjs'), 'node': NODE,
            }), encoding='utf-8')
            result = subprocess.run(
                [PWSH, '-NoLogo', '-NoProfile', '-File', str(RELEASE / 'zalo/diagnose-zalo-windows.ps1'),
                 '-Member', 'fixture'], env={**os.environ, 'USERPROFILE': str(home)},
                capture_output=True, text=True, timeout=30,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('RESULT=instance-manifest-invalid', result.stdout)


if __name__ == '__main__':
    unittest.main()
