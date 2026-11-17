[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Name,
  [Parameter(Mandatory=$true)][string]$TelegramToken,
  [Parameter(Mandatory=$true)][string]$ProviderApiKey,
  [Parameter(Mandatory=$true)][string]$BaseUrl,
  [Parameter(Mandatory=$true)][string]$Model,
  [Parameter(Mandatory=$true)][string]$OwnerIds,
  [string]$GroupId = '',
  [string]$AssistantName = 'Trợ lý OpenClaw',
  [int]$SshPort = 2222,
  [int]$WebPort = 3025,
  [string]$ReleaseDir = $PSScriptRoot,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$image = 'member-vps-golden:20261116'
$container = "user-$Name"
$data = Join-Path $ReleaseDir "customers/$Name/root"
function Docker([string[]]$Args) { & docker @Args; if ($LASTEXITCODE -ne 0) { throw 'Docker command failed.' } }
if ($Name -notmatch '^[a-z][a-z0-9_-]{0,63}$') { throw 'Invalid Name.' }
if (-not (Test-Path (Join-Path $ReleaseDir 'golden-image.tar.gz'))) { throw 'Missing golden-image.tar.gz.' }
& docker info *> $null; if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop is not ready.' }
& docker container inspect $container *> $null; if ($LASTEXITCODE -eq 0) { throw "Container $container already exists." }
if ($DryRun) { Write-Host "DRY-RUN: would create $container from $image with baked-in modules."; exit 0 }
& docker image inspect $image *> $null
if ($LASTEXITCODE -ne 0) { Docker @('load','--input',(Join-Path $ReleaseDir 'golden-image.tar.gz')) }
New-Item -ItemType Directory -Force -Path (Split-Path $data) | Out-Null
New-Item -ItemType Directory -Force -Path $data | Out-Null
$settings = @{ member=$Name; assistant_name=$AssistantName; owner_ids=($OwnerIds -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }); group_id=$GroupId; telegram_token=$TelegramToken; base_url=$BaseUrl; api_key=$ProviderApiKey; api='openai-completions'; model=$Model } | ConvertTo-Json -Depth 5
$settings | & docker run --rm -i --entrypoint bash -v "${ReleaseDir}:/release:ro" -v "${data}:/data" $image -lc 'cat >/tmp/settings.json; python3 /release/configure.py --settings /tmp/settings.json --root /data/.openclaw --runtime-root /root --workspace-dir /data/.openclaw/workspace; chmod 700 /data/.openclaw; rm -f /tmp/settings.json'
Docker @('run','-d','--name',$container,'--hostname',$Name,'--cpus','2','--memory','4g','--restart','unless-stopped','-p',"${SshPort}:22",'-p',"${WebPort}:80",'--mount',"type=bind,source=$data,target=/root",$image)
Docker @('exec',$container,'openclaw','config','validate')
Write-Host "INSTALL COMPLETE: $container | SSH $SshPort | Web $WebPort"
