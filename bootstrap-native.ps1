[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$BundleUrl,
  [Parameter(Mandatory=$true)][string]$Sha256,
  [Parameter(Mandatory=$true)][string]$Name,
  [string]$OwnerIds = '',
  [string]$GroupId = '', [string]$AssistantName = 'Trợ lý OpenClaw', [string]$BaseUrl = 'https://provider.example/v1', [string]$Model = '',
  [string]$Profile = 'basic-assistant-full', [string[]]$Modules = @(), [switch]$FullBundle,
  [string]$QrOwnerId = '',
  [ValidateSet('auto','new','upgrade')][string]$InstallMode = 'auto',
  [string]$ExistingRoot = '',
  [int]$GatewayPort = 0,
  [string]$Audience = '', [string]$Addressing = '', [string]$Style = '',
  [switch]$DryRun,
  [switch]$UserInstall,
  [string]$SecretUrl = '',
  [string]$SecretToken = ''
)
$ErrorActionPreference='Stop'
$originalEnvironment = @{}
foreach ($variable in Get-ChildItem Env:) { if ($variable.Name -like 'OPENCLAW_*' -or $variable.Name -in @('Path','HOME')) { $originalEnvironment[$variable.Name] = $variable.Value } }
if (-not $UserInstall -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'This legacy system-service installation requires elevation. Use the web user-install flow for a new assistant.' }
$work = Join-Path $env:TEMP ("openclaw-native-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls $work /inheritance:r /grant:r "${currentUser}:(OI)(CI)(F)" '*S-1-5-18:(OI)(CI)(F)' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Cannot protect temporary installation files.' }
try {
  $archive = Join-Path $work 'native-full-bundle.tar.gz'
  Invoke-WebRequest -Uri $BundleUrl -OutFile $archive
  $actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $Sha256.ToLowerInvariant()) { throw "SHA256 mismatch: $actual" }
  tar -xzf $archive -C $work
  if ($LASTEXITCODE -ne 0) { throw 'Bundle extraction failed.' }
  $credentialFile = ''
  if ($SecretUrl -and -not $DryRun) {
    if (-not $SecretUrl.StartsWith('https://') -or $SecretToken -notmatch '^[A-Za-z0-9_-]{43}$') { throw 'Invalid private credential handoff.' }
    $credentialFile = Join-Path $work 'local-credentials.json'
    try {
      Invoke-WebRequest -UseBasicParsing -Method Post -Uri $SecretUrl -Headers @{ Authorization="Bearer $SecretToken" } -OutFile $credentialFile -ErrorAction Stop | Out-Null
    } catch { throw 'Cannot receive installation credentials. The one-time code may be expired or already used; create a new request on the web.' }
  }
  $installer = Join-Path $work 'install-native-windows.ps1'
  $installerArgs = @{ Name=$Name; OwnerIds=$OwnerIds; GroupId=$GroupId; AssistantName=$AssistantName; BaseUrl=$BaseUrl; Model=$Model; Profile=$Profile; Modules=$Modules; QrOwnerId=$QrOwnerId; FullBundle=$FullBundle; DryRun=$DryRun; Audience=$Audience; Addressing=$Addressing; Style=$Style; InstallMode=$InstallMode; ExistingRoot=$ExistingRoot; GatewayPort=$GatewayPort; UserInstall=$UserInstall; CredentialFile=$credentialFile }
  $global:LASTEXITCODE = 0
  & $installer @installerArgs
  if ($LASTEXITCODE -ne 0) { throw 'Native installer failed.' }
} finally {
  if (Test-Path $work) { Remove-Item $work -Recurse -Force }
  foreach ($variable in @(Get-ChildItem Env:)) { if (($variable.Name -like 'OPENCLAW_*' -or $variable.Name -eq 'HOME') -and -not $originalEnvironment.ContainsKey($variable.Name)) { Remove-Item "Env:$($variable.Name)" } }
  foreach ($key in $originalEnvironment.Keys) { Set-Item "Env:$key" $originalEnvironment[$key] }
}
