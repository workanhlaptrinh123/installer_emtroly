[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][psobject]$Settings,
  [Parameter(Mandatory=$true)][string]$StatusFile,
  [switch]$CheckOnly,
  [ValidateSet('all', 'ide-only', 'extension-only')][string]$ComponentMode = 'all',
  [switch]$AllowUpdateExisting
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ideVersion = '2.7.0'
$ideUrl = 'https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/2.7.0-4507555968450560/windows-x64/Antigravity%20IDE.exe'
$ideHash = '307c7a41b050ffe742fd4dd1045050df1464de219271f74b5f6c269e9e00c822'
$extensionVersion = '26.51111.21308'
$extensionUrl = 'https://open-vsx.org/api/openai/chatgpt/win32-x64/26.51111.21308/file/openai.chatgpt-26.51111.21308@win32-x64.vsix'
$extensionHash = '5abdd18242a77e85e60b8b727231924c4cdf048fdf5c39079e5d811390c3fca8'
$base = Join-Path $env:LOCALAPPDATA 'EmTroLy'
$userData = Join-Path $base 'Antigravity\UserData'
$extensions = Join-Path $base 'Antigravity\Extensions'
$codexHome = Join-Path $base 'Codex'
$jobId = [string]$Settings.job_id
if ($jobId -cnotmatch '^[a-f0-9]{32}$') { throw 'invalid-editor-job' }
$receipt = Join-Path $base 'installer-job.txt'
$resuming = $false
$recoveryBackup = $null
# A dedicated destination lets a retry reuse only the IDE installed by this job.
$appDir = Join-Path $env:LOCALAPPDATA ('Programs\EmTroLy-Antigravity-IDE-' + $jobId)
$editor = Join-Path $appDir 'Antigravity IDE.exe'
$editorCli = Join-Path $appDir 'bin\antigravity-ide.cmd'
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'EmTroLy - Antigravity.lnk'
$programsFolder = if ($env:EMTROLY_TEST_PROGRAMS_DIR) { $env:EMTROLY_TEST_PROGRAMS_DIR } else { [Environment]::GetFolderPath('Programs') }
$startMenuShortcutPath = if ($programsFolder) { Join-Path $programsFolder 'EmTroLy - Antigravity.lnk' } else { '' }
$downloadDir = Join-Path $env:TEMP ('emtroly-editor-' + [guid]::NewGuid().ToString('N'))
$activationProbe = Join-Path $PSScriptRoot 'activation-probe'
$activationTest = Join-Path $activationProbe 'test.js'

function Write-EditorStatus([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($StatusFile)) { return }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
  for ($attempt = 1; $attempt -le 12; $attempt++) {
    $fs = $null
    try {
      $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
      $fs = New-Object System.IO.FileStream($StatusFile, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, $share)
      $fs.SetLength(0)
      if ($bytes.Length -gt 0) { $fs.Write($bytes, 0, $bytes.Length) }
      $fs.Flush()
      return
    } catch {
      if ($attempt -lt 12) { Start-Sleep -Milliseconds 25 }
    } finally {
      if ($null -ne $fs) { try { $fs.Dispose() } catch { } }
    }
  }
}

function Set-PrivateDirectoryAcl([string]$Path) {
  $acl = New-Object Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
  foreach ($identity in @($user, $system)) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, [Security.AccessControl.FileSystemRights]::FullControl, $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
  }
  if (Test-Path -LiteralPath $Path -PathType Container) {
    [IO.Directory]::SetAccessControl($Path, $acl)
  } else {
    [void][IO.Directory]::CreateDirectory($Path, $acl)
  }
}

function New-PrivateDirectory([string]$Path) {
  if (Test-Path -LiteralPath $Path) { throw 'editor-data-exists' }
  Set-PrivateDirectoryAcl $Path
}

function Get-VerifiedDownload([string]$Url, [string]$Path, [string]$Hash) {
  $maxAttempts = if ($env:EMTROLY_DOWNLOAD_RETRIES -match '^[1-5]$') { [int]$env:EMTROLY_DOWNLOAD_RETRIES } else { 3 }
  $legacyTransport = { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path -TimeoutSec 900 }
  $iwrCmd = Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue
  $useLegacy = ($legacyTransport.ToString() -notmatch 'Invoke-WebRequest') -or
    ($iwrCmd -and $iwrCmd.CommandType -eq 'Function') -or
    ($Url -notmatch '^https?://')
  if (-not $useLegacy) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::DefaultConnectionLimit = 16
    [Net.ServicePointManager]::Expect100Continue = $false
  }
  $label = if ($Url -match '\.vsix($|\?)') { 'Codex Extension' } else { 'Antigravity IDE' }
  $partPath = "$Path.part"
  $downloaded = $false
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $resp = $null
    $inStream = $null
    $outStream = $null
    try {
      if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
      if (Test-Path -LiteralPath $partPath -PathType Leaf) { Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue }
      if ($useLegacy) {
        & $legacyTransport
      } else {
        $req = [System.Net.HttpWebRequest]::Create([uri]$Url)
        $req.UserAgent = 'AnhLapTrinh-EmTroLy-Installer/1.0'
        $req.AllowAutoRedirect = $true
        $req.MaximumAutomaticRedirections = 10
        $req.Timeout = 30000
        $req.ReadWriteTimeout = 60000
        $resp = $req.GetResponse()
        $totalBytes = [long]$resp.ContentLength
        $inStream = $resp.GetResponseStream()
        $outStream = New-Object System.IO.FileStream($partPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read, 262144)
        $buf = New-Object byte[] 262144
        $readTotal = 0L
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $lastTick = -2000L
        while (($n = $inStream.Read($buf, 0, $buf.Length)) -gt 0) {
          $outStream.Write($buf, 0, $n)
          $readTotal += $n
          if (($sw.ElapsedMilliseconds - $lastTick) -ge 450) {
            $lastTick = $sw.ElapsedMilliseconds
            if ((Get-Command Write-EditorStatus -ErrorAction SilentlyContinue) -and $StatusFile) {
              $mbCur = [Math]::Round($readTotal / 1MB, 1)
              $spd = [Math]::Round(($readTotal / 1MB) / [Math]::Max(0.1, $sw.Elapsed.TotalSeconds), 1)
              if ($totalBytes -gt 0) {
                $pct = [Math]::Min(99, [int][Math]::Floor(($readTotal * 100.0) / $totalBytes))
                $mbMax = [Math]::Round($totalBytes / 1MB, 0)
                try { Write-EditorStatus "Đang tải $label... $pct% ($mbCur / $mbMax MB · $spd MB/s)" } catch { }
              } else {
                try { Write-EditorStatus "Đang tải $label... ($mbCur MB · $spd MB/s)" } catch { }
              }
            }
          }
        }
        $outStream.Flush()
        $outStream.Dispose(); $outStream = $null
        $inStream.Dispose(); $inStream = $null
        $resp.Close(); $resp = $null
        Move-Item -LiteralPath $partPath -Destination $Path -Force
      }
      $downloaded = $true
      break
    } catch {
      if ($outStream) { try { $outStream.Dispose() } catch { } }
      if ($inStream) { try { $inStream.Dispose() } catch { } }
      if ($resp) { try { $resp.Close() } catch { } }
      $curlExe = Join-Path $env:SystemRoot 'System32\curl.exe'
      if (-not $useLegacy -and (Test-Path -LiteralPath $curlExe -PathType Leaf)) {
        try {
          if ((Get-Command Write-EditorStatus -ErrorAction SilentlyContinue) -and $StatusFile) {
            try { Write-EditorStatus "Kết nối tải $label bị gián đoạn — đang tải nối tiếp bằng TLS 1.2..." } catch { }
          }
          & $curlExe --fail --location --http1.1 --tlsv1.2 --retry 2 --connect-timeout 30 --max-time 900 -A 'AnhLapTrinh-EmTroLy-Installer/1.0' -C - -o $partPath $Url *> $null
          if ($LASTEXITCODE -ne 0) {
            if (Test-Path -LiteralPath $partPath -PathType Leaf) { Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue }
            & $curlExe --fail --location --http1.1 --tlsv1.2 --retry 2 --connect-timeout 30 --max-time 900 -A 'AnhLapTrinh-EmTroLy-Installer/1.0' -o $partPath $Url *> $null
          }
          if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $partPath -PathType Leaf)) {
            if ((Get-FileHash -LiteralPath $partPath -Algorithm SHA256).Hash -ieq $Hash) {
              Move-Item -LiteralPath $partPath -Destination $Path -Force
              $downloaded = $true
              break
            }
          }
        } catch { }
      }
      if (Test-Path -LiteralPath $partPath -PathType Leaf) { Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue }
      if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
      if ($attempt -lt $maxAttempts) { Start-Sleep -Milliseconds (500 * $attempt) }
    }
  }
  if (-not $downloaded) { throw 'editor-download-failed' }
  if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Hash) {
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    throw 'editor-download-checksum'
  }
}

function Invoke-HiddenProcess([string]$Executable, [string]$Arguments, [int]$TimeoutSeconds) {
  $spCmd = Get-Command Start-Process -ErrorAction SilentlyContinue
  if ($spCmd -and $spCmd.CommandType -eq 'Function') {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Hidden -PassThru
  } else {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.RedirectStandardInput = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    try { $process.StandardInput.Close() } catch { }
  }
  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
    try { if (-not $process.HasExited) { $process.Kill() } } catch { }
    throw 'editor-process-timeout'
  }
  return $process.ExitCode
}

function Quote-Cmd([string]$Value) {
  if ($Value -match '[\r\n"%]') { throw 'editor-invalid-path' }
  return '"' + $Value + '"'
}

function Get-EditorRegistryDirectories($Entry) {
  $directories = @()
  $location = [Environment]::ExpandEnvironmentVariables(([string]$Entry.InstallLocation).Trim().Trim('"'))
  if ($location -and [IO.Path]::IsPathRooted($location)) { $directories += $location }
  foreach ($value in @([string]$Entry.DisplayIcon, [string]$Entry.UninstallString)) {
    $expanded = [Environment]::ExpandEnvironmentVariables($value.Trim())
    if ($expanded -match '^"([^"\r\n]+\.exe)"' -or $expanded -match '^(.+?\.exe)(?:,\s*-?\d+|\s|$)') {
      $executable = $Matches[1].Trim()
      if ([IO.Path]::IsPathRooted($executable)) { $directories += (Split-Path -Parent $executable) }
    }
  }
  return @($directories | Where-Object { $_ } | Select-Object -Unique)
}

function Get-PrivateEditorAppDirectories {
  $programsRoot = Join-Path $env:LOCALAPPDATA 'Programs'
  if (-not (Test-Path -LiteralPath $programsRoot -PathType Container)) { return @() }
  return @(Get-ChildItem -LiteralPath $programsRoot -Directory -Filter 'EmTroLy-Antigravity-IDE-*' -ErrorAction SilentlyContinue)
}

function Resolve-EditorBundle([string]$Root, [bool]$RequirePinnedVersion = $false) {
  if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }
  $productPath = Join-Path $Root 'resources\app\product.json'
  if (-not (Test-Path -LiteralPath $productPath -PathType Leaf)) { return $null }
  $pairs = @(
    @{ Exe = 'Antigravity IDE.exe'; Cli = 'bin\antigravity-ide.cmd' },
    @{ Exe = 'Antigravity.exe'; Cli = 'bin\antigravity.cmd' }
  )
  $matchedExe = $null
  $matchedCli = $null
  foreach ($pair in $pairs) {
    $candidateExe = Join-Path $Root $pair.Exe
    $candidateCli = Join-Path $Root $pair.Cli
    if ((Test-Path -LiteralPath $candidateExe -PathType Leaf) -and (Test-Path -LiteralPath $candidateCli -PathType Leaf)) {
      $matchedExe = $candidateExe
      $matchedCli = $candidateCli
      break
    }
  }
  if (-not $matchedExe) { return $null }
  try {
    $product = Get-Content -LiteralPath $productPath -Raw | ConvertFrom-Json
    if ($product.applicationName -notin @('antigravity-ide', 'antigravity')) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$product.version)) { return $null }
    if ($RequirePinnedVersion -and $product.version -ne '1.107.0') { return $null }
    return [pscustomobject]@{
      AppDir    = $Root
      Editor    = $matchedExe
      EditorCli = $matchedCli
      Version   = [string]$product.version
    }
  } catch {
    return $null
  }
}

function Test-EditorApplicationComplete([string]$Root) {
  return ($null -ne (Resolve-EditorBundle -Root $Root -RequirePinnedVersion $true))
}

function Test-EditorShortcutComplete([string]$Root, [string]$AppRoot) {
  $candidateShortcuts = @($shortcutPath)
  if ($startMenuShortcutPath) { $candidateShortcuts += $startMenuShortcutPath }
  $existingShortcut = @($candidateShortcuts | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1)
  if ($existingShortcut.Count -eq 0) { return $false }
  try {
    $bundle = Resolve-EditorBundle -Root $AppRoot
    if (-not $bundle) { return $false }
    $launchPath = Join-Path $Root 'launch-antigravity.vbs'
    $launch = [IO.File]::ReadAllText($launchPath, [Text.Encoding]::Unicode)
    if ($launch -notmatch [regex]::Escape($bundle.Editor) -or
        $launch -notmatch 'CODEX_HOME' -or
        $launch -notmatch 'procEnv\.Remove' -or
        $launch -match 'ELECTRON_RUN_AS_NODE"\)\s*=\s*""' -or
        $launch -notmatch '--user-data-dir' -or
        $launch -notmatch '--extensions-dir') { return $false }
    $shell = New-Object -ComObject WScript.Shell
    $saved = $shell.CreateShortcut($existingShortcut[0])
    return $saved.TargetPath -ieq (Join-Path $env:SystemRoot 'System32\wscript.exe') -and
      $saved.Arguments -match [regex]::Escape($launchPath) -and
      $saved.WorkingDirectory -ieq $Root
  } catch {
    return $false
  }
}

function Test-EditorDataComplete([string]$Root) {
  foreach ($relative in @('installer-job.txt', 'Codex\config.toml', 'Codex\auth.json',
                           'Antigravity\UserData\User\settings.json', 'launch-antigravity.vbs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $relative) -PathType Leaf)) { return $false }
  }
  try {
    $savedJob = [IO.File]::ReadAllText((Join-Path $Root 'installer-job.txt')).Trim()
    if ($savedJob -notmatch '^[a-f0-9]{32}$') { return $false }
    $config = [IO.File]::ReadAllText((Join-Path $Root 'Codex\config.toml'))
    if ($config -notmatch 'base_url = "https://codex\.anhlaptrinh\.vn/v1"' -or
        $config -notmatch 'requires_openai_auth = true') { return $false }
    $auth = [IO.File]::ReadAllText((Join-Path $Root 'Codex\auth.json')) | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$auth.OPENAI_API_KEY)) { return $false }
    [void]([IO.File]::ReadAllText((Join-Path $Root 'Antigravity\UserData\User\settings.json')) | ConvertFrom-Json)
  } catch {
    return $false
  }
  $extensionsRoot = Join-Path $Root 'Antigravity\Extensions'
  $installed = @(Get-ChildItem -LiteralPath $extensionsRoot -Directory -Filter 'openai.chatgpt-*' -ErrorAction SilentlyContinue | Where-Object {
    $manifest = Join-Path $_.FullName 'package.json'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $false }
    try {
      $package = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
      return $package.publisher -eq 'openai' -and $package.name -eq 'chatgpt' -and
        $package.version -eq $extensionVersion -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'bin\windows-x86_64\codex.exe') -PathType Leaf)
    } catch {
      return $false
    }
  })
  if ($installed.Count -ne 1) { return $false }
  $recordedAppFile = Join-Path $Root 'editor-app-path.txt'
  if (Test-Path -LiteralPath $recordedAppFile -PathType Leaf) {
    $recordedApp = ([IO.File]::ReadAllText($recordedAppFile)).Trim()
    if ($recordedApp -and ($null -ne (Resolve-EditorBundle -Root $recordedApp)) -and (Test-EditorShortcutComplete $Root $recordedApp)) {
      return $true
    }
  }
  foreach ($app in @(Get-PrivateEditorAppDirectories)) {
    if (Test-EditorApplicationComplete $app.FullName -and Test-EditorShortcutComplete $Root $app.FullName) { return $true }
  }
  return $false
}

function Test-GoogleAuthenticodeSignature([string]$Path, [string]$ExpectedHash, [switch]$AllowUnknownWithGoogleSigner) {
  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  $subject = [string]$signature.SignerCertificate.Subject
  if ([string]::IsNullOrWhiteSpace($subject) -or $subject -notmatch '(?i)Google LLC') { return $false }
  if ($signature.Status -eq 'Valid') { return $true }
  # Some Windows installations cannot build Google's certificate chain offline.
  # The pinned hash limits this fallback to the exact official binary.
  if ($signature.Status -eq 'Unknown') {
    if ($ExpectedHash) {
      return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ieq $ExpectedHash
    }
    return [bool]$AllowUnknownWithGoogleSigner
  }
  return $false
}

function Get-EditorRecoveryBackupPath {
  if ($script:recoveryBackup) { return $script:recoveryBackup }
  do {
    $candidate = Join-Path (Split-Path -Parent $base) ('EmTroLy.failed-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  } while (Test-Path -LiteralPath $candidate)
  $script:recoveryBackup = $candidate
  return $candidate
}

function Move-EditorRecoveryItem([string]$Path, [string]$RelativePath) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if ($CheckOnly) { return }
  $backup = Get-EditorRecoveryBackupPath
  $destination = Join-Path $backup $RelativePath
  try {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    Move-Item -LiteralPath $Path -Destination $destination -ErrorAction Stop
  } catch {
    throw 'editor-data-recovery-failed'
  }
}

$isModularUpdate = ([bool]$AllowUpdateExisting -or $ComponentMode -ne 'all')
if (Test-Path -LiteralPath $base -PathType Leaf) { throw 'editor-data-exists' }
if (Test-Path -LiteralPath $base -PathType Container) {
  $savedJob = if (Test-Path -LiteralPath $receipt -PathType Leaf) { [IO.File]::ReadAllText($receipt) } else { '' }
  if ($isModularUpdate) {
    $resuming = $true
  } elseif ($savedJob -ceq $jobId) {
    $resuming = $true
  } elseif (Test-EditorDataComplete -Root $base) {
    throw 'editor-data-exists'
  } elseif ($CheckOnly) {
    return
  } else {
    $recoveryBackup = Get-EditorRecoveryBackupPath
    try {
      Move-Item -LiteralPath $base -Destination $recoveryBackup -ErrorAction Stop
    } catch {
      # Legacy EmTroLy\UI may be locked if launched from an older Desktop shortcut; move all editor items safely
      $children = @(Get-ChildItem -LiteralPath $base -Force -ErrorAction SilentlyContinue)
      $nonUi = @($children | Where-Object { $_.Name -ine 'UI' })
      if ($children.Count -gt 0 -and ($children.Count -gt $nonUi.Count)) {
        try {
          [void][IO.Directory]::CreateDirectory($recoveryBackup)
          foreach ($ch in $nonUi) {
            Move-Item -LiteralPath $ch.FullName -Destination (Join-Path $recoveryBackup $ch.Name) -ErrorAction Stop
          }
        } catch {
          throw 'editor-data-recovery-failed'
        }
      } else {
        throw 'editor-data-recovery-failed'
      }
    }
  }
}

$existingPrivateValidApp = $null
foreach ($privateApp in @(Get-PrivateEditorAppDirectories)) {
  $isCurrentApp = $privateApp.FullName.TrimEnd('\') -ieq $appDir.TrimEnd('\')
  if ($isModularUpdate -and (Test-EditorApplicationComplete $privateApp.FullName)) {
    if (-not $existingPrivateValidApp) { $existingPrivateValidApp = $privateApp.FullName }
    continue
  }
  if ($resuming -and $isCurrentApp -and (Test-EditorApplicationComplete $privateApp.FullName)) { continue }
  Move-EditorRecoveryItem -Path $privateApp.FullName -RelativePath ('Programs\' + $privateApp.Name)
}

function Test-EditorInstallation([string]$Editor) {
  $appDir = Split-Path -Parent $Editor
  $editorCli = Join-Path $appDir 'bin\antigravity-ide.cmd'
  if (-not (Test-Path -LiteralPath $editor -PathType Leaf) -or -not (Test-Path -LiteralPath $editorCli -PathType Leaf)) { throw 'editor-cli-missing' }
  $productPath = Join-Path $appDir 'resources\app\product.json'
  if (-not (Test-Path -LiteralPath $productPath -PathType Leaf)) { throw 'editor-version-unsupported' }
  $product = Get-Content -LiteralPath $productPath -Raw | ConvertFrom-Json
  if ($product.applicationName -ne 'antigravity-ide' -or $product.version -ne '1.107.0') { throw 'editor-version-unsupported' }
}

function Get-EditorRegistryEntries {
  $uninstallKeys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
  $appId = '{AA73B3E3-C6C8-45C8-B1DC-4AE56C751432}_is1'
  Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^Antigravity IDE' -or $_.PSChildName -eq $appId }
}

if ($env:OS -ne 'Windows_NT') { throw 'editor-windows-required' }
if (([string]$Settings.base_url).TrimEnd('/') -cne 'https://codex.anhlaptrinh.vn/v1') { throw 'editor-provider-unsupported' }
if ([string]::IsNullOrWhiteSpace([string]$Settings.ai_api_key)) { throw 'editor-api-key-missing' }
if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\wscript.exe') -PathType Leaf)) { throw 'editor-desktop-missing' }
if (-not (Test-Path -LiteralPath (Split-Path -Parent $shortcutPath) -PathType Container)) {
  if ($startMenuShortcutPath -and $env:EMTROLY_DISABLE_STARTMENU_FALLBACK -ne '1' -and (Test-Path -LiteralPath (Split-Path -Parent $startMenuShortcutPath) -PathType Container)) {
    $shortcutPath = $startMenuShortcutPath
  } else {
    throw 'editor-desktop-missing'
  }
}
foreach ($path in @($editor, $editorCli, $userData, $extensions, $codexHome, $downloadDir, $base, $activationProbe, $activationTest)) { [void](Quote-Cmd $path) }
foreach ($file in @('test.js', 'extension.js', 'package.json')) {
  if (-not (Test-Path -LiteralPath (Join-Path $activationProbe $file) -PathType Leaf)) { throw 'editor-activation-missing' }
}
$reusedBundle = $null
if ($isModularUpdate) {
  $recordedAppFileExisting = Join-Path $base 'editor-app-path.txt'
  if (Test-Path -LiteralPath $recordedAppFileExisting -PathType Leaf) {
    $recAppDir = ([IO.File]::ReadAllText($recordedAppFileExisting)).Trim()
    if ($recAppDir) { $reusedBundle = Resolve-EditorBundle -Root $recAppDir }
  }
  if (-not $reusedBundle -and $existingPrivateValidApp) {
    $reusedBundle = Resolve-EditorBundle -Root $existingPrivateValidApp
  }
}
foreach ($programDirectory in @((Join-Path $env:LOCALAPPDATA 'Programs'), $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
  if ($reusedBundle) { break }
  if (-not $programDirectory) { continue }
  foreach ($folderName in @('Antigravity IDE', 'Antigravity')) {
    $candidateDir = Join-Path $programDirectory $folderName
    foreach ($exeName in @('Antigravity IDE.exe', 'Antigravity.exe')) {
      if (Test-Path -LiteralPath (Join-Path $candidateDir $exeName) -PathType Leaf) {
        $bundle = Resolve-EditorBundle -Root $candidateDir
        if (-not $bundle) { throw 'editor-version-unsupported' }
        $reusedBundle = $bundle
        break
      }
    }
    if ($reusedBundle) { break }
  }
  if ($reusedBundle) { break }
}
$existing = @(Get-EditorRegistryEntries)
foreach ($entry in $existing) {
  $directories = @(Get-EditorRegistryDirectories $entry)
  if ($directories.Count -eq 0 -and -not $reusedBundle) { throw 'editor-registry-ambiguous' }
  foreach ($directory in $directories) {
    $privatePrefix = (Join-Path $env:LOCALAPPDATA 'Programs\EmTroLy-Antigravity-IDE-').TrimEnd('\')
    if ($directory.TrimEnd('\') -ieq $appDir.TrimEnd('\') -or
        $directory.TrimEnd('\') -like ($privatePrefix + '*')) { continue }
    foreach ($name in @('Antigravity IDE.exe', 'Antigravity.exe')) {
      if (Test-Path -LiteralPath (Join-Path $directory $name) -PathType Leaf) {
        if (-not $reusedBundle) {
          $bundle = Resolve-EditorBundle -Root $directory
          if (-not $bundle) { throw 'editor-version-unsupported' }
          $reusedBundle = $bundle
        }
        break
      }
    }
  }
}
$reusingExistingEditor = ($null -ne $reusedBundle)
if ($reusingExistingEditor) {
  $appDir = $reusedBundle.AppDir
  $editor = $reusedBundle.Editor
  $editorCli = $reusedBundle.EditorCli
  foreach ($reusedPath in @($appDir, $editor, $editorCli)) { [void](Quote-Cmd $reusedPath) }
} elseif ($ComponentMode -eq 'extension-only') {
  throw 'editor-ide-missing'
}
if ($CheckOnly) { return }

$oldCodexHome = $env:CODEX_HOME
$oldApiKey = $env:OPENAI_API_KEY
$oldIpcHook = $env:VSCODE_IPC_HOOK_CLI
$oldElectronNode = $env:ELECTRON_RUN_AS_NODE
$oldNodeOptions = $env:NODE_OPTIONS
$oldActivationMarker = $env:EMTROLY_CODEX_ACTIVATION_MARKER
try {
  if ($recoveryBackup) { Write-EditorStatus 'Đã lưu thư mục Em Trợ Lý cài dở; tiếp tục cài Codex trên dữ liệu mới...' }
  if (-not $resuming) {
    if (Test-Path -LiteralPath $base -PathType Container) {
      Set-PrivateDirectoryAcl $base
    } else {
      New-PrivateDirectory $base
    }
    [IO.File]::WriteAllText($receipt, $jobId)
  } else {
    if (-not (Test-Path -LiteralPath $base -PathType Container)) {
      New-PrivateDirectory $base
    } else {
      Set-PrivateDirectoryAcl $base
    }
    if (-not (Test-Path -LiteralPath $receipt -PathType Leaf)) {
      [IO.File]::WriteAllText($receipt, $jobId)
    }
  }
  New-PrivateDirectory $downloadDir
  if ($reusingExistingEditor) {
    Write-EditorStatus 'Đã phát hiện Antigravity IDE có sẵn trên máy; đang dùng để cài Extension Codex và cấu hình riêng...'
  } else {
    if (-not (Test-Path -LiteralPath $editor -PathType Leaf)) {
      Write-EditorStatus 'Đang tải Antigravity IDE chính thức (khoảng 190 MB)...'
      $setup = Join-Path $downloadDir 'antigravity-ide-setup.exe'
      Get-VerifiedDownload -Url $ideUrl -Path $setup -Hash $ideHash
      if (-not (Test-GoogleAuthenticodeSignature -Path $setup -ExpectedHash $ideHash)) { throw 'editor-installer-signature-invalid' }
      Write-EditorStatus 'Đang cài Antigravity IDE...'
      $setupArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOCLOSEAPPLICATIONS /NORESTARTAPPLICATIONS /SP- /MERGETASKS="!runcode" /DIR=' + (Quote-Cmd $appDir)
      if ((Invoke-HiddenProcess $setup $setupArgs 1200) -ne 0) { throw 'editor-install-failed' }
    }
    Test-EditorInstallation $editor
  }
  [IO.File]::WriteAllText((Join-Path $base 'editor-app-path.txt'), $appDir, (New-Object Text.UTF8Encoding($false)))

  Write-EditorStatus 'Đang cấu hình khóa API cho Codex trong thư mục riêng của Em Trợ Lý…'
  foreach ($folder in @($userData, $extensions, $codexHome)) { [void][IO.Directory]::CreateDirectory($folder) }
  $model = [string]$Settings.model
  if ($model -notmatch '^[A-Za-z0-9._-]+$') { throw 'editor-invalid-model' }
  $config = @"
model_provider = "router"
model = "$model"
model_context_window = 272000
model_auto_compact_token_limit = 200000
cli_auth_credentials_store = "file"

[model_providers.router]
name = "router"
base_url = "https://codex.anhlaptrinh.vn/v1"
wire_api = "responses"
requires_openai_auth = true
"@
  [IO.File]::WriteAllText((Join-Path $codexHome 'config.toml'), $config, (New-Object Text.UTF8Encoding($false)))
  $auth = @{ OPENAI_API_KEY = [string]$Settings.ai_api_key } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText((Join-Path $codexHome 'auth.json'), $auth, (New-Object Text.UTF8Encoding($false)))
  $editorSettingsDir = Join-Path $userData 'User'
  [void][IO.Directory]::CreateDirectory($editorSettingsDir)
  $editorSettings = @{
    'extensions.autoUpdate' = $false
    'extensions.autoCheckUpdates' = $false
    'extensions.ignoreRecommendations' = $true
    'update.mode' = 'none'
    'chatgpt.runCodexInWindowsSubsystemForLinux' = $false
  } | ConvertTo-Json
  [IO.File]::WriteAllText((Join-Path $editorSettingsDir 'settings.json'), $editorSettings, (New-Object Text.UTF8Encoding($false)))

  if ($ComponentMode -ne 'ide-only') {
    $vsix = Join-Path $base ('codex-' + $extensionVersion + '.vsix')
    if (-not (Test-Path -LiteralPath $vsix -PathType Leaf) -or (Get-FileHash -LiteralPath $vsix -Algorithm SHA256).Hash -ine $extensionHash) {
      Write-EditorStatus 'Đang tải Codex Extension (khoảng 370 MB)...'
      $part = Join-Path $downloadDir 'codex.vsix'
      Get-VerifiedDownload -Url $extensionUrl -Path $part -Hash $extensionHash
      Move-Item -LiteralPath $part -Destination $vsix -Force
    }
    $env:CODEX_HOME = $codexHome
    $env:OPENAI_API_KEY = $null
    $env:VSCODE_IPC_HOOK_CLI = $null
    $env:ELECTRON_RUN_AS_NODE = $null
    $env:NODE_OPTIONS = $null
    Write-EditorStatus 'Đang cài Codex Extension vào thư mục riêng...'
    $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $extLog = Join-Path $downloadDir 'ext-install.log'
    $cliArgs = '/d /v:off /s /c "chcp 65001 >nul && ' + (Quote-Cmd $editorCli) + ' --user-data-dir ' + (Quote-Cmd $userData) + ' --extensions-dir ' + (Quote-Cmd $extensions) + ' --install-extension ' + (Quote-Cmd $vsix) + ' --force --do-not-include-pack-dependencies > ' + (Quote-Cmd $extLog) + ' 2>&1"'
    $extInstalledOk = $false
    for ($extAttempt = 1; $extAttempt -le 3; $extAttempt++) {
      if ((Invoke-HiddenProcess $cmd $cliArgs 900) -eq 0) {
        $extInstalledOk = $true
        break
      }
      if ($extAttempt -lt 3) {
        Start-Sleep -Seconds 3
      }
    }
    if (-not $extInstalledOk) { throw 'editor-extension-install-failed' }
    $installed = @(Get-ChildItem -LiteralPath $extensions -Directory -Filter 'openai.chatgpt-*' | Where-Object {
      $manifest = Join-Path $_.FullName 'package.json'
      if (-not (Test-Path -LiteralPath $manifest)) { return $false }
      try { $package = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json; return $package.publisher -eq 'openai' -and $package.name -eq 'chatgpt' -and $package.version -eq $extensionVersion } catch { return $false }
    })
    if ($installed.Count -ne 1) { throw 'editor-extension-verification-failed' }
    $codex = Join-Path $installed[0].FullName 'bin\windows-x86_64\codex.exe'
    if (-not (Test-Path -LiteralPath $codex -PathType Leaf)) { throw 'editor-codex-missing' }

    Write-EditorStatus 'Đang kiểm tra Codex và API bằng một yêu cầu thử...'
    $probeArgs = 'exec --skip-git-repo-check --sandbox read-only ' + (Quote-Cmd 'Reply with OK only.')
    $codexProbeOk = $false
    $codexProbeDelayMs = if ($env:TEST_FAIL_CODEX) { 100 } else { 2000 }
    for ($probeAttempt = 1; $probeAttempt -le 3; $probeAttempt++) {
      if ((Invoke-HiddenProcess $codex $probeArgs 180) -eq 0) {
        $codexProbeOk = $true
        break
      }
      if ($probeAttempt -lt 3) { Start-Sleep -Milliseconds ($codexProbeDelayMs * $probeAttempt) }
    }
    if (-not $codexProbeOk) { throw 'editor-codex-probe-failed' }

    Write-EditorStatus 'Đang kiểm tra Codex Extension trong Antigravity IDE...'
    $activationMarker = Join-Path $downloadDir 'activation.ok'
    $env:EMTROLY_CODEX_ACTIVATION_MARKER = $activationMarker
    $activationOk = $false
    $gpuFlagsList = @('--disable-gpu', '--disable-gpu --disable-software-rasterizer')
    for ($actAttempt = 0; $actAttempt -lt $gpuFlagsList.Count; $actAttempt++) {
      if (Test-Path -LiteralPath $activationMarker -PathType Leaf) {
        Remove-Item -LiteralPath $activationMarker -Force -ErrorAction SilentlyContinue
      }
      $activationArgs = $gpuFlagsList[$actAttempt] + ' --skip-welcome --disable-workspace-trust --user-data-dir ' + (Quote-Cmd $userData) +
        ' --extensions-dir ' + (Quote-Cmd $extensions) + ' --extensionDevelopmentPath ' + (Quote-Cmd $activationProbe) +
        ' --extensionTestsPath ' + (Quote-Cmd $activationTest) + ' ' + (Quote-Cmd $downloadDir)
      if ((Invoke-HiddenProcess $editor $activationArgs 180) -eq 0 -and
          (Test-Path -LiteralPath $activationMarker -PathType Leaf) -and
          ([IO.File]::ReadAllText($activationMarker) -ceq 'ok')) {
        $activationOk = $true
        break
      }
      if ($actAttempt -lt ($gpuFlagsList.Count - 1)) { Start-Sleep -Seconds 2 }
    }
    if (-not $activationOk) { throw 'editor-activation-failed' }
  }

  $hasInstalledCodexExt = @(Get-ChildItem -LiteralPath $extensions -Directory -Filter 'openai.chatgpt-*' -ErrorAction SilentlyContinue).Count -gt 0
  if ($ComponentMode -ne 'ide-only' -or $hasInstalledCodexExt) {
    $launchPath = Join-Path $base 'launch-antigravity.vbs'
    $script = @"
Option Explicit
Dim shell, procEnv, name, command
Set shell = CreateObject("WScript.Shell")
Set procEnv = shell.Environment("PROCESS")
procEnv("CODEX_HOME") = "$($codexHome.Replace('"','""'))"
On Error Resume Next
For Each name In Array("OPENAI_API_KEY", "VSCODE_IPC_HOOK_CLI", "ELECTRON_RUN_AS_NODE", "NODE_OPTIONS", "VSCODE_DEV")
  procEnv.Remove name
Next
On Error GoTo 0
shell.CurrentDirectory = "$($appDir.Replace('"','""'))"
command = Chr(34) & "$($editor.Replace('"','""'))" & Chr(34) & _
  " --user-data-dir " & Chr(34) & "$($userData.Replace('"','""'))" & Chr(34) & _
  " --extensions-dir " & Chr(34) & "$($extensions.Replace('"','""'))" & Chr(34) & _
  " --new-window"
shell.Run command, 1, False
Set procEnv = Nothing
Set shell = Nothing
"@
    [IO.File]::WriteAllText($launchPath, $script, [Text.Encoding]::Unicode)
    $shell = New-Object -ComObject WScript.Shell
    $temporaryShortcut = Join-Path $downloadDir 'antigravity.lnk'
    $shortcut = $shell.CreateShortcut($temporaryShortcut)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $shortcut.Arguments = '//B //Nologo ' + (Quote-Cmd $launchPath)
    $shortcut.WorkingDirectory = $base
    $shortcut.IconLocation = $editor + ',0'
    $shortcut.Description = 'Em Trợ Lý - Antigravity IDE và Codex riêng'
    $shortcut.Save()
    $shortcutMoved = $false
    for ($scTry = 1; $scTry -le 3; $scTry++) {
      try {
        if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
        [IO.File]::Move($temporaryShortcut, $shortcutPath)
        $shortcutMoved = $true
        break
      } catch {
        if ($scTry -lt 3) { Start-Sleep -Milliseconds (400 * $scTry) }
      }
    }
    if (-not $shortcutMoved -and $startMenuShortcutPath -and ($shortcutPath -ine $startMenuShortcutPath) -and $env:EMTROLY_DISABLE_STARTMENU_FALLBACK -ne '1' -and (Test-Path -LiteralPath (Split-Path -Parent $startMenuShortcutPath) -PathType Container)) {
      try {
        if (Test-Path -LiteralPath $startMenuShortcutPath) { Remove-Item -LiteralPath $startMenuShortcutPath -Force }
        [IO.File]::Move($temporaryShortcut, $startMenuShortcutPath)
        $shortcutPath = $startMenuShortcutPath
        $shortcutMoved = $true
      } catch { }
    }
    if (-not $shortcutMoved) { throw 'editor-shortcut-failed' }
    $saved = $shell.CreateShortcut($shortcutPath)
    if ($saved.TargetPath -ine (Join-Path $env:SystemRoot 'System32\wscript.exe') -or
        $saved.Arguments -cne ('//B //Nologo ' + (Quote-Cmd $launchPath)) -or
        $saved.WorkingDirectory -ine $base) { throw 'editor-shortcut-failed' }
  }
  if ($ComponentMode -ne 'ide-only' -and $vsix -and (Test-Path -LiteralPath $vsix -PathType Leaf)) {
    Remove-Item -LiteralPath $vsix -Force -ErrorAction SilentlyContinue
  }
} finally {
  $env:CODEX_HOME = $oldCodexHome
  $env:OPENAI_API_KEY = $oldApiKey
  $env:VSCODE_IPC_HOOK_CLI = $oldIpcHook
  $env:ELECTRON_RUN_AS_NODE = $oldElectronNode
  $env:NODE_OPTIONS = $oldNodeOptions
  $env:EMTROLY_CODEX_ACTIVATION_MARKER = $oldActivationMarker
  if (Test-Path -LiteralPath $downloadDir) { Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue }
}
