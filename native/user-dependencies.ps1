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

function Optimize-UserDependencyPath {
  $gcCmd = Get-Command Get-Command -ErrorAction SilentlyContinue
  if ($gcCmd -and $gcCmd.CommandType -eq 'Function') { return }
  $priorityDirs = New-Object System.Collections.Generic.List[string]
  $depBase = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies' } else { '' }
  if ($depBase -and (Test-Path -LiteralPath $depBase -PathType Container)) {
    foreach ($d in @(Get-ChildItem -LiteralPath $depBase -Directory -ErrorAction SilentlyContinue)) {
      if ($d.Name -like 'node-v*' -or $d.Name -like 'python*') { [void]$priorityDirs.Add($d.FullName) }
      elseif ($d.Name -like 'ffmpeg-*') {
        $fb = Join-Path $d.FullName 'bin'
        if (Test-Path -LiteralPath $fb -PathType Container) { [void]$priorityDirs.Add($fb) }
      }
    }
  }
  foreach ($cand in @(
    $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'nodejs' }),
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\nodejs' })
  )) {
    if ($cand -and (Test-Path -LiteralPath $cand -PathType Container)) { [void]$priorityDirs.Add($cand) }
  }
  foreach ($pyRoot in @(
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\Python' }),
    $env:ProgramFiles
  )) {
    if ($pyRoot -and (Test-Path -LiteralPath $pyRoot -PathType Container)) {
      foreach ($pd in @(Get-ChildItem -LiteralPath $pyRoot -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        if (Test-Path -LiteralPath (Join-Path $pd.FullName 'python.exe') -PathType Leaf) {
          [void]$priorityDirs.Add($pd.FullName)
        }
      }
    }
  }

  $rawEntries = @()
  $rawEntries += @($priorityDirs)
  if ($env:OS -eq 'Windows_NT') {
    $uPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $mPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($uPath) { $rawEntries += ($uPath -split ';') }
    if ($env:Path) { $rawEntries += ($env:Path -split ';') }
    if ($mPath) { $rawEntries += ($mPath -split ';') }
  } elseif ($env:Path) {
    $rawEntries += ($env:Path -split [IO.Path]::PathSeparator)
  }

  $normalDirs = New-Object System.Collections.Generic.List[string]
  $winAppsDirs = New-Object System.Collections.Generic.List[string]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in $rawEntries) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    $clean = $entry.Trim().Trim('"').TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($clean) -or (-not $seen.Add($clean))) { continue }
    if ($clean -like '*\WindowsApps*') {
      [void]$winAppsDirs.Add($entry.Trim())
    } else {
      [void]$normalDirs.Add($entry.Trim())
    }
  }
  $sep = if ($env:OS -eq 'Windows_NT') { ';' } else { [string][IO.Path]::PathSeparator }
  $env:Path = (@($normalDirs) + @($winAppsDirs)) -join $sep
}

function Test-PythonCandidate {
  param([Parameter(Mandatory=$true)][string]$Executable)
  if ($Executable -like '*\WindowsApps\*') { return $false }
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
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    for ($attempt = 1; $attempt -le 8; $attempt++) {
      $fs = $null
      try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $fs = New-Object System.IO.FileStream($env:MEMBER_INSTALL_STATUS_FILE, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, $share)
        $fs.SetLength(0)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
        break
      } catch {
        if ($attempt -lt 8) { Start-Sleep -Milliseconds 20 }
      } finally {
        if ($null -ne $fs) { try { $fs.Dispose() } catch { } }
      }
    }
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
  foreach ($stalePart in @(Get-ChildItem -LiteralPath $dependencies -Filter '*.part' -File -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath $stalePart.FullName -Force -ErrorAction SilentlyContinue
  }
  Optimize-UserDependencyPath
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  $needNode = -not (Test-SupportedNodeToolchain)
  $architecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64') { 'x64' } else { throw 'Only Windows x64 is supported.' }
  $archiveName = "node-v24.21.0-win-$architecture.zip"
  $nodeDirectory = Join-Path $dependencies "node-v24.21.0-win-$architecture"
  $nodeExecutable = Join-Path $nodeDirectory 'node.exe'
  $npmExecutable = Join-Path $nodeDirectory 'npm.cmd'
  $needNodeDownload = $needNode -and ((-not (Test-Path -LiteralPath $nodeExecutable)) -or (-not (Test-Path -LiteralPath $npmExecutable)))

  $pythonCandidates = @()
  $gcMeta = Get-Command Get-Command -ErrorAction SilentlyContinue
  $isMockedGetCmd = ($gcMeta -and $gcMeta.CommandType -eq 'Function')
  if ($isMockedGetCmd) {
    $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($pythonCommand -and $pythonCommand.Source -notlike '*\WindowsApps\*') { $pythonCandidates += $pythonCommand.Source }
  } else {
    foreach ($pyCmd in @(Get-Command python.exe -All -ErrorAction SilentlyContinue)) {
      if ($pyCmd.Source -and $pyCmd.Source -notlike '*\WindowsApps\*') { $pythonCandidates += $pyCmd.Source }
    }
  }
  $pythonCandidates += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Python\*\python.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
  if ($env:ProgramFiles) {
    $pythonCandidates += @(Get-ChildItem (Join-Path $env:ProgramFiles 'Python*\python.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
  }
  $pythonCandidates += Join-Path $dependencies 'python313\python.exe'
  $pythonCandidates += Join-Path $dependencies 'python312\python.exe'
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
      $labelsJoined = (@($jobs | ForEach-Object { $_.Label }) -join ', ')
      Write-DependencyInstallStatus ("Đang tải và cài đặt tự động ($labelsJoined)... 0% (đang kết nối máy chủ)")
      $workerScript = {
        param([string]$Uri, [string]$PartOut, [string]$Key, [hashtable]$ProgressMap)
        try {
          try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
          } catch { }
          try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13
          } catch { }
          [Net.ServicePointManager]::DefaultConnectionLimit = 16
          [Net.ServicePointManager]::Expect100Continue = $false
          $webReq = [System.Net.WebRequest]::Create($Uri)
          $webReq.Timeout = 25000
          if ($webReq -is [System.Net.HttpWebRequest]) {
            $webReq.Method = 'GET'
            $webReq.AllowAutoRedirect = $true
            $webReq.MaximumAutomaticRedirections = 10
            $webReq.ReadWriteTimeout = 45000
            $webReq.UserAgent = 'AnhLapTrinh-EmTroLy-Installer/1.0'
          }
          $resp = $webReq.GetResponse()
          try {
            $total = [long]$resp.ContentLength
            $entry = $ProgressMap[$Key]
            if ($entry -and $total -gt 0) { $entry.Total = $total }
            $inStream = $resp.GetResponseStream()
            try {
              $outStream = [System.IO.File]::Open($PartOut, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
              try {
                $buffer = New-Object byte[] 262144
                [long]$received = 0
                while (($read = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                  $outStream.Write($buffer, 0, $read)
                  $received += $read
                  if ($entry) { $entry.Received = $received }
                }
                $outStream.Flush()
              } finally {
                $outStream.Dispose()
              }
            } finally {
              $inStream.Dispose()
            }
          } finally {
            $resp.Close()
          }
          return $true
        } catch {
          $entry = $ProgressMap[$Key]
          if ($entry) { $entry.Error = $_.Exception.Message }
          return $false
        }
      }
      foreach ($job in $jobs) {
        $partOut = "$($job.Out).part"
        if (Test-Path -LiteralPath $partOut -PathType Leaf) { Remove-Item -LiteralPath $partOut -Force -ErrorAction SilentlyContinue }
        $progressMap[$job.Key] = [hashtable]::Synchronized(@{ Received = 0L; Total = [long]$job.ApproxBytes; Error = '' })
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($workerScript).AddArgument([string]$job.Uri).AddArgument([string]$partOut).AddArgument([string]$job.Key).AddArgument($progressMap)
        $handle = $ps.BeginInvoke()
        $active += [pscustomobject]@{
          Key = $job.Key
          Label = $job.Label
          PowerShell = $ps
          Runspace = $rs
          Handle = $handle
          PartOut = $partOut
          Out = $job.Out
        }
      }
      $parSw = [Diagnostics.Stopwatch]::StartNew()
      while (@($active | Where-Object { -not $_.Handle.IsCompleted }).Count -gt 0 -and $parSw.Elapsed.TotalSeconds -lt 900) {
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
        $workerOk = $false
        try {
          if (-not $item.Handle.IsCompleted) {
            try { $item.PowerShell.Stop() } catch { }
          } else {
            $res = $item.PowerShell.EndInvoke($item.Handle)
            if ($res -and ($res | Select-Object -Last 1) -eq $true) { $workerOk = $true }
          }
        } catch {
          $workerOk = $false
        }
        $ok = ($workerOk -and (Test-Path -LiteralPath $item.PartOut -PathType Leaf))
        if ($ok) {
          try {
            Move-Item -LiteralPath $item.PartOut -Destination $item.Out -Force
          } catch { $ok = $false }
        }
        if (-not $ok -and (Test-Path -LiteralPath $item.PartOut -PathType Leaf)) {
          Remove-Item -LiteralPath $item.PartOut -Force -ErrorAction SilentlyContinue
        }
        $parallelDownloads[$item.Key] = $ok
        try { $item.PowerShell.Dispose() } catch { }
        try { $item.Runspace.Close() } catch { }
        try { $item.Runspace.Dispose() } catch { }
      }
    }
  }

  if ($needNode) {
    if ($needNodeDownload) {
      $archiveUri = "https://nodejs.org/dist/v24.21.0/$archiveName"
      $nodeMirrorUri = "https://npmmirror.com/mirrors/node/v24.21.0/$archiveName"
      $checksumUri = 'https://nodejs.org/dist/v24.21.0/SHASUMS256.txt'
      $pinnedNodeHash = '158f7685b44de51f6c0df1d153526cbcd3e1bc739a8dfc607721cef75de9e541'
      $sums = ''
      try {
        if (-not $parallelDownloads['node']) {
          Invoke-FastDependencyDownload -Uri $archiveUri -FallbackUris @($nodeMirrorUri) -OutFile $nodeArchive -TimeoutSec 600 -DisplayName 'Node.js 24'
        }
        try {
          $rawSums = (Invoke-WebRequest -UseBasicParsing -Uri $checksumUri -TimeoutSec 60 -ErrorAction Stop).Content
          $sums = if ($rawSums -is [byte[]]) { [System.Text.Encoding]::ASCII.GetString($rawSums) } else { [string]$rawSums }
        } catch {
          if (-not $isMockedWeb) { $sums = "$pinnedNodeHash  $archiveName" } else { throw }
        }
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
        Invoke-FastDependencyDownload -Uri 'https://www.python.org/ftp/python/3.13.16/python-3.13.16-amd64.exe' -OutFile $pythonInstaller -TimeoutSec 600 -DisplayName 'Python 3.13'
      }
    } catch { throw 'Python download failed.' }
    Write-DependencyInstallStatus 'Đang xác thực chữ ký số và cài đặt Python 3.13...'
    $pinnedPy313Hash = 'fb4f9f5d438b2396da0086dc70b935c530cb578e37adc6d354f7ad2037fee83b'
    $signature = Get-AuthenticodeSignature -FilePath $pythonInstaller
    $sigSubject = if ($signature -and $signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
    $sigValid = ($signature.Status -eq 'Valid' -and $sigSubject -like '*Python Software Foundation*')
    if (-not $sigValid -and -not $isMockedWeb -and $sigSubject -like '*Python Software Foundation*') {
      $sigValid = ((Get-FileHash $pythonInstaller -Algorithm SHA256).Hash.ToLowerInvariant() -eq $pinnedPy313Hash)
    }
    if (-not $sigValid) { throw 'Python installer signature verification failed.' }
    $pythonDirectory = Join-Path $dependencies 'python313'
    $spMeta = Get-Command Start-Process -ErrorAction SilentlyContinue
    if ($spMeta -and $spMeta.CommandType -eq 'Function') {
      $process = Start-Process -FilePath $pythonInstaller -ArgumentList @('/quiet','InstallAllUsers=0','PrependPath=0','Include_test=0',"TargetDir=`"$pythonDirectory`"") -WindowStyle Hidden -Wait -PassThru
    } else {
      $pyArgStr = '/quiet InstallAllUsers=0 PrependPath=0 Include_test=0 TargetDir="' + $pythonDirectory + '"'
      $process = Start-Process -FilePath $pythonInstaller -ArgumentList $pyArgStr -WindowStyle Hidden -Wait -PassThru
    }
    Remove-Item -LiteralPath $pythonInstaller -Force -ErrorAction SilentlyContinue
    $pythonExecutable = Join-Path $pythonDirectory 'python.exe'
    if (($process.ExitCode -notin @(0,3010) -or -not (Test-Path -LiteralPath $pythonExecutable) -or -not (Test-PythonCandidate -Executable $pythonExecutable)) -and -not $isMockedWeb) {
      Write-DependencyInstallStatus 'Đang giải nén gói Python 3.12 độc lập dự phòng (không phụ thuộc MSI)...'
      $nupkgZip = Join-Path $dependencies 'python-3.12.9-standalone.zip'
      $nupkgExtract = Join-Path $dependencies 'python312-pkg'
      $portablePyDir = Join-Path $dependencies 'python312'
      $pinnedNugetHash = 'b7240e3117d94dc2446c4b1250e31306adc817934706937d0992c78f937487ba'
      Invoke-FastDependencyDownload -Uri 'https://www.nuget.org/api/v2/package/python/3.12.9' -OutFile $nupkgZip -TimeoutSec 600 -DisplayName 'Python 3.12 Portable'
      if ((Get-FileHash $nupkgZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pinnedNugetHash) {
        Remove-Item -LiteralPath $nupkgZip -Force -ErrorAction SilentlyContinue
        throw 'Python user installation failed.'
      }
      if (Test-Path -LiteralPath $nupkgExtract) { Remove-Item -LiteralPath $nupkgExtract -Recurse -Force -ErrorAction SilentlyContinue }
      Write-DependencyInstallStatus 'Đang kiểm tra SHA-256 và giải nén Python 3.12 độc lập...'
      Expand-FastDependencyZip -LiteralPath $nupkgZip -DestinationPath $nupkgExtract
      Remove-Item -LiteralPath $nupkgZip -Force -ErrorAction SilentlyContinue
      $toolsFolder = Join-Path $nupkgExtract 'tools'
      if (-not (Test-Path -LiteralPath (Join-Path $toolsFolder 'python.exe') -PathType Leaf)) {
        Remove-Item -LiteralPath $nupkgExtract -Recurse -Force -ErrorAction SilentlyContinue
        throw 'Python user installation failed.'
      }
      if (Test-Path -LiteralPath $portablePyDir) { Remove-Item -LiteralPath $portablePyDir -Recurse -Force -ErrorAction SilentlyContinue }
      Move-Item -LiteralPath $toolsFolder -Destination $portablePyDir -Force
      Remove-Item -LiteralPath $nupkgExtract -Recurse -Force -ErrorAction SilentlyContinue
      $pythonExecutable = Join-Path $portablePyDir 'python.exe'
    } elseif ($process.ExitCode -notin @(0,3010)) {
      throw 'Python user installation failed.'
    }
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
  Write-DependencyInstallStatus 'Đang hoàn tất cấu hình Node.js, Python, FFmpeg để chuyển sang cài đặt OpenClaw...'
}
