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

function Invoke-FastDependencyDownload {
  param(
    [Parameter(Mandatory=$true)][string]$Uri,
    [Parameter(Mandatory=$true)][string]$OutFile,
    [int]$TimeoutSec = 300
  )
  $iwr = Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue
  if ($iwr -and $iwr.CommandType -eq 'Function') {
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile -TimeoutSec $TimeoutSec -ErrorAction Stop
    return
  }
  $client = New-Object System.Net.WebClient
  try {
    $client.Headers.Add('User-Agent', 'AnhLapTrinh-EmTroLy-Installer/1.0')
    $task = $client.DownloadFileTaskAsync([uri]$Uri, $OutFile)
    if (-not $task.Wait($TimeoutSec * 1000)) {
      $client.CancelAsync()
      throw 'Download timed out.'
    }
    if ($task.IsFaulted) { throw $task.Exception.InnerException }
  } finally {
    $client.Dispose()
  }
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
  $parallelDownloads = @{}
  if (-not $isMockedWeb) {
    $jobs = @()
    if ($needNodeDownload) {
      $jobs += @{ Key = 'node'; Uri = "https://nodejs.org/dist/v24.21.0/$archiveName"; Out = $nodeArchive; Timeout = 300 }
    }
    if ($needPythonDownload) {
      $jobs += @{ Key = 'python'; Uri = 'https://www.python.org/ftp/python/3.13.16/python-3.13.16-amd64.exe'; Out = $pythonInstaller; Timeout = 300 }
    }
    if ($needFfmpegDownload) {
      $jobs += @{ Key = 'ffmpeg'; Uri = 'https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip'; Out = $ffmpegArchive; Timeout = 900 }
    }
    if ($jobs.Count -ge 2) {
      $active = @()
      foreach ($job in $jobs) {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'AnhLapTrinh-EmTroLy-Installer/1.0')
        $t = $wc.DownloadFileTaskAsync([uri]$job.Uri, $job.Out)
        $active += [pscustomobject]@{ Key = $job.Key; Client = $wc; Task = $t; Out = $job.Out }
      }
      try {
        [void][System.Threading.Tasks.Task]::WaitAll(@($active | ForEach-Object { $_.Task }), 900000)
      } catch { }
      foreach ($item in $active) {
        $ok = ($item.Task.IsCompleted -and -not $item.Task.IsFaulted -and -not $item.Task.IsCanceled -and (Test-Path -LiteralPath $item.Out -PathType Leaf))
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
          Invoke-FastDependencyDownload -Uri $archiveUri -OutFile $nodeArchive -TimeoutSec 300
        }
        $sums = (Invoke-WebRequest -UseBasicParsing -Uri $checksumUri -TimeoutSec 60 -ErrorAction Stop).Content
      } catch { throw 'Node.js download failed.' }
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
        Invoke-FastDependencyDownload -Uri 'https://www.python.org/ftp/python/3.13.16/python-3.13.16-amd64.exe' -OutFile $pythonInstaller -TimeoutSec 300
      }
    } catch { throw 'Python download failed.' }
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
          Invoke-FastDependencyDownload -Uri 'https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip' -OutFile $ffmpegArchive -TimeoutSec 900
        }
      } catch { throw 'FFmpeg download failed.' }
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
