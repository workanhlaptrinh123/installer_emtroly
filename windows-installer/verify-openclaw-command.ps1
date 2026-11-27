$ErrorActionPreference = 'Stop'
try {
  $root = [string]$env:EMTROLY_PROBE_ROOT
  $expectedVersion = [string]$env:EMTROLY_PROBE_VERSION
  $info = [IO.File]::ReadAllText((Join-Path $root 'windows-cli.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
  if (-not $info.default -or $info.command -ne 'openclaw') { exit 11 }
  $expectedPath = [IO.Path]::GetFullPath([string]$info.path)
  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = [Environment]::ExpandEnvironmentVariables(($machinePath + ';' + $userPath))
  foreach ($name in @('OPENCLAW_STATE_DIR', 'OPENCLAW_CONFIG_PATH', 'OPENCLAW_WORKSPACE_DIR', 'OPENCLAW_PROFILE', 'OPENCLAW_HOME', 'OPENCLAW_GATEWAY_PORT')) {
    $value = [Environment]::GetEnvironmentVariable($name, 'User')
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable($name, 'Machine') }
    [Environment]::SetEnvironmentVariable($name, $value, 'Process')
  }
  $command = Get-Command openclaw -ErrorAction Stop | Select-Object -First 1
  if ($command.CommandType -ne 'Application' -or
      -not [string]::Equals([IO.Path]::GetFullPath($command.Source), $expectedPath, [StringComparison]::OrdinalIgnoreCase)) { exit 12 }
  $version = (& $command.Source --version | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $version -notmatch [regex]::Escape($expectedVersion)) { exit 13 }
  $statusOk = $false
  for ($probeTry = 1; $probeTry -le 4; $probeTry++) {
    & $command.Source status *> $null
    if ($LASTEXITCODE -eq 0) { $statusOk = $true; break }
    if ($probeTry -lt 4) { Start-Sleep -Seconds 2 }
  }
  if (-not $statusOk) { exit 14 }
  exit 0
} catch {
  exit 12
}
