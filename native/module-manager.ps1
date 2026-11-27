[CmdletBinding()]
param([Parameter(Position=0)][ValidateSet('install','validate','list','remove')][string]$Command = 'list', [string]$Profile = '', [string[]]$Module = @(), [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$root = if ($env:OPENCLAW_ROOT) { $env:OPENCLAW_ROOT } else { Join-Path $env:USERPROFILE '.openclaw' }
$instance = $null
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'installer-instance.json')) {
  $instance = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'installer-instance.json') -Encoding UTF8 -Raw | ConvertFrom-Json
  . (Join-Path $PSScriptRoot 'windows-instance.ps1')
  Set-OpenClawInstanceEnvironment -Root $instance.root -InstanceProfile $instance.profile -CliEntry $instance.cli_entry
  if ($instance.PSObject.Properties['path'] -and $instance.path) { $env:Path = $instance.path + ';' + $env:Path }
  $root = $instance.root
}
$depBase = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies' } else { '' }
$prependDirs = @()
if ($instance -and $instance.PSObject.Properties['node'] -and $instance.node -and (Test-Path -LiteralPath $instance.node -PathType Leaf)) {
  $prependDirs += (Split-Path -Parent ([string]$instance.node))
}
if ($depBase -and (Test-Path -LiteralPath $depBase -PathType Container)) {
  foreach ($d in @(Get-ChildItem -LiteralPath $depBase -Directory -ErrorAction SilentlyContinue)) {
    if ($d.Name -like 'node-v*' -or $d.Name -like 'python*') { $prependDirs += $d.FullName }
    elseif ($d.Name -like 'ffmpeg-*' -and (Test-Path -LiteralPath (Join-Path $d.FullName 'bin') -PathType Container)) { $prependDirs += (Join-Path $d.FullName 'bin') }
  }
}
$normParts = @()
$winAppsParts = @()
foreach ($seg in @($prependDirs + @($env:Path -split ';'))) {
  if ([string]::IsNullOrWhiteSpace($seg)) { continue }
  if ($seg -like '*\WindowsApps*') { $winAppsParts += $seg } else { $normParts += $seg }
}
$env:Path = (@($normParts) + @($winAppsParts)) -join ';'

$pythonCandidates = @()
if ($instance -and $instance.PSObject.Properties['python'] -and $instance.python) { $pythonCandidates += [string]$instance.python }
if ($depBase) {
  $pythonCandidates += (Join-Path $depBase 'python313\python.exe')
  $pythonCandidates += (Join-Path $depBase 'python312\python.exe')
}
foreach ($c in @(Get-Command python.exe -All -CommandType Application -ErrorAction SilentlyContinue)) {
  if ($c.Source -and $c.Source -notlike '*\WindowsApps\*') { $pythonCandidates += $c.Source }
}
if ($env:LOCALAPPDATA) {
  $pythonCandidates += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Python\*\python.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
}
if ($env:ProgramFiles) {
  $pythonCandidates += @(Get-ChildItem (Join-Path $env:ProgramFiles 'Python*\python.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
}
$pythonExe = 'python'
foreach ($pyCand in @($pythonCandidates | Where-Object { $_ } | Select-Object -Unique)) {
  if ($pyCand -notlike '*\WindowsApps\*' -and (Test-Path -LiteralPath $pyCand -PathType Leaf)) { $pythonExe = $pyCand; break }
}
$nodeExe = 'node'
if ($instance -and $instance.PSObject.Properties['node'] -and $instance.node -and (Test-Path -LiteralPath $instance.node -PathType Leaf)) {
  $nodeExe = [string]$instance.node
} else {
  $nc = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $nc) { $nc = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
  if ($nc -and $nc.Source) { $nodeExe = $nc.Source }
}

$args = @((Join-Path $root 'module-manager.py'), $Command, '--openclaw-root', $root, '--catalog-root', (Join-Path $root 'module-catalog'), '--skills-source', (Join-Path $root 'module-catalog\skills'))
if ($Profile) { $args += @('--profile', $Profile) }
foreach ($item in $Module) { $args += @('--module', $item) }
if ($DryRun) { $args += '--dry-run' }
& $pythonExe @args
$status = $LASTEXITCODE
if ($status -eq 0 -and $Command -eq 'install' -and $env:OPENCLAW_CLI_ENTRY -and $env:OPENCLAW_SKIP_MODULE_RESTART -ne '1') {
  & $nodeExe $env:OPENCLAW_CLI_ENTRY gateway restart *> $null
}
exit $status
