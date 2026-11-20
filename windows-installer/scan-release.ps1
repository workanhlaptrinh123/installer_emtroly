param(
  [Parameter(Mandatory = $true)]
  [string]$FilePath
)

$ErrorActionPreference = 'Stop'
$file = (Resolve-Path -LiteralPath $FilePath).Path
$before = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
$status = Get-MpComputerStatus
if (-not $status.AntivirusEnabled -or -not $status.AMServiceEnabled -or -not $status.RealTimeProtectionEnabled) {
  throw 'Microsoft Defender Antivirus is unavailable; refusing to publish an unscanned installer.'
}

Update-MpSignature -ErrorAction Stop
$preferences = Get-MpPreference -ErrorAction Stop
if ($preferences.DisableArchiveScanning -or $preferences.DisableScriptScanning -or $preferences.DisableIOAVProtection) {
  throw 'Required Defender scanning features are disabled.'
}
if (@($preferences.ExclusionPath).Where({ $_ }).Count -gt 0 -or
    @($preferences.ExclusionExtension).Where({ $_ }).Count -gt 0 -or
    @($preferences.ExclusionProcess).Where({ $_ }).Count -gt 0) {
  throw 'Defender exclusions are configured; refusing to rely on this scan.'
}
$scanner = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
  throw 'Microsoft Defender command-line scanner is unavailable.'
}

& $scanner -Scan -ScanType 3 -File $file
$scanExit = $LASTEXITCODE
$detections = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object {
  @($_.Resources | Where-Object { $_ -and $_.IndexOf($file, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0
})
if ($scanExit -ne 0 -or $detections.Count -gt 0) {
  throw "Defender scan failed or detected a threat (exit: $scanExit, detections: $($detections.Count))."
}
if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
    (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $before) {
  throw 'Installer was removed or changed during scanning.'
}
Write-Host "Defender scan completed without a reported detection. SHA256: $before"
