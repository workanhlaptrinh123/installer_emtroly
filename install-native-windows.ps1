[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Name,
  [string]$OwnerIds = '',
  [string]$GroupId = '',
  [string]$AssistantName = 'Trợ lý OpenClaw',
  [string]$BaseUrl = 'https://codex.anhlaptrinh.vn/v1',
  [string]$Model = 'gpt-6.1-sol',
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

function Write-NativeInstallStatus([string]$Text) {
  if ($env:MEMBER_INSTALL_STATUS_FILE) {
    [IO.File]::WriteAllText($env:MEMBER_INSTALL_STATUS_FILE, $Text, (New-Object Text.UTF8Encoding($false)))
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
if ($GroupId -notmatch '^-[1-9][0-9]*$') { throw 'GroupId must be an explicit negative Telegram group ID for the group allowlist.' }
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
if (Test-Path $root) { throw "Independent install already exists at $root. Choose Upgrade or another Name. No existing files were changed." }
$env:OPENCLAW_PROFILE = 'member-' + $Name
$env:OPENCLAW_STATE_DIR = $root
$env:OPENCLAW_ROOT = $root
$env:OPENCLAW_CONFIG_PATH = $configPath
$env:OPENCLAW_WORKSPACE_DIR = $workspace
foreach ($selector in @('OPENCLAW_GATEWAY_TOKEN','OPENCLAW_GATEWAY_PASSWORD','OPENCLAW_GATEWAY_PORT','OPENCLAW_SYSTEMD_UNIT','OPENCLAW_LAUNCHD_LABEL','OPENCLAW_WINDOWS_TASK_NAME','OPENCLAW_SERVICE_KIND','OPENCLAW_SERVICE_MARKER')) { Remove-Item "Env:$selector" -ErrorAction SilentlyContinue }
$occupied = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Select-Object -ExpandProperty LocalPort)
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
New-Item -ItemType Directory -Force -Path $root,$workspace,(Join-Path $workspace 'skills') | Out-Null
$status = 'Đang kiểm tra và cài Node.js, Python, FFmpeg nếu máy còn thiếu…'
Write-NativeInstallStatus $status
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls $root /inheritance:r /grant:r "${currentUser}:(OI)(CI)(F)" '*S-1-5-18:(OI)(CI)(F)' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Unable to protect the private instance directory.' }
if ($UserInstall) {
  . (Join-Path $PSScriptRoot 'native\user-dependencies.ps1')
  Initialize-UserDependencies
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  if (Get-Command winget -ErrorAction SilentlyContinue) { winget install --id OpenJS.NodeJS.LTS --exact --silent --accept-package-agreements --accept-source-agreements }
  else { throw 'Node.js is missing and winget is unavailable.' }
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
  if (Get-Command winget -ErrorAction SilentlyContinue) { winget install --id Python.Python.3.12 --exact --silent --accept-package-agreements --accept-source-agreements }
  else { throw 'Python is missing and winget is unavailable.' }
}
if (-not $UserInstall -and -not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  if (Get-Command winget -ErrorAction SilentlyContinue) { winget install --id Gyan.FFmpeg.Shared --exact --silent --accept-package-agreements --accept-source-agreements }
  else { Write-Warning 'FFmpeg is missing; media modules will need FFmpeg installed later.' }
}
$env:Path = $env:Path + ';' + [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { throw 'npm is unavailable after Node.js installation.' }
if (-not (Get-Command python.exe -ErrorAction SilentlyContinue)) { throw 'Python is unavailable. Reopen PowerShell as Administrator and retry.' }
$runtime = Join-Path $root ('runtime\' + $OpenClawVersion)
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
$status = 'Đang tải và cài OpenClaw ' + $OpenClawVersion + '. Bước này có thể mất vài phút…'
Write-NativeInstallStatus $status
$runtimePackage = @{ name='member-openclaw-runtime'; version='1.0.0'; private=$true; allowScripts=@{ '@google/genai'=$true; esbuild=$true; koffi=$true; openclaw=$true; protobufjs=$true; 'tree-sitter-bash'=$true } }
[IO.File]::WriteAllText((Join-Path $runtime 'package.json'), ($runtimePackage | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
$previousErrorAction = $ErrorActionPreference
try {
  $ErrorActionPreference = 'Continue'
  & npm.cmd install --prefix $runtime "openclaw@$OpenClawVersion"
  $npmExitCode = $LASTEXITCODE
} finally { $ErrorActionPreference = $previousErrorAction }
if ($npmExitCode -ne 0) { throw 'Private OpenClaw installation failed.' }
$bundledPostinstall = Join-Path $runtime 'node_modules\openclaw\scripts\postinstall-bundled-plugins.mjs'
if (-not (Test-Path -LiteralPath $bundledPostinstall)) { throw 'Bundled plugin installer was not found.' }
& node $bundledPostinstall
if ($LASTEXITCODE -ne 0) { throw 'Bundled OpenClaw plugin installation failed.' }
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
$account.groups[$targetGroup]=@{ groupPolicy='allowlist'; requireMention=$false; tools=@{ allow=@('*') }; toolsBySender=@{ '*'=@{ alsoAllow=@('exec','process') } } }
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
$status = 'Đang cài các kỹ năng Zalo và tiện ích QR…'
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
& python $ensure @ownerArgs
if ($LASTEXITCODE -ne 0) { throw 'Owner configuration failed.' }
& python $training --openclaw-root $root --workspace $workspace --apply --backup-dir $trainingBackup
if ($LASTEXITCODE -ne 0) { throw 'Owner training configuration failed.' }
& python (Join-Path $PSScriptRoot 'native\finalize_permissions.py') --config $configPath --owners ($owners -join ',')
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
Save-OpenClawInstanceLauncher -Root $root -InstanceProfile $env:OPENCLAW_PROFILE -CliEntry $cliEntry -Port $GatewayPort
if ($UserInstall) {
  Write-NativeInstallStatus 'Đang đăng ký lệnh openclaw vào PATH của tài khoản Windows…'
  Install-UserOpenClawCli -Root $root -CliEntry $cliEntry -Port $GatewayPort -Profile $env:OPENCLAW_PROFILE -ExpectedVersion $OpenClawVersion
  Install-UserGateway -Root $root -CliEntry $cliEntry -Port $GatewayPort
}
if ($zaloSelected) {
  Write-NativeInstallStatus 'Đang cài plugin Zalo và đăng ký /zaloqr, /zalostatus (chưa đăng nhập Zalo)…'
  $zaloOnboard = Join-Path $PSScriptRoot 'zalo\onboard-zalouser-windows.ps1'
  $zaloConfigure = Join-Path $PSScriptRoot 'zalo\configure-zalo.py'
  $zaloQr = Join-Path $workspace 'skills\openclaw-zalo-qr-login\scripts\send_zalo_qr_to_telegram_owner.mjs'
  & powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $zaloOnboard -Root $root -TelegramAccount $Name -OwnerId $QrOwnerId -ConfigureScript $zaloConfigure -QrScript $zaloQr -Quick -PreGateway
  if ($LASTEXITCODE -ne 0) { throw 'Windows Zalo QR plugin installation failed. Telegram remains installed; inspect the error before retrying.' }
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
if ($zaloSelected) {
  Write-NativeInstallStatus 'Trợ lý đã sẵn sàng; /zaloqr và /zalostatus đã hoạt động.'
}
Write-NativeInstallStatus 'Đang hoàn tất kiểm tra trên máy…'
Write-Host "NATIVE INSTALL COMPLETE ($InstallMode): $root"
Write-Host "Dashboard: http://127.0.0.1:$GatewayPort/"
Write-Host "Manage this assistant: & '$root\openclaw-instance.ps1' gateway status"
