import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('PWSH') or shutil.which('pwsh')
DEPENDENCIES = ROOT / 'native/user-dependencies.ps1'

DEPENDENCY_DRIVER = r'''
param($DependencyFile, $FixtureRoot, $Scenario)
$ErrorActionPreference = 'Stop'
$env:LOCALAPPDATA = $FixtureRoot
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:PROCESSOR_ARCHITEW6432 = ''
$script:nodeReady = $Scenario -eq 'installed'
$script:downloads = @()
$script:expanded = @()
$dependencyRoot = Join-Path $FixtureRoot 'MemberInstaller/dependencies'
$fixturePython = Join-Path $FixtureRoot 'python.exe'
$fixtureFfmpeg = Join-Path $FixtureRoot 'ffmpeg.exe'
if ($Scenario -eq 'installed') {
  [IO.File]::WriteAllText($fixturePython, 'mock')
  [IO.File]::WriteAllText($fixtureFfmpeg, "#!/bin/sh`nexit 0`n")
  & /bin/chmod +x $fixtureFfmpeg
}
. $DependencyFile
function Test-SupportedNodeToolchain { return $script:nodeReady }
function Test-PythonCandidate { param([string]$Executable) return (Test-Path -LiteralPath $Executable) }
function Get-Command {
  param([string]$Name, $ErrorAction)
  if ($Name -eq 'python.exe' -and (Test-Path -LiteralPath $fixturePython)) { return [pscustomobject]@{Source=$fixturePython} }
  if ($Name -eq 'ffmpeg.exe') {
    $portable = Join-Path $dependencyRoot 'ffmpeg-9.0.2-essentials_build/bin/ffmpeg.exe'
    if (Test-Path -LiteralPath $fixtureFfmpeg) { return [pscustomobject]@{Source=$fixtureFfmpeg} }
    if (Test-Path -LiteralPath $portable) { return [pscustomobject]@{Source=$portable} }
  }
  return $null
}
function Invoke-WebRequest {
  [CmdletBinding()]
  param([switch]$UseBasicParsing, $Uri, $OutFile, $TimeoutSec)
  if ($Uri -like '*SHASUMS256.txt') { return [pscustomobject]@{Content=(('a' * 64) + '  node-v24.21.0-win-x64.zip')} }
  $script:downloads += [string]$Uri
  [IO.File]::WriteAllText($OutFile, 'mock archive')
}
function Get-FileHash {
  param($Path, $Algorithm)
  if ($Path -like '*ffmpeg*') {
    $hash = if ($Scenario -eq 'bad-ffmpeg-hash') { 'b' * 64 } else { '60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba' }
    return [pscustomobject]@{Hash=$hash}
  }
  return [pscustomobject]@{Hash=('a' * 64)}
}
function Expand-Archive {
  param($LiteralPath, $DestinationPath, [switch]$Force)
  $script:expanded += [string]$LiteralPath
  if ($LiteralPath -like '*node-*') {
    $folder = Join-Path $DestinationPath 'node-v24.21.0-win-x64'
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    [IO.File]::WriteAllText((Join-Path $folder 'node.exe'), 'mock')
    [IO.File]::WriteAllText((Join-Path $folder 'npm.cmd'), 'mock')
    $script:nodeReady = $true
  } else {
    $folder = Join-Path $DestinationPath 'ffmpeg-9.0.2-essentials_build/bin'
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $executable = Join-Path $folder 'ffmpeg.exe'
    [IO.File]::WriteAllText($executable, "#!/bin/sh`nexit 0`n")
    & /bin/chmod +x $executable
  }
}
function Get-AuthenticodeSignature {
  param($FilePath)
  return [pscustomobject]@{Status='Valid'; SignerCertificate=[pscustomobject]@{Subject='Python Software Foundation'}}
}
function Start-Process {
  param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
  $folder = Join-Path $dependencyRoot 'python313'
  New-Item -ItemType Directory -Force -Path $folder | Out-Null
  [IO.File]::WriteAllText((Join-Path $folder 'python.exe'), 'mock')
  return [pscustomobject]@{ExitCode=0}
}
try {
  Initialize-UserDependencies
  $errorMessage = ''
} catch { $errorMessage = [string]$_.Exception.Message }
[pscustomobject]@{error=$errorMessage; downloads=$script:downloads; expanded=$script:expanded; path=$env:Path} | ConvertTo-Json -Compress
'''


@unittest.skipUnless(PWSH and os.name != 'nt', 'PowerShell and Unix fixture executables are required')
class UserDependencyTests(unittest.TestCase):
    def node_check(self, version, include_npm=True, exit_code=0):
        with tempfile.TemporaryDirectory(prefix='member-node-check-') as temporary:
            directory = Path(temporary)
            node = directory / 'node.exe'
            node.write_text(f'#!/bin/sh\necho "{version}"\nexit {exit_code}\n')
            node.chmod(0o755)
            if include_npm:
                npm = directory / 'npm.cmd'
                npm.write_text('#!/bin/sh\nexit 0\n')
                npm.chmod(0o755)
            driver = directory / 'driver.ps1'
            driver.write_text("param($DependencyFile)\n. $DependencyFile\nTest-SupportedNodeToolchain\n")
            environment = os.environ.copy()
            environment['PATH'] = str(directory) + os.pathsep + environment.get('PATH', '')
            process = subprocess.run(
                [PWSH, '-NoProfile', '-File', str(driver), str(DEPENDENCIES)],
                text=True, capture_output=True, env=environment, timeout=30,
            )
            self.assertEqual(process.returncode, 0, process.stderr)
            return process.stdout.strip()

    def test_node_versions_and_missing_npm(self):
        for version, expected in (
            ('v24.15.9', 'False'), ('v24.16.0', 'True'), ('v24.20.0', 'True'),
            ('v25.0.0', 'False'), ('v26.0.0', 'False'), ('v26.1.0', 'True'),
            ('v27.0.0', 'True'), ('invalid', 'False'),
        ):
            with self.subTest(version=version):
                self.assertEqual(self.node_check(version), expected)
        self.assertEqual(self.node_check('v24.20.0', include_npm=False), 'False')
        self.assertEqual(self.node_check('v24.20.0', exit_code=1), 'False')

    def test_python_candidate_runs_without_embedded_quote_arguments(self):
        with tempfile.TemporaryDirectory(prefix='member-python-check-') as temporary:
            driver = Path(temporary) / 'driver.ps1'
            driver.write_text('param($DependencyFile, $Executable)\n. $DependencyFile\nTest-PythonCandidate $Executable\n')
            process = subprocess.run(
                [PWSH, '-NoProfile', '-File', str(driver), str(DEPENDENCIES), shutil.which('python3')],
                text=True, capture_output=True, timeout=30,
            )
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(process.stdout.strip(), 'True')

    def test_missing_dependencies_and_bad_archive_are_handled(self):
        import json

        for scenario in ('installed', 'missing', 'bad-ffmpeg-hash'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(prefix='member-deps-') as temporary:
                driver = Path(temporary) / 'driver.ps1'
                driver.write_text(DEPENDENCY_DRIVER)
                process = subprocess.run(
                    [PWSH, '-NoProfile', '-File', str(driver), str(DEPENDENCIES), temporary, scenario],
                    text=True, capture_output=True, timeout=30,
                )
                self.assertEqual(process.returncode, 0, process.stderr)
                result = json.loads(process.stdout.strip())
                if scenario == 'installed':
                    self.assertEqual(result['error'], '')
                    self.assertEqual(result['downloads'], [])
                elif scenario == 'missing':
                    self.assertEqual(result['error'], '')
                    self.assertEqual(len(result['downloads']), 3)
                    self.assertIn('node-v24.21.0-win-x64', result['path'])
                    self.assertIn('python313', result['path'])
                    self.assertIn('ffmpeg-9.0.2-essentials_build', result['path'])
                else:
                    self.assertEqual(result['error'], 'FFmpeg checksum verification failed.')
                    self.assertEqual(len(result['expanded']), 1)


class DependencyPolicyTests(unittest.TestCase):
    def test_auto_install_has_integrity_checks_and_no_winget_requirement(self):
        text = DEPENDENCIES.read_text(encoding="utf-8")
        self.assertNotIn('node -e', text)
        self.assertNotIn('winget', text.lower())
        self.assertIn('node-v24.21.0-win-$architecture.zip', text)
        self.assertIn('SHASUMS256.txt', text)
        self.assertIn('Get-AuthenticodeSignature', text)
        self.assertIn('Python Software Foundation', text)
        self.assertIn('ffmpeg-9.0.2-essentials_build.zip', text)
        self.assertIn('60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba', text)
        self.assertIn('FFmpeg dependency verification failed.', text)


if __name__ == '__main__':
    unittest.main()
