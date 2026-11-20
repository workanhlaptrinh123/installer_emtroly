param([string]$AccountDirectory = [Environment]::GetFolderPath('UserProfile'))

$ErrorActionPreference = 'Stop'
$root = Join-Path $AccountDirectory 'openclaw'
$version = '2026.11.4'
$entry = Join-Path $root "runtime\$version\node_modules\openclaw\openclaw.mjs"
$manifest = Get-Content -LiteralPath (Join-Path $root 'installer-instance.json') -Encoding UTF8 -Raw | ConvertFrom-Json
if ($manifest.root -ne $root -or $manifest.mode -ne 'user' -or $manifest.cli_entry -ne $entry -or
    $manifest.profile -ne 'member-emtroly' -or -not (Test-Path -LiteralPath $entry -PathType Leaf)) {
  throw 'Không tìm thấy đúng bản OpenClaw của Em Trợ Lý để sửa PATH.'
}
$dependencies = Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies'
$nodePaths = @((Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue).Source,
               (Join-Path $dependencies 'node-v24.21.0-win-x64\node.exe'))
$nodePath = $nodePaths | Where-Object { $_ -and $_ -eq $manifest.node -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
if (-not $nodePath) { throw 'Không tìm thấy Node.js đã dùng để cài trợ lý.' }
$pythonPaths = @((Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue).Source,
                 (Join-Path $dependencies 'python313\python.exe'))
$pythonPaths += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Python\*\python.exe') -ErrorAction SilentlyContinue | ForEach-Object FullName)
$pythonPath = $pythonPaths | Where-Object { $_ -and $_ -notlike '*\WindowsApps\*' -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
if (-not $pythonPath) { throw 'Không tìm thấy Python đã dùng để cài trợ lý.' }
. (Join-Path $PSScriptRoot '..\native\windows-cli.ps1')
Install-UserOpenClawCli -Root $root -CliEntry $entry -Profile $manifest.profile -Port $manifest.port -ExpectedVersion $version -Node $nodePath -Python $pythonPath
$previousRoot = $env:EMTROLY_PROBE_ROOT
$previousVersion = $env:EMTROLY_PROBE_VERSION
try {
  $env:EMTROLY_PROBE_ROOT = $root
  $env:EMTROLY_PROBE_VERSION = $version
  $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  & $shell -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'verify-openclaw-command.ps1')
  if ($LASTEXITCODE -ne 0) { throw 'PowerShell mới chưa nhận đúng lệnh openclaw status.' }
} finally {
  $env:EMTROLY_PROBE_ROOT = $previousRoot
  $env:EMTROLY_PROBE_VERSION = $previousVersion
}
