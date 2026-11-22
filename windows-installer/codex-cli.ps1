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

  return [pscustomobject]@{
    Available = $false
    Executable = ''
    CodexHome = if ($hasPrivateCodexHome) { $emTroLyCodexHome } else { '' }
    Source = 'none'
    Label = 'Chưa tìm thấy Codex CLI (hãy cài ở mục Cài đặt trước)'
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

function Start-CodexInteractiveWindow {
  param(
    [Parameter(Mandatory=$true)][string]$WorkspaceDir,
    [string]$Model = ''
  )
  $info = Find-EmTroLyCodexCli
  if (-not $info.Available) { throw 'codex-cli-missing' }
  if (-not (Test-Path -LiteralPath $WorkspaceDir -PathType Container)) { throw 'codex-workspace-missing' }
  if ($info.Executable -match '[\r\n"%&|<>^]') { throw 'codex-invalid-executable' }

  $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $cliArgs = @('--no-alt-screen')
  if (-not [string]::IsNullOrWhiteSpace($Model) -and $Model -match '^[A-Za-z0-9._/-]+$') {
    $cliArgs += @('-m', (Format-CodexProcessArgument $Model))
  }
  $innerCmd = '"' + $info.Executable + '" ' + ($cliArgs -join ' ')
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $cmdExe
  $startInfo.Arguments = '/d /k "' + $innerCmd + '"'
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
  if ($info.Executable -match '[\r\n"%&|<>^]' -or ($info.CodexHome -and $info.CodexHome -match '[\r\n"%&|<>^]')) {
    throw 'codex-invalid-executable'
  }

  $binDir = Join-Path $env:LOCALAPPDATA 'OpenClaw\bin'
  [void][IO.Directory]::CreateDirectory($binDir)

  $shimLines = @(
    '@echo off',
    'setlocal',
    'set "OPENAI_API_KEY="',
    'set "ELECTRON_RUN_AS_NODE="',
    'set "VSCODE_IPC_HOOK_CLI="',
    'set "NODE_OPTIONS="',
    'set "VSCODE_DEV="'
  )
  if (-not [string]::IsNullOrWhiteSpace($info.CodexHome)) {
    $shimLines += ('set "CODEX_HOME=' + $info.CodexHome + '"')
  }
  $shimLines += ('"' + $info.Executable + '" %*')
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
      foreach ($name in @('wizard.ps1', 'wizard-helpers.ps1', 'codex-cli.ps1', 'auto-heal-codex.ps1', 'manage-instance.ps1', 'validation.ps1')) {
        $srcFile = Join-Path $PayloadRoot ('windows-installer\' + $name)
        if (Test-Path -LiteralPath $srcFile -PathType Leaf) {
          $txt = [IO.File]::ReadAllText($srcFile, [System.Text.Encoding]::UTF8)
          [IO.File]::WriteAllText((Join-Path $emWinDir $name), $txt, (New-Object System.Text.UTF8Encoding($true)))
        }
      }
      $qrBridge = Join-Path $PayloadRoot 'windows-installer\zalo-qr-session.mjs'
      if (Test-Path -LiteralPath $qrBridge -PathType Leaf) {
        Copy-Item -LiteralPath $qrBridge -Destination (Join-Path $emWinDir 'zalo-qr-session.mjs') -Force
      }
      foreach ($rf in @('alt.png', 'MANIFEST.txt')) {
        $rSrc = Join-Path $PayloadRoot $rf
        if (Test-Path -LiteralPath $rSrc -PathType Leaf) {
          Copy-Item -LiteralPath $rSrc -Destination (Join-Path $emUiDir $rf) -Force
        }
      }
      $icoSrc = Join-Path $PayloadRoot 'windows-installer\alt.ico'
      if (Test-Path -LiteralPath $icoSrc -PathType Leaf) {
        Copy-Item -LiteralPath $icoSrc -Destination (Join-Path $emWinDir 'alt.ico') -Force
      }
      $uiLauncher = Join-Path $binDir 'emtroly-ui.cmd'
      $uiWizard = Join-Path $emWinDir 'wizard.ps1'
      $uiVbs = Join-Path $emUiDir 'launch-emtroly-codex-ui.vbs'
      if ((Test-Path -LiteralPath $uiWizard -PathType Leaf) -and $uiWizard -notmatch '[\r\n"%&|<>^]') {
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
        $uiBody = "@echo off`r`n`"%SystemRoot%\System32\wscript.exe`" //B //Nologo `"$uiVbs`"`r`n"
        [IO.File]::WriteAllText($uiLauncher, $uiBody, $shimEnc)
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

    $proc.StandardInput.WriteLine($prompt)
    $proc.StandardInput.Flush()
    $proc.StandardInput.Close()

    $stderrSeenLines = New-Object 'System.Collections.Generic.HashSet[string]'
    $outTask = $proc.StandardOutput.ReadLineAsync()
    $errTask = $proc.StandardError.ReadLineAsync()
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
