[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][psobject]$Settings,
  [Parameter(Mandatory=$true)][string]$StatusFile,
  [switch]$CheckOnly
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
$downloadDir = Join-Path $env:TEMP ('emtroly-editor-' + [guid]::NewGuid().ToString('N'))
$activationProbe = Join-Path $PSScriptRoot 'activation-probe'
$activationTest = Join-Path $activationProbe 'test.js'

function Write-EditorStatus([string]$Text) {
  [IO.File]::WriteAllText($StatusFile, $Text, (New-Object Text.UTF8Encoding($false)))
}

function New-PrivateDirectory([string]$Path) {
  if (Test-Path -LiteralPath $Path) { throw 'editor-data-exists' }
  $acl = New-Object Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
  foreach ($identity in @($user, $system)) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, [Security.AccessControl.FileSystemRights]::FullControl, $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
  }
  [void][IO.Directory]::CreateDirectory($Path, $acl)
}

function Get-VerifiedDownload([string]$Url, [string]$Path, [string]$Hash) {
  try { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path -TimeoutSec 900 } catch { throw 'editor-download-failed' }
  if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Hash) { throw 'editor-download-checksum' }
}

function Invoke-HiddenProcess([string]$Executable, [string]$Arguments, [int]$TimeoutSeconds) {
  $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Hidden -PassThru
  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
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

function Test-EditorApplicationComplete([string]$Root) {
  $editorPath = Join-Path $Root 'Antigravity IDE.exe'
  $editorCliPath = Join-Path $Root 'bin\antigravity-ide.cmd'
  $productPath = Join-Path $Root 'resources\app\product.json'
  if (-not (Test-Path -LiteralPath $editorPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $editorCliPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $productPath -PathType Leaf)) { return $false }
  try {
    $product = Get-Content -LiteralPath $productPath -Raw | ConvertFrom-Json
    return $product.applicationName -eq 'antigravity-ide' -and $product.version -eq '1.107.0'
  } catch {
    return $false
  }
}

function Test-EditorShortcutComplete([string]$Root, [string]$AppRoot) {
  if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) { return $false }
  try {
    $launchPath = Join-Path $Root 'launch-antigravity.vbs'
    $launch = [IO.File]::ReadAllText($launchPath, [Text.Encoding]::Unicode)
    $editorPath = Join-Path $AppRoot 'Antigravity IDE.exe'
    if ($launch -notmatch [regex]::Escape($editorPath) -or
        $launch -notmatch 'CODEX_HOME' -or
        $launch -notmatch '--user-data-dir' -or
        $launch -notmatch '--extensions-dir') { return $false }
    $shell = New-Object -ComObject WScript.Shell
    $saved = $shell.CreateShortcut($shortcutPath)
    return $saved.TargetPath -ine (Join-Path $env:SystemRoot 'System32\wscript.exe') -and
      $saved.Arguments -match [regex]::Escape($launchPath) -and
      $saved.WorkingDirectory -ine $Root
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

if (Test-Path -LiteralPath $base -PathType Leaf) { throw 'editor-data-exists' }
if (Test-Path -LiteralPath $base -PathType Container) {
  $savedJob = if (Test-Path -LiteralPath $receipt -PathType Leaf) { [IO.File]::ReadAllText($receipt) } else { '' }
  if ($savedJob -ceq $jobId) {
    $resuming = $true
  } elseif (Test-EditorDataComplete -Root $base) {
    throw 'editor-data-exists'
  } elseif ($CheckOnly) {
    return
  } else {
    $recoveryBackup = Get-EditorRecoveryBackupPath
    try { Move-Item -LiteralPath $base -Destination $recoveryBackup -ErrorAction Stop } catch { throw 'editor-data-recovery-failed' }
  }
}

foreach ($privateApp in @(Get-PrivateEditorAppDirectories)) {
  $isCurrentApp = $privateApp.FullName.TrimEnd('\') -ieq $appDir.TrimEnd('\')
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
if (-not (Test-Path -LiteralPath (Split-Path -Parent $shortcutPath) -PathType Container) -or
    -not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\wscript.exe') -PathType Leaf)) { throw 'editor-desktop-missing' }
foreach ($path in @($editor, $editorCli, $userData, $extensions, $codexHome, $downloadDir, $base, $activationProbe, $activationTest)) { [void](Quote-Cmd $path) }
foreach ($file in @('test.js', 'extension.js', 'package.json')) {
  if (-not (Test-Path -LiteralPath (Join-Path $activationProbe $file) -PathType Leaf)) { throw 'editor-activation-missing' }
}
foreach ($programDirectory in @((Join-Path $env:LOCALAPPDATA 'Programs'), $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
  if (-not $programDirectory) { continue }
  foreach ($relativePath in @('Antigravity IDE\Antigravity IDE.exe', 'Antigravity\Antigravity.exe')) {
    if (Test-Path -LiteralPath (Join-Path $programDirectory $relativePath) -PathType Leaf) { throw 'editor-select-existing' }
  }
}
$existing = @(Get-EditorRegistryEntries)
foreach ($entry in $existing) {
  $directories = @(Get-EditorRegistryDirectories $entry)
  if ($directories.Count -eq 0) { throw 'editor-registry-ambiguous' }
  foreach ($directory in $directories) {
    $privatePrefix = (Join-Path $env:LOCALAPPDATA 'Programs\EmTroLy-Antigravity-IDE-').TrimEnd('\')
    if ($directory.TrimEnd('\') -ieq $appDir.TrimEnd('\') -or
        $directory.TrimEnd('\') -like ($privatePrefix + '*')) { continue }
    foreach ($name in @('Antigravity IDE.exe', 'Antigravity.exe')) {
      if (Test-Path -LiteralPath (Join-Path $directory $name) -PathType Leaf) { throw 'editor-select-existing' }
    }
  }
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
    New-PrivateDirectory $base
    [IO.File]::WriteAllText($receipt, $jobId)
  }
  New-PrivateDirectory $downloadDir
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

  Write-EditorStatus 'Đang cấu hình khóa API cho Codex trong thư mục riêng của Em Trợ Lý…'
  foreach ($folder in @($userData, $extensions, $codexHome)) { [void][IO.Directory]::CreateDirectory($folder) }
  $model = [string]$Settings.model
  if ($model -notmatch '^[A-Za-z0-9._-]+$') { throw 'editor-invalid-model' }
  $config = @"
model_provider = "router"
model = "$model"
preferred_auth_method = "apikey"
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
  $cliArgs = '/d /v:off /s /c "' + (Quote-Cmd $editorCli) + ' --user-data-dir ' + (Quote-Cmd $userData) + ' --extensions-dir ' + (Quote-Cmd $extensions) + ' --install-extension ' + (Quote-Cmd $vsix) + ' --do-not-include-pack-dependencies"'
  if ((Invoke-HiddenProcess $cmd $cliArgs 900) -ne 0) { throw 'editor-extension-install-failed' }
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
  if ((Invoke-HiddenProcess $codex $probeArgs 180) -ne 0) { throw 'editor-codex-probe-failed' }

  Write-EditorStatus 'Đang kiểm tra Codex Extension trong Antigravity IDE...'
  $activationMarker = Join-Path $downloadDir 'activation.ok'
  $env:EMTROLY_CODEX_ACTIVATION_MARKER = $activationMarker
  $activationArgs = '--skip-welcome --disable-workspace-trust --user-data-dir ' + (Quote-Cmd $userData) +
    ' --extensions-dir ' + (Quote-Cmd $extensions) + ' --extensionDevelopmentPath ' + (Quote-Cmd $activationProbe) +
    ' --extensionTestsPath ' + (Quote-Cmd $activationTest) + ' ' + (Quote-Cmd $downloadDir)
  if ((Invoke-HiddenProcess $editor $activationArgs 180) -ne 0 -or
      -not (Test-Path -LiteralPath $activationMarker -PathType Leaf) -or
      [IO.File]::ReadAllText($activationMarker) -cne 'ok') { throw 'editor-activation-failed' }

  $launchPath = Join-Path $base 'launch-antigravity.vbs'
  $script = @"
Option Explicit
Dim shell, command
Set shell = CreateObject("WScript.Shell")
shell.Environment("PROCESS")("CODEX_HOME") = "$($codexHome.Replace('"','""'))"
shell.Environment("PROCESS")("OPENAI_API_KEY") = ""
shell.Environment("PROCESS")("VSCODE_IPC_HOOK_CLI") = ""
shell.Environment("PROCESS")("ELECTRON_RUN_AS_NODE") = ""
shell.Environment("PROCESS")("NODE_OPTIONS") = ""
shell.CurrentDirectory = "$($base.Replace('"','""'))"
command = Chr(34) & "$($editor.Replace('"','""'))" & Chr(34) & _
  " --user-data-dir " & Chr(34) & "$($userData.Replace('"','""'))" & Chr(34) & _
  " --extensions-dir " & Chr(34) & "$($extensions.Replace('"','""'))" & Chr(34) & _
  " --new-window"
shell.Run command, 1, False
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
  if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
  [IO.File]::Move($temporaryShortcut, $shortcutPath)
  $saved = $shell.CreateShortcut($shortcutPath)
  if ($saved.TargetPath -ine (Join-Path $env:SystemRoot 'System32\wscript.exe') -or
      $saved.Arguments -cne ('//B //Nologo ' + (Quote-Cmd $launchPath)) -or
      $saved.WorkingDirectory -ine $base) { throw 'editor-shortcut-failed' }
  Remove-Item -LiteralPath $vsix -Force -ErrorAction SilentlyContinue
} finally {
  $env:CODEX_HOME = $oldCodexHome
  $env:OPENAI_API_KEY = $oldApiKey
  $env:VSCODE_IPC_HOOK_CLI = $oldIpcHook
  $env:ELECTRON_RUN_AS_NODE = $oldElectronNode
  $env:NODE_OPTIONS = $oldNodeOptions
  $env:EMTROLY_CODEX_ACTIVATION_MARKER = $oldActivationMarker
  if (Test-Path -LiteralPath $downloadDir) { Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue }
}
