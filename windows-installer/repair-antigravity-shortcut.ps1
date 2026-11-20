[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$base = Join-Path $env:LOCALAPPDATA 'EmTroLy'
$programsRoot = Join-Path $env:LOCALAPPDATA 'Programs'
$extensionVersion = '26.51111.21308'
$pending = Join-Path $env:USERPROFILE 'openclaw\installer-codex-pending.json'
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'EmTroLy - Antigravity.lnk'
$legacyShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Em Trợ Lý - Antigravity.lnk'
$receipt = Join-Path $base 'installer-job.txt'

function Test-EditorApplication([string]$Root) {
  $editor = Join-Path $Root 'Antigravity IDE.exe'
  $cli = Join-Path $Root 'bin\antigravity-ide.cmd'
  $productPath = Join-Path $Root 'resources\app\product.json'
  if (-not (Test-Path -LiteralPath $editor -PathType Leaf) -or
      -not (Test-Path -LiteralPath $cli -PathType Leaf) -or
      -not (Test-Path -LiteralPath $productPath -PathType Leaf)) { return $false }
  try {
    $product = Get-Content -LiteralPath $productPath -Raw | ConvertFrom-Json
    return $product.applicationName -eq 'antigravity-ide' -and $product.version -eq '1.107.0'
  } catch {
    return $false
  }
}

function Test-EmTroLyDataComplete([string]$Root) {
  if (Test-Path -LiteralPath $pending -PathType Leaf) { return $false }
  foreach ($relative in @('installer-job.txt', 'Codex\config.toml', 'Codex\auth.json',
                           'Antigravity\UserData\User\settings.json')) {
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
  return $installed.Count -eq 1
}

if (-not (Test-Path -LiteralPath $base -PathType Container) -or
    -not (Test-Path -LiteralPath (Split-Path -Parent $shortcutPath) -PathType Container) -or
    -not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\wscript.exe') -PathType Leaf) -or
    -not (Test-EmTroLyDataComplete $base)) { exit 2 }

$appRoot = $null
$savedJob = if (Test-Path -LiteralPath $receipt -PathType Leaf) { [IO.File]::ReadAllText($receipt).Trim() } else { '' }
if ($savedJob -match '^[a-f0-9]{32}$') {
  $candidate = Join-Path $programsRoot ('EmTroLy-Antigravity-IDE-' + $savedJob)
  if (Test-EditorApplication $candidate) { $appRoot = $candidate }
}
if (-not $appRoot -and (Test-Path -LiteralPath $programsRoot -PathType Container)) {
  $appRoot = @(Get-ChildItem -LiteralPath $programsRoot -Directory -Filter 'EmTroLy-Antigravity-IDE-*' -ErrorAction SilentlyContinue | Where-Object {
    Test-EditorApplication $_.FullName
  } | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
if (-not $appRoot) { exit 2 }

$editor = Join-Path $appRoot 'Antigravity IDE.exe'
$userData = Join-Path $base 'Antigravity\UserData'
$extensions = Join-Path $base 'Antigravity\Extensions'
$codexHome = Join-Path $base 'Codex'
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
shell.CurrentDirectory = "$($appRoot.Replace('"','""'))"
command = Chr(34) & "$($editor.Replace('"','""'))" & Chr(34) & _
  " --user-data-dir " & Chr(34) & "$($userData.Replace('"','""'))" & Chr(34) & _
  " --extensions-dir " & Chr(34) & "$($extensions.Replace('"','""'))" & Chr(34) & _
  " --new-window"
shell.Run command, 1, False
Set shell = Nothing
"@
[IO.File]::WriteAllText($launchPath, $script, [Text.Encoding]::Unicode)

$shell = New-Object -ComObject WScript.Shell
$temporaryShortcut = Join-Path $env:TEMP ('emtroly-repair-' + [guid]::NewGuid().ToString('N') + '.lnk')
$shortcut = $shell.CreateShortcut($temporaryShortcut)
$shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$shortcut.Arguments = '//B //Nologo "' + $launchPath + '"'
$shortcut.WorkingDirectory = $base
$shortcut.IconLocation = $editor + ',0'
$shortcut.Description = 'Em Trợ Lý - Antigravity IDE và Codex riêng'
$shortcut.Save()
if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
[IO.File]::Move($temporaryShortcut, $shortcutPath)
$saved = $shell.CreateShortcut($shortcutPath)
if ($saved.TargetPath -ine (Join-Path $env:SystemRoot 'System32\wscript.exe') -or
    $saved.Arguments -cne ('//B //Nologo "' + $launchPath + '"') -or
    $saved.WorkingDirectory -ine $base) { throw 'shortcut-verification-failed' }

if (Test-Path -LiteralPath $legacyShortcutPath -PathType Leaf) {
  try {
    $legacy = $shell.CreateShortcut($legacyShortcutPath)
    $legacyOwned = ([string]::IsNullOrWhiteSpace([string]$legacy.TargetPath) -and
      [string]::IsNullOrWhiteSpace([string]$legacy.Arguments)) -or
      $legacy.Arguments -match '(?i)launch-antigravity\.vbs'
    if ($legacyOwned) { Remove-Item -LiteralPath $legacyShortcutPath -Force }
  } catch { }
}
exit 0
