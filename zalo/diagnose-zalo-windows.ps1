[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Member)

$ErrorActionPreference = 'Stop'
if ($Member -notmatch '^[a-z][a-z0-9_-]{0,63}$') { Write-Output 'RESULT=invalid-member'; exit 1 }

try {
  $root = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE ('.openclaw-member-' + $Member))).TrimEnd('\', '/')
  $manifestPath = Join-Path $root 'installer-instance.json'
  $configPath = Join-Path $root 'openclaw.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Output 'RESULT=instance-not-found'
    exit 1
  }
  $instance = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
  $manifestRoot = [IO.Path]::GetFullPath([string]$instance.root).TrimEnd('\', '/')
  $cliEntry = [IO.Path]::GetFullPath([string]$instance.cli_entry)
  $node = [string]$instance.node
  if (-not $root.Equals($manifestRoot, [StringComparison]::OrdinalIgnoreCase) -or
      $instance.profile -ne ('member-' + $Member) -or
      -not $cliEntry.StartsWith(($root + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase) -or
      -not (Test-Path -LiteralPath $cliEntry -PathType Leaf) -or
      -not (Test-Path -LiteralPath $node -PathType Leaf)) {
    Write-Output 'RESULT=instance-manifest-invalid'
    exit 1
  }
  foreach ($selector in @('OPENCLAW_HOME','OPENCLAW_GATEWAY_TOKEN','OPENCLAW_GATEWAY_PASSWORD','OPENCLAW_GATEWAY_PORT','OPENCLAW_SYSTEMD_UNIT','OPENCLAW_LAUNCHD_LABEL','OPENCLAW_WINDOWS_TASK_NAME','OPENCLAW_SERVICE_KIND','OPENCLAW_SERVICE_MARKER','OPENCLAW_GATEWAY_SERVICE_PID')) {
    Remove-Item "Env:$selector" -ErrorAction SilentlyContinue
  }
  $env:HOME = $env:USERPROFILE
  $env:OPENCLAW_STATE_DIR = $root
  $env:OPENCLAW_CONFIG_PATH = $configPath
  $env:OPENCLAW_WORKSPACE_DIR = Join-Path $root 'workspace'
  $env:OPENCLAW_PROFILE = [string]$instance.profile
  if ($instance.path) { $env:Path = [string]$instance.path }
  $config = [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
  $channel = if ($config.channels.zalouser) { 'configured' } else { 'not-configured' }
  $plugin = 'unknown'
  $gateway = 'unknown'
  $gatewayZalo = 'unknown'
  $gatewayQr = 'unknown'

  $ErrorActionPreference = 'Continue'
  try {
    $pluginOutput = & $node $cliEntry plugins info zalouser --json 2>$null
    $pluginExit = $LASTEXITCODE
    $healthOutput = & $node $cliEntry gateway health --json 2>$null
    $healthExit = $LASTEXITCODE
  } finally { $ErrorActionPreference = 'Stop' }
  try {
    $pluginInfo = ($pluginOutput | Out-String) | ConvertFrom-Json -ErrorAction Stop
    if ($pluginExit -eq 0 -and $pluginInfo.plugin.id -eq 'zalouser') {
      if ($pluginInfo.plugin.enabled -eq $true -and $pluginInfo.plugin.status -eq 'loaded') { $plugin = 'enabled-loaded' }
      elseif ($pluginInfo.plugin.enabled -eq $true) { $plugin = 'enabled-not-loaded' }
      else { $plugin = 'disabled' }
    } elseif ($pluginInfo.ok -eq $false -and [string]$pluginInfo.error.message -match '^Plugin not found: zalouser\.') { $plugin = 'not-found' }
  } catch { }
  try {
    $health = ($healthOutput | Out-String) | ConvertFrom-Json -ErrorAction Stop
    if ($healthExit -eq 0 -and $health.ok) {
      $gateway = 'healthy'
      $gatewayZalo = if ('zalouser' -in @($health.plugins.loaded)) { 'loaded' } else { 'not-loaded' }
      $gatewayQr = if ('telegram-zalo-owner-login' -in @($health.plugins.loaded)) { 'loaded' } else { 'not-loaded' }
    } else { $gateway = 'not-verified' }
  } catch { $gateway = 'not-verified' }
  Write-Output 'RESULT=diagnostic-complete'
  Write-Output "PLUGIN=$plugin"
  Write-Output "ZALO_CHANNEL=$channel"
  Write-Output "GATEWAY=$gateway"
  Write-Output "GATEWAY_ZALO=$gatewayZalo"
  Write-Output "GATEWAY_QR=$gatewayQr"
} catch {
  Write-Output 'RESULT=diagnostic-failed'
  exit 1
}
