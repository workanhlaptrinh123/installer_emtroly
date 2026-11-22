function Invoke-ZaloPluginCli {
  param([string]$Node, [string]$CliEntry, [string[]]$Arguments)
  $commandArguments = @($CliEntry) + $Arguments
  foreach ($argument in $commandArguments) {
    if ($argument -match '["\r\n]' -or $argument.EndsWith('\')) { throw 'Invalid OpenClaw CLI argument.' }
  }
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $Node
  $startInfo.Arguments = (($commandArguments | ForEach-Object { '"' + $_ + '"' }) -join ' ')
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
  $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) { throw 'OpenClaw CLI did not start.' }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout.Result; Stderr = $stderr.Result }
  } finally {
    $process.Dispose()
  }
}

function Set-ZaloFailureDetail {
  param([string]$Detail)
  $allowed = @('cli-error', 'permission-denied', 'gateway-unavailable', 'plugin-busy', 'approval-required', 'plugin-not-found', 'plugin-version-mismatch', 'plugin-not-loaded', 'invalid-response')
  if ($Detail -notin $allowed) { $Detail = 'cli-error' }
  if ($env:MEMBER_INSTALL_ZALO_STAGE_FILE) {
    [IO.File]::WriteAllText(($env:MEMBER_INSTALL_ZALO_STAGE_FILE + '.detail'), $Detail, [Text.Encoding]::ASCII)
  }
}

function Set-ZaloCliFailureDetail {
  param([psobject]$Result)
  $output = [string]$Result.Stdout + "`n" + [string]$Result.Stderr
  $detail = if ($output -match '(?i)EACCES|EPERM|access is denied|permission denied') { 'permission-denied' }
  elseif ($output -match '(?i)capability consent|accept.capabilities|approval required') { 'approval-required' }
  elseif ($output -match '(?i)plugin lifecycle.{0,80}(busy|lease)|lease.{0,80}(busy|held)|mutation.{0,80}busy') { 'plugin-busy' }
  elseif ($output -match '(?i)gateway.{0,80}(unavailable|disconnected|refused|timed out)|ECONNREFUSED') { 'gateway-unavailable' }
  elseif ($output -match '(?i)plugin (not found|not installed)') { 'plugin-not-found' }
  else { 'cli-error' }
  Set-ZaloFailureDetail $detail
}

function Get-ZaloPluginInfo {
  param([string]$Node, [string]$CliEntry)
  $result = Invoke-ZaloPluginCli -Node $Node -CliEntry $CliEntry -Arguments @('plugins', 'info', 'zalouser', '--json')
  try { $document = $result.Stdout | ConvertFrom-Json -ErrorAction Stop } catch {
    if ($result.ExitCode -ne 0) { Set-ZaloCliFailureDetail $result } else { Set-ZaloFailureDetail 'invalid-response' }
    throw 'Could not inspect Zalo plugin.'
  }
  if ($result.ExitCode -ne 0) {
    if ($document.ok -eq $false -and [string]$document.error.message -match '^Plugin not found: zalouser\.') { return $null }
    Set-ZaloCliFailureDetail $result
    throw 'Could not inspect Zalo plugin.'
  }
  if (-not $document.plugin -or $document.plugin.id -ne 'zalouser') {
    Set-ZaloFailureDetail 'invalid-response'
    throw 'Could not inspect Zalo plugin.'
  }
  return $document
}
