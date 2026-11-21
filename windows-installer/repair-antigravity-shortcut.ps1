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

function Resolve-EditorBundle([string]$Root, [bool]$RequirePinnedVersion = $false) {
  if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }
  $productPath = Join-Path $Root 'resources\app\product.json'
  if (-not (Test-Path -LiteralPath $productPath -PathType Leaf)) { return $null }
  foreach ($pair in @(
    @{ Exe = 'Antigravity IDE.exe'; Cli = 'bin\antigravity-ide.cmd' },
    @{ Exe = 'Antigravity.exe'; Cli = 'bin\antigravity.cmd' }
  )) {
    $editor = Join-Path $Root $pair.Exe
    $cli = Join-Path $Root $pair.Cli
    if ((Test-Path -LiteralPath $editor -PathType Leaf) -and (Test-Path -LiteralPath $cli -PathType Leaf)) {
      try {
        $product = Get-Content -LiteralPath $productPath -Raw | ConvertFrom-Json
        if ($product.applicationName -notin @('antigravity-ide', 'antigravity')) { return $null }
        if ([string]::IsNullOrWhiteSpace([string]$product.version)) { return $null }
        if ($RequirePinnedVersion -and $product.version -ne '1.107.0') { return $null }
        return [pscustomobject]@{ AppDir = $Root; Editor = $editor }
      } catch {
        return $null
      }
    }
  }
  return $null
}

function Test-EditorApplication([string]$Root) {
  return ($null -ne (Resolve-EditorBundle -Root $Root -RequirePinnedVersion $true))
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

$bundle = $null
$recordedPathFile = Join-Path $base 'editor-app-path.txt'
if (Test-Path -LiteralPath $recordedPathFile -PathType Leaf) {
  $recordedDir = ([IO.File]::ReadAllText($recordedPathFile)).Trim()
  $bundle = Resolve-EditorBundle -Root $recordedDir
}
$savedJob = if (Test-Path -LiteralPath $receipt -PathType Leaf) { [IO.File]::ReadAllText($receipt).Trim() } else { '' }
if (-not $bundle -and $savedJob -match '^[a-f0-9]{32}$') {
  $candidate = Join-Path $programsRoot ('EmTroLy-Antigravity-IDE-' + $savedJob)
  if (Test-EditorApplication $candidate) { $bundle = Resolve-EditorBundle -Root $candidate -RequirePinnedVersion $true }
}
if (-not $bundle -and (Test-Path -LiteralPath $programsRoot -PathType Container)) {
  $foundPrivate = @(Get-ChildItem -LiteralPath $programsRoot -Directory -Filter 'EmTroLy-Antigravity-IDE-*' -ErrorAction SilentlyContinue | Where-Object {
    Test-EditorApplication $_.FullName
  } | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
  if ($foundPrivate.Count -gt 0) { $bundle = Resolve-EditorBundle -Root $foundPrivate[0].FullName -RequirePinnedVersion $true }
}
if (-not $bundle) {
  foreach ($progDir in @($programsRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $progDir) { continue }
    foreach ($subName in @('Antigravity IDE', 'Antigravity')) {
      $b = Resolve-EditorBundle -Root (Join-Path $progDir $subName)
      if ($b) { $bundle = $b; break }
    }
    if ($bundle) { break }
  }
}
if (-not $bundle) { exit 2 }

$appRoot = $bundle.AppDir
$editor = $bundle.Editor
$userData = Join-Path $base 'Antigravity\UserData'
$extensions = Join-Path $base 'Antigravity\Extensions'
$codexHome = Join-Path $base 'Codex'
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
shell.CurrentDirectory = "$($appRoot.Replace('"','""'))"
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
