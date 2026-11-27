function Resolve-WindowsCliPython {
  $candidates = @()
  if ($env:LOCALAPPDATA) {
    $candidates += (Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies\python313\python.exe')
    $candidates += (Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies\python312\python.exe')
  }
  foreach ($c in @(Get-Command python.exe -All -CommandType Application -ErrorAction SilentlyContinue)) {
    if ($c.Source -and $c.Source -notlike '*\WindowsApps\*') { $candidates += $c.Source }
  }
  if ($env:LOCALAPPDATA) {
    $candidates += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Python\*\python.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
  }
  if ($env:ProgramFiles) {
    $candidates += @(Get-ChildItem (Join-Path $env:ProgramFiles 'Python*\python.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
  }
  foreach ($exe in @($candidates | Where-Object { $_ } | Select-Object -Unique)) {
    if ($exe -notlike '*\WindowsApps\*' -and (Test-Path -LiteralPath $exe -PathType Leaf)) { return $exe }
  }
  throw 'Python executable outside WindowsApps was not found.'
}

function Install-UserOpenClawCli {
  param([string]$Root, [string]$CliEntry, [int]$Port, [string]$Profile, [string]$ExpectedVersion,
        [string]$Python = (Resolve-WindowsCliPython),
        [string]$Node = (Get-Command node.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
  $helper = Join-Path $PSScriptRoot 'skills\tao-tro-ly-openclaw-windows-macos-linux\scripts\install_windows_cli.py'
  if (-not (Test-Path -LiteralPath $helper)) { throw 'OpenClaw CLI PATH helper is missing.' }
  $userProfilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
  $previousPath = $env:Path
  $runtimeBin = Join-Path (Split-Path (Split-Path $CliEntry)) '.bin'
  try {
    $env:Path = (@($previousPath -split ';' | Where-Object { $_.Trim('"').TrimEnd('\') -ine $runtimeBin.TrimEnd('\') }) -join ';')
    $resultText = & $python $helper --root $Root --home $userProfilePath --node $node --cli-entry $CliEntry --port $Port --profile $Profile | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'OpenClaw CLI PATH installation failed.' }
  } finally { $env:Path = $previousPath }
  try { $result = $resultText | ConvertFrom-Json } catch { throw 'OpenClaw CLI PATH helper returned invalid output.' }
  $cliPath = [string]$result.cli_path
  $userBin = [string]$result.user_bin
  if ([string]::IsNullOrWhiteSpace($cliPath) -or -not (Test-Path -LiteralPath $cliPath) -or
      [string]::IsNullOrWhiteSpace($userBin) -or -not (Test-Path -LiteralPath $userBin)) {
    throw 'OpenClaw CLI shim was not created.'
  }
  $commandName = if ([bool]$result.default_cli) { 'openclaw' } else { [string]$result.cli_alias }
  $cliVersion = (& $cliPath --version | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $cliVersion -notmatch [regex]::Escape($ExpectedVersion)) { throw 'OpenClaw CLI shim verification failed.' }
  $cliInfo = @{ command = $commandName; path = $cliPath; default = [bool]$result.default_cli }
  [IO.File]::WriteAllText((Join-Path $Root 'windows-cli.json'), ($cliInfo | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}
