[CmdletBinding()]
param(
  [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
$stubDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installerDir = Split-Path -Parent $stubDir
$repoRoot = Split-Path -Parent $installerDir
$csFile = Join-Path $stubDir 'EmTroLySetup.cs'
$manifestFile = Join-Path $stubDir 'app.manifest'
$iconFile = Join-Path $installerDir 'alt.ico'
$logoPngSrc = Join-Path $repoRoot 'alt.png'
$targetExe = if ($OutFile) { [IO.Path]::GetFullPath($OutFile) } else { Join-Path $stubDir 'EmTroLy-Setup.exe' }
$shaFile = "$targetExe.sha256"

$fwDir = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$wpfDir = Join-Path $fwDir 'WPF'
$csc = Join-Path $fwDir 'csc.exe'
if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
  throw "Microsoft .NET Framework 4.x C# compiler not found at: $csc"
}

Add-Type -AssemblyName System.Drawing
$tempResDir = Join-Path ([IO.Path]::GetTempPath()) ('emtroly-stub-res-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempResDir)

try {
  $scaledLogoPath = Join-Path $tempResDir 'EmTroLyLogo.png'
  if (Test-Path -LiteralPath $logoPngSrc -PathType Leaf) {
    $srcBmp = [System.Drawing.Bitmap]::FromFile($logoPngSrc)
    try {
      $targetH = 96
      $targetW = [Math]::Max(96, [int][Math]::Round(($srcBmp.Width * [double]$targetH) / [Math]::Max(1, $srcBmp.Height)))
      $dstBmp = New-Object System.Drawing.Bitmap($targetW, $targetH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      try {
        $g = [System.Drawing.Graphics]::FromImage($dstBmp)
        try {
          $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
          $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
          $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
          $g.DrawImage($srcBmp, 0, 0, $targetW, $targetH)
        } finally {
          $g.Dispose()
        }
        $dstBmp.Save($scaledLogoPath, [System.Drawing.Imaging.ImageFormat]::Png)
      } finally {
        $dstBmp.Dispose()
      }
    } finally {
      $srcBmp.Dispose()
    }
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
    '/reference:System.Core.dll',
    '/reference:System.Xaml.dll',
    "/reference:$(Join-Path $wpfDir 'WindowsBase.dll')",
    "/reference:$(Join-Path $wpfDir 'PresentationCore.dll')",
    "/reference:$(Join-Path $wpfDir 'PresentationFramework.dll')"
  )
  if (Test-Path -LiteralPath $scaledLogoPath -PathType Leaf) {
    $cscArgs += "/resource:$scaledLogoPath,EmTroLyLogo.png"
  }
  $cscArgs += $csFile

  & $csc @cscArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to compile EmTroLy-Setup.exe (exit code $LASTEXITCODE)."
  }
} finally {
  Remove-Item -LiteralPath $tempResDir -Recurse -Force -ErrorAction SilentlyContinue
}

$hash = (Get-FileHash -LiteralPath $targetExe -Algorithm SHA256).Hash.ToLowerInvariant()
$leaf = Split-Path -Leaf $targetExe
[IO.File]::WriteAllText($shaFile, "$hash *$leaf`n", [System.Text.Encoding]::ASCII)
Write-Host "Built bootstrapper: $targetExe"
Write-Host "SHA-256: $hash"
