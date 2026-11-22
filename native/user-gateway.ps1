function Install-UserGateway {
  param([string]$Root, [string]$CliEntry, [int]$Port)
  $manifestPath = Join-Path $Root 'installer-instance.json'
  $manifest = Get-Content -LiteralPath $manifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
  $manifest | Add-Member -NotePropertyName mode -NotePropertyValue 'user' -Force
  $manifest | Add-Member -NotePropertyName node -NotePropertyValue (Get-Command node).Source -Force
  $manifest | Add-Member -NotePropertyName home -NotePropertyValue $env:USERPROFILE -Force
  $manifest | Add-Member -NotePropertyName path -NotePropertyValue $env:Path -Force
  [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  Copy-Item (Join-Path $PSScriptRoot 'user-gateway.ps1') (Join-Path $Root 'user-gateway.ps1') -Force
  Copy-Item (Join-Path $PSScriptRoot 'user-gateway.cjs') (Join-Path $Root 'user-gateway.cjs') -Force
  $launcher = @'
$ErrorActionPreference = 'Stop'
$instance = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'installer-instance.json') -Encoding UTF8 -Raw | ConvertFrom-Json
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
  [IO.File]::WriteAllText($startupFile, $body, [Text.Encoding]::Unicode)
}

function Test-StaleGatewayPidRecord {
  param(
    [Parameter(Mandatory=$true)][string]$PidPath,
    [psobject]$Record = $null,
    [int]$StaleSeconds = 60
  )
  if ($env:EMTROLY_STALE_PID_SECONDS -match '^[1-9][0-9]*$') {
    $StaleSeconds = [int]$env:EMTROLY_STALE_PID_SECONDS
  }
  $ageSec = 0.0
  try {
    $ageSec = ([DateTime]::UtcNow - (Get-Item -LiteralPath $PidPath).LastWriteTimeUtc).TotalSeconds
  } catch { }
  if ($Record -and $Record.PSObject.Properties['startedAt'] -and $Record.startedAt) {
    try {
      $startedUtc = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Record.startedAt).UtcDateTime
      $ageSec = [Math]::Max($ageSec, ([DateTime]::UtcNow - $startedUtc).TotalSeconds)
    } catch { }
  }
  return ($ageSec -ge $StaleSeconds)
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
  $stopSentinel = Join-Path $Root 'user-gateway.stop'
  $target = $null
  $supervisorProc = $null
  if (Test-Path $pidPath) {
    $record = $null
    try {
      $record = Get-Content -LiteralPath $pidPath -Raw | ConvertFrom-Json
    } catch {
      if (Test-StaleGatewayPidRecord -PidPath $pidPath) {
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
      } else {
        throw 'Gateway PID file is corrupted or being written.'
      }
    }
    if ($record) {
      if ($record.PSObject.Properties['supervisorPid'] -and $record.supervisorPid) {
        $supCandidate = Get-CimInstance Win32_Process -Filter "ProcessId = $($record.supervisorPid)" -ErrorAction SilentlyContinue
        if ($supCandidate -and $supCandidate.CommandLine -like '*user-gateway.cjs*') {
          $supervisorProc = $supCandidate
        }
      }
      if (-not $record.pid) {
        $launcherRunning = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue | Where-Object {
          $_.CommandLine -like '*user-gateway.cjs*' -and $_.CommandLine -like "*$Root*"
        }).Count -gt 0
        if (-not $launcherRunning -and (Test-StaleGatewayPidRecord -PidPath $pidPath -Record $record)) {
          Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
        } else {
          throw 'Gateway startup is still in progress. Wait before retrying.'
        }
      } else {
        $target = Get-CimInstance Win32_Process -Filter "ProcessId = $($record.pid)" -ErrorAction Stop
        if ($target -and ($target.CommandLine -notlike "*$CliEntry*" -or $target.CommandLine -notmatch '\bgateway\s+run\b')) {
          $staleFromPreBoot = $false
          try {
            $osBootUtc = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime()
            $pidWriteUtc = (Get-Item -LiteralPath $pidPath).LastWriteTimeUtc
            if ($pidWriteUtc -lt $osBootUtc) { $staleFromPreBoot = $true }
          } catch { }
          if ($staleFromPreBoot -and $action -eq 'start') {
            Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
            $target = $null
          } else {
            throw 'Saved PID belongs to another process. Nothing was stopped.'
          }
        }
        if (-not $target -and -not $supervisorProc -and (Test-Path -LiteralPath $pidPath)) { Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue }
      }
    }
  }
  if ($action -in @('stop','restart') -and ($target -or $supervisorProc)) {
    [IO.File]::WriteAllText($stopSentinel, 'stop', [Text.UTF8Encoding]::new($false))
    if ($supervisorProc) {
      Stop-Process -Id ([int]$record.supervisorPid) -Force -ErrorAction SilentlyContinue
      Wait-Process -Id ([int]$record.supervisorPid) -Timeout 10 -ErrorAction SilentlyContinue
    }
    if ($target) {
      Stop-Process -Id $record.pid -ErrorAction Stop
      Wait-Process -Id $record.pid -Timeout 30 -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stopSentinel -Force -ErrorAction SilentlyContinue
    $target = $null
    $supervisorProc = $null
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
