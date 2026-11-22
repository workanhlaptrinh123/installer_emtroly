[CmdletBinding()]
param(
  [string]$Version = 'latest',
  [switch]$DownloadOnly,
  [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($env:OS -ne 'Windows_NT' -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
  throw 'Bo cai Em Tro Ly tren Windows yeu cau Windows 10/11 64-bit (x64).'
}

$repo = 'workanhlaptrinh123/installer_emtroly'
$apiUrl = if ($Version -eq 'latest') {
  "https://api.github.com/repos/$repo/releases/latest"
} else {
  $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
  "https://api.github.com/repos/$repo/releases/tags/$tag"
}

Write-Host '==> Dang kiem tra phien ban moi nhat cua Em Tro Ly tren GitHub...' -ForegroundColor Cyan
$headers = @{ 'User-Agent' = 'AnhLapTrinh-EmTroLy-WindowsBootstrap/1.0'; 'Accept' = 'application/vnd.github+json' }
$release = Invoke-RestMethod -UseBasicParsing -Uri $apiUrl -Headers $headers -TimeoutSec 30

$exeAsset = @($release.assets | Where-Object { $_.name -eq 'emtroly.exe' } | Select-Object -First 1)
$shaAsset = @($release.assets | Where-Object { $_.name -eq 'emtroly.exe.sha256' } | Select-Object -First 1)
if ($exeAsset.Count -eq 0 -or $shaAsset.Count -eq 0) {
  throw "Khong tim thay emtroly.exe tren phien ban $($release.tag_name). Vui long doi GitHub Actions dong goi xong roi thu lai."
}

$workDir = if ($OutFile) {
  Split-Path -Parent ([IO.Path]::GetFullPath($OutFile))
} else {
  Join-Path $env:LOCALAPPDATA 'AnhLapTrinh\EmTroLy\bootstrap'
}
[void][IO.Directory]::CreateDirectory($workDir)
$targetExe = if ($OutFile) { [IO.Path]::GetFullPath($OutFile) } else { Join-Path $workDir "emtroly-$($release.tag_name).exe" }
$shaText = (Invoke-RestMethod -UseBasicParsing -Uri $shaAsset[0].browser_download_url -Headers $headers -TimeoutSec 30) | Out-String
$shaMatch = [regex]::Match($shaText, '(?i)\b([a-f0-9]{64})\b')
if (-not $shaMatch.Success) {
  throw 'Khong doc duoc ma kiem tra SHA-256 chinh thuc tu GitHub Release.'
}
$expectedHash = $shaMatch.Groups[1].Value.ToLowerInvariant()

$needDownload = $true
if (Test-Path -LiteralPath $targetExe -PathType Leaf) {
  if ((Get-FileHash -LiteralPath $targetExe -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedHash) {
    $needDownload = $false
  }
}

if ($needDownload) {
  Write-Host "==> Dang tai Em Tro Ly $($release.tag_name) (xac thuc SHA-256, khong dinh nhan trinh duyet SmartScreen)..." -ForegroundColor Cyan
  $tmpExe = "$targetExe.part"
  if (Test-Path -LiteralPath $tmpExe -PathType Leaf) { Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue }

  Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromMinutes(10)
  $client.DefaultRequestHeaders.UserAgent.ParseAdd('AnhLapTrinh-EmTroLy-WindowsBootstrap/1.0')
  try {
    $resp = $client.GetAsync([uri]$exeAsset[0].browser_download_url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    [void]$resp.EnsureSuccessStatusCode()
    $inStream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $outStream = New-Object System.IO.FileStream($tmpExe, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 262144)
    try {
      $inStream.CopyTo($outStream)
    } finally {
      $outStream.Dispose()
      $inStream.Dispose()
    }
  } finally {
    $client.Dispose()
  }

  $actualHash = (Get-FileHash -LiteralPath $tmpExe -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne $expectedHash) {
    Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue
    throw "Ma SHA-256 khong khop (mong doi: $expectedHash, nhan duoc: $actualHash). Da huy de bao ve may."
  }
  Move-Item -LiteralPath $tmpExe -Destination $targetExe -Force
}

try { Unblock-File -LiteralPath $targetExe -ErrorAction SilentlyContinue } catch { }
Write-Host "==> Da xac minh SHA-256 an toan ($expectedHash)." -ForegroundColor Green

if ($DownloadOnly) {
  Write-Host "==> Da luu tai: $targetExe" -ForegroundColor Green
  return
}

Write-Host '==> Dang khoi dong giao dien Em Tro Ly...' -ForegroundColor Green
Start-Process -FilePath $targetExe
