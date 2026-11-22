[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$FilePath
)

$ErrorActionPreference = 'Stop'
$resolvedExe = (Resolve-Path -LiteralPath $FilePath).Path
$shaFile = "$resolvedExe.sha256"

function Update-ReleaseChecksum([string]$ExePath, [string]$ChecksumPath) {
  $hash = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $name = Split-Path -Leaf $ExePath
  [IO.File]::WriteAllText($ChecksumPath, "$hash  $name`n", [System.Text.Encoding]::ASCII)
}

function Find-WindowsSignTool {
  $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  $kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  if (Test-Path -LiteralPath $kitsRoot -PathType Container) {
    $candidates = @(Get-ChildItem -LiteralPath $kitsRoot -Filter 'signtool.exe' -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
      Sort-Object FullName -Descending)
    if ($candidates.Count -gt 0) { return $candidates[0].FullName }
  }
  return ''
}

# Option 1: Microsoft Azure Trusted Signing (instant SmartScreen reputation)
if (-not [string]::IsNullOrWhiteSpace($env:AZURE_TRUSTED_SIGNING_ENDPOINT) -and
    -not [string]::IsNullOrWhiteSpace($env:AZURE_CODE_SIGNING_ACCOUNT) -and
    -not [string]::IsNullOrWhiteSpace($env:AZURE_CERT_PROFILE) -and
    -not [string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_ID) -and
    -not [string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_SECRET) -and
    -not [string]::IsNullOrWhiteSpace($env:AZURE_TENANT_ID)) {
  Write-Host 'Signing emtroly.exe with Microsoft Azure Trusted Signing...'
  $signTool = Find-WindowsSignTool
  if (-not $signTool) { throw 'signtool.exe not found on Windows runner.' }
  $dlibDir = Join-Path $env:RUNNER_TEMP 'azure-trusted-signing'
  [void][IO.Directory]::CreateDirectory($dlibDir)
  $nupkg = Join-Path $dlibDir 'dlib.zip'
  Invoke-WebRequest -UseBasicParsing -Uri 'https://www.nuget.org/api/v2/package/Microsoft.Trusted.Signing.Client' -OutFile $nupkg
  Expand-Archive -LiteralPath $nupkg -DestinationPath (Join-Path $dlibDir 'extracted') -Force
  $dlibDll = @(Get-ChildItem -Path (Join-Path $dlibDir 'extracted') -Filter 'Azure.CodeSigning.Dlib.dll' -Recurse -File |
    Where-Object { $_.FullName -match 'x64' } | Select-Object -First 1)
  if ($dlibDll.Count -eq 0) { throw 'Azure.CodeSigning.Dlib.dll x64 not found.' }
  $metaPath = Join-Path $dlibDir 'metadata.json'
  $metaJson = @{
    Endpoint = $env:AZURE_TRUSTED_SIGNING_ENDPOINT.Trim()
    CodeSigningAccountName = $env:AZURE_CODE_SIGNING_ACCOUNT.Trim()
    CertificateProfileName = $env:AZURE_CERT_PROFILE.Trim()
  } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText($metaPath, $metaJson, (New-Object System.Text.UTF8Encoding($false)))
  & $signTool sign /v /debug /fd SHA256 /tr 'http://timestamp.acs.microsoft.com' /td SHA256 /dlib $dlibDll[0].FullName /dmdf $metaPath $resolvedExe
  if ($LASTEXITCODE -ne 0) { throw 'Azure Trusted Signing failed.' }
  Update-ReleaseChecksum -ExePath $resolvedExe -ChecksumPath $shaFile
  Write-Host 'Authenticode signature applied (Azure Trusted Signing) and SHA-256 updated.'
  exit 0
}

# Option 2: Standard Authenticode PFX Code Signing Certificate (WINDOWS_PFX_BASE64 + WINDOWS_PFX_PASSWORD)
if (-not [string]::IsNullOrWhiteSpace($env:WINDOWS_PFX_BASE64)) {
  Write-Host 'Signing emtroly.exe with Authenticode PFX certificate...'
  $signTool = Find-WindowsSignTool
  if (-not $signTool) { throw 'signtool.exe not found on Windows runner.' }
  $pfxFile = Join-Path ([IO.Path]::GetTempPath()) ('emtroly-codesign-' + [guid]::NewGuid().ToString('N') + '.pfx')
  try {
    [IO.File]::WriteAllBytes($pfxFile, [Convert]::FromBase64String($env:WINDOWS_PFX_BASE64.Trim()))
    $signArgs = @('sign', '/fd', 'SHA256', '/tr', 'http://timestamp.digicert.com', '/td', 'SHA256', '/f', $pfxFile)
    if (-not [string]::IsNullOrWhiteSpace($env:WINDOWS_PFX_PASSWORD)) {
      $signArgs += @('/p', $env:WINDOWS_PFX_PASSWORD)
    }
    $signArgs += $resolvedExe
    & $signTool @signArgs
    if ($LASTEXITCODE -ne 0) { throw 'Authenticode PFX signing failed.' }
  } finally {
    Remove-Item -LiteralPath $pfxFile -Force -ErrorAction SilentlyContinue
  }
  Update-ReleaseChecksum -ExePath $resolvedExe -ChecksumPath $shaFile
  Write-Host 'Authenticode signature applied (PFX) and SHA-256 updated.'
  exit 0
}

Write-Host 'No code-signing secrets configured (AZURE_TRUSTED_SIGNING_ENDPOINT or WINDOWS_PFX_BASE64); skipping optional Authenticode signing.'
exit 0
