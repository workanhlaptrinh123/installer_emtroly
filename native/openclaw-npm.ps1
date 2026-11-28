function Remove-EmTroLyNpmSecrets {
  param(
    [string]$Text = '',
    [string[]]$Secrets = @()
  )
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $clean = [string]$Text
  foreach ($sec in @($Secrets)) {
    if (-not [string]::IsNullOrWhiteSpace($sec) -and $sec.Length -ge 6) {
      $clean = $clean.Replace($sec, '[REDACTED_SECRET]')
    }
  }
  $clean = [regex]::Replace($clean, '[0-9]{5,}:[A-Za-z0-9_-]{20,}', '[REDACTED_TELEGRAM_TOKEN]')
  $clean = [regex]::Replace($clean, 'sk-[A-Za-z0-9_-]{12,}', '[REDACTED_API_KEY]')
  $clean = [regex]::Replace($clean, '("token"\s*:\s*")[0-9a-fA-F]{24,}(")', '$1[REDACTED_GATEWAY_TOKEN]$2')
  return $clean
}

function Test-IsNpmTlsCipherError {
  param([string]$LogText = '')
  if ([string]::IsNullOrWhiteSpace($LogText)) { return $false }
  return ($LogText -match '(?i)ERR_SSL_CIPHER_OPERATION_FAILED|ERR_SSL_DECRYPTION_FAILED_OR_BAD_RECORD_MAC|ERR_SSL_BAD_RECORD_MAC|ossl_gcm_stream_update|ciphercommon_gcm|bad record mac|cipher operation failed|decryption failed|tlsv1 alert|ssl3_get_record|SSL routines')
}

function Test-IsNpmCacheOrTarballCorruptError {
  param([string]$LogText = '')
  if ([string]::IsNullOrWhiteSpace($LogText)) { return $false }
  if (Test-IsNpmTlsCipherError -LogText $LogText) { return $true }
  return ($LogText -match '(?i)EINTEGRITY|sha512-|Z_DATA_ERROR|TAR_BAD_ARCHIVE|unexpected end of file|premature close|zlib|EBADF|ENOENT.*_cacache|corrupted?')
}

function Get-EmTroLyNodeVersionInfo {
  param([string]$VersionText = '')
  $m = [regex]::Match([string]$VersionText, 'v?(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return $null }
  return [pscustomobject]@{
    Major = [int]$m.Groups[1].Value
    Minor = [int]$m.Groups[2].Value
    Patch = [int]$m.Groups[3].Value
    Full  = "v$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
  }
}

function Test-EmTroLyPeBinaryFile {
  param([string]$FilePath = '')
  if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $false }
  try {
    $fs = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      if ($fs.Length -lt 64) { return $false }
      $b0 = $fs.ReadByte()
      $b1 = $fs.ReadByte()
      return ($b0 -eq 0x4D -and $b1 -eq 0x5A)
    } finally {
      $fs.Dispose()
    }
  } catch {
    return $false
  }
}

function Get-EmTroLyNodeCandidateMetadata {
  param(
    [Parameter(Mandatory=$true)][string]$NodeExe,
    [Parameter(Mandatory=$true)][string]$NpmCmd,
    [bool]$IsBundled = $false,
    [string]$Origin = 'machine'
  )
  $nodeDir = Split-Path -Parent $NodeExe
  $verText = ''
  $archText = ''
  $archOk = $true

  if (Test-EmTroLyPeBinaryFile -FilePath $NodeExe) {
    try {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $NodeExe
      $psi.Arguments = '-e "console.log(process.versions.node + ''|'' + process.arch)"'
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
      $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
      [void]$psi.EnvironmentVariables.Remove('NODE_OPTIONS')
      $proc = New-Object System.Diagnostics.Process
      $proc.StartInfo = $psi
      [void]$proc.Start()
      $outTask = $proc.StandardOutput.ReadToEndAsync()
      $errTask = $proc.StandardError.ReadToEndAsync()
      if ($proc.WaitForExit(5000)) {
        $proc.WaitForExit()
        if ($proc.ExitCode -eq 0) {
          $probeLine = ($outTask.GetAwaiter().GetResult()).Trim()
          if ($probeLine -match '^(\d+\.\d+\.\d+)\|([A-Za-z0-9_]+)$') {
            $verText = "v$($Matches[1])"
            $archText = $Matches[2].ToLowerInvariant()
          }
        }
      } else {
        try { $proc.Kill() } catch { }
      }
      $proc.Dispose()
    } catch { }

    if (-not $verText) {
      try {
        $psiV = New-Object System.Diagnostics.ProcessStartInfo
        $psiV.FileName = $NodeExe
        $psiV.Arguments = '--version'
        $psiV.UseShellExecute = $false
        $psiV.CreateNoWindow = $true
        $psiV.RedirectStandardOutput = $true
        $psiV.RedirectStandardError = $true
        [void]$psiV.EnvironmentVariables.Remove('NODE_OPTIONS')
        $procV = New-Object System.Diagnostics.Process
        $procV.StartInfo = $psiV
        [void]$procV.Start()
        $outTaskV = $procV.StandardOutput.ReadToEndAsync()
        if ($procV.WaitForExit(5000)) {
          $procV.WaitForExit()
          if ($procV.ExitCode -eq 0) {
            $verText = ($outTaskV.GetAwaiter().GetResult()).Trim()
          }
        } else {
          try { $procV.Kill() } catch { }
        }
        $procV.Dispose()
      } catch { }
    }
  }

  $dirLeaf = Split-Path -Leaf $nodeDir
  if (-not $verText -and $dirLeaf -match 'node-v(\d+\.\d+\.\d+)') {
    $verText = "v$($Matches[1])"
  }
  if (-not $archText -and $dirLeaf -match 'win-(x64|arm64|x86)') {
    $archText = $Matches[1].ToLowerInvariant()
  }
  if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -and $archText -and $archText -ne 'x64') {
    $archOk = $false
  }

  $verInfo = Get-EmTroLyNodeVersionInfo -VersionText $verText
  $major = if ($verInfo) { $verInfo.Major } else { 0 }
  $minor = if ($verInfo) { $verInfo.Minor } else { 0 }
  $isSupportedPrimary = (($major -eq 24 -and $minor -ge 16) -or ($major -eq 26 -and $minor -ge 1) -or ($major -gt 26))
  $isLts = ($major -in @(22, 20)) -and $archOk

  return [pscustomobject]@{
    NodeExe            = $NodeExe
    NpmCmd             = $NpmCmd
    NodeDir            = $nodeDir
    Version            = $(if ($verInfo) { $verInfo.Full } else { $verText })
    Major              = $major
    Minor              = $minor
    Patch              = $(if ($verInfo) { $verInfo.Patch } else { 0 })
    Arch               = $archText
    ArchOk             = $archOk
    IsBundled          = $IsBundled
    IsSupportedPrimary = $isSupportedPrimary
    IsLts              = $isLts
    Origin             = $Origin
  }
}

function Resolve-EmTroLyNodeToolchains {
  param(
    [string]$PayloadRoot = '',
    [string]$OpenClawRoot = '',
    [string]$LocalAppData = ''
  )
  $localBase = if (-not [string]::IsNullOrWhiteSpace($LocalAppData)) { $LocalAppData } else { $env:LOCALAPPDATA }
  $candidatesRaw = New-Object System.Collections.Generic.List[object]

  if ($OpenClawRoot) {
    $instFile = Join-Path $OpenClawRoot 'installer-instance.json'
    if (Test-Path -LiteralPath $instFile -PathType Leaf) {
      try {
        $instObj = [IO.File]::ReadAllText($instFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($instObj -and $instObj.PSObject.Properties['node'] -and $instObj.node) {
          $instNode = [string]$instObj.node
          if (Test-Path -LiteralPath $instNode -PathType Leaf) {
            [void]$candidatesRaw.Add([pscustomobject]@{ Dir = (Split-Path -Parent $instNode); Bundled = $true; Origin = 'instance' })
          }
        }
      } catch { }
    }
  }

  $depBase = if ($localBase) { Join-Path $localBase 'MemberInstaller\dependencies' } else { '' }
  if ($depBase -and (Test-Path -LiteralPath $depBase -PathType Container)) {
    foreach ($d in @(Get-ChildItem -LiteralPath $depBase -Directory -Filter 'node-v*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
      [void]$candidatesRaw.Add([pscustomobject]@{ Dir = $d.FullName; Bundled = $true; Origin = 'member-bundled' })
    }
  }

  if ($PayloadRoot -and (Test-Path -LiteralPath $PayloadRoot -PathType Container)) {
    foreach ($sub in @('dependencies', 'native', '.')) {
      $scanDir = if ($sub -eq '.') { $PayloadRoot } else { Join-Path $PayloadRoot $sub }
      if (Test-Path -LiteralPath $scanDir -PathType Container) {
        foreach ($d in @(Get-ChildItem -LiteralPath $scanDir -Directory -Filter 'node-v*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
          [void]$candidatesRaw.Add([pscustomobject]@{ Dir = $d.FullName; Bundled = $true; Origin = 'payload-bundled' })
        }
      }
    }
  }

  foreach ($stdDir in @(
    $(if ($env:EMTROLY_IGNORE_SYSTEM_NODE -ne '1' -and $env:ProgramFiles) { Join-Path $env:ProgramFiles 'nodejs' }),
    $(if ($env:EMTROLY_IGNORE_SYSTEM_NODE -ne '1' -and $localBase) { Join-Path $localBase 'Programs\nodejs' })
  )) {
    if ($stdDir -and (Test-Path -LiteralPath $stdDir -PathType Container)) {
      [void]$candidatesRaw.Add([pscustomobject]@{ Dir = $stdDir; Bundled = $false; Origin = 'system-default' })
    }
  }

  if ($env:EMTROLY_IGNORE_SYSTEM_NODE -ne '1' -and $env:APPDATA) {
    $nvmDir = Join-Path $env:APPDATA 'nvm'
    if (Test-Path -LiteralPath $nvmDir -PathType Container) {
      foreach ($nd in @(Get-ChildItem -LiteralPath $nvmDir -Directory -Filter 'v*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        [void]$candidatesRaw.Add([pscustomobject]@{ Dir = $nd.FullName; Bundled = $false; Origin = 'nvm' })
      }
    }
  }

  if ($env:EMTROLY_IGNORE_SYSTEM_NODE -ne '1') {
    foreach ($cmdHit in @(Get-Command node.exe -All -CommandType Application -ErrorAction SilentlyContinue)) {
      if ($cmdHit.Source -and $cmdHit.Source -notlike '*\WindowsApps\*') {
        [void]$candidatesRaw.Add([pscustomobject]@{ Dir = (Split-Path -Parent $cmdHit.Source); Bundled = $false; Origin = 'path' })
      }
    }
  }

  $seenDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $resolved = New-Object System.Collections.Generic.List[object]

  foreach ($item in $candidatesRaw) {
    if (-not $item.Dir) { continue }
    $normDir = try { [IO.Path]::GetFullPath($item.Dir).TrimEnd('\') } catch { $item.Dir.TrimEnd('\') }
    if (-not $seenDirs.Add($normDir)) { continue }
    $nodeExeCand = Join-Path $normDir 'node.exe'
    $npmCmdCand = Join-Path $normDir 'npm.cmd'
    if ((Test-Path -LiteralPath $nodeExeCand -PathType Leaf) -and (Test-Path -LiteralPath $npmCmdCand -PathType Leaf)) {
      $meta = Get-EmTroLyNodeCandidateMetadata -NodeExe $nodeExeCand -NpmCmd $npmCmdCand -IsBundled ([bool]$item.Bundled) -Origin ([string]$item.Origin)
      [void]$resolved.Add($meta)
    }
  }

  # Last-resort pair if node.exe and npm.cmd live in separate PATH directories
  if ($resolved.Count -eq 0) {
    $nCmd = @(Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -and $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1)
    $mCmd = @(Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -and $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1)
    if ($nCmd.Count -gt 0 -and $mCmd.Count -gt 0) {
      $meta = Get-EmTroLyNodeCandidateMetadata -NodeExe $nCmd[0].Source -NpmCmd $mCmd[0].Source -IsBundled $false -Origin 'path-split'
      [void]$resolved.Add($meta)
    } elseif ($mCmd.Count -gt 0) {
      $npmDir = Split-Path -Parent $mCmd[0].Source
      $nodeSibling = Join-Path $npmDir 'node.exe'
      $nodePathUse = if (Test-Path -LiteralPath $nodeSibling -PathType Leaf) { $nodeSibling } else { $mCmd[0].Source }
      $meta = Get-EmTroLyNodeCandidateMetadata -NodeExe $nodePathUse -NpmCmd $mCmd[0].Source -IsBundled $false -Origin 'npm-only'
      [void]$resolved.Add($meta)
    }
  }

  $allResolved = $resolved.ToArray()
  $primary = $allResolved | Where-Object { $_.IsBundled -and $_.IsSupportedPrimary } | Select-Object -First 1
  if (-not $primary) { $primary = $allResolved | Where-Object { $_.IsBundled } | Select-Object -First 1 }
  if (-not $primary) { $primary = $allResolved | Where-Object { $_.IsSupportedPrimary } | Select-Object -First 1 }
  if (-not $primary -and $allResolved.Count -gt 0) { $primary = $allResolved[0] }

  $primaryKey = if ($primary) { $primary.NodeExe.ToLowerInvariant() } else { '' }
  $lts = $allResolved | Where-Object { $_.IsBundled -and $_.Major -eq 22 -and $_.ArchOk -and $_.NodeExe.ToLowerInvariant() -ne $primaryKey } | Select-Object -First 1
  if (-not $lts) { $lts = $allResolved | Where-Object { $_.IsBundled -and $_.Major -eq 20 -and $_.ArchOk -and $_.NodeExe.ToLowerInvariant() -ne $primaryKey } | Select-Object -First 1 }
  if (-not $lts) { $lts = $allResolved | Where-Object { $_.Major -eq 22 -and $_.ArchOk -and $_.NodeExe.ToLowerInvariant() -ne $primaryKey } | Select-Object -First 1 }
  if (-not $lts) { $lts = $allResolved | Where-Object { $_.Major -eq 20 -and $_.ArchOk -and $_.NodeExe.ToLowerInvariant() -ne $primaryKey } | Select-Object -First 1 }

  return [pscustomobject]@{
    Primary = $primary
    Lts     = $lts
    All     = $allResolved
  }
}

function Wait-EmTroLyRuntimeProcessesExit {
  param(
    [Parameter(Mandatory=$true)][string]$TargetDir,
    [int]$WaitMs = 5000
  )
  if ([string]::IsNullOrWhiteSpace($TargetDir) -or $env:EMTROLY_SKIP_PROCESS_SWEEP -eq '1') { return }
  $needles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $rawTrim = $TargetDir.Trim().TrimEnd('\')
  if ($rawTrim) { [void]$needles.Add($rawTrim) }
  try {
    $fullTrim = [IO.Path]::GetFullPath($TargetDir).TrimEnd('\')
    if ($fullTrim) { [void]$needles.Add($fullTrim) }
  } catch { }
  if (Test-Path -LiteralPath $TargetDir) {
    try {
      $fso = New-Object -ComObject Scripting.FileSystemObject
      $shortFolder = $fso.GetFolder($TargetDir).ShortPath
      if ($shortFolder) { [void]$needles.Add($shortFolder.TrimEnd('\')) }
    } catch { }
  }
  if ($needles.Count -eq 0) { return }
  $needleList = @($needles)

  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    $matching = @()
    try {
      $matching = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe' OR Name = 'npm.cmd'" -ErrorAction SilentlyContinue | Where-Object {
        if (-not $_.ProcessId -or ([int]$_.ProcessId -eq $PID) -or -not $_.CommandLine) { return $false }
        $cmdLineText = [string]$_.CommandLine
        foreach ($ndl in $needleList) {
          if ($cmdLineText.IndexOf($ndl, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
        return $false
      })
    } catch { $matching = @() }
    if ($matching.Count -eq 0) { return }
    if ($sw.ElapsedMilliseconds -ge $WaitMs) {
      foreach ($procItem in $matching) {
        try {
          $pObj = Get-Process -Id ([int]$procItem.ProcessId) -ErrorAction SilentlyContinue
          if ($pObj) {
            Stop-Process -Id ([int]$procItem.ProcessId) -Force -ErrorAction SilentlyContinue
            [void]$pObj.WaitForExit(3000)
          }
        } catch { }
      }
      return
    }
    Start-Sleep -Milliseconds 150
  }
}

function Clear-EmTroLyDirectorySafe {
  param([Parameter(Mandatory=$true)][string]$DirPath)
  if ([string]::IsNullOrWhiteSpace($DirPath) -or -not (Test-Path -LiteralPath $DirPath)) { return }
  try {
    $item = Get-Item -LiteralPath $DirPath -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
  } catch { return }

  $cmdExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\cmd.exe' } else { 'cmd.exe' }
  if (Test-Path -LiteralPath $cmdExe -PathType Leaf) {
    try {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $cmdExe
      $psi.Arguments = '/d /s /c "rmdir /s /q "' + $DirPath + '""'
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
      $proc = [System.Diagnostics.Process]::Start($psi)
      [void]$proc.WaitForExit(20000)
      $proc.Dispose()
    } catch { }
  }
  if (Test-Path -LiteralPath $DirPath) {
    Remove-Item -LiteralPath $DirPath -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Format-EmTroLyCmdArg {
  param([string]$Value = '')
  if ($Value -match '[\r\n\x00]') { throw 'Invalid command argument.' }
  if ($Value.Length -gt 0 -and $Value -notmatch '[\s"&()^%;,=]') { return $Value }
  $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
  return '"' + $escaped + '"'
}

function Invoke-EmTroLyNpmAttempt {
  param(
    [Parameter(Mandatory=$true)][string]$NodeExe,
    [Parameter(Mandatory=$true)][string]$NpmCmd,
    [Parameter(Mandatory=$true)][string[]]$NpmArguments,
    [Parameter(Mandatory=$true)][string]$WorkingDir,
    [Parameter(Mandatory=$true)][string]$AttemptLogFile,
    [string]$SummaryLogFile = '',
    [Parameter(Mandatory=$true)][string]$NpmCacheDir,
    [Parameter(Mandatory=$true)][string]$NpmrcPath,
    [Parameter(Mandatory=$true)][string]$RegistryUrl,
    [int]$MaxSockets = 2,
    [string]$NodeOptions = '',
    [string]$OpenSslIa32Cap = '',
    [string]$AttemptLabel = 'attempt',
    [int]$AttemptNumber = 1,
    [string]$RuntimeCleanupDir = '',
    [int]$TimeoutSeconds = 600,
    [string[]]$SecretsToRedact = @()
  )
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $AttemptLogFile))
  [void][IO.Directory]::CreateDirectory($NpmCacheDir)
  $npmrcDir = Split-Path -Parent $NpmrcPath
  if ($npmrcDir) { [void][IO.Directory]::CreateDirectory($npmrcDir) }

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  # Strictly enforce npm integrity verification and TLS certificate validation.
  $npmrcContent = @(
    "registry=$RegistryUrl",
    "maxsockets=$MaxSockets",
    'fetch-retries=5',
    'fetch-retry-mintimeout=1500',
    'fetch-retry-maxtimeout=10000',
    'fetch-timeout=600000',
    'audit=false',
    'fund=false'
  ) -join "`n"
  [IO.File]::WriteAllText($NpmrcPath, ($npmrcContent + "`n"), $utf8NoBom)

  $nodeDir = Split-Path -Parent $NodeExe
  $cmdExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\cmd.exe' } else { 'cmd.exe' }
  $quotedCmd = Format-EmTroLyCmdArg -Value $NpmCmd
  $quotedArgs = @($NpmArguments | ForEach-Object { Format-EmTroLyCmdArg -Value ([string]$_) })
  $innerCmd = $quotedCmd + ' ' + ($quotedArgs -join ' ')

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $cmdExe
  $psi.Arguments = '/d /s /c "' + $innerCmd + '"'
  $psi.WorkingDirectory = $WorkingDir
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

  $curPath = if ($psi.EnvironmentVariables.ContainsKey('PATH')) { $psi.EnvironmentVariables['PATH'] } else { $env:Path }
  if ($nodeDir) {
    $psi.EnvironmentVariables['PATH'] = ($nodeDir + ';' + $curPath).TrimEnd(';')
  }
  $psi.EnvironmentVariables['NPM_CONFIG_CACHE'] = $NpmCacheDir
  $psi.EnvironmentVariables['NPM_CONFIG_USERCONFIG'] = $NpmrcPath
  $psi.EnvironmentVariables['NPM_CONFIG_MAXSOCKETS'] = [string]$MaxSockets
  $psi.EnvironmentVariables['NPM_CONFIG_UPDATE_NOTIFIER'] = 'false'
  $psi.EnvironmentVariables['NO_COLOR'] = '1'
  foreach ($rmVar in @('NPM_CONFIG_PREFIX', 'NPM_CONFIG_REGISTRY', 'NODE_OPTIONS', 'OPENSSL_ia32cap', 'NODE_TLS_REJECT_UNAUTHORIZED')) {
    [void]$psi.EnvironmentVariables.Remove($rmVar)
  }
  if (-not [string]::IsNullOrWhiteSpace($OpenSslIa32Cap)) {
    $psi.EnvironmentVariables['OPENSSL_ia32cap'] = $OpenSslIa32Cap
  }
  if (-not [string]::IsNullOrWhiteSpace($NodeOptions)) {
    $psi.EnvironmentVariables['NODE_OPTIONS'] = $NodeOptions
  }

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  $exitCode = 1
  $timedOut = $false
  $rawOut = ''
  $rawErr = ''
  try {
    [void]$proc.Start()
    try { $proc.StandardInput.Close() } catch { }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
      $timedOut = $true
      $exitCode = 124
      try {
        $taskkill = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\taskkill.exe' } else { 'taskkill.exe' }
        $tkPsi = New-Object System.Diagnostics.ProcessStartInfo
        $tkPsi.FileName = $taskkill
        $tkPsi.Arguments = "/PID $($proc.Id) /T /F"
        $tkPsi.UseShellExecute = $false
        $tkPsi.CreateNoWindow = $true
        $tkProc = [System.Diagnostics.Process]::Start($tkPsi)
        [void]$tkProc.WaitForExit(3000)
        $tkProc.Dispose()
      } catch { }
      try { $proc.Kill() } catch { }
      try { [void]$proc.WaitForExit(5000) } catch { }
    } else {
      $proc.WaitForExit()
      $exitCode = [int]$proc.ExitCode
    }
    try { if ($outTask.Wait(5000)) { $rawOut = $outTask.Result } } catch { }
    try { if ($errTask.Wait(5000)) { $rawErr = $errTask.Result } } catch { }
  } finally {
    $proc.Dispose()
  }

  if ($RuntimeCleanupDir) {
    Wait-EmTroLyRuntimeProcessesExit -TargetDir $RuntimeCleanupDir -WaitMs 5000
  }

  $combined = ($rawOut + "`r`n" + $rawErr).Trim()
  if ($timedOut -and $combined -notmatch 'timed out') {
    $combined = ($combined + "`r`nnpm process timed out after $TimeoutSeconds seconds.").Trim()
  }
  $safeCombined = Remove-EmTroLyNpmSecrets -Text $combined -Secrets $SecretsToRedact
  $header = @(
    "attempt=$AttemptNumber label=$AttemptLabel exit=$exitCode",
    "node=$NodeExe npm=$NpmCmd",
    "registry=$RegistryUrl maxsockets=$MaxSockets",
    "cache=$NpmCacheDir",
    "OPENSSL_ia32cap=$(if ($OpenSslIa32Cap) { $OpenSslIa32Cap } else { '<unset>' })",
    "NODE_OPTIONS=$(if ($NodeOptions) { $NodeOptions } else { '<unset>' })",
    '------------------------------------------------------------'
  ) -join "`r`n"
  $attemptBody = ($header + "`r`n" + $safeCombined).TrimEnd() + "`r`n"
  [IO.File]::WriteAllText($AttemptLogFile, $attemptBody, $utf8NoBom)

  if ($SummaryLogFile) {
    try {
      [void][IO.Directory]::CreateDirectory((Split-Path -Parent $SummaryLogFile))
      [IO.File]::AppendAllText($SummaryLogFile, ($attemptBody + "`r`n"), $utf8NoBom)
    } catch { }
  }

  return [pscustomobject]@{
    AttemptNumber  = $AttemptNumber
    Label          = $AttemptLabel
    ExitCode       = $exitCode
    TimedOut       = $timedOut
    Output         = $safeCombined
    LogFile        = $AttemptLogFile
    Registry       = $RegistryUrl
    MaxSockets     = $MaxSockets
    NodeExe        = $NodeExe
    NpmCmd         = $NpmCmd
    CacheDir       = $NpmCacheDir
    NodeOptions    = $NodeOptions
    OpenSslIa32Cap = $OpenSslIa32Cap
  }
}

function Test-OpenClawRuntimeArtifacts {
  param([Parameter(Mandatory=$true)][string]$RuntimeDir)
  $pkgJson = Join-Path $RuntimeDir 'node_modules\openclaw\package.json'
  $binCmd = Join-Path $RuntimeDir 'node_modules\.bin\openclaw.cmd'
  $missing = @()
  if (-not (Test-Path -LiteralPath $pkgJson -PathType Leaf) -or (Get-Item -LiteralPath $pkgJson -ErrorAction SilentlyContinue).Length -le 0) {
    $missing += $pkgJson
  }
  if (-not (Test-Path -LiteralPath $binCmd -PathType Leaf) -or (Get-Item -LiteralPath $binCmd -ErrorAction SilentlyContinue).Length -le 0) {
    $missing += $binCmd
  }
  return [pscustomobject]@{
    Ok              = ($missing.Count -eq 0)
    Missing         = $missing
    PackageJsonPath = $pkgJson
    OpenClawCmdPath = $binCmd
  }
}

function New-EmTroLyNpmRetryPlan {
  param(
    [Parameter(Mandatory=$true)]$Toolchains,
    [string]$PrimaryRegistry = 'https://registry.npmjs.org/',
    [string]$FallbackRegistry = 'https://registry.npmmirror.com/',
    [bool]$IsTlsError = $false
  )
  $primaryTc = $Toolchains.Primary
  $ltsTc = $Toolchains.Lts
  $chaChaStrict = '--tls-max-v1.2 --tls-cipher-list=ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:DHE-RSA-CHACHA20-POLY1305:!AESGCM:!GCM'
  $chaChaCompat = '--tls-max-v1.2 --tls-cipher-list=ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DEFAULT'

  $plan = New-Object System.Collections.Generic.List[object]
  if ($IsTlsError) {
    if ($ltsTc) {
      [void]$plan.Add([pscustomobject]@{
        Label          = "node-lts-$($ltsTc.Major)"
        Toolchain      = $ltsTc
        Registry       = $PrimaryRegistry
        MaxSockets     = 1
        OpenSslIa32Cap = ''
        NodeOptions    = ''
        StatusMessage  = "Phát hiện lỗi giải mã TLS/OpenSSL — đang thử lại với Node $($ltsTc.Version) LTS và giảm kết nối đồng thời..."
      })
    }
    [void]$plan.Add([pscustomobject]@{
      Label          = 'ia32cap-maxsockets1'
      Toolchain      = $primaryTc
      Registry       = $PrimaryRegistry
      MaxSockets     = 1
      OpenSslIa32Cap = '~0x200000200000000'
      NodeOptions    = ''
      StatusMessage  = 'Đang thử lại OpenClaw với OPENSSL_ia32cap (~0x200000200000000) và maxsockets=1...'
    })
    [void]$plan.Add([pscustomobject]@{
      Label          = 'ia32cap-tls12'
      Toolchain      = $primaryTc
      Registry       = $PrimaryRegistry
      MaxSockets     = 1
      OpenSslIa32Cap = '~0x200000200000000'
      NodeOptions    = '--tls-max-v1.2'
      StatusMessage  = 'Đang thử lại OpenClaw với chế độ TLS 1.2 (--tls-max-v1.2) và bộ nhớ đệm riêng mới...'
    })
    [void]$plan.Add([pscustomobject]@{
      Label          = 'ia32cap-tls12-chacha20'
      Toolchain      = $primaryTc
      Registry       = $PrimaryRegistry
      MaxSockets     = 1
      OpenSslIa32Cap = '~0x200000200000000'
      NodeOptions    = $chaChaStrict
      StatusMessage  = 'Đang thử lại OpenClaw với cipher ChaCha20 (TLS 1.2, loại trừ AES-GCM)...'
    })
    if ($ltsTc) {
      [void]$plan.Add([pscustomobject]@{
        Label          = "node-lts-$($ltsTc.Major)-tls12-chacha20"
        Toolchain      = $ltsTc
        Registry       = $PrimaryRegistry
        MaxSockets     = 1
        OpenSslIa32Cap = '~0x200000200000000'
        NodeOptions    = $chaChaStrict
        StatusMessage  = "Đang thử lại với Node $($ltsTc.Version) LTS cùng TLS 1.2 / ChaCha20..."
      })
    }
    if (-not [string]::IsNullOrWhiteSpace($FallbackRegistry)) {
      $fbTc = if ($ltsTc) { $ltsTc } else { $primaryTc }
      [void]$plan.Add([pscustomobject]@{
        Label          = 'fallback-registry-scalar-tls12-chacha20'
        Toolchain      = $fbTc
        Registry       = $FallbackRegistry
        MaxSockets     = 1
        OpenSslIa32Cap = '0:0'
        NodeOptions    = $chaChaStrict
        StatusMessage  = 'Đang chuyển sang máy chủ npm dự phòng với chế độ bảo toàn toàn vẹn và TLS 1.2 / ChaCha20...'
      })
    }
  } else {
    [void]$plan.Add([pscustomobject]@{
      Label          = 'retry-maxsockets1'
      Toolchain      = $primaryTc
      Registry       = $PrimaryRegistry
      MaxSockets     = 1
      OpenSslIa32Cap = ''
      NodeOptions    = ''
      StatusMessage  = 'Kết nối tải gói OpenClaw tạm gián đoạn — đang tự động thử lại (maxsockets=1)...'
    })
    if (-not [string]::IsNullOrWhiteSpace($FallbackRegistry)) {
      [void]$plan.Add([pscustomobject]@{
        Label          = 'fallback-registry-tls12'
        Toolchain      = $primaryTc
        Registry       = $FallbackRegistry
        MaxSockets     = 1
        OpenSslIa32Cap = '~0x200000200000000'
        NodeOptions    = '--tls-max-v1.2'
        StatusMessage  = 'Đang chuyển sang máy chủ npm dự phòng với chế độ TLS 1.2...'
      })
    }
    [void]$plan.Add([pscustomobject]@{
      Label          = 'scalar-tls12-chacha20'
      Toolchain      = $primaryTc
      Registry       = $PrimaryRegistry
      MaxSockets     = 1
      OpenSslIa32Cap = '0:0'
      NodeOptions    = $chaChaStrict
      StatusMessage  = 'Đang thử lại tải gói OpenClaw với chế độ TLS 1.2 / ChaCha20...'
    })
  }
  return $plan.ToArray()
}

function Invoke-EmTroLyNpmPackageWithTlsRetry {
  param(
    [Parameter(Mandatory=$true)][string]$PrefixDir,
    [Parameter(Mandatory=$true)][string[]]$Packages,
    [Parameter(Mandatory=$true)][string]$CacheRootDir,
    [Parameter(Mandatory=$true)][string]$LogsDir,
    [string]$PayloadRoot = '',
    [string]$OpenClawRoot = '',
    [string]$PrimaryRegistry = 'https://registry.npmjs.org/',
    [string]$FallbackRegistry = 'https://registry.npmmirror.com/',
    [int]$MaxSocketsInitial = 2,
    [int]$RetryDelayBaseSeconds = 2,
    [string[]]$ExtraNpmFlags = @(),
    [string]$LogFilePrefix = 'npm-install',
    [string[]]$SecretsToRedact = @(),
    $StatusCallback = $null,
    $LogCallback = $null,
    [switch]$CleanNodeModulesOnFailure,
    $VerifySuccess = $null
  )
  $toolchains = Resolve-EmTroLyNodeToolchains -PayloadRoot $PayloadRoot -OpenClawRoot $OpenClawRoot
  if (-not $toolchains.Primary -or -not $toolchains.Primary.NpmCmd) {
    throw 'npm is unavailable after Node.js installation.'
  }

  [void][IO.Directory]::CreateDirectory($PrefixDir)
  [void][IO.Directory]::CreateDirectory($LogsDir)
  [void][IO.Directory]::CreateDirectory($CacheRootDir)

  $summaryLog = Join-Path $LogsDir ($LogFilePrefix + '.log')
  $isolatedNpmrc = Join-Path $PrefixDir '.npmrc.emtroly'
  $initialSockets = [Math]::Max(1, [Math]::Min(2, $MaxSocketsInitial))

  if (Test-Path -LiteralPath $summaryLog -PathType Leaf) {
    Remove-Item -LiteralPath $summaryLog -Force -ErrorAction SilentlyContinue
  }

  $firstStep = [pscustomobject]@{
    Label          = 'primary-default'
    Toolchain      = $toolchains.Primary
    Registry       = $PrimaryRegistry
    MaxSockets     = $initialSockets
    OpenSslIa32Cap = ''
    NodeOptions    = ''
    StatusMessage  = ''
  }

  $queue = New-Object System.Collections.Generic.List[object]
  [void]$queue.Add($firstStep)
  $triedLabels = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $attemptLogs = New-Object System.Collections.Generic.List[string]
  $attempts = New-Object System.Collections.Generic.List[object]
  $planExpandedForTls = $false
  $planExpandedGeneral = $false
  $attemptIndex = 0
  $lastFailureOutput = ''

  try {
    for ($idx = 0; $idx -lt $queue.Count; $idx++) {
      $step = $queue[$idx]
      if (-not $triedLabels.Add($step.Label)) { continue }
      $attemptIndex++

      if ($attemptIndex -gt 1) {
        if ($StatusCallback -and $step.StatusMessage) {
          try { & $StatusCallback $step.StatusMessage } catch { }
        }
        $delayMs = if ($env:EMTROLY_NPM_RETRY_DELAY_MS -match '^[0-9]+$') {
          [int]$env:EMTROLY_NPM_RETRY_DELAY_MS
        } else {
          ($attemptIndex - 1) * $RetryDelayBaseSeconds * 1000
        }
        if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
      }

      $attemptCache = Join-Path $CacheRootDir ("attempt-$attemptIndex")
      $attemptLog = Join-Path $LogsDir ("$LogFilePrefix-attempt-$attemptIndex.log")
      [void]$attemptLogs.Add($attemptLog)

      $npmArgs = @('install', '--prefix', $PrefixDir) + $Packages + @('--no-audit', '--no-fund', '--loglevel=error') + $ExtraNpmFlags
      $res = Invoke-EmTroLyNpmAttempt `
        -NodeExe $step.Toolchain.NodeExe `
        -NpmCmd $step.Toolchain.NpmCmd `
        -NpmArguments $npmArgs `
        -WorkingDir $PrefixDir `
        -AttemptLogFile $attemptLog `
        -SummaryLogFile $summaryLog `
        -NpmCacheDir $attemptCache `
        -NpmrcPath $isolatedNpmrc `
        -RegistryUrl $step.Registry `
        -MaxSockets $step.MaxSockets `
        -NodeOptions $step.NodeOptions `
        -OpenSslIa32Cap $step.OpenSslIa32Cap `
        -AttemptLabel $step.Label `
        -AttemptNumber $attemptIndex `
        -RuntimeCleanupDir $PrefixDir `
        -SecretsToRedact $SecretsToRedact

      [void]$attempts.Add($res)

      if ($res.ExitCode -eq 0) {
        if ($VerifySuccess) {
          $ver = & $VerifySuccess $PrefixDir
          if (-not $ver.Ok) {
            $missingStr = ($ver.Missing -join ', ')
            $verErrMsg = "OpenClaw installation verification failed: missing required package.json or openclaw.cmd ($missingStr)."
            if ($LogCallback) {
              try { & $LogCallback $verErrMsg } catch { }
            }
            $script:LastOpenClawNpmResult = [pscustomobject]@{
              Success            = $false
              VerificationFailed = $true
              MissingArtifacts   = $ver.Missing
              PrimaryNodeExe     = $toolchains.Primary.NodeExe
              UsedNodeExe        = $step.Toolchain.NodeExe
              UsedNpmCmd         = $step.Toolchain.NpmCmd
              Attempts           = $attempts.ToArray()
              LogFiles           = $attemptLogs.ToArray()
              SummaryLogFile     = $summaryLog
              LastOutput         = $res.Output
              ErrorMessage       = $verErrMsg
            }
            throw 'openclaw-npm-verification-failed'
          }
        }
        # Keep winning attempt cache isolated cleanly; remove only failed attempt caches
        for ($cIdx = 1; $cIdx -lt $attemptIndex; $cIdx++) {
          $failedCacheDir = Join-Path $CacheRootDir ("attempt-$cIdx")
          if (Test-Path -LiteralPath $failedCacheDir) {
            Clear-EmTroLyDirectorySafe -DirPath $failedCacheDir
          }
        }
        $script:LastOpenClawNpmResult = [pscustomobject]@{
          Success            = $true
          VerificationFailed = $false
          MissingArtifacts   = @()
          PrimaryNodeExe     = $toolchains.Primary.NodeExe
          UsedNodeExe        = $step.Toolchain.NodeExe
          UsedNpmCmd         = $step.Toolchain.NpmCmd
          Registry           = $step.Registry
          CacheDir           = $attemptCache
          Attempts           = $attempts.ToArray()
          LogFiles           = $attemptLogs.ToArray()
          SummaryLogFile     = $summaryLog
          LastOutput         = $res.Output
        }
        return $script:LastOpenClawNpmResult
      }

      $lastFailureOutput = $res.Output
      $tailLines = @($res.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 20)
      $tailJoined = ($tailLines -join ' | ')
      if ($LogCallback) {
        try {
          & $LogCallback ("npm install attempt $attemptIndex ($($step.Label), registry=$($step.Registry), maxsockets=$($step.MaxSockets)) failed (exit=$($res.ExitCode)): $tailJoined")
        } catch { }
      }

      if ($CleanNodeModulesOnFailure) {
        Wait-EmTroLyRuntimeProcessesExit -TargetDir $PrefixDir -WaitMs 5000
        $partialModules = Join-Path $PrefixDir 'node_modules'
        if (Test-Path -LiteralPath $partialModules) {
          Clear-EmTroLyDirectorySafe -DirPath $partialModules
        }
        $partialLock = Join-Path $PrefixDir 'package-lock.json'
        if (Test-Path -LiteralPath $partialLock -PathType Leaf) {
          Remove-Item -LiteralPath $partialLock -Force -ErrorAction SilentlyContinue
        }
      }

      $isTlsNow = Test-IsNpmTlsCipherError -LogText $res.Output
      $isCorruptNow = Test-IsNpmCacheOrTarballCorruptError -LogText $res.Output
      if ($isCorruptNow -and (Test-Path -LiteralPath $attemptCache)) {
        Clear-EmTroLyDirectorySafe -DirPath $attemptCache
      }

      if ($isTlsNow -and -not $planExpandedForTls) {
        $planExpandedForTls = $true
        $tlsSteps = New-EmTroLyNpmRetryPlan -Toolchains $toolchains -PrimaryRegistry $PrimaryRegistry -FallbackRegistry $FallbackRegistry -IsTlsError $true
        foreach ($ts in $tlsSteps) {
          if (-not $triedLabels.Contains($ts.Label) -and (@($queue | Where-Object { $_.Label -eq $ts.Label }).Count -eq 0)) {
            [void]$queue.Add($ts)
          }
        }
      } elseif (-not $planExpandedGeneral -and -not $planExpandedForTls) {
        $planExpandedGeneral = $true
        $genSteps = New-EmTroLyNpmRetryPlan -Toolchains $toolchains -PrimaryRegistry $PrimaryRegistry -FallbackRegistry $FallbackRegistry -IsTlsError $false
        foreach ($gs in $genSteps) {
          if (-not $triedLabels.Contains($gs.Label) -and (@($queue | Where-Object { $_.Label -eq $gs.Label }).Count -eq 0)) {
            [void]$queue.Add($gs)
          }
        }
      }
    }
  } finally {
    Remove-Item -LiteralPath $isolatedNpmrc -Force -ErrorAction SilentlyContinue
  }

  $script:LastOpenClawNpmResult = [pscustomobject]@{
    Success            = $false
    VerificationFailed = $false
    MissingArtifacts   = @()
    PrimaryNodeExe     = $toolchains.Primary.NodeExe
    UsedNodeExe        = $toolchains.Primary.NodeExe
    UsedNpmCmd         = $toolchains.Primary.NpmCmd
    Attempts           = $attempts.ToArray()
    LogFiles           = $attemptLogs.ToArray()
    SummaryLogFile     = $summaryLog
    LastOutput         = $lastFailureOutput
    IsTlsError         = (Test-IsNpmTlsCipherError -LogText $lastFailureOutput)
  }
  return $script:LastOpenClawNpmResult
}

function Invoke-OpenClawNpmInstall {
  param(
    [Parameter(Mandatory=$true)][string]$RuntimeDir,
    [Parameter(Mandatory=$true)][string]$OpenClawRoot,
    [string]$OpenClawVersion = '2026.11.4',
    [string]$LogsDir = '',
    [string]$NpmCacheRoot = '',
    [string]$PayloadRoot = '',
    [string]$PrimaryRegistry = 'https://registry.npmjs.org/',
    [string]$FallbackRegistry = 'https://registry.npmmirror.com/',
    [int]$MaxSocketsInitial = 2,
    [int]$RetryDelayBaseSeconds = 2,
    [string[]]$SecretsToRedact = @(),
    $StatusCallback = $null,
    $LogCallback = $null
  )
  [void][IO.Directory]::CreateDirectory($RuntimeDir)
  $resolvedLogsDir = if (-not [string]::IsNullOrWhiteSpace($LogsDir)) { $LogsDir } else { Join-Path $OpenClawRoot 'logs' }
  $resolvedCacheRoot = if (-not [string]::IsNullOrWhiteSpace($NpmCacheRoot)) { $NpmCacheRoot } else { Join-Path $OpenClawRoot 'npm-cache' }

  $pkgPath = Join-Path $RuntimeDir 'package.json'
  if (-not (Test-Path -LiteralPath $pkgPath -PathType Leaf)) {
    $runtimePackage = @{
      name         = 'member-openclaw-runtime'
      version      = '1.0.0'
      private      = $true
      allowScripts = @{
        '@google/genai'    = $true
        esbuild            = $true
        koffi              = $true
        openclaw           = $true
        protobufjs         = $true
        'tree-sitter-bash' = $true
      }
    }
    [IO.File]::WriteAllText($pkgPath, ($runtimePackage | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  }

  $verifyCb = {
    param([string]$TargetPrefix)
    return (Test-OpenClawRuntimeArtifacts -RuntimeDir $TargetPrefix)
  }

  $res = Invoke-EmTroLyNpmPackageWithTlsRetry `
    -PrefixDir $RuntimeDir `
    -Packages @("openclaw@$OpenClawVersion") `
    -CacheRootDir $resolvedCacheRoot `
    -LogsDir $resolvedLogsDir `
    -PayloadRoot $PayloadRoot `
    -OpenClawRoot $OpenClawRoot `
    -PrimaryRegistry $PrimaryRegistry `
    -FallbackRegistry $FallbackRegistry `
    -MaxSocketsInitial $MaxSocketsInitial `
    -RetryDelayBaseSeconds $RetryDelayBaseSeconds `
    -LogFilePrefix 'npm-install' `
    -SecretsToRedact $SecretsToRedact `
    -StatusCallback $StatusCallback `
    -LogCallback $LogCallback `
    -CleanNodeModulesOnFailure `
    -VerifySuccess $verifyCb

  if (-not $res.Success) {
    throw 'Private OpenClaw installation failed.'
  }

  $artifacts = Test-OpenClawRuntimeArtifacts -RuntimeDir $RuntimeDir
  if (-not $artifacts.Ok) {
    throw 'openclaw-npm-verification-failed'
  }
  return $res
}
