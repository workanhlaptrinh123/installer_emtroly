function Install-UserGateway {
  param([string]$Root, [string]$CliEntry, [int]$Port)
  $manifestPath = Join-Path $Root 'installer-instance.json'
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $manifest | Add-Member -NotePropertyName mode -NotePropertyValue 'user' -Force
  $manifest | Add-Member -NotePropertyName node -NotePropertyValue (Get-Command node).Source -Force
  $manifest | Add-Member -NotePropertyName home -NotePropertyValue $env:USERPROFILE -Force
  $manifest | Add-Member -NotePropertyName path -NotePropertyValue $env:Path -Force
  [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  Copy-Item (Join-Path $PSScriptRoot 'user-gateway.ps1') (Join-Path $Root 'user-gateway.ps1') -Force
  Copy-Item (Join-Path $PSScriptRoot 'user-gateway.cjs') (Join-Path $Root 'user-gateway.cjs') -Force
  $launcher = @'
$ErrorActionPreference = 'Stop'
$instance = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'installer-instance.json') -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'windows-instance.ps1')
. (Join-Path $PSScriptRoot 'user-gateway.ps1')
Set-OpenClawInstanceEnvironment -Root $instance.root -InstanceProfile $instance.profile -CliEntry $instance.cli_entry
$env:Path = $instance.path
Invoke-InstanceCli -Root $instance.root -CliEntry $instance.cli_entry @args
exit $LASTEXITCODE
'@
  [IO.File]::WriteAllText((Join-Path $Root 'openclaw-instance.ps1'), $launcher, [Text.UTF8Encoding]::new($false))
  $startup = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
  if (-not $startup) { throw 'Windows user Startup directory is unavailable.' }
  $startupFile = Join-Path $startup ("OpenClaw-$($manifest.profile).vbs")
  $command = '"' + (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') + '" -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Root 'openclaw-instance.ps1') + '" gateway start'
  $body = 'CreateObject("WScript.Shell").Run "' + $command.Replace('"','""') + '", 0, False'
  [IO.File]::WriteAllText($startupFile, $body, [Text.UTF8Encoding]::new($false))
}

function Invoke-InstanceCli {
  param([string]$Root, [string]$CliEntry, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
  if ($Arguments.Count -lt 2 -or $Arguments[0] -ne 'gateway' -or $Arguments[1] -notin @('install','start','stop','restart','status')) {
    & node $CliEntry @Arguments
    $global:LASTEXITCODE = $LASTEXITCODE
    return
  }
  $action = $Arguments[1]
  if ($action -eq 'install') { $global:LASTEXITCODE = 0; return }
  if ($action -eq 'status') {
    & node $CliEntry gateway health --json
    $global:LASTEXITCODE = $LASTEXITCODE
    return
  }
  $pidPath = Join-Path $Root 'user-gateway.pid.json'
  $target = $null
  if (Test-Path $pidPath) {
    $record = Get-Content -LiteralPath $pidPath -Raw | ConvertFrom-Json
    if (-not $record.pid) { throw 'Gateway startup is still in progress. Wait before retrying.' }
    $target = Get-CimInstance Win32_Process -Filter "ProcessId = $($record.pid)" -ErrorAction Stop
    if ($target -and ($target.CommandLine -notlike "*$CliEntry*" -or $target.CommandLine -notmatch '\bgateway\s+run\b')) { throw 'Saved PID belongs to another process. Nothing was stopped.' }
    if (-not $target) { Remove-Item -LiteralPath $pidPath }
  }
  if ($action -in @('stop','restart') -and $target) {
    Stop-Process -Id $record.pid -ErrorAction Stop
    Wait-Process -Id $record.pid -Timeout 30 -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pidPath
    $target = $null
  }
  if ($action -in @('start','restart') -and -not $target) {
    & node (Join-Path $Root 'user-gateway.cjs') start
    if ($LASTEXITCODE -ne 0) { throw 'User gateway start failed.' }
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
      Start-Sleep -Seconds 2
      & node $CliEntry gateway health --json *> $null
      if ($LASTEXITCODE -eq 0) { $global:LASTEXITCODE = 0; return }
    }
    throw 'User gateway did not become healthy. Inspect user-gateway.log; do not start another gateway.'
  }
  $global:LASTEXITCODE = 0
}
