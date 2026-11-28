[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Name,
  [string]$OwnerIds = '',
  [string]$GroupId = '',
  [string]$AssistantName = 'Trợ lý OpenClaw',
  [string]$BaseUrl = 'https://codex.anhlaptrinh.vn/v1',
  [string]$Model = 'gpt-6.2-sol',
  [string]$Profile = 'basic-assistant-full',
  [string]$Audience = '',
  [string]$Addressing = '',
  [string]$Style = '',
  [string[]]$Modules = @(),
  [string]$QrOwnerId = '',
  [string]$OpenClawVersion = '2026.11.4',
  [ValidateSet('auto','new','upgrade')][string]$InstallMode = 'auto',
  [string]$ExistingRoot = '',
  [string]$InstallRoot = '',
  [int]$GatewayPort = 0,
  [switch]$FullBundle,
  [switch]$DryRun,
  [switch]$UserInstall,
  [string]$CredentialFile = '',
  [psobject]$CredentialData = $null
)
$ErrorActionPreference = 'Stop'

function Write-NativeInstallLog([string]$Entry, [string[]]$Secrets = @()) {
  if (-not $env:EMTROLY_INSTALL_LOG_FILE) { return }
  try {
    $safe = [string]$Entry
    foreach ($s in $Secrets) {
      if ($s -and $s.Length -ge 6) { $safe = $safe.Replace($s, '[REDACTED_SECRET]') }
    }
    $safe = [regex]::Replace($safe, '[0-9]{5,}:[A-Za-z0-9_-]{20,}', '[REDACTED_TELEGRAM_TOKEN]')
    $safe = [regex]::Replace($safe, 'sk-[A-Za-z0-9_-]{12,}', '[REDACTED_API_KEY]')
    $safe = [regex]::Replace($safe, '("token"\s*:\s*")[0-9a-fA-F]{24,}(")', '$1[REDACTED_GATEWAY_TOKEN]$2')
    $logParent = Split-Path -Parent $env:EMTROLY_INSTALL_LOG_FILE
    if ($logParent -and -not (Test-Path -LiteralPath $logParent -PathType Container)) {
      [void][IO.Directory]::CreateDirectory($logParent)
    }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    [IO.File]::AppendAllText($env:EMTROLY_INSTALL_LOG_FILE, "[$stamp] [native] $safe`r`n", (New-Object Text.UTF8Encoding($false)))
  } catch { }
}

function Write-NativeInstallStatus([string]$Text) {
  if ($env:MEMBER_INSTALL_STATUS_FILE) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    for ($attempt = 1; $attempt -le 12; $attempt++) {
      $fs = $null
      try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $fs = New-Object System.IO.FileStream($env:MEMBER_INSTALL_STATUS_FILE, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, $share)
        $fs.SetLength(0)
        if ($bytes.Length -gt 0) { $fs.Write($bytes, 0, $bytes.Length) }
        $fs.Flush()
        break
      } catch {
        if ($attempt -lt 12) { Start-Sleep -Milliseconds 25 }
      } finally {
        if ($null -ne $fs) { try { $fs.Dispose() } catch { } }
      }
    }
  }
  Write-NativeInstallLog -Entry ("STATUS: " + $Text)
}

function Optimize-NativeProcessPath {
  $priority = New-Object System.Collections.Generic.List[string]
  $depBase = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies' } else { '' }
  if ($depBase -and (Test-Path -LiteralPath $depBase -PathType Container)) {
    foreach ($d in @(Get-ChildItem -LiteralPath $depBase -Directory -ErrorAction SilentlyContinue)) {
      if ($d.Name -like 'node-v*' -or $d.Name -like 'python*') { [void]$priority.Add($d.FullName) }
      elseif ($d.Name -like 'ffmpeg-*') {
        $fb = Join-Path $d.FullName 'bin'
        if (Test-Path -LiteralPath $fb -PathType Container) { [void]$priority.Add($fb) }
      }
    }
  }
  foreach ($cand in @(
    $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'nodejs' }),
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\nodejs' })
  )) {
    if ($cand -and (Test-Path -LiteralPath $cand -PathType Container)) { [void]$priority.Add($cand) }
  }
  foreach ($pyRoot in @(
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\Python' }),
    $env:ProgramFiles
  )) {
    if ($pyRoot -and (Test-Path -LiteralPath $pyRoot -PathType Container)) {
      foreach ($pd in @(Get-ChildItem -LiteralPath $pyRoot -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        if (Test-Path -LiteralPath (Join-Path $pd.FullName 'python.exe') -PathType Leaf) { [void]$priority.Add($pd.FullName) }
      }
    }
  }
  $uPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $mPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $allRaw = @($priority)
  if ($env:Path) { $allRaw += ($env:Path -split ';') }
  if ($uPath) { $allRaw += ($uPath -split ';') }
  if ($mPath) { $allRaw += ($mPath -split ';') }
  $normal = New-Object System.Collections.Generic.List[string]
  $winApps = New-Object System.Collections.Generic.List[string]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($item in $allRaw) {
    if ([string]::IsNullOrWhiteSpace($item)) { continue }
    $norm = $item.Trim().Trim('"').TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($norm) -or (-not $seen.Add($norm))) { continue }
    if ($norm -like '*\WindowsApps*') { [void]$winApps.Add($item.Trim()) } else { [void]$normal.Add($item.Trim()) }
  }
  $env:Path = (@($normal) + @($winApps)) -join ';'
}

function Resolve-VerifiedPythonExe {
  $candidates = @()
  $depBase = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies' } else { '' }
  if ($depBase) {
    $candidates += (Join-Path $depBase 'python313\python.exe')
    $candidates += (Join-Path $depBase 'python312\python.exe')
  }
  foreach ($cmd in @(Get-Command python.exe -All -CommandType Application -ErrorAction SilentlyContinue)) {
    if ($cmd.Source -and $cmd.Source -notlike '*\WindowsApps\*') { $candidates += $cmd.Source }
  }
  if ($env:LOCALAPPDATA) {
    $candidates += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Python\*\python.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
  }
  if ($env:ProgramFiles) {
    $candidates += @(Get-ChildItem (Join-Path $env:ProgramFiles 'Python*\python.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
  }
  foreach ($exe in @($candidates | Where-Object { $_ } | Select-Object -Unique)) {
    if ($exe -like '*\WindowsApps\*' -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
    try {
      & $exe -c 'import json,sqlite3,sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' *> $null
      if ($LASTEXITCODE -eq 0) { return $exe }
    } catch { }
  }
  return ''
}

function Test-CanResetIncompleteRoot([string]$DirPath) {
  if ([string]::IsNullOrWhiteSpace($DirPath) -or -not (Test-Path -LiteralPath $DirPath -PathType Container)) { return $false }
  try {
    $rootItem = Get-Item -LiteralPath $DirPath -Force -ErrorAction Stop
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
  } catch { return $false }
  $children = @(Get-ChildItem -LiteralPath $DirPath -Force -ErrorAction SilentlyContinue)
  if ($children.Count -eq 0) { return $true }
  $markerFile = Join-Path $DirPath '.emtroly-installing.json'
  if (Test-Path -LiteralPath $markerFile -PathType Leaf) {
    try {
      $mObj = [IO.File]::ReadAllText($markerFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
      if ($mObj -and $mObj.pid -and ([int]$mObj.pid -ne $PID)) {
        $liveProc = Get-Process -Id ([int]$mObj.pid) -ErrorAction SilentlyContinue
        if ($liveProc -and $liveProc.ProcessName -match '^(?i)(powershell|pwsh|emtroly)$') { return $false }
      }
    } catch { }
    return $true
  }
  $hasCompletedLauncher = (Test-Path -LiteralPath (Join-Path $DirPath 'openclaw-instance.ps1') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $DirPath 'installer-instance.json') -PathType Leaf)
  if ($hasCompletedLauncher) { return $false }
  $knownItems = @(
    'runtime', 'workspace', 'npm-cache', 'logs', 'backups',
    'openclaw.json', 'telegram.token', 'member-provider.secret',
    'installation-credentials.json', 'modules.json', 'module-manager.ps1',
    'windows-instance.ps1', 'user-gateway.ps1', 'user-gateway.cjs',
    'user-gateway.log', 'user-gateway.pid.json', 'user-gateway.stop',
    'installer-codex-pending.json', 'agents', 'sessions', 'credentials',
    'devices', 'cron', 'canvas', '.codex'
  )
  foreach ($ch in $children) {
    if ($ch.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    if ($ch.Name -notin $knownItems) { return $false }
  }
  return $true
}

function Clear-IncompleteRootInPlace([string]$DirPath) {
  if (-not (Test-Path -LiteralPath $DirPath -PathType Container)) { return }
  try {
    $strayNodes = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue | Where-Object {
      $_.CommandLine -and $_.CommandLine.IndexOf($DirPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    foreach ($sn in $strayNodes) {
      if ($sn.ProcessId) { Stop-Process -Id ([int]$sn.ProcessId) -Force -ErrorAction SilentlyContinue }
    }
  } catch { }
  $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
  foreach ($ch in @(Get-ChildItem -LiteralPath $DirPath -Force -ErrorAction SilentlyContinue)) {
    if ($ch.PSIsContainer -and (Test-Path -LiteralPath $cmdExe -PathType Leaf)) {
      try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $cmdExe
        $psi.Arguments = '/d /s /c "rmdir /s /q "' + $ch.FullName + '""'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $p = [System.Diagnostics.Process]::Start($psi)
        [void]$p.WaitForExit(20000)
        $p.Dispose()
      } catch { }
    }
    if (Test-Path -LiteralPath $ch.FullName) {
      Remove-Item -LiteralPath $ch.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

if (-not $UserInstall -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'System-service mode requires Administrator; new web installations use UserInstall.' }
if ($Name -notmatch '^[a-z][a-z0-9_-]{0,63}$') { throw 'Name must use lowercase letters, numbers, underscore or hyphen.' }
. (Join-Path $PSScriptRoot 'native\windows-instance.ps1')
if ($InstallMode -ne 'new') {
  $existing = Select-OpenClawInstance -HomeDirectory $env:USERPROFILE -Name $Name -ExistingRoot $ExistingRoot
  if ($existing) {
    if (Test-Path (Join-Path $existing 'user-gateway.cjs')) { throw 'This user installation already exists. Use its instance helper to check or repair it; do not overwrite it with a fresh installation.' }
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Upgrading this legacy service needs Windows elevation. New user installations do not.' }
    & (Join-Path $PSScriptRoot 'native\upgrade-windows.ps1') -ExistingRoot $existing -OpenClawVersion $OpenClawVersion -DryRun:$DryRun
    return
  }
  if ($InstallMode -eq 'upgrade') { throw 'No existing installation found. Choose independent new installation.' }
}
if ([string]::IsNullOrWhiteSpace($Model)) { throw 'Model is required.' }
if ($BaseUrl -match '^\s*\[[^\]]+\]\((https?://[^)]+)\)\s*$') { $BaseUrl = $Matches[1] }
$owners = @($OwnerIds -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[1-9][0-9]*$' })
if ($owners.Count -eq 0) { throw 'At least one positive Telegram owner ID is required.' }
$GroupId = $GroupId.Trim()
if (-not [string]::IsNullOrWhiteSpace($GroupId) -and $GroupId -notmatch '^-[1-9][0-9]*$') { throw 'GroupId must be an explicit negative Telegram group ID for the group allowlist, or left empty.' }
$zaloSelected = ($Profile -eq 'installer-basic') -or ($Modules -contains 'zalo-personal') -or ($Modules -contains 'zalo-qr-basic')
if ($zaloSelected -and ($QrOwnerId -notin $owners)) { throw 'QrOwnerId must be one of the Telegram owner IDs.' }
if ($DryRun) { Write-Host "DRY-RUN: native OpenClaw $OpenClawVersion for $Name (model: $Model); no files or services changed."; exit 0 }
$root = Join-Path $env:USERPROFILE ('.openclaw-member-' + $Name)
if ($InstallRoot) {
  $expectedRoot = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'openclaw')).TrimEnd('\')
  $requestedRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
  if ($InstallMode -ne 'new' -or -not $UserInstall -or
      -not [string]::Equals($requestedRoot, $expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Invalid install root; no files were changed.'
  }
  $root = $expectedRoot
}
$workspace = Join-Path $root 'workspace'
$configPath = Join-Path $root 'openclaw.json'
if (Test-Path -LiteralPath $root) {
  if (Test-CanResetIncompleteRoot -DirPath $root) {
    Write-NativeInstallStatus 'Phát hiện thư mục OpenClaw trống hoặc cài dở từ lần trước — đang làm sạch để tiếp tục cài đặt…'
    Clear-IncompleteRootInPlace -DirPath $root
  } else {
    throw "Independent install already exists at $root. Choose Upgrade or another Name. No existing files were changed."
  }
}
$env:OPENCLAW_PROFILE = 'member-' + $Name
$env:OPENCLAW_STATE_DIR = $root
$env:OPENCLAW_ROOT = $root
$env:OPENCLAW_CONFIG_PATH = $configPath
$env:OPENCLAW_WORKSPACE_DIR = $workspace
foreach ($selector in @('OPENCLAW_GATEWAY_TOKEN','OPENCLAW_GATEWAY_PASSWORD','OPENCLAW_GATEWAY_PORT','OPENCLAW_SYSTEMD_UNIT','OPENCLAW_LAUNCHD_LABEL','OPENCLAW_WINDOWS_TASK_NAME','OPENCLAW_SERVICE_KIND','OPENCLAW_SERVICE_MARKER')) { Remove-Item "Env:$selector" -ErrorAction SilentlyContinue }
$occupied = @()
try {
  $occupied = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Select-Object -ExpandProperty LocalPort)
} catch {
  $occupied = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Select-Object -ExpandProperty Port)
}
if ($GatewayPort -ne 0 -and ($GatewayPort -lt 1024 -or $GatewayPort -gt 65000)) { throw 'GatewayPort must be between 1024 and 65000.' }
$automaticPort = $GatewayPort -eq 0
if ($automaticPort) { $GatewayPort = 19789 }
while (@($occupied | Where-Object { $_ -ge ($GatewayPort - 110) -and $_ -le ($GatewayPort + 110) }).Count -gt 0) {
  if (-not $automaticPort) { throw 'Gateway port range is occupied. Choose another port at least 120 away from another gateway.' }
  $GatewayPort += 120
  if ($GatewayPort -gt 65000) { throw 'No free gateway port range was found.' }
}
function Unprotect([Security.SecureString]$Value) { $buffer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value); try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($buffer) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($buffer) } }
$credentials = $null
if ($CredentialData) {
  $credentials = $CredentialData
  $tg = [string]$credentials.telegram_token
  $key = [string]$credentials.ai_api_key
} elseif ($CredentialFile) {
  $credentials = Get-Content -LiteralPath $CredentialFile -Raw | ConvertFrom-Json
  $tg = [string]$credentials.telegram_token
  $key = [string]$credentials.ai_api_key
} else {
  $tg = Unprotect (Read-Host 'Telegram Bot Token (use a separate bot for this instance)' -AsSecureString)
  $key = Unprotect (Read-Host 'Provider API Key' -AsSecureString)
}
if ([string]::IsNullOrWhiteSpace($tg) -or [string]::IsNullOrWhiteSpace($key)) { throw 'Telegram token and API key must not be empty.' }
$status = 'Đang kiểm tra và cài Node.js, Python, FFmpeg nếu máy còn thiếu…'
Write-NativeInstallStatus $status
Optimize-NativeProcessPath
if ($UserInstall) {
  . (Join-Path $PSScriptRoot 'native\user-dependencies.ps1')
  Initialize-UserDependencies
  Optimize-NativeProcessPath
}
if (-not (Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue)) {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    & winget install --id OpenJS.NodeJS.LTS --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements
    Optimize-NativeProcessPath
  } else {
    throw 'Node.js is missing and winget is unavailable.'
  }
}
$verifiedPythonExe = Resolve-VerifiedPythonExe
if (-not $verifiedPythonExe) {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    & winget install --id Python.Python.3.12 --scope user --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements
    Optimize-NativeProcessPath
    $verifiedPythonExe = Resolve-VerifiedPythonExe
    if (-not $verifiedPythonExe) {
      & winget install --id Python.Python.3.12 --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements
      Optimize-NativeProcessPath
      $verifiedPythonExe = Resolve-VerifiedPythonExe
    }
  } else {
    throw 'Python is missing and winget is unavailable.'
  }
}
if (-not $UserInstall -and -not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  if (Get-Command winget -ErrorAction SilentlyContinue) { winget install --id Gyan.FFmpeg.Shared --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements }
  else { Write-Warning 'FFmpeg is missing; media modules will need FFmpeg installed later.' }
}
Optimize-NativeProcessPath
if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { throw 'npm is unavailable after Node.js installation.' }
if (-not $verifiedPythonExe) { $verifiedPythonExe = Resolve-VerifiedPythonExe }
if (-not $verifiedPythonExe) { throw 'Python is unavailable. Reopen PowerShell as Administrator and retry.' }
$env:Path = (Split-Path -Parent $verifiedPythonExe) + ';' + $env:Path

New-Item -ItemType Directory -Force -Path $root,$workspace,(Join-Path $workspace 'skills') | Out-Null
$installingMarkerPath = Join-Path $root '.emtroly-installing.json'
[IO.File]::WriteAllText($installingMarkerPath, (@{ pid = $PID; startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); name = $Name } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls $root /inheritance:r /grant:r "${currentUser}:(OI)(CI)(F)" '*S-1-5-18:(OI)(CI)(F)' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Unable to protect the private instance directory.' }
$runtime = Join-Path $root ('runtime\' + $OpenClawVersion)
$logsDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $runtime,$logsDir | Out-Null
$status = 'Đang tải và cài OpenClaw ' + $OpenClawVersion + '. Bước này có thể mất vài phút…'
Write-NativeInstallStatus $status
$runtimePackage = @{ name='member-openclaw-runtime'; version='1.0.0'; private=$true; allowScripts=@{ '@google/genai'=$true; esbuild=$true; koffi=$true; openclaw=$true; protobufjs=$true; 'tree-sitter-bash'=$true } }
[IO.File]::WriteAllText((Join-Path $runtime 'package.json'), ($runtimePackage | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
$isolatedNpmrc = Join-Path $runtime '.npmrc.emtroly'
$npmCacheDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'MemberInstaller\npm-cache' } else { Join-Path $root 'npm-cache' }
New-Item -ItemType Directory -Force -Path $npmCacheDir | Out-Null
$npmLogFile = Join-Path $logsDir 'npm-install.log'
$previousErrorAction = $ErrorActionPreference
$hadNpmCache = Test-Path Env:NPM_CONFIG_CACHE
$oldNpmCache = if ($hadNpmCache) { $env:NPM_CONFIG_CACHE } else { $null }
$hadNpmUserCfg = Test-Path Env:NPM_CONFIG_USERCONFIG
$oldNpmUserCfg = if ($hadNpmUserCfg) { $env:NPM_CONFIG_USERCONFIG } else { $null }
$hadNpmPrefix = Test-Path Env:NPM_CONFIG_PREFIX
$oldNpmPrefix = if ($hadNpmPrefix) { $env:NPM_CONFIG_PREFIX } else { $null }
$hadNodeOptions = Test-Path Env:NODE_OPTIONS
$oldNodeOptions = if ($hadNodeOptions) { $env:NODE_OPTIONS } else { $null }
$hadIa32Cap = Test-Path Env:OPENSSL_ia32cap
$oldIa32Cap = if ($hadIa32Cap) { $env:OPENSSL_ia32cap } else { $null }
$npmExitCode = 1
try {
  $env:NPM_CONFIG_CACHE = $npmCacheDir
  $env:NPM_CONFIG_USERCONFIG = $isolatedNpmrc
  if (Test-Path Env:NPM_CONFIG_PREFIX) { Remove-Item Env:NPM_CONFIG_PREFIX -ErrorAction SilentlyContinue }
  if (Test-Path Env:NODE_OPTIONS) { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue }
  for ($npmTry = 1; $npmTry -le 3; $npmTry++) {
    $registryUrl = if ($npmTry -ge 3) { 'https://registry.npmmirror.com/' } else { 'https://registry.npmjs.org/' }
    $maxSockets = if ($npmTry -eq 1) { 6 } elseif ($npmTry -eq 2) { 2 } else { 1 }
    [IO.File]::WriteAllText($isolatedNpmrc, "registry=$registryUrl`nmaxsockets=$maxSockets`nfetch-retries=5`nfetch-retry-mintimeout=2000`nfetch-retry-maxtimeout=15000`nfetch-timeout=600000`naudit=false`nfund=false`n", [Text.UTF8Encoding]::new($false))
    if ($npmTry -ge 2) {
      # Work around OpenSSL 3 AES-GCM / VAES / TLS 1.3 cipher failures on affected Windows CPUs, VPNs, and AV SSL proxies
      $env:OPENSSL_ia32cap = '~0x200000200000000'
      $env:NODE_OPTIONS = '--tls-max-v1.2 --tls-cipher-list=ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-CHACHA20-POLY1305:DEFAULT'
    } else {
      if (Test-Path Env:NODE_OPTIONS) { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue }
      if ($hadIa32Cap) { $env:OPENSSL_ia32cap = $oldIa32Cap } elseif (Test-Path Env:OPENSSL_ia32cap) { Remove-Item Env:OPENSSL_ia32cap -ErrorAction SilentlyContinue }
    }
    $ErrorActionPreference = 'Continue'
    & npm.cmd install --prefix $runtime "openclaw@$OpenClawVersion" --no-audit --no-fund --prefer-offline --loglevel=error *> $npmLogFile
    $npmExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction
    if ($npmExitCode -eq 0) { break }
    $npmTail = if (Test-Path -LiteralPath $npmLogFile -PathType Leaf) { (@(Get-Content -LiteralPath $npmLogFile -Tail 20 -ErrorAction SilentlyContinue) -join ' | ') } else { '' }
    Write-NativeInstallLog -Entry ("npm install attempt $npmTry/3 failed (exit=$npmExitCode): $npmTail") -Secrets @($tg, $key)
    if ($npmTry -lt 3) {
      if ($npmTail -match 'ERR_SSL_CIPHER_OPERATION_FAILED|ossl_gcm_stream_update|ciphercommon_gcm|cipher operation failed') {
        $retryStatus = if ($npmTry -eq 1) {
          'Phát hiện lỗi giải mã TLS/SSL — đang tự động thử cài lại OpenClaw ở chế độ TLS 1.2 / ChaCha20 (lần 2/3)...'
        } else {
          'Đang chuyển sang máy chủ npm dự phòng với chế độ bảo toàn kết nối TLS (lần 3/3)...'
        }
        Write-NativeInstallStatus $retryStatus
      } else {
        Write-NativeInstallStatus "Windows đang quét tệp hoặc mạng chập chờn — đang tự động thử cài lại OpenClaw (lần $($npmTry + 1)/3)..."
      }
      $partialModules = Join-Path $runtime 'node_modules'
      if (Test-Path -LiteralPath $partialModules) {
        $cmdClean = Join-Path $env:SystemRoot 'System32\cmd.exe'
        if (Test-Path -LiteralPath $cmdClean -PathType Leaf) {
          try {
            $psiNpm = New-Object System.Diagnostics.ProcessStartInfo($cmdClean, '/d /s /c "rmdir /s /q "' + $partialModules + '""')
            $psiNpm.UseShellExecute = $false; $psiNpm.CreateNoWindow = $true
            $pNpm = [System.Diagnostics.Process]::Start($psiNpm); [void]$pNpm.WaitForExit(15000); $pNpm.Dispose()
          } catch { }
        }
        Remove-Item -LiteralPath $partialModules -Recurse -Force -ErrorAction SilentlyContinue
      }
      Start-Sleep -Seconds (3 * $npmTry)
    }
  }
} finally {
  $ErrorActionPreference = $previousErrorAction
  if ($hadNpmCache) { $env:NPM_CONFIG_CACHE = $oldNpmCache } elseif (Test-Path Env:NPM_CONFIG_CACHE) { Remove-Item Env:NPM_CONFIG_CACHE -ErrorAction SilentlyContinue }
  if ($hadNpmUserCfg) { $env:NPM_CONFIG_USERCONFIG = $oldNpmUserCfg } elseif (Test-Path Env:NPM_CONFIG_USERCONFIG) { Remove-Item Env:NPM_CONFIG_USERCONFIG -ErrorAction SilentlyContinue }
  if ($hadNpmPrefix) { $env:NPM_CONFIG_PREFIX = $oldNpmPrefix } elseif (Test-Path Env:NPM_CONFIG_PREFIX) { Remove-Item Env:NPM_CONFIG_PREFIX -ErrorAction SilentlyContinue }
  if ($hadNodeOptions) { $env:NODE_OPTIONS = $oldNodeOptions } elseif (Test-Path Env:NODE_OPTIONS) { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue }
  if ($hadIa32Cap) { $env:OPENSSL_ia32cap = $oldIa32Cap } elseif (Test-Path Env:OPENSSL_ia32cap) { Remove-Item Env:OPENSSL_ia32cap -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $isolatedNpmrc -Force -ErrorAction SilentlyContinue
}
if ($npmExitCode -ne 0) { throw 'Private OpenClaw installation failed.' }
$bundledPostinstall = Join-Path $runtime 'node_modules\openclaw\scripts\postinstall-bundled-plugins.mjs'
if (-not (Test-Path -LiteralPath $bundledPostinstall)) { throw 'Bundled plugin installer was not found.' }
$postinstallOk = $false
for ($piTry = 1; $piTry -le 2; $piTry++) {
  & node $bundledPostinstall
  if ($LASTEXITCODE -eq 0) { $postinstallOk = $true; break }
  if ($piTry -lt 2) { Start-Sleep -Seconds 2 }
}
if (-not $postinstallOk) { throw 'Bundled OpenClaw plugin installation failed.' }
$cliEntry = Join-Path $runtime 'node_modules\openclaw\openclaw.mjs'
if (-not (Test-Path $cliEntry)) { throw "Private OpenClaw CLI was not found: $cliEntry" }
$env:OPENCLAW_CLI_ENTRY = $cliEntry
$env:Path = (Join-Path $runtime 'node_modules\.bin') + ';' + $env:Path
function Invoke-OpenClaw { & node $cliEntry @args; $global:LASTEXITCODE = $LASTEXITCODE }
if ($UserInstall) {
  . (Join-Path $PSScriptRoot 'native\user-gateway.ps1')
  function Invoke-OpenClaw { Invoke-InstanceCli -Root $root -CliEntry $cliEntry @args; $global:LASTEXITCODE = $LASTEXITCODE }
}
. (Join-Path $PSScriptRoot 'native\windows-cli.ps1')
$tokenPath = Join-Path $root 'telegram.token'
[IO.File]::WriteAllText($tokenPath, "$tg`n", [Text.UTF8Encoding]::new($false))
$secretPath = Join-Path $root 'member-provider.secret'
[IO.File]::WriteAllText($secretPath, "$key`n", [Text.UTF8Encoding]::new($false))
foreach ($privateFile in @($tokenPath, $secretPath)) {
  & icacls $privateFile /inheritance:r /grant:r "${currentUser}:(F)" '*S-1-5-18:(F)' *> $null
  if ($LASTEXITCODE -ne 0) { throw 'Unable to protect customer credential files.' }
}
if ($credentials) {
  $additional = @{ extra_secret=$credentials.extra_secret; module_credentials=$credentials.module_credentials } | ConvertTo-Json -Depth 20
  $additionalPath = Join-Path $root 'installation-credentials.json'
  [IO.File]::WriteAllText($additionalPath, $additional, [Text.UTF8Encoding]::new($false))
  & icacls $additionalPath /inheritance:r /grant:r "${currentUser}:(F)" '*S-1-5-18:(F)' *> $null
  if ($LASTEXITCODE -ne 0) { throw 'Unable to protect module credential file.' }
}
$account = @{
  enabled=$true; tokenFile=$tokenPath; dmPolicy='allowlist'; allowFrom=$owners
  groupPolicy='allowlist'; groupAllowFrom=@('*')
}
$targetGroup = $GroupId
$account.groups=@{}
if (-not [string]::IsNullOrWhiteSpace($targetGroup)) {
  $account.groups[$targetGroup]=@{ groupPolicy='allowlist'; requireMention=$false; tools=@{ allow=@('*') }; toolsBySender=@{ '*'=@{ alsoAllow=@('exec','process') } } }
}
$randomBytes = New-Object byte[] 32
$randomGenerator = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $randomGenerator.GetBytes($randomBytes) } finally { $randomGenerator.Dispose() }
$gatewayToken = [BitConverter]::ToString($randomBytes).Replace('-', '').ToLowerInvariant()
$config = @{
  gateway=@{ mode='local'; bind='loopback'; port=$GatewayPort; auth=@{ mode='token'; token=$gatewayToken } }
  secrets=@{ providers=@{ customer=@{ source='file'; path=(Join-Path $root 'member-provider.secret'); mode='singleValue' } } }
  models=@{ providers=@{ customer=@{ baseUrl=$BaseUrl; apiKey=@{ source='file'; provider='customer'; id='value' }; api='openai-completions'; models=@(@{ id=$Model; name=$Model }) }; openai=@{ baseUrl=$BaseUrl; apiKey=@{ source='file'; provider='customer'; id='value' }; auth='api-key'; api='openai-completions'; models=@(@{ id='cx/gpt-image-2'; name='Member image API' }) } } }
  agents=@{ defaults=@{ workspace=$workspace; model=@{ primary="customer/$Model" }; mediaModels=@{ image=@{ primary='openai/cx/gpt-image-2'; timeoutMs=240000 } } }; entries=@{ main=@{ name=$AssistantName; tools=@{ exec=@{ host='gateway'; mode='full'; strictInlineEval=$false }; toolsBySender=@{ '*'=@{ alsoAllow=@('exec','process','group:fs') } } } } } }
  channels=@{ telegram=@{ enabled=$true; groupPolicy='allowlist'; defaultAccount=$Name; commands=@{ native=$true; nativeSkills=$false }; accounts=@{ $Name=$account } } }
  bindings=@(@{ agentId='main'; match=@{ channel='telegram'; accountId=$Name } })
  commands=@{ ownerAllowFrom=@($owners | ForEach-Object { "telegram:$_" }) }
  tools=@{ exec=@{ host='gateway'; mode='full'; strictInlineEval=$false } }
} | ConvertTo-Json -Depth 20
$env:OPENCLAW_STATE_DIR = $root
$env:OPENCLAW_CONFIG_PATH = $configPath
$env:OPENCLAW_WORKSPACE_DIR = $workspace
[IO.File]::WriteAllText($configPath, "$config`n", [Text.UTF8Encoding]::new($false))
& icacls $configPath /inheritance:r /grant:r "${currentUser}:(F)" '*S-1-5-18:(F)' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Unable to protect config.' }
Invoke-OpenClaw config validate --json
if ($LASTEXITCODE -ne 0) { throw 'Generated OpenClaw config is invalid. Check the preceding validator output.' }
$status = if ($zaloSelected) { 'Đang cài các kỹ năng trợ lý, Zalo và tiện ích QR…' } else { 'Đang cài các kỹ năng trợ lý, tạo ảnh và xử lý tài liệu…' }
Write-NativeInstallStatus $status
$managerInstaller = Join-Path $PSScriptRoot 'native\install-module-manager-windows.ps1'
& powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $managerInstaller -OpenClawRoot $root
if ($LASTEXITCODE -ne 0) { throw 'Module manager installation failed.' }
if ($FullBundle) {
  & powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File (Join-Path $PSScriptRoot 'native\sync-skills.ps1') -OpenClawRoot $root -BundleDir (Join-Path $PSScriptRoot 'native\skills')
} else {
  $manager = Join-Path $root 'module-manager.ps1'
  $hadSkipRestart = Test-Path Env:OPENCLAW_SKIP_MODULE_RESTART
  $previousSkipRestart = $env:OPENCLAW_SKIP_MODULE_RESTART
  try {
    $env:OPENCLAW_SKIP_MODULE_RESTART = '1'
    & $manager -Command install -Profile $Profile -Module $Modules
    if ($LASTEXITCODE -ne 0) { throw 'Module installation failed.' }
  } finally {
    if ($hadSkipRestart) { $env:OPENCLAW_SKIP_MODULE_RESTART = $previousSkipRestart }
    else { Remove-Item Env:OPENCLAW_SKIP_MODULE_RESTART -ErrorAction SilentlyContinue }
  }
}
$ensure = Join-Path $PSScriptRoot 'native\skills\tao-tro-ly-openclaw-windows-macos-linux\scripts\ensure_default_telegram_owner.py'
$training = Join-Path $PSScriptRoot 'native\skills\sync-openclaw-owner-training\scripts\sync_owner_training_policy.py'
$backup = Join-Path $root 'backups\onboarding'
$ownerBackup = Join-Path $backup 'owner'
$trainingBackup = Join-Path $backup 'training'
$ownerArgs = @('--openclaw-root',$root,'--account-id',$Name,'--agent-id','main','--apply','--backup-dir',$ownerBackup)
foreach ($owner in $owners) { $ownerArgs += @('--owner-id',$owner) }
& $verifiedPythonExe $ensure @ownerArgs
if ($LASTEXITCODE -ne 0) { throw 'Owner configuration failed.' }
& $verifiedPythonExe $training --openclaw-root $root --workspace $workspace --apply --backup-dir $trainingBackup
if ($LASTEXITCODE -ne 0) { throw 'Owner training configuration failed.' }
& $verifiedPythonExe (Join-Path $PSScriptRoot 'native\finalize_permissions.py') --config $configPath --owners ($owners -join ',')
if ($LASTEXITCODE -ne 0) { throw 'Permission configuration failed.' }
$status = 'Đang cấu hình quyền Full Exec cho chủ bot Telegram…'
Write-NativeInstallStatus $status
$approvals = @{
  version = 1
  defaults = @{ security='allowlist'; ask='on-miss'; askFallback='deny'; autoAllowSkills=$false }
  agents = @{ main=@{ security='full'; ask='off'; askFallback='full'; autoAllowSkills=$true; allowlist=@() } }
} | ConvertTo-Json -Depth 8 -Compress
$approvals | & node $cliEntry approvals set --stdin --json | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Full Exec approval store configuration failed.' }
$approvalState = (& node $cliEntry approvals get --json | Out-String) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $approvalState.file.agents.main.security -ne 'full' -or $approvalState.file.agents.main.ask -ne 'off') { throw 'Full Exec approval store verification failed.' }
$customerProfile = "# Ho so tro ly`n`nTen tro ly: $AssistantName`n`nDoi tuong phuc vu: $Audience`n`nCach xung ho: $Addressing`n`nPhong cach tra loi: $Style`n"
[IO.File]::WriteAllText((Join-Path $workspace 'CUSTOMER_PROFILE.md'), $customerProfile, [Text.UTF8Encoding]::new($false))
$agentInstructions = Join-Path $workspace 'AGENTS.md'
$reference = 'Read CUSTOMER_PROFILE.md and follow the assistant name, audience, addressing and response style.'
if (-not (Test-Path $agentInstructions) -or -not (Select-String -Path $agentInstructions -SimpleMatch $reference -Quiet)) { Add-Content -Path $agentInstructions -Value "`n$reference" -Encoding UTF8 }
Invoke-OpenClaw config validate --json
if ($LASTEXITCODE -ne 0) { throw 'OpenClaw configuration is invalid.' }
Invoke-OpenClaw skills check
if ($LASTEXITCODE -ne 0) { throw 'OpenClaw skills check failed.' }
Save-OpenClawInstanceLauncher -Root $root -InstanceProfile $env:OPENCLAW_PROFILE -CliEntry $cliEntry -Port $GatewayPort -Python $verifiedPythonExe
if ($UserInstall) {
  Write-NativeInstallStatus 'Đang đăng ký lệnh openclaw vào PATH của tài khoản Windows…'
  Install-UserOpenClawCli -Root $root -CliEntry $cliEntry -Port $GatewayPort -Profile $env:OPENCLAW_PROFILE -ExpectedVersion $OpenClawVersion -Python $verifiedPythonExe
  Install-UserGateway -Root $root -CliEntry $cliEntry -Port $GatewayPort -Python $verifiedPythonExe
}
if ($zaloSelected) {
  Write-NativeInstallStatus 'Đang cài plugin Zalo và đăng ký /zaloqr, /zalostatus (chưa đăng nhập Zalo)…'
  $zaloOnboard = Join-Path $PSScriptRoot 'zalo\onboard-zalouser-windows.ps1'
  $zaloConfigure = Join-Path $PSScriptRoot 'zalo\configure-zalo.py'
  $zaloQr = Join-Path $workspace 'skills\openclaw-zalo-qr-login\scripts\send_zalo_qr_to_telegram_owner.mjs'
  $zaloLogFile = Join-Path $logsDir 'zalo-onboard.log'
  $prevErrZ = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $zaloOnboard -Root $root -TelegramAccount $Name -OwnerId $QrOwnerId -ConfigureScript $zaloConfigure -QrScript $zaloQr -Quick -PreGateway *> $zaloLogFile
    $zaloExit = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prevErrZ }
  if ($zaloExit -ne 0) {
    $zaloTail = if (Test-Path -LiteralPath $zaloLogFile -PathType Leaf) { (@(Get-Content -LiteralPath $zaloLogFile -Tail 20 -ErrorAction SilentlyContinue) -join ' | ') } else { '' }
    Write-NativeInstallLog -Entry ("zalo onboard failed (exit=$zaloExit): $zaloTail") -Secrets @($tg, $key)
    throw 'Windows Zalo QR plugin installation failed. Telegram remains installed; inspect the error before retrying.'
  }
}
$status = 'Đang khởi động Gateway và kiểm tra kết nối…'
Write-NativeInstallStatus $status
Invoke-OpenClaw gateway install --force --port $GatewayPort
if ($LASTEXITCODE -ne 0) { throw 'Isolated gateway service installation failed.' }
Invoke-OpenClaw gateway restart *> $null
if ($LASTEXITCODE -ne 0) { throw 'Gateway restart failed.' }
Invoke-OpenClaw --version
Invoke-OpenClaw gateway status --require-rpc
if ($LASTEXITCODE -ne 0) { throw 'Gateway status check failed.' }
Remove-Item -LiteralPath $installingMarkerPath -Force -ErrorAction SilentlyContinue
if ($zaloSelected) {
  Write-NativeInstallStatus 'Trợ lý đã sẵn sàng; /zaloqr và /zalostatus đã hoạt động.'
}
Write-NativeInstallStatus 'Đang hoàn tất kiểm tra trên máy…'
Write-Host "NATIVE INSTALL COMPLETE ($InstallMode): $root"
Write-Host "Dashboard: http://127.0.0.1:$GatewayPort/"
Write-Host "Manage this assistant: & '$root\openclaw-instance.ps1' gateway status"
