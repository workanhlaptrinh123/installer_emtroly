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

function Initialize-UserDependencies {
  if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
    throw 'This release requires Windows x64; Windows ARM64 is not supported by the bundled Python dependency path.'
  }
  $dependencies = Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies'
  New-Item -ItemType Directory -Path $dependencies -Force | Out-Null
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  if (-not (Test-SupportedNodeToolchain)) {
    $architecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64') { 'x64' } else { throw 'Only Windows x64 is supported.' }
    $archiveName = "node-v24.21.0-win-$architecture.zip"
    $nodeDirectory = Join-Path $dependencies "node-v24.21.0-win-$architecture"
    $nodeExecutable = Join-Path $nodeDirectory 'node.exe'
    $npmExecutable = Join-Path $nodeDirectory 'npm.cmd'
    if (-not (Test-Path -LiteralPath $nodeExecutable) -or -not (Test-Path -LiteralPath $npmExecutable)) {
      $archive = Join-Path $dependencies $archiveName
      $archiveUri = "https://nodejs.org/dist/v24.21.0/$archiveName"
      $checksumUri = 'https://nodejs.org/dist/v24.21.0/SHASUMS256.txt'
      try {
        Invoke-WebRequest -UseBasicParsing -Uri $archiveUri -OutFile $archive -TimeoutSec 300 -ErrorAction Stop
        $sums = (Invoke-WebRequest -UseBasicParsing -Uri $checksumUri -TimeoutSec 60 -ErrorAction Stop).Content
      } catch { throw 'Node.js download failed.' }
      $expected = [regex]::Match($sums, "(?m)^([a-f0-9]{64})\s+$([regex]::Escape($archiveName))\r?$")
      if (-not $expected.Success -or (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected.Groups[1].Value) { throw 'Portable Node checksum verification failed.' }
      Expand-Archive -LiteralPath $archive -DestinationPath $dependencies -Force
      Remove-Item -LiteralPath $archive -Force
    }
    $env:Path = $nodeDirectory + ';' + $env:Path
  }
  if (-not (Test-SupportedNodeToolchain)) { throw 'Node.js/npm dependency verification failed.' }

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
  if (-not $pythonExecutable) {
    $installer = Join-Path $dependencies 'python-3.13.16-amd64.exe'
    try {
      Invoke-WebRequest -UseBasicParsing -Uri 'https://www.python.org/ftp/python/3.13.16/python-3.13.16-amd64.exe' -OutFile $installer -TimeoutSec 300 -ErrorAction Stop
    } catch { throw 'Python download failed.' }
    $signature = Get-AuthenticodeSignature -FilePath $installer
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike '*Python Software Foundation*') { throw 'Python installer signature verification failed.' }
    $pythonDirectory = Join-Path $dependencies 'python313'
    $process = Start-Process -FilePath $installer -ArgumentList @('/quiet','InstallAllUsers=0','PrependPath=0','Include_test=0',"TargetDir=`"$pythonDirectory`"") -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -notin @(0,3010)) { throw 'Python user installation failed.' }
    $pythonExecutable = Join-Path $pythonDirectory 'python.exe'
    Remove-Item -LiteralPath $installer -Force
  }
  if (-not (Test-Path -LiteralPath $pythonExecutable) -or -not (Test-PythonCandidate -Executable $pythonExecutable)) { throw 'Python dependency verification failed.' }
  $env:Path = (Split-Path -Parent $pythonExecutable) + ';' + $env:Path

  if (-not (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) {
    $ffmpegDirectory = Join-Path $dependencies 'ffmpeg-9.0.2-essentials_build'
    $ffmpegBin = Join-Path $ffmpegDirectory 'bin'
    $ffmpegExecutable = Join-Path $ffmpegBin 'ffmpeg.exe'
    if (-not (Test-Path -LiteralPath $ffmpegExecutable)) {
      $archive = Join-Path $dependencies 'ffmpeg-9.0.2-essentials_build.zip'
      $expectedHash = '60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba'
      try {
        Invoke-WebRequest -UseBasicParsing -Uri 'https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip' -OutFile $archive -TimeoutSec 900 -ErrorAction Stop
      } catch { throw 'FFmpeg download failed.' }
      if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) { throw 'FFmpeg checksum verification failed.' }
      Expand-Archive -LiteralPath $archive -DestinationPath $dependencies -Force
      Remove-Item -LiteralPath $archive -Force
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
