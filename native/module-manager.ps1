[CmdletBinding()]
param([Parameter(Position=0)][ValidateSet('install','validate','list','remove')][string]$Command = 'list', [string]$Profile = '', [string[]]$Module = @(), [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$root = if ($env:OPENCLAW_ROOT) { $env:OPENCLAW_ROOT } else { Join-Path $env:USERPROFILE '.openclaw' }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'installer-instance.json')) {
  $instance = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'installer-instance.json') -Raw | ConvertFrom-Json
  . (Join-Path $PSScriptRoot 'windows-instance.ps1')
  Set-OpenClawInstanceEnvironment -Root $instance.root -InstanceProfile $instance.profile -CliEntry $instance.cli_entry
  $root = $instance.root
}
$args = @((Join-Path $root 'module-manager.py'), $Command, '--openclaw-root', $root, '--catalog-root', (Join-Path $root 'module-catalog'), '--skills-source', (Join-Path $root 'module-catalog\skills'))
if ($Profile) { $args += @('--profile', $Profile) }
foreach ($item in $Module) { $args += @('--module', $item) }
if ($DryRun) { $args += '--dry-run' }
& python @args
$status = $LASTEXITCODE
if ($status -eq 0 -and $Command -eq 'install' -and $env:OPENCLAW_CLI_ENTRY -and $env:OPENCLAW_SKIP_MODULE_RESTART -ne '1') {
  & node $env:OPENCLAW_CLI_ENTRY gateway restart *> $null
}
exit $status
