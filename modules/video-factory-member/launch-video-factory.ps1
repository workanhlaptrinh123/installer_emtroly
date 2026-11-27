# Launch Xưởng Video AI module installer directly into the existing OpenClaw instance
$ErrorActionPreference = 'Stop'

$moduleDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installerDir = Join-Path $moduleDir 'installer'
$guiScript = Join-Path $installerDir 'app_gui.py'

if (-not (Test-Path -LiteralPath $guiScript -PathType Leaf)) {
  Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
  [System.Windows.MessageBox]::Show("Không tìm thấy giao diện Xưởng Video AI tại:`n$guiScript", 'Xưởng Video AI', 'OK', 'Error') | Out-Null
  exit 1
}

function Find-PythonGuiExecutable {
  $candidates = @(
    "$env:LOCALAPPDATA\Programs\Python\Python312\pythonw.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\pythonw.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python313\pythonw.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe"
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
      return $c
    }
  }
  foreach ($cmdName in @('pythonw', 'python', 'python3')) {
    $cmd = Get-Command $cmdName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source -and ($cmd.Source -notmatch 'WindowsApps\\python')) {
      return $cmd.Source
    }
  }
  return ''
}

$pyExe = Find-PythonGuiExecutable
if (-not $pyExe) {
  # Auto-install Python 3.12 via winget silently if missing
  $winget = Get-Command winget -ErrorAction SilentlyContinue
  if ($winget) {
    $p = Start-Process -FilePath $winget.Source -ArgumentList @(
      'install', '-e', '--id', 'Python.Python.3.12', '--scope', 'user',
      '--accept-package-agreements', '--accept-source-agreements'
    ) -Wait -PassThru -WindowStyle Hidden
    $pyExe = Find-PythonGuiExecutable
  }
}

if (-not $pyExe) {
  Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
  [System.Windows.MessageBox]::Show(
    "Máy chưa có Python 3.12 để mở giao diện Xưởng Video AI.`nVui lòng cài Python 3.12 (python.org) hoặc chạy bản cài độc lập OpenClaw-VideoFactory-Setup.exe.",
    'Xưởng Video AI', 'OK', 'Warning'
  ) | Out-Null
  exit 1
}

$env:PYTHONPATH = $installerDir
$winStyle = if ($pyExe -like '*pythonw.exe') { 'Normal' } else { 'Hidden' }
Start-Process -FilePath $pyExe -ArgumentList @("`"$guiScript`"") -WorkingDirectory $moduleDir -WindowStyle $winStyle | Out-Null
