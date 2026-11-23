function Install-EmTroLyWindows {
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
  $apiBase = if ($env:EMTROLY_BOOTSTRAP_API_BASE) {
    $env:EMTROLY_BOOTSTRAP_API_BASE.TrimEnd('/')
  } else {
    "https://api.github.com/repos/$repo/releases"
  }
  $apiUrl = if ($Version -eq 'latest') {
    "$apiBase/latest"
  } else {
    $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
    "$apiBase/tags/$tag"
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
  $shaRaw = (Invoke-WebRequest -UseBasicParsing -Uri $shaAsset[0].browser_download_url -Headers $headers -TimeoutSec 30).Content
  $shaText = if ($shaRaw -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($shaRaw) } else { [string]$shaRaw }
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
    Write-Host "==> Dang tai Em Tro Ly $($release.tag_name) (xac thuc SHA-256, khong dinh nhan SmartScreen trinh duyet)..." -ForegroundColor Cyan
    $tmpExe = "$targetExe.part"
    if (Test-Path -LiteralPath $tmpExe -PathType Leaf) { Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue }

    $req = [System.Net.HttpWebRequest]::Create([uri]$exeAsset[0].browser_download_url)
    $req.Method = 'GET'
    $req.AllowAutoRedirect = $true
    $req.UserAgent = 'AnhLapTrinh-EmTroLy-WindowsBootstrap/1.0'
    $req.Timeout = 600000
    $req.ReadWriteTimeout = 120000
    $resp = $req.GetResponse()
    try {
      $totalBytes = [long]$resp.ContentLength
      $inStream = $resp.GetResponseStream()
      try {
        $outStream = New-Object System.IO.FileStream($tmpExe, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 262144)
        try {
          $buf = New-Object byte[] 262144
          $readTotal = 0L
          $lastPrint = [Environment]::TickCount - 1000
          while (($n = $inStream.Read($buf, 0, $buf.Length)) -gt 0) {
            $outStream.Write($buf, 0, $n)
            $readTotal += $n
            $now = [Environment]::TickCount
            if (($now - $lastPrint) -ge 800 -and $totalBytes -gt 0) {
              $lastPrint = $now
              $pct = [int][Math]::Floor(($readTotal * 100.0) / $totalBytes)
              $mbDone = ($readTotal / 1MB).ToString('0.0')
              $mbAll = ($totalBytes / 1MB).ToString('0.0')
              Write-Host ("`r    Da tai: {0} / {1} MB ({2}%)   " -f $mbDone, $mbAll, $pct) -NoNewline -ForegroundColor Gray
            }
          }
          if ($totalBytes -gt 0) { Write-Host '' }
        } finally {
          $outStream.Dispose()
        }
      } finally {
        $inStream.Dispose()
      }
    } finally {
      $resp.Close()
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
}

if ($env:EMTROLY_BOOTSTRAP_NO_AUTORUN -ne '1') {
  Install-EmTroLyWindows @args
}
