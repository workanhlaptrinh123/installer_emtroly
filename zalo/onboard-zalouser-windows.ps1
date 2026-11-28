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
$instance = $null
if (Test-Path -LiteralPath (Join-Path $Root 'installer-instance.json')) {
  $instance = Get-Content -LiteralPath (Join-Path $Root 'installer-instance.json') -Encoding UTF8 -Raw | ConvertFrom-Json
  . (Join-Path $Root 'windows-instance.ps1')
  Set-OpenClawInstanceEnvironment -Root $Root -InstanceProfile $instance.profile -CliEntry $instance.cli_entry
  if ($instance.PSObject.Properties['path'] -and $instance.path) { $env:Path = $instance.path + ';' + $env:Path }
}
$zaloDepBase = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies' } else { '' }
$zaloPriorityDirs = @()
if ($instance -and $instance.PSObject.Properties['node'] -and $instance.node -and (Test-Path -LiteralPath $instance.node -PathType Leaf)) {
  $zaloPriorityDirs += (Split-Path -Parent ([string]$instance.node))
}
if ($zaloDepBase -and (Test-Path -LiteralPath $zaloDepBase -PathType Container)) {
  foreach ($zd in @(Get-ChildItem -LiteralPath $zaloDepBase -Directory -ErrorAction SilentlyContinue)) {
    if ($zd.Name -like 'node-v*' -or $zd.Name -like 'python*') { $zaloPriorityDirs += $zd.FullName }
    elseif ($zd.Name -like 'ffmpeg-*' -and (Test-Path -LiteralPath (Join-Path $zd.FullName 'bin') -PathType Container)) { $zaloPriorityDirs += (Join-Path $zd.FullName 'bin') }
  }
}
foreach ($stdNodeDir in @(
  $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'nodejs' }),
  $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\nodejs' })
)) {
  if ($stdNodeDir -and (Test-Path -LiteralPath $stdNodeDir -PathType Container)) { $zaloPriorityDirs += $stdNodeDir }
}
$zaloNorm = @()
$zaloWinApps = @()
foreach ($zSeg in @($zaloPriorityDirs + @($env:Path -split ';'))) {
  if ([string]::IsNullOrWhiteSpace($zSeg)) { continue }
  if ($zSeg -like '*\WindowsApps*') { $zaloWinApps += $zSeg } else { $zaloNorm += $zSeg }
}
$env:Path = (@($zaloNorm) + @($zaloWinApps)) -join ';'

$nodeCandidates = @()
if ($instance -and $instance.PSObject.Properties['node'] -and $instance.node) { $nodeCandidates += [string]$instance.node }
if ($zaloDepBase -and (Test-Path -LiteralPath $zaloDepBase -PathType Container)) {
  $nodeCandidates += @(Get-ChildItem -LiteralPath $zaloDepBase -Directory -Filter 'node-v*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'node.exe' })
}
$cmdNodeObj = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $cmdNodeObj) { $cmdNodeObj = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 }
if ($cmdNodeObj -and $cmdNodeObj.Source) { $nodeCandidates += $cmdNodeObj.Source }
$node = ''
foreach ($nc in @($nodeCandidates | Where-Object { $_ } | Select-Object -Unique)) {
  if (Test-Path -LiteralPath $nc -PathType Leaf) { $node = $nc; break }
}
if (-not $node) { $node = (Get-Command node -ErrorAction Stop).Source }
$nodeParent = Split-Path -Parent $node
if ($nodeParent) { $env:Path = "$nodeParent;$env:Path" }
$env:OPENCLAW_NODE_EXE = $node

$pyCandidates = @()
if ($instance -and $instance.PSObject.Properties['python'] -and $instance.python) { $pyCandidates += [string]$instance.python }
if ($zaloDepBase) {
  $pyCandidates += (Join-Path $zaloDepBase 'python313\python.exe')
  $pyCandidates += (Join-Path $zaloDepBase 'python312\python.exe')
}
foreach ($pyc in @(Get-Command python.exe -All -CommandType Application -ErrorAction SilentlyContinue)) {
  if ($pyc.Source -and $pyc.Source -notlike '*\WindowsApps\*') { $pyCandidates += $pyc.Source }
}
if ($env:LOCALAPPDATA) {
  $pyCandidates += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Python\*\python.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
}
if ($env:ProgramFiles) {
  $pyCandidates += @(Get-ChildItem (Join-Path $env:ProgramFiles 'Python*\python.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
}
$pythonExe = ''
foreach ($pyPath in @($pyCandidates | Where-Object { $_ } | Select-Object -Unique)) {
  if ($pyPath -notlike '*\WindowsApps\*' -and (Test-Path -LiteralPath $pyPath -PathType Leaf)) { $pythonExe = $pyPath; break }
}
if (-not $pythonExe) { $pythonExe = 'python' }

if (-not $env:OPENCLAW_CLI_ENTRY) {
  $npmRoot = (& npm root --global | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'Unable to locate the OpenClaw CLI.' }
  $env:OPENCLAW_CLI_ENTRY = Join-Path $npmRoot 'openclaw\openclaw.mjs'
}
if (-not (Test-Path $env:OPENCLAW_CLI_ENTRY)) { throw 'OpenClaw CLI entrypoint was not found.' }
function openclaw { & $node $env:OPENCLAW_CLI_ENTRY @args; $global:LASTEXITCODE = $LASTEXITCODE }
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
  $openClawNpmHelper = Join-Path (Split-Path -Parent $PSScriptRoot) 'native\openclaw-npm.ps1'
  if (-not (Test-Path -LiteralPath $openClawNpmHelper -PathType Leaf)) {
    $openClawNpmHelper = Join-Path $Root 'native\openclaw-npm.ps1'
  }
  if (Test-Path -LiteralPath $openClawNpmHelper -PathType Leaf) {
    try { . $openClawNpmHelper } catch { }
  }
  $hadNpmCacheZ = Test-Path Env:NPM_CONFIG_CACHE
  $oldNpmCacheZ = if ($hadNpmCacheZ) { $env:NPM_CONFIG_CACHE } else { $null }
  $hadNpmPrefixZ = Test-Path Env:NPM_CONFIG_PREFIX
  $oldNpmPrefixZ = if ($hadNpmPrefixZ) { $env:NPM_CONFIG_PREFIX } else { $null }
  $hadNpmMaxSocketsZ = Test-Path Env:NPM_CONFIG_MAXSOCKETS
  $oldNpmMaxSocketsZ = if ($hadNpmMaxSocketsZ) { $env:NPM_CONFIG_MAXSOCKETS } else { $null }
  $hadNodeOptsZ = Test-Path Env:NODE_OPTIONS
  $oldNodeOptsZ = if ($hadNodeOptsZ) { $env:NODE_OPTIONS } else { $null }
  $hadIa32Z = Test-Path Env:OPENSSL_ia32cap
  $oldIa32Z = if ($hadIa32Z) { $env:OPENSSL_ia32cap } else { $null }
  $hadRegZ = Test-Path Env:NPM_CONFIG_REGISTRY
  $oldRegZ = if ($hadRegZ) { $env:NPM_CONFIG_REGISTRY } else { $null }
  $hadUserCfgZ = Test-Path Env:NPM_CONFIG_USERCONFIG
  $oldUserCfgZ = if ($hadUserCfgZ) { $env:NPM_CONFIG_USERCONFIG } else { $null }
  $zaloCacheRoot = Join-Path $Root 'npm-cache\zalo'
  $zaloNpmrc = Join-Path $zaloCacheRoot '.npmrc.zalo'
  [void][IO.Directory]::CreateDirectory($zaloCacheRoot)
  try {
    if (Test-Path Env:NPM_CONFIG_PREFIX) { Remove-Item Env:NPM_CONFIG_PREFIX -ErrorAction SilentlyContinue }
    $zaloToolchains = if (Get-Command -Name 'Resolve-EmTroLyNodeToolchains' -ErrorAction SilentlyContinue) {
      Resolve-EmTroLyNodeToolchains -OpenClawRoot $Root
    } else { $null }
    $ltsZNode = if ($zaloToolchains -and $zaloToolchains.Lts -and $zaloToolchains.Lts.NodeExe) { [string]$zaloToolchains.Lts.NodeExe } else { '' }
    $chaChaStrictZ = '--tls-max-v1.2 --tls-cipher-list=ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:DHE-RSA-CHACHA20-POLY1305:!AESGCM:!GCM'

    $zaloAttempts = New-Object System.Collections.Generic.List[object]
    [void]$zaloAttempts.Add([pscustomobject]@{ NodeExe=$node; Registry='https://registry.npmjs.org/'; MaxSockets='2'; Ia32=''; NodeOpts=''; Bridge=$false })
    [void]$zaloAttempts.Add([pscustomobject]@{
      NodeExe    = $(if ($ltsZNode) { $ltsZNode } else { $node })
      Registry   = 'https://registry.npmjs.org/'
      MaxSockets = '1'
      Ia32       = '~0x200000200000000'
      NodeOpts   = $chaChaStrictZ
      Bridge     = [bool](Get-Command -Name 'Start-EmTroLyNpmSChannelBridge' -ErrorAction SilentlyContinue)
    })

    $installResult = $null
    for ($zIdx = 0; $zIdx -lt $zaloAttempts.Count; $zIdx++) {
      $zStep = $zaloAttempts[$zIdx]
      $zTry = $zIdx + 1
      $zAttemptCache = Join-Path $zaloCacheRoot ("attempt-$zTry")
      [void][IO.Directory]::CreateDirectory($zAttemptCache)
      $env:NPM_CONFIG_CACHE = $zAttemptCache
      $zBridge = $null
      $zEffectiveRegistry = $zStep.Registry
      if ($zStep.Bridge) {
        $zBridge = Start-EmTroLyNpmSChannelBridge -UpstreamRegistryUrl $zStep.Registry -FallbackRegistryUrl 'https://registry.npmmirror.com/' -AllowedHosts @('registry.npmjs.org', 'registry.npmmirror.com', 'cdn.npmmirror.com')
        if ($zBridge) {
          $zEffectiveRegistry = $zBridge.ProxyUrl
        } else {
          $zEffectiveRegistry = 'https://registry.npmmirror.com/'
        }
      } elseif ($zTry -ge 2) {
        $zEffectiveRegistry = 'https://registry.npmmirror.com/'
      }
      try {
        [IO.File]::WriteAllText($zaloNpmrc, ("registry=$zEffectiveRegistry`nmaxsockets=$($zStep.MaxSockets)`nfetch-timeout=600000`naudit=false`nfund=false`n"), [Text.UTF8Encoding]::new($false))
        $env:NPM_CONFIG_USERCONFIG = $zaloNpmrc
        $env:NPM_CONFIG_REGISTRY = $zEffectiveRegistry
        $env:NPM_CONFIG_MAXSOCKETS = $zStep.MaxSockets
        if ($zStep.Ia32) { $env:OPENSSL_ia32cap = $zStep.Ia32 } elseif (Test-Path Env:OPENSSL_ia32cap) { Remove-Item Env:OPENSSL_ia32cap -ErrorAction SilentlyContinue }
        if ($zStep.NodeOpts) { $env:NODE_OPTIONS = $zStep.NodeOpts } elseif (Test-Path Env:NODE_OPTIONS) { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue }

        $installResult = Invoke-ZaloPluginCli -Node $zStep.NodeExe -CliEntry $env:OPENCLAW_CLI_ENTRY -Arguments @('plugins', 'install', '--pin', "@openclaw/zalouser@$coreVersion")
      } finally {
        if ($zBridge) { try { $zBridge.Dispose() } catch { } }
      }
      if ($installResult.ExitCode -eq 0) { break }
      $pluginInfo = Get-ZaloPluginInfo -Node $node -CliEntry $env:OPENCLAW_CLI_ENTRY
      if ($pluginInfo) { break }
      $zOutText = [string]($installResult.Output)
      if ((Get-Command -Name 'Test-IsNpmTlsCipherError' -ErrorAction SilentlyContinue) -and ((Test-IsNpmTlsCipherError -LogText $zOutText) -or (Test-IsNpmCacheOrTarballCorruptError -LogText $zOutText))) {
        Remove-Item -LiteralPath $zAttemptCache -Recurse -Force -ErrorAction SilentlyContinue
      }
      if ($zTry -lt $zaloAttempts.Count) {
        $zDelayMs = if ($env:EMTROLY_NPM_RETRY_DELAY_MS -match '^[0-9]+$') { [int]$env:EMTROLY_NPM_RETRY_DELAY_MS } else { ([Math]::Min(2, $zTry) * 1000) }
        if ($zDelayMs -gt 0) { Start-Sleep -Milliseconds $zDelayMs }
      }
    }
  } finally {
    Remove-Item -LiteralPath $zaloNpmrc -Force -ErrorAction SilentlyContinue
    if ($hadNpmCacheZ) { $env:NPM_CONFIG_CACHE = $oldNpmCacheZ } elseif (Test-Path Env:NPM_CONFIG_CACHE) { Remove-Item Env:NPM_CONFIG_CACHE -ErrorAction SilentlyContinue }
    if ($hadNpmPrefixZ) { $env:NPM_CONFIG_PREFIX = $oldNpmPrefixZ } elseif (Test-Path Env:NPM_CONFIG_PREFIX) { Remove-Item Env:NPM_CONFIG_PREFIX -ErrorAction SilentlyContinue }
    if ($hadNpmMaxSocketsZ) { $env:NPM_CONFIG_MAXSOCKETS = $oldNpmMaxSocketsZ } elseif (Test-Path Env:NPM_CONFIG_MAXSOCKETS) { Remove-Item Env:NPM_CONFIG_MAXSOCKETS -ErrorAction SilentlyContinue }
    if ($hadNodeOptsZ) { $env:NODE_OPTIONS = $oldNodeOptsZ } elseif (Test-Path Env:NODE_OPTIONS) { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue }
    if ($hadIa32Z) { $env:OPENSSL_ia32cap = $oldIa32Z } elseif (Test-Path Env:OPENSSL_ia32cap) { Remove-Item Env:OPENSSL_ia32cap -ErrorAction SilentlyContinue }
    if ($hadRegZ) { $env:NPM_CONFIG_REGISTRY = $oldRegZ } elseif (Test-Path Env:NPM_CONFIG_REGISTRY) { Remove-Item Env:NPM_CONFIG_REGISTRY -ErrorAction SilentlyContinue }
    if ($hadUserCfgZ) { $env:NPM_CONFIG_USERCONFIG = $oldUserCfgZ } elseif (Test-Path Env:NPM_CONFIG_USERCONFIG) { Remove-Item Env:NPM_CONFIG_USERCONFIG -ErrorAction SilentlyContinue }
  }
  if (-not $pluginInfo -and $installResult -and $installResult.ExitCode -ne 0) { Set-ZaloCliFailureDetail $installResult; throw 'Zalo plugin installation failed.' }
  Set-ZaloInstallStage 'plugin-inspect'
  if (-not $pluginInfo) { $pluginInfo = Get-ZaloPluginInfo -Node $node -CliEntry $env:OPENCLAW_CLI_ENTRY }
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
  $stopSentinel = Join-Path $Root 'user-gateway.stop'
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
    [IO.File]::WriteAllText($stopSentinel, 'stop', [Text.UTF8Encoding]::new($false))
    if ($record.PSObject.Properties['supervisorPid'] -and $record.supervisorPid) {
      $supProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($record.supervisorPid)" -ErrorAction SilentlyContinue
      if ($supProc -and $supProc.CommandLine -like '*user-gateway.cjs*') {
        Stop-Process -Id ([int]$record.supervisorPid) -Force -ErrorAction SilentlyContinue
      }
    }
    $target = Get-Process -Id $savedPid -ErrorAction Stop
    Stop-Process -InputObject $target -ErrorAction Stop
    $target.WaitForExit(30000) | Out-Null
    if (-not $target.HasExited) { throw 'Gateway did not exit.' }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction Stop
    Remove-Item -LiteralPath $stopSentinel -Force -ErrorAction SilentlyContinue
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
  & $pythonExe $ConfigureScript --root $Root --private-access
  if ($LASTEXITCODE -ne 0) { throw 'Zalo configuration validation failed.' }
  $ownerQrInstaller = Join-Path $Root 'workspace\skills\telegram-zalo-owner-login\scripts\deploy-native.py'
  Set-ZaloInstallStage 'qr-install'
  & $pythonExe $ownerQrInstaller --root $Root --home $env:USERPROFILE --node $node --cli-entry $env:OPENCLAW_CLI_ENTRY --telegram-account $TelegramAccount --zalo-account default --agent main --ensure
  if ($LASTEXITCODE -ne 0) { throw 'Owner-only Zalo QR tool installation failed.' }
  if (-not $Quick) {
    $mentionInstaller = Join-Path $PSScriptRoot 'install-windows-reply-mention.py'
    Set-ZaloInstallStage 'mention-patch'
    & $pythonExe $mentionInstaller --plugin-source $pluginInfo.plugin.source --root $Root --node $node --cli-entry $env:OPENCLAW_CLI_ENTRY
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
Start-Sleep -Seconds 3
Set-ZaloInstallStage 'verify'
& openclaw config validate --json | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'OpenClaw configuration is invalid after Zalo setup.' }
$health = $null
for ($hTry = 1; $hTry -le 5; $hTry++) {
  try {
    $health = (& $node $env:OPENCLAW_CLI_ENTRY gateway health --json | Out-String) | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0 -and $health.ok -and 'zalouser' -in @($health.plugins.loaded) -and 'telegram-zalo-owner-login' -in @($health.plugins.loaded)) { break }
  } catch { }
  if ($hTry -lt 5) { Start-Sleep -Seconds 2 }
}
if (-not $health -or -not $health.ok) { throw 'Gateway health check failed after Zalo setup.' }
if ('zalouser' -notin @($health.plugins.loaded) -or 'telegram-zalo-owner-login' -notin @($health.plugins.loaded)) { throw 'Zalo or owner QR plugin is not loaded by the gateway.' }
$qrInspection = $null
$qrTools = @()
for ($qTry = 1; $qTry -le 5; $qTry++) {
  try {
    $qrInspection = (& openclaw plugins inspect telegram-zalo-owner-login --runtime --json | Out-String) | ConvertFrom-Json
    $qrTools = @($qrInspection.plugin.toolNames)
    foreach ($tool in @($qrInspection.tools)) { $qrTools += @($tool.names) }
    if ($LASTEXITCODE -eq 0 -and $qrInspection.plugin.status -eq 'loaded' -and $qrInspection.plugin.enabled -eq $true -and
        'zaloqr' -in @($qrInspection.commands) -and 'zalostatus' -in @($qrInspection.commands) -and
        'telegram_zalo_login_qr' -in $qrTools) { break }
  } catch { }
  if ($qTry -lt 5) { Start-Sleep -Seconds 2 }
}
if (-not $qrInspection -or $qrInspection.plugin.status -ne 'loaded' -or $qrInspection.plugin.enabled -ne $true -or
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
