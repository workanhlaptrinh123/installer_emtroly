function Normalize-OpenClawTaskPath {
  param([string]$Path)
  $normalized = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"').Trim("'")).Replace('/','\')
  $prefix = if ($normalized.StartsWith('\\')) { '\\' } else { '' }
  return ($prefix + ($normalized -replace '^\\{2,}', '' -replace '\\{2,}', '\')).TrimEnd('\').ToLowerInvariant()
}

function Test-OpenClawTaskTarget {
  param($Task, [string]$Root)
  if (@($Task.Actions).Count -ne 1) { return $false }
  $action = @($Task.Actions)[0]
  $execute = Normalize-OpenClawTaskPath -Path ([string]$action.Execute)
  $command = [string]$action.Arguments
  $expected = Normalize-OpenClawTaskPath -Path (Join-Path $Root 'gateway.cmd')
  $expectedHidden = Normalize-OpenClawTaskPath -Path (Join-Path $Root 'gateway.vbs')
  $paths = @()
  if ($execute -match '\.(cmd|vbs)$') {
    $paths = @($execute)
    if (-not [string]::IsNullOrWhiteSpace($command)) { return $false }
  } else {
    if (($execute -split '\\')[-1] -notin @('cmd.exe','wscript.exe','cscript.exe','powershell.exe','pwsh.exe')) { return $false }
    if ($command -match '(?i)(?:^|\s)-(?:encodedcommand|enc)\s+([a-z0-9+/=]+)(?:\s|$)') {
      try { $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])) } catch { return $false }
    }
    $pattern = '"([^"\r\n]+\.(?:cmd|vbs))"|''([^''\r\n]+\.(?:cmd|vbs))''|(?:^|\s)([^\s"'';]+\.(?:cmd|vbs))(?=\s|$)'
    foreach ($match in [regex]::Matches($command, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
      foreach ($group in @(1,2,3)) { if ($match.Groups[$group].Success) { $paths += Normalize-OpenClawTaskPath -Path $match.Groups[$group].Value; break } }
    }
  }
  if ($paths.Count -ne 1) { return $false }
  if ($paths[0] -eq $expected) { return $true }
  if ($paths[0] -ne $expectedHidden) { return $false }
  $hiddenPath = Join-Path $Root 'gateway.vbs'
  if (-not (Test-Path -LiteralPath $hiddenPath -PathType Leaf)) { return $false }
  if ((Get-Item -LiteralPath $hiddenPath).Length -gt 65536) { return $false }
  $body = ((Get-Content -LiteralPath $hiddenPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith("'") }) -join "`n")
  $patterns = @(
    '^Set WshShell = CreateObject\("WScript\.Shell"\)\nWshShell\.Run chr\(34\) & "((?:""|[^"])*)" & chr\(34\), 0\nSet WshShell = Nothing$',
    '^Set shell = CreateObject\("WScript\.Shell"\)\n(?:shell\.Environment\("Process"\)\("OPENCLAW_WINDOWS_TASK_HIDDEN_LAUNCHER"\) = "wscript"\n)?WScript\.Quit shell\.Run\("((?:""|[^"])*)", 0, True\)$',
    '^WScript\.Quit CreateObject\("WScript\.Shell"\)\.Run\("((?:""|[^"])*)", 0, True\)$',
    '^CreateObject\("WScript\.Shell"\)\.Run "((?:""|[^"])*)", 0, False$'
  )
  foreach ($pattern in $patterns) {
    $match = [regex]::Match($body, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) { return (Normalize-OpenClawTaskPath -Path $match.Groups[1].Value.Replace('""','"')) -eq $expected }
  }
  return $false
}

function Find-OpenClawInstances {
  param([string]$HomeDirectory, [string]$Name)
  $instances = @()
  foreach ($directory in @(Get-ChildItem -LiteralPath $HomeDirectory -Directory -Force -ErrorAction Stop)) {
    if ($directory.Name -ne '.openclaw' -and $directory.Name -notlike '.openclaw-*') { continue }
    if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $directory.FullName 'openclaw.json') -PathType Leaf)) { continue }
    $instanceProfile = if ($directory.Name -eq '.openclaw') { '' } else { $directory.Name.Substring(10) }
    $instances += [pscustomobject]@{
      Root = $directory.FullName
      Profile = $instanceProfile
      Exact = $directory.Name -in @(('.openclaw-member-' + $Name), ('.openclaw-' + $Name))
    }
  }
  return $instances
}

function Select-OpenClawInstance {
  param([string]$HomeDirectory, [string]$Name, [string]$ExistingRoot = '')
  if ($ExistingRoot) {
    $resolved = (Resolve-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($ExistingRoot)) -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath (Join-Path $resolved 'openclaw.json') -PathType Leaf)) { throw 'Selected installation has no openclaw.json.' }
    return $resolved
  }
  $instances = @(Find-OpenClawInstances -HomeDirectory $HomeDirectory -Name $Name)
  $matching = @($instances | Where-Object { $_.Exact })
  if ($matching.Count -eq 1) { return $matching[0].Root }
  if ($instances.Count -eq 0) { return '' }
  if ($instances.Count -eq 1) {
    $answer = Read-Host "Found existing installation: $($instances[0].Root). Upgrade this installation? [y/N]"
    if ($answer -notin @('y','Y')) { throw 'Upgrade cancelled. Choose independent new installation to keep this assistant unchanged.' }
    return $instances[0].Root
  }
  Write-Host 'Multiple installations found. Choose the assistant to upgrade (0 cancels):'
  for ($index = 0; $index -lt $instances.Count; $index++) { Write-Host ("{0}. {1}" -f ($index + 1), $instances[$index].Root) }
  $selection = 0
  if (-not [int]::TryParse((Read-Host 'Installation number'), [ref]$selection) -or $selection -lt 1 -or $selection -gt $instances.Count) { throw 'No installation selected. Nothing was changed.' }
  return $instances[$selection - 1].Root
}

function Set-OpenClawInstanceEnvironment {
  param([string]$Root, [string]$InstanceProfile, [string]$CliEntry)
  foreach ($selector in @('OPENCLAW_HOME','OPENCLAW_GATEWAY_TOKEN','OPENCLAW_GATEWAY_PASSWORD','OPENCLAW_GATEWAY_PORT','OPENCLAW_SYSTEMD_UNIT','OPENCLAW_LAUNCHD_LABEL','OPENCLAW_WINDOWS_TASK_NAME','OPENCLAW_SERVICE_KIND','OPENCLAW_SERVICE_MARKER','OPENCLAW_GATEWAY_SERVICE_PID')) { Remove-Item "Env:$selector" -ErrorAction SilentlyContinue }
  if ($env:OS -eq 'Windows_NT') {
    $accountHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($accountHome)) { throw 'Cannot resolve the Windows account home for service management.' }
    $env:HOME = $accountHome
  }
  if ($InstanceProfile) { $env:OPENCLAW_PROFILE = $InstanceProfile } else { Remove-Item Env:OPENCLAW_PROFILE -ErrorAction SilentlyContinue }
  $env:OPENCLAW_ROOT = $Root
  $env:OPENCLAW_STATE_DIR = $Root
  $env:OPENCLAW_CONFIG_PATH = Join-Path $Root 'openclaw.json'
  $env:OPENCLAW_WORKSPACE_DIR = Join-Path $Root 'workspace'
  if ($CliEntry) { $env:OPENCLAW_CLI_ENTRY = $CliEntry }
}

function Save-OpenClawInstanceLauncher {
  param([string]$Root, [string]$InstanceProfile, [string]$CliEntry, [int]$Port)
  $manifest = @{ root=$Root; profile=$InstanceProfile; cli_entry=$CliEntry; port=$Port }
  [IO.File]::WriteAllText((Join-Path $Root 'installer-instance.json'), ($manifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows-instance.ps1') -Destination (Join-Path $Root 'windows-instance.ps1') -Force
  $launcher = @'
$ErrorActionPreference = 'Stop'
$instance = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'installer-instance.json') -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'windows-instance.ps1')
Set-OpenClawInstanceEnvironment -Root $instance.root -InstanceProfile $instance.profile -CliEntry $instance.cli_entry
& node $instance.cli_entry @args
exit $LASTEXITCODE
'@
  [IO.File]::WriteAllText((Join-Path $Root 'openclaw-instance.ps1'), $launcher, [Text.UTF8Encoding]::new($false))
}
