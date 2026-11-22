[CmdletBinding()]
param([string]$OpenClawRoot = (Join-Path $env:USERPROFILE '.openclaw'))
$ErrorActionPreference = 'Stop'
$base = Split-Path -Parent $PSScriptRoot
$catalog = Join-Path $OpenClawRoot 'module-catalog'
New-Item -ItemType Directory -Force -Path $OpenClawRoot, $catalog, (Join-Path $catalog 'skills') | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'module-manager.py') (Join-Path $OpenClawRoot 'module-manager.py')
Copy-Item -Force (Join-Path $PSScriptRoot 'module-manager.ps1') (Join-Path $OpenClawRoot 'module-manager.ps1')
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $catalog 'modules'), (Join-Path $catalog 'profiles')
Copy-Item -Recurse -Force (Join-Path $base 'modules') $catalog
Copy-Item -Recurse -Force (Join-Path $base 'profiles') $catalog
Copy-Item -Force (Join-Path $PSScriptRoot 'module-skills.json') $catalog
Copy-Item -Recurse -Force (Join-Path $PSScriptRoot 'skills\*') (Join-Path $catalog 'skills')
Write-Host "Native module manager installed at $OpenClawRoot"
