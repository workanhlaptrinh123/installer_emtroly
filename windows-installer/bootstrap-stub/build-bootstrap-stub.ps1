[CmdletBinding()]
param(
  [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
$stubDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installerDir = Split-Path -Parent $stubDir
$csFile = Join-Path $stubDir 'EmTroLySetup.cs'
$manifestFile = Join-Path $stubDir 'app.manifest'
$iconFile = Join-Path $installerDir 'alt.ico'
$targetExe = if ($OutFile) { [IO.Path]::GetFullPath($OutFile) } else { Join-Path $stubDir 'EmTroLy-Setup.exe' }
$shaFile = "$targetExe.sha256"

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
  throw "Microsoft .NET Framework 4.x C# compiler not found at: $csc"
}

[void][IO.Directory]::CreateDirectory((Split-Path -Parent $targetExe))
$cscArgs = @(
  '/nologo',
  '/target:winexe',
  '/platform:x64',
  '/optimize+',
  '/codepage:65001',
  '/utf8output',
  "/win32icon:$iconFile",
  "/win32manifest:$manifestFile",
  "/out:$targetExe",
  '/reference:System.dll',
  '/reference:System.Drawing.dll',
  '/reference:System.Windows.Forms.dll',
  $csFile
)

& $csc @cscArgs
if ($LASTEXITCODE -ne 0) {
  throw "Failed to compile EmTroLy-Setup.exe (exit code $LASTEXITCODE)."
}

$hash = (Get-FileHash -LiteralPath $targetExe -Algorithm SHA256).Hash.ToLowerInvariant()
$leaf = Split-Path -Leaf $targetExe
[IO.File]::WriteAllText($shaFile, "$hash *$leaf`n", [System.Text.Encoding]::ASCII)
Write-Host "Built immutable bootstrapper: $targetExe"
Write-Host "SHA-256: $hash"
