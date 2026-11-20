[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$FilePath,
  [Parameter(Mandatory = $true)][string]$CertificatePath,
  [Parameter(Mandatory = $true)][string]$CertificatePassword,
  [string]$TimestampUrl = 'https://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'

function Find-SignTool {
  $roots = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'),
    (Join-Path $env:ProgramFiles 'Windows Kits\10\bin')
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }

  $candidate = Get-ChildItem -LiteralPath $roots -Filter 'signtool.exe' -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
  if (-not $candidate) { throw 'signtool.exe was not found on the GitHub Windows runner.' }
  return $candidate.FullName
}

$file = (Resolve-Path -LiteralPath $FilePath).Path
$certificate = (Resolve-Path -LiteralPath $CertificatePath).Path
if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'Installer file does not exist.' }
if (-not (Test-Path -LiteralPath $certificate -PathType Leaf)) { throw 'Signing certificate does not exist.' }

$signtool = Find-SignTool
& $signtool sign /fd SHA256 /td SHA256 /tr $TimestampUrl /f $certificate /p $CertificatePassword $file
if ($LASTEXITCODE -ne 0) { throw "signtool failed with exit code $LASTEXITCODE." }

$signature = Get-AuthenticodeSignature -LiteralPath $file
if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate) {
  throw "Installer signature is not valid: $($signature.Status)."
}

$checksumPath = "$file.sha256"
if (Test-Path -LiteralPath $checksumPath -PathType Leaf) {
  $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
  [IO.File]::WriteAllText(
    $checksumPath,
    "$hash  $([IO.Path]::GetFileName($file))`n",
    [Text.Encoding]::ASCII
  )
}

Write-Host "Authenticode signature verified for $([IO.Path]::GetFileName($file))."
