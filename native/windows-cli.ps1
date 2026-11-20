function Install-UserOpenClawCli {
  param([string]$Root, [string]$CliEntry, [int]$Port, [string]$Profile, [string]$ExpectedVersion,
        [string]$Python = (Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source,
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
