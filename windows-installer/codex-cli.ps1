[CmdletBinding()]
param(
  [switch]$RunWorker,
  [string]$RequestFile = '',
  [string]$OutputFile = ''
)

function Remove-AnsiEscapeCodes([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $clean = [regex]::Replace($Text, "\x1B\[[0-?]*[ -/]*[@-~]", '')
  $clean = [regex]::Replace($clean, "\x1B\][^\x07]*(\x07|\x1B\\)", '')
  return $clean
}

function Protect-CodexOutputText([string]$Text, [string]$SecretKey = '') {
  $clean = Remove-AnsiEscapeCodes $Text
  if (-not [string]::IsNullOrWhiteSpace($SecretKey) -and $SecretKey.Length -ge 6) {
    $clean = $clean.Replace($SecretKey, '[ĐÃ ẨN KHÓA BÍ MẬT]')
  }
  return $clean
}

function Test-ShouldSkipCodexNoiseLine([string]$Line) {
  if ($null -eq $Line) { return $true }
  $t = $Line.Trim()
  if ($t -match 'ERROR\s+codex_core::session::session:\s+failed to load skill\s+.*SKILL\.md:\s+missing YAML frontmatter') { return $true }
  if ($t -match '^warning:\s+Codex is ignoring \d+ unrecognized configuration setting') { return $true }
  if ($t -match '^user\s+\(.*config\.toml\):\s+`?preferred_auth_method`?\s+is ignored') { return $true }
  if ($t -match '^warning:\s+Model metadata for\s+.*\s+not found\.\s+Defaulting to fallback metadata') { return $true }
  return $false
}

function Repair-EmTroLyCodexConfigFile([string]$CodexHome, [string]$PreferredModel = '') {
  if ([string]::IsNullOrWhiteSpace($CodexHome)) { return }
  $cfgPath = Join-Path $CodexHome 'config.toml'
  if (-not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) { return }
  try {
    $raw = [IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
    $updated = $raw
    $updated = [regex]::Replace($updated, '(?m)^\s*preferred_auth_method\s*=.*\r?\n?', '')
    if (-not [string]::IsNullOrWhiteSpace($PreferredModel) -and $PreferredModel -match '^[A-Za-z0-9._-]+$') {
      if ($updated -match '(?m)^model\s*=\s*"GPT-6\.1-sol"\s*$' -or $updated -match '(?m)^model\s*=\s*"gpt-6\.1-sol"\s*$') {
        $updated = [regex]::Replace($updated, '(?m)^model\s*=\s*"[^"]+"\s*$', ('model = "' + $PreferredModel + '"'))
      }
    }
    if ($updated -notmatch '(?m)^\s*model_context_window\s*=') {
      $updated = [regex]::Replace(
        $updated,
        '(?m)^(model\s*=\s*"[^"]+"\r?\n)',
        ('$1model_context_window = 272000' + "`r`n" + 'model_auto_compact_token_limit = 200000' + "`r`n")
      )
    }
    if ($updated -cne $raw) {
      [IO.File]::WriteAllText($cfgPath, $updated, (New-Object System.Text.UTF8Encoding($false)))
    }
  } catch { }
}

function Get-CodexDefaultWorkspace {
  $openclawRoot = Join-Path $env:USERPROFILE 'openclaw'
  if ($openclawRoot -and (Test-Path -LiteralPath $openclawRoot -PathType Container)) {
    return $openclawRoot
  }
  if ($env:USERPROFILE -and (Test-Path -LiteralPath $env:USERPROFILE -PathType Container)) {
    return $env:USERPROFILE
  }
  return (Get-Location).Path
}

function Find-EmTroLyCodexCli {
  $emTroLyBase = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'EmTroLy' } else { '' }
  $emTroLyCodexHome = if ($emTroLyBase) { Join-Path $emTroLyBase 'Codex' } else { '' }
  $hasPrivateCodexHome = $emTroLyCodexHome -and
    (Test-Path -LiteralPath (Join-Path $emTroLyCodexHome 'config.toml') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $emTroLyCodexHome 'auth.json') -PathType Leaf)

  if ($emTroLyBase) {
    $extRoot = Join-Path $emTroLyBase 'Antigravity\Extensions'
    if (Test-Path -LiteralPath $extRoot -PathType Container) {
      $candidates = @(Get-ChildItem -LiteralPath $extRoot -Directory -Filter 'openai.chatgpt-*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
      foreach ($dir in $candidates) {
        $exe = Join-Path $dir.FullName 'bin\windows-x86_64\codex.exe'
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
          return [pscustomobject]@{
            Available = $true
            Executable = $exe
            CodexHome = if ($hasPrivateCodexHome) { $emTroLyCodexHome } else { '' }
            Source = 'emtroly'
            Label = 'Sẵn sàng · Codex riêng của Em Trợ Lý'
          }
        }
      }
    }

    $standaloneExe = Join-Path $emTroLyBase 'Codex\bin\codex.exe'
    if (Test-Path -LiteralPath $standaloneExe -PathType Leaf) {
      return [pscustomobject]@{
        Available = $true
        Executable = $standaloneExe
        CodexHome = if ($hasPrivateCodexHome) { $emTroLyCodexHome } else { '' }
        Source = 'emtroly'
        Label = 'Sẵn sàng · Codex CLI riêng của Em Trợ Lý'
      }
    }
  }

  $editorRoots = @()
  if ($env:USERPROFILE) {
    $editorRoots += (Join-Path $env:USERPROFILE '.antigravity\extensions')
    $editorRoots += (Join-Path $env:USERPROFILE '.vscode\extensions')
  }
  foreach ($root in $editorRoots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    $candidates = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'openai.chatgpt-*' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending)
    foreach ($dir in $candidates) {
      $exe = Join-Path $dir.FullName 'bin\windows-x86_64\codex.exe'
      if (Test-Path -LiteralPath $exe -PathType Leaf) {
        $defaultHome = if ($hasPrivateCodexHome) {
          $emTroLyCodexHome
        } elseif ($env:USERPROFILE -and (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.codex') -PathType Container)) {
          Join-Path $env:USERPROFILE '.codex'
        } else { '' }
        return [pscustomobject]@{
          Available = $true
          Executable = $exe
          CodexHome = $defaultHome
          Source = 'extension'
          Label = 'Sẵn sàng · Codex CLI trong tiện ích mở rộng'
        }
      }
    }
  }

  foreach ($cmdName in @('codex.exe', 'codex.cmd')) {
    $found = @(Get-Command $cmdName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($found.Count -gt 0 -and $found[0].Source -and (Test-Path -LiteralPath $found[0].Source -PathType Leaf)) {
      $defaultHome = if ($hasPrivateCodexHome) {
        $emTroLyCodexHome
      } elseif ($env:USERPROFILE -and (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.codex') -PathType Container)) {
        Join-Path $env:USERPROFILE '.codex'
      } else { '' }
      return [pscustomobject]@{
        Available = $true
        Executable = $found[0].Source
        CodexHome = $defaultHome
        Source = 'path'
        Label = 'Sẵn sàng · Codex CLI trên máy'
      }
    }
  }

  if ($emTroLyBase) {
    $autoHealCmd = Join-Path $emTroLyBase 'AutoHealCli\node_modules\.bin\codex.cmd'
    if (Test-Path -LiteralPath $autoHealCmd -PathType Leaf) {
      $autoHealJs = Join-Path $emTroLyBase 'AutoHealCli\node_modules\@openai\codex\bin\codex.js'
      $autoHealWinPkg = Join-Path $emTroLyBase 'AutoHealCli\node_modules\@openai\codex-win32-x64'
      if (-not (Test-Path -LiteralPath $autoHealJs -PathType Leaf) -or (Test-Path -LiteralPath $autoHealWinPkg -PathType Container)) {
        return [pscustomobject]@{
          Available = $true
          Executable = $autoHealCmd
          CodexHome = if ($hasPrivateCodexHome) { $emTroLyCodexHome } else { '' }
          Source = 'emtroly'
          Label = 'Sẵn sàng · Codex CLI tự sửa lỗi của Em Trợ Lý'
        }
      }
    }
  }

  return [pscustomobject]@{
    Available = $false
    Executable = ''
    CodexHome = if ($hasPrivateCodexHome) { $emTroLyCodexHome } else { '' }
    Source = 'none'
    Label = 'Chưa tìm thấy Codex CLI (hãy cài ở mục Cài đặt trước)'
  }
}

function Install-EmTroLyCodexCliFirst {
  param(
    [Parameter(Mandatory=$true)][psobject]$Settings,
    [string]$PayloadRoot = '',
    [string]$StatusFile = '',
    [string]$EditorJobId = '',
    [switch]$ForceConfigUpdate
  )
  if (-not $env:LOCALAPPDATA) {
    return [pscustomobject]@{ Installed = $false; Executable = ''; CodexHome = '' }
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $writeMsg = {
    param([string]$Msg)
    if ($StatusFile) {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Msg)
      for ($attempt = 1; $attempt -le 8; $attempt++) {
        $fs = $null
        try {
          $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
          $fs = New-Object System.IO.FileStream($StatusFile, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, $share)
          $fs.SetLength(0)
          if ($bytes.Length -gt 0) { $fs.Write($bytes, 0, $bytes.Length) }
          $fs.Flush()
          break
        } catch {
          if ($attempt -lt 8) { Start-Sleep -Milliseconds 20 }
        } finally {
          if ($null -ne $fs) { try { $fs.Dispose() } catch { } }
        }
      }
    }
  }

  & $writeMsg 'Đang cài đặt và cấu hình Codex CLI trước tiên...'

  $emBase = Join-Path $env:LOCALAPPDATA 'EmTroLy'
  $codexHome = Join-Path $emBase 'Codex'
  $codexBinDir = Join-Path $codexHome 'bin'
  $standaloneExe = Join-Path $codexBinDir 'codex.exe'
  $receiptPath = Join-Path $emBase 'installer-job.txt'

  $emBaseExistedBefore = Test-Path -LiteralPath $emBase -PathType Container
  if (-not $emBaseExistedBefore -and -not (Test-Path -LiteralPath $emBase)) {
    New-CodexPrivateDirectory $emBase
    if ($EditorJobId -match '^[a-f0-9]{32}$') {
      [IO.File]::WriteAllText($receiptPath, $EditorJobId, $utf8NoBom)
    }
  }
  if (-not (Test-Path -LiteralPath $codexHome -PathType Container)) {
    New-CodexPrivateDirectory $codexHome
  }

  $apiKey = if ($Settings -and $Settings.PSObject.Properties['ai_api_key']) { ([string]$Settings.ai_api_key).Trim() } else { '' }
  $model = if ($Settings -and $Settings.PSObject.Properties['model'] -and [string]$Settings.model -match '^[A-Za-z0-9._-]+$') { ([string]$Settings.model).Trim() } else { 'gpt-6.2-sol' }
  $baseUrl = if ($Settings -and $Settings.PSObject.Properties['base_url'] -and [string]$Settings.base_url -match '^https://') { ([string]$Settings.base_url).Trim().TrimEnd('/') } else { 'https://codex.anhlaptrinh.vn/v1' }
  $skipEditor = ($Settings -and $Settings.PSObject.Properties['skip_editor'] -and [bool]$Settings.skip_editor)

  # Only seed/update Codex config & auth if not colliding with a foreign completed EmTroLy folder
  $canWriteCodexConfig = $ForceConfigUpdate -or (-not $emBaseExistedBefore) -or
    (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) -or
    ($EditorJobId -and ([IO.File]::ReadAllText($receiptPath).Trim() -ceq $EditorJobId)) -or
    $skipEditor

  if ($canWriteCodexConfig -and -not [string]::IsNullOrWhiteSpace($apiKey)) {
    $cfgToml = @"
model_provider = "router"
model = "$model"
model_context_window = 272000
model_auto_compact_token_limit = 200000
cli_auth_credentials_store = "file"

[model_providers.router]
name = "router"
base_url = "$baseUrl"
wire_api = "responses"
requires_openai_auth = true
"@
    [IO.File]::WriteAllText((Join-Path $codexHome 'config.toml'), $cfgToml, $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $codexHome 'auth.json'), (@{ OPENAI_API_KEY = $apiKey } | ConvertTo-Json -Compress), $utf8NoBom)
  }

  $existingInfo = Find-EmTroLyCodexCli
  if ($existingInfo.Available -and ($existingInfo.Source -eq 'emtroly' -or $baseUrl -cne 'https://codex.anhlaptrinh.vn/v1') -and $existingInfo.Executable -and (Test-Path -LiteralPath $existingInfo.Executable -PathType Leaf)) {
    try { [void](Register-EmTroLyCodexCli -PayloadRoot $PayloadRoot) } catch { }
    $openclawBin = Join-Path $env:LOCALAPPDATA 'OpenClaw\bin'
    if ((Test-Path -LiteralPath $openclawBin -PathType Container) -and ($env:Path -notlike "*$openclawBin*")) {
      $env:Path = "$openclawBin;$env:Path"
    }
    return [pscustomobject]@{
      Installed  = $true
      Executable = $existingInfo.Executable
      CodexHome  = if ($existingInfo.CodexHome) { $existingInfo.CodexHome } else { $codexHome }
    }
  }

  # Fresh Windows PC: Download pinned Codex VSIX once, extract standalone codex.exe immediately, and cache VSIX for Antigravity step!
  $extensionVersion = '26.51111.21308'
  $extensionUrl = 'https://open-vsx.org/api/openai/chatgpt/win32-x64/26.51111.21308/file/openai.chatgpt-26.51111.21308@win32-x64.vsix'
  $extensionHash = '5abdd18242a77e85e60b8b727231924c4cdf048fdf5c39079e5d811390c3fca8'

  if ($env:OS -eq 'Windows_NT' -and $baseUrl -ceq 'https://codex.anhlaptrinh.vn/v1') {
    $cachedVsix = Join-Path $emBase ('codex-' + $extensionVersion + '.vsix')
    $vsixReady = (Test-Path -LiteralPath $cachedVsix -PathType Leaf) -and ((Get-FileHash -LiteralPath $cachedVsix -Algorithm SHA256).Hash -ieq $extensionHash)

    if (-not $vsixReady) {
      $tmpDlDir = Join-Path $env:TEMP ('emtroly-editor-' + [guid]::NewGuid().ToString('N'))
      [void][IO.Directory]::CreateDirectory($tmpDlDir)
      $tmpVsix = Join-Path $tmpDlDir 'codex.vsix'
      try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $knownTotalLen = 389000000L
        for ($dlTry = 1; $dlTry -le 3; $dlTry++) {
          $handler = $null
          $client = $null
          $inStream = $null
          $outStream = $null
          try {
            $resumeAt = if (Test-Path -LiteralPath $tmpVsix -PathType Leaf) { (Get-Item -LiteralPath $tmpVsix).Length } else { 0L }
            if ($resumeAt -gt 0 -and ((Get-FileHash -LiteralPath $tmpVsix -Algorithm SHA256).Hash -ieq $extensionHash)) {
              Move-Item -LiteralPath $tmpVsix -Destination $cachedVsix -Force
              $vsixReady = $true
              break
            }
            if ($resumeAt -eq 0) {
              & $writeMsg 'Đang tải gói Codex CLI & Extension (khoảng 370 MB)...'
              $handler = New-Object System.Net.Http.HttpClientHandler
              $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
              $client = New-Object System.Net.Http.HttpClient($handler)
              $client.Timeout = [TimeSpan]::FromMinutes(20)
              $resp = $client.GetAsync($extensionUrl, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
              [void]$resp.EnsureSuccessStatusCode()
              $totalLen = if ($resp.Content.Headers.ContentLength) { [long]$resp.Content.Headers.ContentLength } else { $knownTotalLen }
              $knownTotalLen = $totalLen
              $inStream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
              $outStream = New-Object System.IO.FileStream($tmpVsix, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read, 262144)
              $buf = New-Object byte[] 262144
              $readTotal = 0L
              $sw = [Diagnostics.Stopwatch]::StartNew()
              $lastTick = -2000L
              while (($n = $inStream.Read($buf, 0, $buf.Length)) -gt 0) {
                $outStream.Write($buf, 0, $n)
                $readTotal += $n
                if (($sw.ElapsedMilliseconds - $lastTick) -ge 450) {
                  $lastTick = $sw.ElapsedMilliseconds
                  $pct = [Math]::Min(99, [int][Math]::Floor(($readTotal * 100.0) / [Math]::Max(1L, $totalLen)))
                  $mbCur = [Math]::Round($readTotal / 1MB, 1)
                  $mbMax = [Math]::Round($totalLen / 1MB, 0)
                  $spd = [Math]::Round(($readTotal / 1MB) / [Math]::Max(0.1, $sw.Elapsed.TotalSeconds), 1)
                  & $writeMsg "Đang tải gói Codex CLI & Extension... $pct% ($mbCur / $mbMax MB · $spd MB/s)"
                }
              }
              $outStream.Flush()
              $outStream.Dispose(); $outStream = $null
              $inStream.Dispose(); $inStream = $null
              $client.Dispose(); $client = $null
              $handler.Dispose(); $handler = $null
              if ((Get-FileHash -LiteralPath $tmpVsix -Algorithm SHA256).Hash -ieq $extensionHash) {
                Move-Item -LiteralPath $tmpVsix -Destination $cachedVsix -Force
                $vsixReady = $true
                break
              }
              Remove-Item -LiteralPath $tmpVsix -Force -ErrorAction SilentlyContinue
            } else {
              throw 'resume-via-curl'
            }
          } catch {
            if ($outStream) { try { $outStream.Flush() } catch { }; try { $outStream.Dispose() } catch { } }
            if ($inStream) { try { $inStream.Dispose() } catch { } }
            if ($client) { try { $client.Dispose() } catch { } }
            if ($handler) { try { $handler.Dispose() } catch { } }
            $curlFallback = Join-Path $env:SystemRoot 'System32\curl.exe'
            if ((Test-Path -LiteralPath $curlFallback -PathType Leaf) -and $extensionUrl -match '^https://') {
              $prevEaCurl = $ErrorActionPreference
              try {
                $ErrorActionPreference = 'Continue'
                $stagnant = 0
                for ($hop = 1; $hop -le 120 -and $stagnant -lt 8; $hop++) {
                  $curVBytes = if (Test-Path -LiteralPath $tmpVsix -PathType Leaf) { (Get-Item -LiteralPath $tmpVsix).Length } else { 0L }
                  $mbVHop = [Math]::Round($curVBytes / 1MB, 1)
                  $mbVMax = [Math]::Round($knownTotalLen / 1MB, 0)
                  $pctVHop = [Math]::Min(99, [int][Math]::Floor(($curVBytes * 100.0) / [Math]::Max(1L, $knownTotalLen)))
                  & $writeMsg "Đang tải nối tiếp Codex VSIX... $pctVHop% ($mbVHop / $mbVMax MB · chặng $hop)"
                  & $curlFallback -sS --fail --location --http1.1 --tlsv1.2 --connect-timeout 25 --max-time 180 --speed-limit 10240 --speed-time 15 -A 'AnhLapTrinh-EmTroLy-Installer/1.0' -C - -o $tmpVsix $extensionUrl 2>$null
                  $curlRc = $LASTEXITCODE
                  if (Test-Path -LiteralPath $tmpVsix -PathType Leaf) {
                    $newVBytes = (Get-Item -LiteralPath $tmpVsix).Length
                    if ($curlRc -eq 0 -or $newVBytes -ge $knownTotalLen) {
                      if ((Get-FileHash -LiteralPath $tmpVsix -Algorithm SHA256).Hash -ieq $extensionHash) {
                        Move-Item -LiteralPath $tmpVsix -Destination $cachedVsix -Force
                        $vsixReady = $true
                        break
                      }
                      if ($curlRc -eq 0) {
                        Remove-Item -LiteralPath $tmpVsix -Force -ErrorAction SilentlyContinue
                        $stagnant++
                        continue
                      }
                    }
                    if ($curlRc -eq 33 -or $newVBytes -lt $curVBytes) {
                      Remove-Item -LiteralPath $tmpVsix -Force -ErrorAction SilentlyContinue
                      $stagnant++
                    } elseif ($newVBytes -gt $curVBytes) {
                      $stagnant = 0
                    } else {
                      $stagnant++
                    }
                  } else {
                    $stagnant++
                  }
                  if ($hop -lt 120) { Start-Sleep -Milliseconds 150 }
                }
                if ($vsixReady) { break }
              } catch {
              } finally {
                $ErrorActionPreference = $prevEaCurl
              }
            }
            if ($dlTry -lt 3) { Start-Sleep -Seconds (2 * $dlTry) }
          }
        }
      } finally {
        if (Test-Path -LiteralPath $tmpDlDir) { Remove-Item -LiteralPath $tmpDlDir -Recurse -Force -ErrorAction SilentlyContinue }
      }
    }

    if ($vsixReady -and $canWriteCodexConfig) {
      & $writeMsg 'Đang giải nén và kích hoạt Codex CLI...'
      try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [void][IO.Directory]::CreateDirectory($codexBinDir)
        $zip = [System.IO.Compression.ZipFile]::OpenRead($cachedVsix)
        try {
          $entry = $zip.Entries | Where-Object { $_.FullName -replace '\\','/' -ieq 'extension/bin/windows-x86_64/codex.exe' } | Select-Object -First 1
          if ($entry) {
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $standaloneExe, $true)
          }
        } finally {
          $zip.Dispose()
        }
      } catch { }
      if ($skipEditor -and (Test-Path -LiteralPath $standaloneExe -PathType Leaf)) {
        Remove-Item -LiteralPath $cachedVsix -Force -ErrorAction SilentlyContinue
      }
    }
  }

  # Fallback to npm @openai/codex if standalone VSIX extraction wasn't available
  if (-not (Test-Path -LiteralPath $standaloneExe -PathType Leaf) -and (Get-Command Ensure-AutoHealCodexBinary -ErrorAction SilentlyContinue)) {
    if ($env:OS -eq 'Windows_NT' -and $baseUrl -ceq 'https://codex.anhlaptrinh.vn/v1') {
      try { [void](Ensure-AutoHealCodexBinary -PayloadRoot $PayloadRoot) } catch { }
    }
  }

  $finalInfo = Find-EmTroLyCodexCli
  if ($finalInfo.Available) {
    try { [void](Register-EmTroLyCodexCli -PayloadRoot $PayloadRoot) } catch { }
    $openclawBin = Join-Path $env:LOCALAPPDATA 'OpenClaw\bin'
    if ((Test-Path -LiteralPath $openclawBin -PathType Container) -and ($env:Path -notlike "*$openclawBin*")) {
      $env:Path = "$openclawBin;$env:Path"
    }
  }

  return [pscustomobject]@{
    Installed  = [bool]$finalInfo.Available
    Executable = [string]$finalInfo.Executable
    CodexHome  = if ($finalInfo.CodexHome) { [string]$finalInfo.CodexHome } else { $codexHome }
  }
}

function Format-CodexProcessArgument([string]$Value) {
  if ($Value -match '[\r\n]') { throw 'codex-invalid-argument' }
  if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
  $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
  return '"' + $escaped + '"'
}

function New-CodexExecArgumentString {
  param(
    [Parameter(Mandatory=$true)][string]$WorkspaceDir,
    [bool]$AllowEdit = $true,
    [string]$LastMessageFile = '',
    [string]$Model = ''
  )
  $sandboxMode = if ($AllowEdit) { 'danger-full-access' } else { 'read-only' }
  $parts = @(
    'exec',
    '--skip-git-repo-check',
    '--color', 'never',
    '--sandbox', $sandboxMode,
    '-C', (Format-CodexProcessArgument $WorkspaceDir)
  )
  if (-not [string]::IsNullOrWhiteSpace($Model) -and $Model -match '^[A-Za-z0-9._/-]+$') {
    $parts += @('-m', (Format-CodexProcessArgument $Model))
  }
  if (-not [string]::IsNullOrWhiteSpace($LastMessageFile)) {
    $parts += @('-o', (Format-CodexProcessArgument $LastMessageFile))
  }
  $parts += '-'
  return ($parts -join ' ')
}

function New-CodexPrivateDirectory([string]$Path) {
  $acl = New-Object System.Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
  foreach ($identity in @($user, $system)) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
      $identity,
      [System.Security.AccessControl.FileSystemRights]::FullControl,
      $inherit,
      [System.Security.AccessControl.PropagationFlags]::None,
      [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule)
  }
  [void][IO.Directory]::CreateDirectory($Path, $acl)
}

function Escape-BatchLiteralValue([string]$Value) {
  if ($null -eq $Value) { return '' }
  if ($Value -match '[\r\n"\x00]') { throw 'codex-invalid-executable' }
  return $Value.Replace('%', '%%')
}

function Start-CodexInteractiveWindow {
  param(
    [Parameter(Mandatory=$true)][string]$WorkspaceDir,
    [string]$Model = ''
  )
  $info = Find-EmTroLyCodexCli
  if (-not $info.Available) { throw 'codex-cli-missing' }
  if (-not (Test-Path -LiteralPath $WorkspaceDir -PathType Container)) { throw 'codex-workspace-missing' }
  if ($info.Executable -match '[\r\n"\x00]') { throw 'codex-invalid-executable' }

  $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $cliArgs = @('--no-alt-screen')
  if (-not [string]::IsNullOrWhiteSpace($Model) -and $Model -match '^[A-Za-z0-9._/-]+$') {
    $cliArgs += @('-m', (Format-CodexProcessArgument $Model))
  }
  $innerCmd = '"' + $info.Executable + '" ' + ($cliArgs -join ' ')
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $cmdExe
  $startInfo.Arguments = '/d /s /k ""' + $innerCmd + '""'
  $startInfo.WorkingDirectory = $WorkspaceDir
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $false
  if (-not [string]::IsNullOrWhiteSpace($info.CodexHome)) {
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $info.CodexHome
    if (Test-Path -LiteralPath (Join-Path $info.CodexHome 'auth.json') -PathType Leaf) {
      [void]$startInfo.EnvironmentVariables.Remove('OPENAI_API_KEY')
    }
  }
  foreach ($varName in @('ELECTRON_RUN_AS_NODE', 'VSCODE_IPC_HOOK_CLI', 'NODE_OPTIONS', 'VSCODE_DEV')) {
    [void]$startInfo.EnvironmentVariables.Remove($varName)
  }
  [void][Diagnostics.Process]::Start($startInfo)
}

function Register-EmTroLyCodexCli {
  param([string]$PayloadRoot = '')
  $info = Find-EmTroLyCodexCli
  if (-not $info.Available -or $info.Source -ne 'emtroly' -or [string]::IsNullOrWhiteSpace($info.Executable)) {
    return [pscustomobject]@{ Registered = $false; Command = ''; Path = '' }
  }
  if (-not $env:LOCALAPPDATA) {
    return [pscustomobject]@{ Registered = $false; Command = ''; Path = '' }
  }
  $escapedExe = Escape-BatchLiteralValue $info.Executable
  $escapedHome = if ($info.CodexHome) { Escape-BatchLiteralValue $info.CodexHome } else { '' }

  $binDir = Join-Path $env:LOCALAPPDATA 'OpenClaw\bin'
  [void][IO.Directory]::CreateDirectory($binDir)

  $shimLines = @(
    '@echo off',
    '"%SystemRoot%\System32\chcp.com" 65001 >nul',
    'setlocal DisableDelayedExpansion',
    'set "OPENAI_API_KEY="',
    'set "ELECTRON_RUN_AS_NODE="',
    'set "VSCODE_IPC_HOOK_CLI="',
    'set "NODE_OPTIONS="',
    'set "VSCODE_DEV="'
  )
  if (-not [string]::IsNullOrWhiteSpace($escapedHome)) {
    $shimLines += ('set "CODEX_HOME=' + $escapedHome + '"')
  }
  $shimLines += ('"' + $escapedExe + '" %*')
  $shimLines += 'exit /b %errorlevel%'
  $shimBody = ($shimLines -join "`r`n") + "`r`n"
  $asciiEnc = [System.Text.Encoding]::ASCII
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $shimEnc = if ($shimBody -match '[^\u0000-\u007F]') { $utf8NoBom } else { $asciiEnc }

  $aliasPath = Join-Path $binDir 'codex-emtroly.cmd'
  [IO.File]::WriteAllText($aliasPath, $shimBody, $shimEnc)

  $defaultShim = Join-Path $binDir 'codex.cmd'
  $hasExternalConflict = $false
  $existingCmds = @(Get-Command codex, codex.exe, codex.cmd -CommandType Application -ErrorAction SilentlyContinue)
  foreach ($cmd in $existingCmds) {
    if ($cmd.Source -and ($cmd.Source.TrimEnd('\') -ine $defaultShim.TrimEnd('\'))) {
      $cmdDir = Split-Path -Parent $cmd.Source
      if ($cmdDir.TrimEnd('\') -ine $binDir.TrimEnd('\')) {
        $hasExternalConflict = $true
        break
      }
    }
  }
  $selectedCommand = 'codex-emtroly'
  $selectedPath = $aliasPath
  if (-not $hasExternalConflict) {
    [IO.File]::WriteAllText($defaultShim, $shimBody, $shimEnc)
    $selectedCommand = 'codex'
    $selectedPath = $defaultShim
  }

  if (-not [string]::IsNullOrWhiteSpace($PayloadRoot)) {
    try {
      $emUiDir = Join-Path $env:LOCALAPPDATA 'EmTroLyUI'
      $emWinDir = Join-Path $emUiDir 'windows-installer'
      [void][IO.Directory]::CreateDirectory($emWinDir)
      $isSameRoot = $false
      if (Test-Path -LiteralPath $PayloadRoot -PathType Container) {
        try {
          $isSameRoot = ([IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\') -ieq [IO.Path]::GetFullPath($emUiDir).TrimEnd('\'))
        } catch { }
      }
      if (-not $isSameRoot -and (Test-Path -LiteralPath $PayloadRoot -PathType Container)) {
        $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
        foreach ($name in @(
          'wizard.ps1', 'wizard-helpers.ps1', 'codex-cli.ps1', 'auto-heal-codex.ps1',
          'manage-instance.ps1', 'validation.ps1', 'repair-antigravity-shortcut.ps1',
          'install-antigravity-codex.ps1', 'run-native-install.ps1', 'verify-openclaw-command.ps1'
        )) {
          $srcFile = Join-Path $PayloadRoot ('windows-installer\' + $name)
          if (Test-Path -LiteralPath $srcFile -PathType Leaf) {
            $txt = [IO.File]::ReadAllText($srcFile, [System.Text.Encoding]::UTF8)
            [IO.File]::WriteAllText((Join-Path $emWinDir $name), $txt, $utf8WithBom)
          }
        }
        foreach ($assetName in @('zalo-qr-session.mjs', 'alt.ico', 'launch-wizard.vbs')) {
          $assetSrc = Join-Path $PayloadRoot ('windows-installer\' + $assetName)
          if (Test-Path -LiteralPath $assetSrc -PathType Leaf) {
            Copy-Item -LiteralPath $assetSrc -Destination (Join-Path $emWinDir $assetName) -Force
          }
        }
        $probeSrc = Join-Path $PayloadRoot 'windows-installer\activation-probe'
        if (Test-Path -LiteralPath $probeSrc -PathType Container) {
          $probeDst = Join-Path $emWinDir 'activation-probe'
          [void][IO.Directory]::CreateDirectory($probeDst)
          Copy-Item -Path (Join-Path $probeSrc '*') -Destination $probeDst -Recurse -Force
        }
        foreach ($rf in @('alt.png', 'MANIFEST.txt', 'configure.py')) {
          $rSrc = Join-Path $PayloadRoot $rf
          if (Test-Path -LiteralPath $rSrc -PathType Leaf) {
            Copy-Item -LiteralPath $rSrc -Destination (Join-Path $emUiDir $rf) -Force
          }
        }
        $nativeRootPs = Join-Path $PayloadRoot 'install-native-windows.ps1'
        if (Test-Path -LiteralPath $nativeRootPs -PathType Leaf) {
          $nativeTxt = [IO.File]::ReadAllText($nativeRootPs, [System.Text.Encoding]::UTF8)
          [IO.File]::WriteAllText((Join-Path $emUiDir 'install-native-windows.ps1'), $nativeTxt, $utf8WithBom)
        }
        foreach ($subDir in @('native', 'modules', 'profiles', 'zalo')) {
          $subSrc = Join-Path $PayloadRoot $subDir
          if (Test-Path -LiteralPath $subSrc -PathType Container) {
            $subDst = Join-Path $emUiDir $subDir
            [void][IO.Directory]::CreateDirectory($subDst)
            Copy-Item -Path (Join-Path $subSrc '*') -Destination $subDst -Recurse -Force
          }
        }
      }
      $uiLauncher = Join-Path $binDir 'emtroly-ui.cmd'
      $uiWizard = Join-Path $emWinDir 'wizard.ps1'
      $uiVbs = Join-Path $emUiDir 'launch-emtroly-codex-ui.vbs'
      if ((Test-Path -LiteralPath $uiWizard -PathType Leaf) -and $uiWizard -notmatch '[\r\n"\x00]' -and $uiVbs -notmatch '[\r\n"\x00]') {
        $psExePath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $codexVbsBody = @"
Option Explicit
Dim shell, command
Set shell = CreateObject("WScript.Shell")
shell.CurrentDirectory = "$($emUiDir.Replace('"','""'))"
command = Chr(34) & "$($psExePath.Replace('"','""'))" & Chr(34) & " -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & "$($uiWizard.Replace('"','""'))" & Chr(34) & " -PayloadRoot " & Chr(34) & "$($emUiDir.Replace('"','""'))" & Chr(34) & " -CodexMode"
shell.Run command, 0, False
Set shell = Nothing
"@
        [IO.File]::WriteAllText($uiVbs, $codexVbsBody, [System.Text.Encoding]::Unicode)
        $escapedUiVbs = Escape-BatchLiteralValue $uiVbs
        $uiBody = "@echo off`r`n`"%SystemRoot%\System32\chcp.com`" 65001 >nul`r`nsetlocal DisableDelayedExpansion`r`n`"%SystemRoot%\System32\wscript.exe`" //B //Nologo `"$escapedUiVbs`"`r`n"
        $uiEnc = if ($uiBody -match '[^\u0000-\u007F]') { $utf8NoBom } else { $asciiEnc }
        [IO.File]::WriteAllText($uiLauncher, $uiBody, $uiEnc)
      }
    } catch { }
  }

  $codexCliMeta = @{
    command = $selectedCommand
    alias = 'codex-emtroly'
    path = $selectedPath
    default = (-not $hasExternalConflict)
  } | ConvertTo-Json
  [IO.File]::WriteAllText((Join-Path (Join-Path $env:LOCALAPPDATA 'EmTroLy') 'codex-cli.json'), $codexCliMeta, $utf8NoBom)

  return [pscustomobject]@{
    Registered = $true
    Command = $selectedCommand
    Path = $selectedPath
  }
}

function Invoke-CodexWorker {
  param(
    [Parameter(Mandatory=$true)][string]$RequestPath,
    [Parameter(Mandatory=$true)][string]$LogPath
  )
  $ErrorActionPreference = 'Stop'
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $tempCodexHome = $null
  $lastMessageFile = "$LogPath.last"
  $pidFile = "$LogPath.pid"
  $secretKey = ''

  function Append-WorkerLine([string]$Line) {
    $safe = Protect-CodexOutputText -Text $Line -SecretKey $secretKey
    [IO.File]::AppendAllText($LogPath, ($safe + [Environment]::NewLine), $utf8NoBom)
  }

  try {
    $request = $null
    try {
      $request = [IO.File]::ReadAllText($RequestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } finally {
      Remove-Item -LiteralPath $RequestPath -Force -ErrorAction SilentlyContinue
    }

    $executable = [string]$request.executable
    $workspace = [string]$request.workspace
    $prompt = [string]$request.prompt
    $allowEdit = [bool]$request.allow_edit
    $codexHome = [string]$request.codex_home
    $model = [string]$request.model
    $baseUrl = ([string]$request.base_url).Trim().TrimEnd('/')
    $secretKey = [string]$request.api_key

    if ([string]::IsNullOrWhiteSpace($executable) -or -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
      Append-WorkerLine 'Không tìm thấy tệp thực thi Codex CLI trên máy.'
      exit 2
    }
    if ([string]::IsNullOrWhiteSpace($workspace) -or -not (Test-Path -LiteralPath $workspace -PathType Container)) {
      Append-WorkerLine 'Thư mục cần chỉnh sửa không tồn tại. Vui lòng chọn lại thư mục hợp lệ.'
      exit 2
    }
    if ([string]::IsNullOrWhiteSpace($prompt)) {
      Append-WorkerLine 'Chưa có nội dung yêu cầu cho Codex CLI.'
      exit 2
    }

    if (-not [string]::IsNullOrWhiteSpace($codexHome)) {
      Repair-EmTroLyCodexConfigFile -CodexHome $codexHome -PreferredModel $model
    }

    if ([string]::IsNullOrWhiteSpace($codexHome) -and -not [string]::IsNullOrWhiteSpace($secretKey)) {
      $tempCodexHome = Join-Path (Split-Path -Parent $LogPath) ('codex-home-' + [guid]::NewGuid().ToString('N'))
      New-CodexPrivateDirectory $tempCodexHome
      $selectedModel = if (-not [string]::IsNullOrWhiteSpace($model) -and $model -match '^[A-Za-z0-9._-]+$') { $model } else { 'gpt-6.2-sol' }
      $selectedUrl = if ($baseUrl -match '^https://') { $baseUrl } else { 'https://codex.anhlaptrinh.vn/v1' }
      $cfg = @"
model_provider = "router"
model = "$selectedModel"
model_context_window = 272000
model_auto_compact_token_limit = 200000
cli_auth_credentials_store = "file"

[model_providers.router]
name = "router"
base_url = "$selectedUrl"
wire_api = "responses"
requires_openai_auth = true
"@
      [IO.File]::WriteAllText((Join-Path $tempCodexHome 'config.toml'), $cfg, $utf8NoBom)
      $authJson = @{ OPENAI_API_KEY = $secretKey } | ConvertTo-Json -Compress
      [IO.File]::WriteAllText((Join-Path $tempCodexHome 'auth.json'), $authJson, $utf8NoBom)
      $codexHome = $tempCodexHome
    }

    $modeLabel = if ($allowEdit) { 'Cho phép tự động đọc & chỉnh sửa tệp' } else { 'Chỉ kiểm tra & trả lời (read-only)' }
    Append-WorkerLine "Đang gửi yêu cầu tới Codex CLI..."
    Append-WorkerLine "Thư mục: $workspace"
    Append-WorkerLine "Chế độ : $modeLabel"
    Append-WorkerLine "------------------------------------------------------------"

    $argString = New-CodexExecArgumentString -WorkspaceDir $workspace -AllowEdit $allowEdit -LastMessageFile $lastMessageFile -Model $model
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    if ($executable -match '\.(cmd|bat)$') {
      $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
      $startInfo.FileName = $cmdExe
      $startInfo.Arguments = '/d /s /c ""' + $executable + '" ' + $argString + '"'
    } else {
      $startInfo.FileName = $executable
      $startInfo.Arguments = $argString
    }
    $startInfo.WorkingDirectory = $workspace
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8

    $startInfo.EnvironmentVariables['NO_COLOR'] = '1'
    $startInfo.EnvironmentVariables['PYTHONUTF8'] = '1'
    foreach ($varName in @('ELECTRON_RUN_AS_NODE', 'VSCODE_IPC_HOOK_CLI', 'NODE_OPTIONS', 'VSCODE_DEV')) {
      [void]$startInfo.EnvironmentVariables.Remove($varName)
    }
    if (-not [string]::IsNullOrWhiteSpace($codexHome)) {
      $startInfo.EnvironmentVariables['CODEX_HOME'] = $codexHome
      if (Test-Path -LiteralPath (Join-Path $codexHome 'auth.json') -PathType Leaf) {
        [void]$startInfo.EnvironmentVariables.Remove('OPENAI_API_KEY')
      }
    }

    [Console]::InputEncoding = $utf8NoBom
    [Console]::OutputEncoding = $utf8NoBom
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $startInfo
    [void]$proc.Start()
    [IO.File]::WriteAllText($pidFile, [string]$proc.Id, [Text.Encoding]::ASCII)

    $stderrSeenLines = New-Object 'System.Collections.Generic.HashSet[string]'
    $outTask = $proc.StandardOutput.ReadLineAsync()
    $errTask = $proc.StandardError.ReadLineAsync()
    try {
      $proc.StandardInput.WriteLine($prompt)
      $proc.StandardInput.Flush()
    } catch { } finally {
      try { $proc.StandardInput.Close() } catch { }
    }
    while ($null -ne $outTask -or $null -ne $errTask) {
      $activeTasks = @()
      if ($null -ne $outTask) { $activeTasks += $outTask }
      if ($null -ne $errTask) { $activeTasks += $errTask }
      $completedIndex = [System.Threading.Tasks.Task]::WaitAny($activeTasks, 250)
      if ($completedIndex -lt 0) { continue }
      $finished = $activeTasks[$completedIndex]
      if ($finished -eq $outTask) {
        $line = $outTask.GetAwaiter().GetResult()
        if ($null -eq $line) {
          $outTask = $null
        } else {
          $cleanOut = Remove-AnsiEscapeCodes $line
          if (-not (Test-ShouldSkipCodexNoiseLine $cleanOut)) {
            $trimmedOut = $cleanOut.Trim()
            if ([string]::IsNullOrEmpty($trimmedOut) -or -not $stderrSeenLines.Contains($trimmedOut)) {
              Append-WorkerLine $line
            }
          }
          $outTask = $proc.StandardOutput.ReadLineAsync()
        }
      } elseif ($finished -eq $errTask) {
        $line = $errTask.GetAwaiter().GetResult()
        if ($null -eq $line) {
          $errTask = $null
        } else {
          $cleanErr = Remove-AnsiEscapeCodes $line
          if (-not (Test-ShouldSkipCodexNoiseLine $cleanErr)) {
            $trimmedErr = $cleanErr.Trim()
            if (-not [string]::IsNullOrEmpty($trimmedErr)) {
              [void]$stderrSeenLines.Add($trimmedErr)
            }
            Append-WorkerLine $line
          }
          $errTask = $proc.StandardError.ReadLineAsync()
        }
      }
    }

    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    $proc.Dispose()

    if (Test-Path -LiteralPath $lastMessageFile -PathType Leaf) {
      $finalText = ([IO.File]::ReadAllText($lastMessageFile, [Text.Encoding]::UTF8)).Trim()
      if (-not [string]::IsNullOrWhiteSpace($finalText)) {
        $existingLog = if (Test-Path -LiteralPath $LogPath -PathType Leaf) { [IO.File]::ReadAllText($LogPath, [Text.Encoding]::UTF8) } else { '' }
        if (-not $existingLog.Contains($finalText)) {
          Append-WorkerLine ''
          Append-WorkerLine '--- Kết quả từ Codex ---'
          Append-WorkerLine $finalText
        }
      }
    }

    Append-WorkerLine '------------------------------------------------------------'
    if ($exitCode -eq 0) {
      Append-WorkerLine 'Hoàn tất yêu cầu Codex CLI thành công.'
    } else {
      Append-WorkerLine "Codex CLI kết thúc với mã trạng thái $exitCode. Hãy kiểm tra khóa API, kết nối mạng hoặc nội dung yêu cầu."
    }
    exit $exitCode
  } catch {
    Append-WorkerLine ('Không thể chạy Codex CLI: ' + $_.Exception.Message)
    exit 1
  } finally {
    Remove-Item -LiteralPath $RequestPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $lastMessageFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    if ($tempCodexHome -and (Test-Path -LiteralPath $tempCodexHome)) {
      Remove-Item -LiteralPath $tempCodexHome -Recurse -Force -ErrorAction SilentlyContinue
    }
    $secretKey = ''
  }
}

if ($RunWorker) {
  Invoke-CodexWorker -RequestPath $RequestFile -LogPath $OutputFile
}
