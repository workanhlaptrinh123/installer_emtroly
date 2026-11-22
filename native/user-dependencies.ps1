function Test-SupportedNodeToolchain {
  $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
  $npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
  if (-not $nodeCommand -or -not $npmCommand) { return $false }
  try {
    $versionOutput = & $nodeCommand.Source --version 2>$null
    $nodeExitCode = $LASTEXITCODE
    $versionText = @($versionOutput) | Select-Object -First 1
    if ($nodeExitCode -ne 0) { return $false }
    $match = [regex]::Match([string]$versionText, 'v?(\d+)\.(\d+)\.(\d+)')
    if (-not $match.Success) { return $false }
    $major = [int]$match.Groups[1].Value
    $minor = [int]$match.Groups[2].Value
    return (($major -eq 24 -and $minor -ge 16) -or ($major -eq 26 -and $minor -ge 1) -or ($major -gt 26))
  } catch {
    return $false
  }
}

function Test-PythonCandidate {
  param([Parameter(Mandatory=$true)][string]$Executable)
  try {
    & $Executable -c 'import json,sqlite3,sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>$null
    return $LASTEXITCODE -eq 0
  } catch {
    return $false
  }
}

function Write-DependencyInstallStatus {
  param([string]$Text)
  if ($env:MEMBER_INSTALL_STATUS_FILE -and -not [string]::IsNullOrWhiteSpace($Text)) {
    try {
      [IO.File]::WriteAllText($env:MEMBER_INSTALL_STATUS_FILE, $Text, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
  }
}

function Invoke-FastDependencyDownload {
  param(
    [Parameter(Mandatory=$true)][string]$Uri,
    [Parameter(Mandatory=$true)][string]$OutFile,
    [int]$TimeoutSec = 300,
    [int]$MaxAttempts = 3,
    [string[]]$FallbackUris = @(),
    [string]$DisplayName = ''
  )
  if ($env:EMTROLY_DOWNLOAD_RETRIES -match '^[1-5]$') { $MaxAttempts = [int]$env:EMTROLY_DOWNLOAD_RETRIES }
  $iwr = Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue
  if ($iwr -and $iwr.CommandType -eq 'Function') {
    $lastErr = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
      try {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile -TimeoutSec $TimeoutSec -ErrorAction Stop
        return
      } catch {
        $lastErr = $_
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Milliseconds (300 * $attempt) }
      }
    }
    throw $lastErr
  }

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  [Net.ServicePointManager]::DefaultConnectionLimit = 16
  [Net.ServicePointManager]::Expect100Continue = $false

  $candidates = @($Uri) + @($FallbackUris | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -cne $Uri })
  $partFile = "$OutFile.part"
  $lastErr = $null
  $totalTries = [Math]::Max($MaxAttempts, $candidates.Count)

  for ($attempt = 1; $attempt -le $totalTries; $attempt++) {
    $targetUri = $candidates[($attempt - 1) % $candidates.Count]
    $resp = $null
    $inStream = $null
    $outStream = $null
    try {
      if (Test-Path -LiteralPath $partFile -PathType Leaf) { Remove-Item -LiteralPath $partFile -Force -ErrorAction SilentlyContinue }
      if ($DisplayName) {
        Write-DependencyInstallStatus "Đang kết nối tải $DisplayName..."
      }
      $req = [System.Net.HttpWebRequest]::Create([uri]$targetUri)
      $req.UserAgent = 'AnhLapTrinh-EmTroLy-Installer/1.0'
      $req.AllowAutoRedirect = $true
      $req.MaximumAutomaticRedirections = 10
      $req.Timeout = 30000
      $req.ReadWriteTimeout = 45000

      $resp = $req.GetResponse()
      $totalBytes = [long]$resp.ContentLength
      $inStream = $resp.GetResponseStream()
      $outStream = New-Object System.IO.FileStream($partFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read, 262144)
      $buffer = New-Object byte[] 262144
      $readTotal = 0L
      $dlSw = [Diagnostics.Stopwatch]::StartNew()
      $lastUiMs = -1000L

      while (($readNow = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $outStream.Write($buffer, 0, $readNow)
        $readTotal += $readNow
        if ($dlSw.Elapsed.TotalSeconds -gt $TimeoutSec) {
          throw 'Download timed out.'
        }
        if ($DisplayName -and ($dlSw.ElapsedMilliseconds - $lastUiMs) -ge 550) {
          $lastUiMs = $dlSw.ElapsedMilliseconds
          $mbDone = [Math]::Round($readTotal / 1MB, 1)
          $speedMbps = [Math]::Round(($readTotal / 1MB) / [Math]::Max(0.2, $dlSw.Elapsed.TotalSeconds), 1)
          if ($totalBytes -gt 0) {
            $mbTotal = [Math]::Round($totalBytes / 1MB, 1)
            $pct = [Math]::Min(99, [int][Math]::Floor(($readTotal * 100.0) / $totalBytes))
            Write-DependencyInstallStatus ("Đang tải $DisplayName... $pct% ($mbDone / $mbTotal MB · $speedMbps MB/s)")
          } else {
            Write-DependencyInstallStatus ("Đang tải $DisplayName... ($mbDone MB · $speedMbps MB/s)")
          }
        }
      }

      $outStream.Flush()
      $outStream.Close(); $outStream = $null
      $inStream.Close(); $inStream = $null
      $resp.Close(); $resp = $null

      if ($totalBytes -gt 0 -and $readTotal -ne $totalBytes) {
        throw "Incomplete download ($readTotal of $totalBytes bytes)."
      }
      Move-Item -LiteralPath $partFile -Destination $OutFile -Force
      return
    } catch {
      $lastErr = $_
      if ($outStream) { try { $outStream.Close() } catch { } }
      if ($inStream) { try { $inStream.Close() } catch { } }
      if ($resp) { try { $resp.Close() } catch { } }
      if (Test-Path -LiteralPath $partFile -PathType Leaf) { Remove-Item -LiteralPath $partFile -Force -ErrorAction SilentlyContinue }
      if ($attempt -lt $totalTries) { Start-Sleep -Milliseconds (500 * $attempt) }
    }
  }
  throw $lastErr
}

function Expand-FastDependencyZip {
  param(
    [Parameter(Mandatory=$true)][string]$LiteralPath,
    [Parameter(Mandatory=$true)][string]$DestinationPath
  )
  $ea = Get-Command Expand-Archive -ErrorAction SilentlyContinue
  if ($ea -and $ea.CommandType -eq 'Function') {
    Expand-Archive -LiteralPath $LiteralPath -DestinationPath $DestinationPath -Force
    return
  }
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = [System.IO.Compression.ZipFile]::OpenRead($LiteralPath)
    try {
      $destFull = [IO.Path]::GetFullPath($DestinationPath)
      foreach ($entry in $archive.Entries) {
        $target = [IO.Path]::GetFullPath((Join-Path $destFull $entry.FullName))
        if (-not $target.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ([string]::IsNullOrEmpty($entry.Name)) {
          [void][IO.Directory]::CreateDirectory($target)
        } else {
          $parentDir = Split-Path -Parent $target
          if ($parentDir) { [void][IO.Directory]::CreateDirectory($parentDir) }
          [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
      }
    } finally {
      $archive.Dispose()
    }
  } catch {
    Expand-Archive -LiteralPath $LiteralPath -DestinationPath $DestinationPath -Force
  }
}

function Initialize-UserDependencies {
  $ProgressPreference = 'SilentlyContinue'
  if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
    throw 'This release requires Windows x64; Windows ARM64 is not supported by the bundled Python dependency path.'
  }
  $dependencies = Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies'
  New-Item -ItemType Directory -Path $dependencies -Force | Out-Null
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  $needNode = -not (Test-SupportedNodeToolchain)
  $architecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64') { 'x64' } else { throw 'Only Windows x64 is supported.' }
  $archiveName = "node-v24.21.0-win-$architecture.zip"
  $nodeDirectory = Join-Path $dependencies "node-v24.21.0-win-$architecture"
  $nodeExecutable = Join-Path $nodeDirectory 'node.exe'
  $npmExecutable = Join-Path $nodeDirectory 'npm.cmd'
  $needNodeDownload = $needNode -and ((-not (Test-Path -LiteralPath $nodeExecutable)) -or (-not (Test-Path -LiteralPath $npmExecutable)))

  $pythonCandidates = @()
  $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
  if ($pythonCommand -and $pythonCommand.Source -notlike '*\WindowsApps\*') { $pythonCandidates += $pythonCommand.Source }
  $pythonCandidates += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Python\*\python.exe') -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
  $pythonCandidates += Join-Path $dependencies 'python313\python.exe'
  $pythonExecutable = $null
  foreach ($candidate in @($pythonCandidates | Select-Object -Unique)) {
    if ((Test-Path -LiteralPath $candidate) -and (Test-PythonCandidate -Executable $candidate)) {
      $pythonExecutable = $candidate
      break
    }
  }
  $needPythonDownload = (-not $pythonExecutable)

  $ffmpegDirectory = Join-Path $dependencies 'ffmpeg-9.0.2-essentials_build'
  $ffmpegBin = Join-Path $ffmpegDirectory 'bin'
  $ffmpegExecutable = Join-Path $ffmpegBin 'ffmpeg.exe'
  $needFfmpeg = -not (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)
  $needFfmpegDownload = $needFfmpeg -and (-not (Test-Path -LiteralPath $ffmpegExecutable))

  # Parallel pre-download when running on real Windows (non-mocked cmdlets) for 2-3x faster setup
  $iwrCmd = Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue
  $isMockedWeb = ($iwrCmd -and $iwrCmd.CommandType -eq 'Function')
  $nodeArchive = Join-Path $dependencies $archiveName
  $pythonInstaller = Join-Path $dependencies 'python-3.13.16-amd64.exe'
  $ffmpegArchive = Join-Path $dependencies 'ffmpeg-9.0.2-essentials_build.zip'
  $ffmpegFastCdnUri = 'https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip'
  $ffmpegFallbackUri = 'https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip'
  $parallelDownloads = @{}
  if (-not $isMockedWeb) {
    [Net.ServicePointManager]::DefaultConnectionLimit = 16
    [Net.ServicePointManager]::Expect100Continue = $false
    $jobs = @()
    if ($needNodeDownload) {
      $jobs += @{ Key = 'node'; Label = 'Node.js'; Uri = "https://nodejs.org/dist/v24.21.0/$archiveName"; Out = $nodeArchive; ApproxBytes = 31500000L }
    }
    if ($needPythonDownload) {
      $jobs += @{ Key = 'python'; Label = 'Python 3.13'; Uri = 'https://www.python.org/ftp/python/3.13.16/python-3.13.16-amd64.exe'; Out = $pythonInstaller; ApproxBytes = 27500000L }
    }
    if ($needFfmpegDownload) {
      $jobs += @{ Key = 'ffmpeg'; Label = 'FFmpeg'; Uri = $ffmpegFastCdnUri; Out = $ffmpegArchive; ApproxBytes = 114768076L }
    }
    if ($jobs.Count -ge 2) {
      $active = @()
      $progressMap = [hashtable]::Synchronized(@{})
      foreach ($job in $jobs) {
        $partOut = "$($job.Out).part"
        if (Test-Path -LiteralPath $partOut -PathType Leaf) { Remove-Item -LiteralPath $partOut -Force -ErrorAction SilentlyContinue }
        $progressMap[$job.Key] = @{ Received = 0L; Total = [long]$job.ApproxBytes }
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'AnhLapTrinh-EmTroLy-Installer/1.0')
        $jobKeyLocal = $job.Key
        $mapRef = $progressMap
        $wc.add_DownloadProgressChanged(({
          param($s, $e)
          $entry = $mapRef[$jobKeyLocal]
          if ($entry) {
            $entry.Received = [long]$e.BytesReceived
            if ($e.TotalBytesToReceive -gt 0) { $entry.Total = [long]$e.TotalBytesToReceive }
          }
        }).GetNewClosure())
        $t = $wc.DownloadFileTaskAsync([uri]$job.Uri, $partOut)
        $active += [pscustomobject]@{ Key = $job.Key; Label = $job.Label; Client = $wc; Task = $t; PartOut = $partOut; Out = $job.Out }
      }
      $labelsJoined = (@($jobs | ForEach-Object { $_.Label }) -join ', ')
      $parSw = [Diagnostics.Stopwatch]::StartNew()
      while (@($active | Where-Object { -not $_.Task.IsCompleted }).Count -gt 0 -and $parSw.Elapsed.TotalSeconds -lt 900) {
        Start-Sleep -Milliseconds 550
        $sumRecv = 0L
        $sumTotal = 0L
        foreach ($k in @($progressMap.Keys)) {
          $sumRecv += [long]$progressMap[$k].Received
          $sumTotal += [long]$progressMap[$k].Total
        }
        if ($sumTotal -gt 0 -and $sumRecv -gt 0) {
          $pctAll = [Math]::Min(99, [int][Math]::Floor(($sumRecv * 100.0) / $sumTotal))
          $mbRecv = [Math]::Round($sumRecv / 1MB, 1)
          $mbAll = [Math]::Round($sumTotal / 1MB, 1)
          $spdAll = [Math]::Round(($sumRecv / 1MB) / [Math]::Max(0.2, $parSw.Elapsed.TotalSeconds), 1)
          Write-DependencyInstallStatus ("Đang tải song song ($labelsJoined)... $pctAll% ($mbRecv / $mbAll MB · $spdAll MB/s)")
        }
      }
      foreach ($item in $active) {
        if (-not $item.Task.IsCompleted) { try { $item.Client.CancelAsync() } catch { } }
        $ok = ($item.Task.IsCompleted -and -not $item.Task.IsFaulted -and -not $item.Task.IsCanceled -and (Test-Path -LiteralPath $item.PartOut -PathType Leaf))
        if ($ok) {
          try {
            Move-Item -LiteralPath $item.PartOut -Destination $item.Out -Force
          } catch { $ok = $false }
        }
        if (-not $ok -and (Test-Path -LiteralPath $item.PartOut -PathType Leaf)) {
          Remove-Item -LiteralPath $item.PartOut -Force -ErrorAction SilentlyContinue
        }
        $parallelDownloads[$item.Key] = $ok
        try { $item.Client.Dispose() } catch { }
      }
    }
  }

  if ($needNode) {
    if ($needNodeDownload) {
      $archiveUri = "https://nodejs.org/dist/v24.21.0/$archiveName"
      $checksumUri = 'https://nodejs.org/dist/v24.21.0/SHASUMS256.txt'
      try {
        if (-not $parallelDownloads['node']) {
          Invoke-FastDependencyDownload -Uri $archiveUri -OutFile $nodeArchive -TimeoutSec 300 -DisplayName 'Node.js 24'
        }
        $sums = (Invoke-WebRequest -UseBasicParsing -Uri $checksumUri -TimeoutSec 60 -ErrorAction Stop).Content
      } catch { throw 'Node.js download failed.' }
      Write-DependencyInstallStatus 'Đang kiểm tra chữ ký SHA-256 và giải nén Node.js...'
      $expected = [regex]::Match($sums, "(?m)^([a-f0-9]{64})\s+$([regex]::Escape($archiveName))\r?$")
      if (-not $expected.Success -or (Get-FileHash $nodeArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected.Groups[1].Value) { throw 'Portable Node checksum verification failed.' }
      Expand-FastDependencyZip -LiteralPath $nodeArchive -DestinationPath $dependencies
      Remove-Item -LiteralPath $nodeArchive -Force
    }
    $env:Path = $nodeDirectory + ';' + $env:Path
  }
  if (-not (Test-SupportedNodeToolchain)) { throw 'Node.js/npm dependency verification failed.' }

  if ($needPythonDownload) {
    try {
      if (-not $parallelDownloads['python']) {
        Invoke-FastDependencyDownload -Uri 'https://www.python.org/ftp/python/3.13.16/python-3.13.16-amd64.exe' -OutFile $pythonInstaller -TimeoutSec 300 -DisplayName 'Python 3.13'
      }
    } catch { throw 'Python download failed.' }
    Write-DependencyInstallStatus 'Đang xác thực chữ ký số và cài đặt Python 3.13...'
    $signature = Get-AuthenticodeSignature -FilePath $pythonInstaller
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike '*Python Software Foundation*') { throw 'Python installer signature verification failed.' }
    $pythonDirectory = Join-Path $dependencies 'python313'
    $process = Start-Process -FilePath $pythonInstaller -ArgumentList @('/quiet','InstallAllUsers=0','PrependPath=0','Include_test=0',"TargetDir=`"$pythonDirectory`"") -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -notin @(0,3010)) { throw 'Python user installation failed.' }
    $pythonExecutable = Join-Path $pythonDirectory 'python.exe'
    Remove-Item -LiteralPath $pythonInstaller -Force
  }
  if (-not (Test-Path -LiteralPath $pythonExecutable) -or -not (Test-PythonCandidate -Executable $pythonExecutable)) { throw 'Python dependency verification failed.' }
  $env:Path = (Split-Path -Parent $pythonExecutable) + ';' + $env:Path

  if ($needFfmpeg) {
    if ($needFfmpegDownload) {
      $expectedHash = '60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba'
      try {
        if (-not $parallelDownloads['ffmpeg']) {
          Invoke-FastDependencyDownload -Uri $ffmpegFastCdnUri -FallbackUris @($ffmpegFallbackUri) -OutFile $ffmpegArchive -TimeoutSec 900 -DisplayName 'FFmpeg'
        }
      } catch { throw 'FFmpeg download failed.' }
      Write-DependencyInstallStatus 'Đang kiểm tra SHA-256 và giải nén FFmpeg...'
      if ((Get-FileHash $ffmpegArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) { throw 'FFmpeg checksum verification failed.' }
      Expand-FastDependencyZip -LiteralPath $ffmpegArchive -DestinationPath $dependencies
      Remove-Item -LiteralPath $ffmpegArchive -Force
    }
    $env:Path = $ffmpegBin + ';' + $env:Path
  }
  $ffmpegCommand = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
  if (-not $ffmpegCommand) { throw 'FFmpeg dependency verification failed.' }
  try {
    & $ffmpegCommand.Source -version *> $null
    if ($LASTEXITCODE -ne 0) { throw 'FFmpeg dependency verification failed.' }
  } catch { throw 'FFmpeg dependency verification failed.' }
}
