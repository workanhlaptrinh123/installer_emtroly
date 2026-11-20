[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Root,
  [Parameter(Mandatory=$true)][string]$TelegramAccount,
  [Parameter(Mandatory=$true)][string]$OwnerId,
  [Parameter(Mandatory=$true)][string]$ConfigureScript,
  [Parameter(Mandatory=$true)][string]$QrScript,
  [switch]$Quick,
  [switch]$PreGateway
)
$ErrorActionPreference = 'Stop'
function Set-ZaloInstallStage([string]$Stage) {
  if ($env:MEMBER_INSTALL_ZALO_STAGE_FILE) {
    [IO.File]::WriteAllText($env:MEMBER_INSTALL_ZALO_STAGE_FILE, $Stage, [Text.Encoding]::ASCII)
  }
}
Set-ZaloInstallStage 'preflight'
$env:OPENCLAW_STATE_DIR = $Root
$env:OPENCLAW_CONFIG_PATH = Join-Path $Root 'openclaw.json'
if (Test-Path -LiteralPath (Join-Path $Root 'installer-instance.json')) {
  $instance = Get-Content -LiteralPath (Join-Path $Root 'installer-instance.json') -Encoding UTF8 -Raw | ConvertFrom-Json
  . (Join-Path $Root 'windows-instance.ps1')
  Set-OpenClawInstanceEnvironment -Root $Root -InstanceProfile $instance.profile -CliEntry $instance.cli_entry
}
if (-not $env:OPENCLAW_CLI_ENTRY) {
  $npmRoot = (& npm root --global | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'Unable to locate the OpenClaw CLI.' }
  $env:OPENCLAW_CLI_ENTRY = Join-Path $npmRoot 'openclaw\openclaw.mjs'
}
if (-not (Test-Path $env:OPENCLAW_CLI_ENTRY)) { throw 'OpenClaw CLI entrypoint was not found.' }
function openclaw { & node $env:OPENCLAW_CLI_ENTRY @args; $global:LASTEXITCODE = $LASTEXITCODE }
if (Test-Path (Join-Path $Root 'user-gateway.ps1')) {
  . (Join-Path $Root 'user-gateway.ps1')
  function openclaw { Invoke-InstanceCli -Root $Root -CliEntry $env:OPENCLAW_CLI_ENTRY @args; $global:LASTEXITCODE = $LASTEXITCODE }
}
if (-not (Test-Path (Join-Path $Root 'openclaw.json'))) { throw 'OpenClaw config was not found.' }
if ($OwnerId -notmatch '^[1-9][0-9]*$') { throw 'QR owner ID must be numeric.' }
$configPath = Join-Path $Root 'openclaw.json'
$backupPath = "$configPath.before-zalo-$(Get-Date -Format yyyyMMddHHmmss)"
Copy-Item $configPath $backupPath
. (Join-Path $PSScriptRoot 'windows-plugin.ps1')
$node = (Get-Command node -ErrorAction Stop).Source
Set-ZaloInstallStage 'version'
$versionResult = Invoke-ZaloPluginCli -Node $node -CliEntry $env:OPENCLAW_CLI_ENTRY -Arguments @('--version')
$versionMatch = [regex]::Match($versionResult.Stdout, '([0-9]+\.[0-9]+\.[0-9]+)')
if ($versionResult.ExitCode -ne 0 -or -not $versionMatch.Success) {
  Set-ZaloCliFailureDetail $versionResult
  throw 'Unable to determine OpenClaw version.'
}
$coreVersion = $versionMatch.Value
Set-ZaloInstallStage 'plugin-inspect'
$pluginInfo = Get-ZaloPluginInfo -Node $node -CliEntry $env:OPENCLAW_CLI_ENTRY
if (-not $pluginInfo) {
  Set-ZaloInstallStage 'plugin-install'
  $installResult = Invoke-ZaloPluginCli -Node $node -CliEntry $env:OPENCLAW_CLI_ENTRY -Arguments @('plugins', 'install', '--pin', "@openclaw/zalouser@$coreVersion")
  if ($installResult.ExitCode -ne 0) { Set-ZaloCliFailureDetail $installResult; throw 'Zalo plugin installation failed.' }
  Set-ZaloInstallStage 'plugin-inspect'
  $pluginInfo = Get-ZaloPluginInfo -Node $node -CliEntry $env:OPENCLAW_CLI_ENTRY
}
if (-not $pluginInfo) { Set-ZaloFailureDetail 'plugin-not-found'; throw 'Zalo plugin was not found after installation.' }
if ($pluginInfo.plugin.packageName -ne '@openclaw/zalouser' -or $pluginInfo.plugin.version -ne $coreVersion) {
  Set-ZaloFailureDetail 'plugin-version-mismatch'
  throw 'Existing Zalo plugin does not match the OpenClaw version.'
}
if ($pluginInfo.plugin.enabled -ne $true) {
  Set-ZaloInstallStage 'plugin-enable'
  $enableResult = Invoke-ZaloPluginCli -Node $node -CliEntry $env:OPENCLAW_CLI_ENTRY -Arguments @('plugins', 'enable', 'zalouser')
  if ($enableResult.ExitCode -ne 0) { Set-ZaloCliFailureDetail $enableResult; throw 'Zalo plugin enable failed.' }
  Set-ZaloInstallStage 'plugin-inspect'
  $pluginInfo = Get-ZaloPluginInfo -Node $node -CliEntry $env:OPENCLAW_CLI_ENTRY
}
if (-not $pluginInfo -or $pluginInfo.plugin.enabled -ne $true -or $pluginInfo.plugin.status -ne 'loaded') {
  Set-ZaloFailureDetail 'plugin-not-loaded'
  throw 'Zalo plugin is not enabled and loaded.'
}
if (-not $Quick) {
  Set-ZaloInstallStage 'plugin-doctor'
  $doctorResult = Invoke-ZaloPluginCli -Node $node -CliEntry $env:OPENCLAW_CLI_ENTRY -Arguments @('plugins', 'doctor')
  if ($doctorResult.ExitCode -ne 0) { Set-ZaloCliFailureDetail $doctorResult; throw 'Zalo plugin doctor failed.' }
  Set-ZaloInstallStage 'plugin-source'
  if (-not $pluginInfo.plugin.source) { Set-ZaloFailureDetail 'invalid-response'; throw 'Could not locate the enabled Zalo plugin.' }
}
function Stop-SelectedGateway {
  $stopSucceeded = $false
  try {
    & openclaw gateway stop *> $null
    $stopSucceeded = $LASTEXITCODE -eq 0
  } catch { $stopSucceeded = $false }
  if ($stopSucceeded) { return }

  $pidPath = Join-Path $Root 'user-gateway.pid.json'
  if (-not (Test-Path -LiteralPath $pidPath)) {
    throw 'Could not safely identify the selected gateway.'
  }
  try {
    $record = Get-Content -LiteralPath $pidPath -Raw | ConvertFrom-Json
    $savedPid = 0
    if (-not [int]::TryParse([string]$record.pid, [ref]$savedPid) -or $savedPid -le 0) { throw 'Invalid gateway PID.' }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $savedPid" -ErrorAction Stop
    if (-not $process) {
      throw 'Saved gateway process is not running.'
    }
    $commandLine = [string]$process.CommandLine
    if ($commandLine.IndexOf($env:OPENCLAW_CLI_ENTRY, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or $commandLine -notmatch '\bgateway\s+run\b') {
      throw 'Saved gateway PID does not belong to this OpenClaw instance.'
    }
    $target = Get-Process -Id $savedPid -ErrorAction Stop
    Stop-Process -InputObject $target -ErrorAction Stop
    $target.WaitForExit(30000) | Out-Null
    if (-not $target.HasExited) { throw 'Gateway did not exit.' }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction Stop
  } catch {
    throw 'Could not stop the selected gateway for Zalo setup.'
  }
}
if (-not $PreGateway) {
  Set-ZaloInstallStage 'gateway-stop'
  Stop-SelectedGateway
}
try {
  Set-ZaloInstallStage 'zalo-config'
  $env:OPENCLAW_CONFIG_PATH = $configPath
  & python $ConfigureScript --root $Root --private-access
  if ($LASTEXITCODE -ne 0) { throw 'Zalo configuration validation failed.' }
  $ownerQrInstaller = Join-Path $Root 'workspace\skills\telegram-zalo-owner-login\scripts\deploy-native.py'
  Set-ZaloInstallStage 'qr-install'
  & python $ownerQrInstaller --root $Root --home $env:USERPROFILE --node $node --cli-entry $env:OPENCLAW_CLI_ENTRY --telegram-account $TelegramAccount --zalo-account default --agent main --ensure
  if ($LASTEXITCODE -ne 0) { throw 'Owner-only Zalo QR tool installation failed.' }
  if (-not $Quick) {
    $mentionInstaller = Join-Path $PSScriptRoot 'install-windows-reply-mention.py'
    Set-ZaloInstallStage 'mention-patch'
    & python $mentionInstaller --plugin-source $pluginInfo.plugin.source --root $Root --node $node --cli-entry $env:OPENCLAW_CLI_ENTRY
    if ($LASTEXITCODE -ne 0) { throw 'Zalo reply mention verification failed.' }
  }
} catch {
  if (-not $PreGateway) { & openclaw gateway start *> $null }
  throw
}
if ($PreGateway) {
  Set-ZaloInstallStage 'pre-gateway-complete'
  Write-Host 'WINDOWS ZALO PRE-GATEWAY INSTALL COMPLETE: owner can request /zaloqr; login remains unverified.'
  return
}
Set-ZaloInstallStage 'gateway-start'
& openclaw gateway start *> $null
if ($LASTEXITCODE -ne 0) { throw 'OpenClaw gateway start failed.' }
Start-Sleep -Seconds 5
Set-ZaloInstallStage 'verify'
& openclaw config validate --json | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'OpenClaw configuration is invalid after Zalo setup.' }
$health = (& node $env:OPENCLAW_CLI_ENTRY gateway health --json | Out-String) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $health.ok) { throw 'Gateway health check failed after Zalo setup.' }
if ('zalouser' -notin @($health.plugins.loaded) -or 'telegram-zalo-owner-login' -notin @($health.plugins.loaded)) { throw 'Zalo or owner QR plugin is not loaded by the gateway.' }
$qrInspection = (& openclaw plugins inspect telegram-zalo-owner-login --runtime --json | Out-String) | ConvertFrom-Json
$qrTools = @($qrInspection.plugin.toolNames)
foreach ($tool in @($qrInspection.tools)) { $qrTools += @($tool.names) }
if ($LASTEXITCODE -ne 0 -or $qrInspection.plugin.status -ne 'loaded' -or $qrInspection.plugin.enabled -ne $true -or
    'zaloqr' -notin @($qrInspection.commands) -or 'zalostatus' -notin @($qrInspection.commands) -or
    'telegram_zalo_login_qr' -notin $qrTools) { throw 'Owner QR plugin did not register /zaloqr.' }
if ($Quick) {
  Set-ZaloInstallStage 'quick-complete'
  Write-Host 'WINDOWS ZALO QUICK INSTALL COMPLETE: owner can request /zaloqr; advanced skills are deferred.'
  return
}
$plugins = (& openclaw plugins list --json | Out-String) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect installed plugins.' }
$zaloPlugin = @($plugins.plugins | Where-Object { $_.id -eq 'zalouser' })
$qrPlugin = @($plugins.plugins | Where-Object { $_.id -eq 'telegram-zalo-owner-login' })
if ($zaloPlugin.Count -ne 1 -or $zaloPlugin[0].status -ne 'loaded' -or $qrPlugin.Count -ne 1 -or $qrPlugin[0].status -ne 'loaded' -or $qrPlugin[0].enabled -ne $true) { throw 'Zalo or owner QR plugin is not loaded by the gateway.' }
Set-ZaloInstallStage 'complete'
Write-Host 'WINDOWS ZALO INSTALL COMPLETE: owner can request /zaloqr in a private Telegram chat; login remains unverified.'
