[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ExistingRoot, [string]$OpenClawVersion = '2026.11.4', [switch]$DryRun)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-instance.ps1')
$root = (Resolve-Path -LiteralPath $ExistingRoot -ErrorAction Stop).Path
$configPath = Join-Path $root 'openclaw.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'Upgrade target has no openclaw.json.' }
$leaf = Split-Path -Leaf $root
if ($leaf -ne '.openclaw' -and $leaf -notmatch '^\.openclaw-[a-z][a-z0-9_-]*$') { throw 'Cannot safely identify this installation service. Use its original installer for a custom state directory.' }
$instanceProfile = if ($leaf -eq '.openclaw') { '' } else { $leaf.Substring(10) }
if ($DryRun) { Write-Host "DRY-RUN: upgrade $root; no files or services changed."; return }
if (-not (Get-Command node -ErrorAction SilentlyContinue) -or -not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { throw 'Existing installation requires Node.js/npm. No configuration was changed.' }
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$port = if ($config.gateway.port) { [int]$config.gateway.port } else { 18789 }
$taskName = if ($instanceProfile) { "OpenClaw Gateway ($instanceProfile)" } else { 'OpenClaw Gateway' }
$task = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
if ($task -and -not (Test-OpenClawTaskTarget -Task $task -Root $root)) { throw 'Cannot verify that this task launches the selected installation. No files or services were changed. The launcher format may be unsupported; do not delete the task.' }
$backup = Join-Path (Split-Path -Parent $root) ('openclaw-upgrade-backups\' + $leaf + '-' + (Get-Date -Format yyyyMMddHHmmss) + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls $backup /inheritance:r /grant:r "${currentUser}:(OI)(CI)(F)" '*S-1-5-18:(OI)(CI)(F)' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Cannot protect upgrade backup.' }
Write-Host "Backing up existing state (excluding runtime/backups): $backup"
& robocopy $root (Join-Path $backup 'state') /E /XJ /XD (Join-Path $root 'runtime') (Join-Path $root 'backups') /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -gt 7) { throw 'State backup failed. Upgrade was not started.' }
$taskXml = if ($task) { Export-ScheduledTask -TaskName $taskName -TaskPath '\' } else { $null }
if ($taskXml) { [IO.File]::WriteAllText((Join-Path $backup 'scheduled-task.xml'), $taskXml) }
$manifestPath = Join-Path $root 'installer-instance.json'
$oldManifest = if (Test-Path -LiteralPath $manifestPath) { Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } else { $null }
$oldCli = if ($oldManifest) { $oldManifest.cli_entry } else { $null }
$oldPackage = if ($oldCli) { Join-Path (Split-Path -Parent $oldCli) 'package.json' } else { $null }
if (-not $oldPackage) {
  $globalRoot = (& npm.cmd root --global | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'Cannot identify existing runtime.' }
  $oldPackage = Join-Path $globalRoot 'openclaw\package.json'
}
if (Test-Path -LiteralPath $oldPackage) {
  $oldVersion = (Get-Content -LiteralPath $oldPackage -Raw | ConvertFrom-Json).version
  if ([version]($oldVersion -split '-')[0] -gt [version]($OpenClawVersion -split '-')[0]) { throw "Existing runtime $oldVersion is newer than bundle $OpenClawVersion. Refusing downgrade; use a compatible bundle." }
}

function Repair-OpenClawLegacyConfig {
  param([string]$Path)
  $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  if ($config.gateway -and $config.gateway.nodes -and $config.gateway.nodes.denyCommands) {
    $nodes = $config.gateway.nodes
    $commands = $nodes.PSObject.Properties['commands']
    if (-not $commands) {
      $nodes | Add-Member -NotePropertyName commands -NotePropertyValue ([pscustomobject]@{})
      $commands = $nodes.PSObject.Properties['commands']
    }
    if (-not $commands.Value.PSObject.Properties['deny']) {
      $commands.Value | Add-Member -NotePropertyName deny -NotePropertyValue $nodes.denyCommands
    } else {
      $commands.Value.deny = @(@($commands.Value.deny) + @($nodes.denyCommands) | Select-Object -Unique)
    }
  }
  foreach ($retired in @(
    @{ Parent=$config.meta; Name='lastTouchedAt' },
    @{ Parent=$config.commands; Name='ownerDisplay' },
    @{ Parent=$config.gateway.controlUi; Name='allowInsecureAuth' },
    @{ Parent=$config.gateway.tailscale; Name='resetOnExit' },
    @{ Parent=$config.gateway.nodes; Name='denyCommands' }
  )) {
    if ($null -ne $retired.Parent) { $retired.Parent.PSObject.Properties.Remove($retired.Name) }
  }
  if ($config.agents -and @($config.agents.list).Count -gt 1 -and -not @($config.agents.list | Where-Object { $_.default -eq $true }).Count) {
    $ownership = $config.agents.PSObject.Properties['ownership']
    if ($ownership) { $ownership.Value = 'explicit' }
    else { $config.agents | Add-Member -NotePropertyName ownership -NotePropertyValue 'explicit' }
  }
  $temp = "$Path.migrated.$([guid]::NewGuid().ToString('N')).tmp"
  [IO.File]::WriteAllText($temp, ($config | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $temp -Destination $Path -Force
}

$runtime = Join-Path $root ('runtime\upgrade-' + [guid]::NewGuid().ToString('N'))
$runtimePackage = @{ name='member-openclaw-runtime-upgrade'; version='1.0.0'; private=$true; allowScripts=@{ '@google/genai'=$true; esbuild=$true; koffi=$true; openclaw=$true; protobufjs=$true; 'tree-sitter-bash'=$true } }
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
[IO.File]::WriteAllText((Join-Path $runtime 'package.json'), ($runtimePackage | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
& npm.cmd install --prefix $runtime "openclaw@$OpenClawVersion"
if ($LASTEXITCODE -ne 0) { throw "Private runtime installation failed. Existing service is unchanged. Backup: $backup" }
$cliEntry = Join-Path $runtime 'node_modules\openclaw\openclaw.mjs'
Set-OpenClawInstanceEnvironment -Root $root -InstanceProfile $instanceProfile -CliEntry $cliEntry
$candidatePath = Join-Path $root ('openclaw.upgrade-candidate-' + [guid]::NewGuid().ToString('N') + '.json')
Copy-Item -LiteralPath $configPath -Destination $candidatePath
Repair-OpenClawLegacyConfig -Path $candidatePath
try {
  $env:OPENCLAW_CONFIG_PATH = $candidatePath
  $ErrorActionPreference = 'Continue'
  & node $cliEntry config validate --json
  $validationExit = $LASTEXITCODE
} finally {
  $env:OPENCLAW_CONFIG_PATH = $configPath
  $ErrorActionPreference = 'Stop'
}
if ($validationExit -ne 0) {
  Remove-Item -LiteralPath $candidatePath -Force
  throw "Upgrade stopped: candidate config is incompatible. Original config and service unchanged. Backup: $backup."
}
$serviceChanged = $false
$configChanged = $false
try {
  $configChanged = $true
  Copy-Item -LiteralPath $candidatePath -Destination $configPath -Force
  if ($task) {
    $serviceChanged = $true
    & node $cliEntry gateway stop
    if ($LASTEXITCODE -ne 0) { throw 'Could not stop the selected gateway.' }
  }
  & node $cliEntry doctor --fix --non-interactive --yes
  if ($LASTEXITCODE -ne 0) { throw 'OpenClaw state database migration failed. The gateway was not upgraded.' }
  if ($task) {
    & node $cliEntry gateway stop
    if ($LASTEXITCODE -ne 0) { throw 'Could not stop the gateway after state database migration.' }
  }
  $serviceChanged = $true
  & node $cliEntry gateway install --port $port --force
  if ($LASTEXITCODE -ne 0) { throw 'Gateway service upgrade failed.' }
  & node $cliEntry gateway restart
  if ($LASTEXITCODE -ne 0) { throw 'Upgraded gateway failed to restart.' }
  & node $cliEntry gateway status --require-rpc
  if ($LASTEXITCODE -ne 0) { throw 'Upgraded gateway status failed.' }
  Save-OpenClawInstanceLauncher -Root $root -InstanceProfile $instanceProfile -CliEntry $cliEntry -Port $port
} catch {
  $failure = $_
  if ($configChanged) { Copy-Item -LiteralPath (Join-Path (Join-Path $backup 'state') 'openclaw.json') -Destination $configPath -Force }
  if ($serviceChanged) {
    Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    $savedStateDir = Join-Path (Join-Path $backup 'state') 'state'
    $currentStateDir = Join-Path $root 'state'
    if (Test-Path -LiteralPath $savedStateDir -PathType Container) {
      foreach ($database in @(Get-ChildItem -LiteralPath $savedStateDir -Filter 'openclaw.sqlite*' -File -Force -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $database.FullName -Destination (Join-Path $currentStateDir $database.Name) -Force
      }
    }
    foreach ($file in @('openclaw.json','gateway.cmd','gateway.vbs','installer-instance.json','openclaw-instance.ps1','windows-instance.ps1')) {
      $saved = Join-Path (Join-Path $backup 'state') $file
      if (Test-Path -LiteralPath $saved) { Copy-Item -LiteralPath $saved -Destination (Join-Path $root $file) -Force }
    }
    if ($taskXml) {
      Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Xml $taskXml -Force | Out-Null
      if ($task.State -eq 'Running') { Start-ScheduledTask -TaskName $taskName -TaskPath '\' }
    } else { Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue }
  }
  throw "Upgrade failed; previous service/config restoration attempted. Backup: $backup. $failure"
} finally {
  if (Test-Path -LiteralPath $candidatePath) { Remove-Item -LiteralPath $candidatePath -Force }
}
Write-Host "NATIVE UPGRADE COMPLETE: $root"
Write-Host "Credentials, owners, bindings, workspace and modules preserved. Backup: $backup"
Write-Host "Dashboard: http://127.0.0.1:$port/"
