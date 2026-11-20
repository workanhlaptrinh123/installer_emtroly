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

function Test-EditorInstallation([string]$Editor) {
  $appDir = Split-Path -Parent $Editor
  $editorCli = Join-Path $appDir 'bin\antigravity-ide.cmd'
  if (-not (Test-Path -LiteralPath $editor -PathType Leaf) -or -not (Test-Path -LiteralPath $editorCli -PathType Leaf)) { throw 'editor-cli-missing' }
  $editorSignature = Get-AuthenticodeSignature -LiteralPath $editor
  if ($editorSignature.Status -ne 'Valid' -or $editorSignature.SignerCertificate.Subject -notmatch 'Google') { throw 'editor-signature-invalid' }
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

function Find-InstalledEditor {
  $directories = @((Join-Path $env:LOCALAPPDATA 'Programs\Antigravity IDE'))
  foreach ($parent in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($parent) { $directories += Join-Path $parent 'Antigravity IDE' }
  }
  foreach ($entry in Get-EditorRegistryEntries) { $directories += @(Get-EditorRegistryDirectories $entry) }
  $found = @()
  foreach ($directory in $directories) {
    try {
      if ($directory.StartsWith('\\')) { continue }
      $path = Join-Path ([IO.Path]::GetFullPath($directory)) 'Antigravity IDE.exe'
      if ($path -in $found -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
      Test-EditorInstallation $path
      $found += $path
    } catch { continue }
  }
  return $found
}
