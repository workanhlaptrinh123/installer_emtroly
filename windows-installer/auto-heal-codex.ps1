function Test-IsAutoHealableError([string]$ErrorCode, [string]$Stage = '') {
  if ([string]::IsNullOrWhiteSpace($ErrorCode)) { return $false }
  $nonHealable = @(
    'invalid-member',
    'missing-assistant-name',
    'invalid-owners',
    'invalid-group',
    'invalid-telegram-token',
    'missing-api-key',
    'invalid-model',
    'invalid-base-url',
    'invalid-port',
    'full-access-consent-required',
    'invalid-qr-owner',
    'zalo-required',
    'unsupported-architecture',
    'instance-exists',
    'provider-unavailable',
    'provider-model-unavailable',
    'telegram-unavailable',
    'telegram-invalid-bot',
    'invalid-editor-job',
    'editor-busy',
    'editor-data-exists',
    'editor-provider-unsupported',
    'editor-api-key-missing',
    'editor-download-checksum',
    'editor-installer-signature-invalid',
    'FFmpeg checksum verification failed.',
    'Portable Node checksum verification failed.',
    'Python installer signature verification failed.'
  )
  if ($ErrorCode -in $nonHealable) { return $false }
  if ($Stage -in @('input', 'provider', 'telegram')) { return $false }
  return $true
}

function Remove-SensitiveStrings {
  param(
    [string]$Text = '',
    [string[]]$Secrets = @()
  )
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $clean = $Text
  foreach ($sec in @($Secrets)) {
    if (-not [string]::IsNullOrWhiteSpace($sec) -and $sec.Length -ge 6) {
      $clean = $clean.Replace($sec, '[REDACTED_SECRET]')
    }
  }
  $clean = [regex]::Replace($clean, '[0-9]{5,}:[A-Za-z0-9_-]{20,}', '[REDACTED_TELEGRAM_TOKEN]')
  $clean = [regex]::Replace($clean, 'sk-[A-Za-z0-9_-]{12,}', '[REDACTED_API_KEY]')
  $clean = [regex]::Replace($clean, '("token"\s*:\s*")[0-9a-fA-F]{24,}(")', '$1[REDACTED_GATEWAY_TOKEN]$2')
  return $clean
}

function Test-EmTroLyCodexBinaryRunnable {
  param([string]$Executable)
  if ([string]::IsNullOrWhiteSpace($Executable) -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    return $false
  }
  $norm = $Executable.Replace('/', '\')
  if ($norm -match '\\AutoHealCli\\node_modules\\\.bin\\codex\.cmd$') {
    $healRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Executable))
    $jsEntry = Join-Path $healRoot 'node_modules\@openai\codex\bin\codex.js'
    if (Test-Path -LiteralPath $jsEntry -PathType Leaf) {
      $winOptPkg = Join-Path $healRoot 'node_modules\@openai\codex-win32-x64'
      if (-not (Test-Path -LiteralPath $winOptPkg -PathType Container)) {
        return $false
      }
      try {
        $psiProbe = New-Object System.Diagnostics.ProcessStartInfo
        $psiProbe.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psiProbe.Arguments = '/d /s /c ""' + $Executable + '" --version"'
        $psiProbe.UseShellExecute = $false
        $psiProbe.CreateNoWindow = $true
        $psiProbe.RedirectStandardOutput = $true
        $psiProbe.RedirectStandardError = $true
        [void]$psiProbe.EnvironmentVariables.Remove('NODE_OPTIONS')
        $pProbe = [System.Diagnostics.Process]::Start($psiProbe)
        if (-not $pProbe.WaitForExit(15000)) {
          try { $pProbe.Kill() } catch { }
          try { $pProbe.Dispose() } catch { }
          return $false
        }
        $ecProbe = $pProbe.ExitCode
        try { $pProbe.Dispose() } catch { }
        return ($ecProbe -eq 0)
      } catch {
        return $false
      }
    }
  }
  return $true
}

function Ensure-AutoHealCodexBinary {
  param([string]$PayloadRoot = '')
  if (Get-Command Find-EmTroLyCodexCli -ErrorAction SilentlyContinue) {
    $found = Find-EmTroLyCodexCli
    if ($found.Available -and $found.Executable -and (Test-EmTroLyCodexBinaryRunnable -Executable $found.Executable)) {
      return $found.Executable
    }
  }
  foreach ($cmdName in @('codex.exe', 'codex.cmd')) {
    $cmd = @(Get-Command $cmdName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($cmd.Count -gt 0 -and $cmd[0].Source -and (Test-EmTroLyCodexBinaryRunnable -Executable $cmd[0].Source)) {
      return $cmd[0].Source
    }
  }

  if (-not $env:LOCALAPPDATA) { return '' }

  # Fast offline win: if a cached Codex VSIX already exists in EmTroLy, extract standalone codex.exe directly
  $emTroLyDir = Join-Path $env:LOCALAPPDATA 'EmTroLy'
  $standaloneCodex = Join-Path $emTroLyDir 'Codex\bin\codex.exe'
  if (-not (Test-Path -LiteralPath $standaloneCodex -PathType Leaf) -and (Test-Path -LiteralPath $emTroLyDir -PathType Container)) {
    $cachedVsix = @(Get-ChildItem -LiteralPath $emTroLyDir -Filter 'codex-*.vsix' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($cachedVsix.Count -gt 0) {
      try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $standaloneCodex))
        $zip = [System.IO.Compression.ZipFile]::OpenRead($cachedVsix[0].FullName)
        try {
          $entry = $zip.Entries | Where-Object { $_.FullName -replace '\\','/' -ieq 'extension/bin/windows-x86_64/codex.exe' } | Select-Object -First 1
          if ($entry) {
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $standaloneCodex, $true)
          }
        } finally {
          $zip.Dispose()
        }
        if (Test-Path -LiteralPath $standaloneCodex -PathType Leaf) {
          return $standaloneCodex
        }
      } catch { }
    }
  }

  $autoHealRoot = Join-Path $emTroLyDir 'AutoHealCli'
  $cachedCmd = Join-Path $autoHealRoot 'node_modules\.bin\codex.cmd'
  if (Test-EmTroLyCodexBinaryRunnable -Executable $cachedCmd) {
    return $cachedCmd
  }

  # Clean broken npm AutoHealCli lacking @openai/codex-win32-x64 before reinstalling
  if (Test-Path -LiteralPath (Join-Path $autoHealRoot 'node_modules\@openai\codex\bin\codex.js') -PathType Leaf) {
    try {
      Remove-Item -LiteralPath (Join-Path $autoHealRoot 'node_modules') -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath (Join-Path $autoHealRoot 'package-lock.json') -Force -ErrorAction SilentlyContinue
    } catch { }
  }

  $npmCmd = @(Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($npmCmd.Count -eq 0 -and $PayloadRoot) {
    $depScript = Join-Path $PayloadRoot 'native\user-dependencies.ps1'
    if (Test-Path -LiteralPath $depScript -PathType Leaf) {
      try {
        . ([ScriptBlock]::Create([IO.File]::ReadAllText($depScript, [System.Text.Encoding]::UTF8)))
        Initialize-UserDependencies
        $env:Path = $env:Path + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        $npmCmd = @(Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
      } catch { }
    }
  }
  if ($npmCmd.Count -eq 0) { return '' }

  try {
    [void][IO.Directory]::CreateDirectory($autoHealRoot)
    $pkgFile = Join-Path $autoHealRoot 'package.json'
    if (-not (Test-Path -LiteralPath $pkgFile -PathType Leaf)) {
      [IO.File]::WriteAllText($pkgFile, '{"name":"emtroly-autoheal-codex","private":true}', (New-Object System.Text.UTF8Encoding($false)))
    }
    $prevEA = $ErrorActionPreference
    $hadHealNodeOpts = Test-Path Env:NODE_OPTIONS
    $oldHealNodeOpts = if ($hadHealNodeOpts) { $env:NODE_OPTIONS } else { $null }
    $hadHealIa32 = Test-Path Env:OPENSSL_ia32cap
    $oldHealIa32 = if ($hadHealIa32) { $env:OPENSSL_ia32cap } else { $null }
    try {
      $ErrorActionPreference = 'Continue'
      & $npmCmd[0].Source install --prefix $autoHealRoot --include=optional '@openai/codex' '@openai/codex-win32-x64' --no-audit --no-fund --maxsockets=3 *> $null
      if ($LASTEXITCODE -ne 0 -or -not (Test-EmTroLyCodexBinaryRunnable -Executable $cachedCmd)) {
        if (Test-Path -LiteralPath (Join-Path $autoHealRoot 'node_modules') -PathType Container) {
          Remove-Item -LiteralPath (Join-Path $autoHealRoot 'node_modules') -Recurse -Force -ErrorAction SilentlyContinue
        }
        $env:OPENSSL_ia32cap = '~0x200000200000000'
        $env:NODE_OPTIONS = '--tls-max-v1.2 --tls-cipher-list=ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-CHACHA20-POLY1305:DEFAULT'
        & $npmCmd[0].Source install --prefix $autoHealRoot --include=optional '@openai/codex' '@openai/codex-win32-x64' --no-audit --no-fund --maxsockets=1 --registry=https://registry.npmmirror.com/ *> $null
      }
    } finally {
      $ErrorActionPreference = $prevEA
      if ($hadHealNodeOpts) { $env:NODE_OPTIONS = $oldHealNodeOpts } elseif (Test-Path Env:NODE_OPTIONS) { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue }
      if ($hadHealIa32) { $env:OPENSSL_ia32cap = $oldHealIa32 } elseif (Test-Path Env:OPENSSL_ia32cap) { Remove-Item Env:OPENSSL_ia32cap -ErrorAction SilentlyContinue }
    }
    if (Test-EmTroLyCodexBinaryRunnable -Executable $cachedCmd) {
      return $cachedCmd
    }
  } catch { }
  return ''
}

function Build-SafeAutoHealPrompt {
  param(
    [string]$Stage,
    [string]$ErrorCode,
    [string]$ErrorDetail = '',
    [string]$OpenClawRoot,
    [string]$PayloadRoot,
    [psobject]$Settings,
    [int]$Attempt = 1
  )
  $secrets = @()
  if ($Settings) {
    if ($Settings.PSObject.Properties['telegram_token']) { $secrets += [string]$Settings.telegram_token }
    if ($Settings.PSObject.Properties['ai_api_key']) { $secrets += [string]$Settings.ai_api_key }
  }

  $safeDetail = Remove-SensitiveStrings -Text $ErrorDetail -Secrets $secrets
  $gatewayTail = ''
  if ($OpenClawRoot) {
    $gwLog = Join-Path $OpenClawRoot 'user-gateway.log'
    if (Test-Path -LiteralPath $gwLog -PathType Leaf) {
      try {
        $tailLines = @(Get-Content -LiteralPath $gwLog -Tail 40 -ErrorAction SilentlyContinue) -join "`n"
        $gatewayTail = Remove-SensitiveStrings -Text $tailLines -Secrets $secrets
      } catch { }
    }
  }

  $zaloFlag = if ($Settings -and $Settings.PSObject.Properties['configure_zalo']) { [string][bool]$Settings.configure_zalo } else { 'unknown' }
  $ownersText = if ($Settings -and $Settings.PSObject.Properties['owner_ids']) { [string]$Settings.owner_ids } else { '' }
  $groupText = if ($Settings -and $Settings.PSObject.Properties['group_id']) { [string]$Settings.group_id } else { '' }
  $modelText = if ($Settings -and $Settings.PSObject.Properties['model']) { [string]$Settings.model } else { 'gpt-6.2-sol' }
  $portText = if ($Settings -and $Settings.PSObject.Properties['gateway_port']) { [string]$Settings.gateway_port } else { '0' }

  $prompt = @"
Bạn là hệ thống tự động chẩn đoán và sửa lỗi cài đặt của bộ cài Windows "Anh Lập Trình - Em Trợ Lý" (Lần tự sửa thứ $Attempt).
Một bước cài đặt / kiểm tra vừa gặp lỗi trên máy khách. Hãy kiểm tra nguyên nhân thực tế trên máy và SỬA TRỰC TIẾP để bước kiểm tra nghiệm thu tiếp theo vượt qua thành công.

THÔNG TIN SỰ CỐ:
- Bước gặp lỗi (stage): $Stage
- Mã lỗi (code): $ErrorCode
- Chi tiết lỗi (đã che mã bí mật): $safeDetail

THÔNG SỐ CÀI ĐẶT CHUẨN CỦA EM TRỢ LÝ:
- Thư mục trợ lý OpenClaw: $OpenClawRoot
- Thư mục bộ nguồn cài đặt (PayloadRoot): $PayloadRoot
- Phiên bản OpenClaw yêu cầu: 2026.11.4 (CLI tại: $OpenClawRoot\runtime\2026.11.4\node_modules\openclaw\openclaw.mjs)
- Tên tài khoản Telegram (member): emtroly
- Telegram Owner IDs: $ownersText
- Telegram Group ID: $groupText
- Model AI: $modelText
- Cổng Gateway yêu cầu: $portText (0 = tự chọn cổng trống từ 19789)
- Cài đặt Zalo (/zaloqr): $zaloFlag
- Thư mục lệnh CLI trong User PATH: $env:LOCALAPPDATA\OpenClaw\bin
- Thư mục dữ liệu Antigravity & Codex riêng: $env:LOCALAPPDATA\EmTroLy

NHẬT KÝ GATEWAY GẦN NHẤT (nếu có):
$gatewayTail

NGUYÊN TẮC BẮT BUỘC:
1. Chỉ kiểm tra và sửa trong phạm vi thư mục của người dùng hiện tại ($OpenClawRoot, $env:LOCALAPPDATA\OpenClaw, $env:LOCALAPPDATA\EmTroLy và User PATH). Tuyệt đối KHÔNG xóa dữ liệu cá nhân ngoài phạm vi này.
2. Tuyệt đối KHÔNG in nội dung tệp telegram.token hoặc member-provider.secret hoặc auth.json ra màn hình.
3. Bạn có thể đọc và gọi các công cụ chuẩn có sẵn trong $PayloadRoot (như native\windows-cli.ps1, native\user-gateway.ps1, native\finalize_permissions.py, zalo\onboard-zalouser-windows.ps1, windows-installer\repair-antigravity-shortcut.ps1).
4. Nếu sự cố ở bước `editor` (cài Antigravity IDE / Codex Extension / lối tắt Desktop): kiểm tra tiến trình `Antigravity IDE.exe` bị treo, kiểm tra thư mục `$env:LOCALAPPDATA\EmTroLy` (xử lý khóa tệp hoặc thư mục dở dang nếu bị kẹt), cài lại tiện ích từ tệp `.vsix` sẵn có trong `$env:LOCALAPPDATA\EmTroLy` bằng `antigravity-ide.cmd --user-data-dir ... --extensions-dir ... --install-extension ... --force`, hoặc chạy `windows-installer\repair-antigravity-shortcut.ps1` nếu thiếu shortcut.
5. Nếu sự cố ở bước tải/chuẩn bị môi trường (`Node.js`, `Python`, `FFmpeg`, `npm`): kiểm tra `$env:LOCALAPPDATA\MemberInstaller\dependencies`, xóa tệp `.part` tải dở bị hỏng và chạy lại `Initialize-UserDependencies` từ `$PayloadRoot\native\user-dependencies.ps1`. Lưu ý quan trọng trên Windows: KHÔNG dùng `--scope user` với `winget install --id OpenJS.NodeJS.LTS` (bộ cài Node.js MSI chỉ hỗ trợ machine scope; ưu tiên dùng bản giải nén độc lập trong `MemberInstaller\dependencies` hoặc bỏ `--scope user`); luôn loại trừ alias rỗng `WindowsApps\python.exe` (đặt đường dẫn Python thật lên trước `WindowsApps` trong User PATH, không sửa Machine PATH); nếu thấy tệp `.emtroly-installing.json` hoặc `installer-codex-pending.json` mồ côi khi tiến trình cài đã dừng thì dọn sạch để bước tiếp theo không bị kẹt.
6. Nếu lỗi liên quan Gateway chưa chạy hoặc kẹt cổng: kiểm tra tiến trình cũ, cổng trống trong openclaw.json và khởi động lại bằng openclaw-instance.ps1 gateway restart rồi kiểm tra gateway health --json.
7. Nếu lỗi liên quan lệnh openclaw trong PATH (cli-probe-*): kiểm tra windows-cli.json và %LOCALAPPDATA%\OpenClaw\bin\openclaw.cmd và biến môi trường User Path.
8. Nếu lỗi liên quan plugin Zalo: kiểm tra plugins list / plugins enable zalouser và telegram-zalo-owner-login rồi khởi động lại Gateway.
9. Cuối cùng, viết 1–2 câu tiếng Việt ngắn gọn dễ hiểu tóm tắt bạn đã sửa gì.
"@
  return $prompt
}

function Invoke-CodexAutoHeal {
  param(
    [Parameter(Mandatory=$true)][string]$Stage,
    [Parameter(Mandatory=$true)][string]$ErrorCode,
    [string]$ErrorDetail = '',
    [Parameter(Mandatory=$true)][string]$OpenClawRoot,
    [Parameter(Mandatory=$true)][string]$PayloadRoot,
    [psobject]$Settings = $null,
    [string]$StatusFile = '',
    [int]$Attempt = 1,
    [int]$TimeoutSeconds = 300
  )
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $writeStatus = {
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

  $apiKey = ''
  if ($Settings -and $Settings.PSObject.Properties['ai_api_key'] -and -not [string]::IsNullOrWhiteSpace([string]$Settings.ai_api_key)) {
    $apiKey = ([string]$Settings.ai_api_key).Trim()
  }
  if ([string]::IsNullOrWhiteSpace($apiKey) -and $OpenClawRoot) {
    $secPath = Join-Path $OpenClawRoot 'member-provider.secret'
    if (Test-Path -LiteralPath $secPath -PathType Leaf) {
      try { $apiKey = ([IO.File]::ReadAllText($secPath, [System.Text.Encoding]::UTF8)).Trim() } catch { }
    }
  }
  if ([string]::IsNullOrWhiteSpace($apiKey) -and $env:LOCALAPPDATA) {
    $authPath = Join-Path $env:LOCALAPPDATA 'EmTroLy\Codex\auth.json'
    if (Test-Path -LiteralPath $authPath -PathType Leaf) {
      try { $apiKey = [string](([IO.File]::ReadAllText($authPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).OPENAI_API_KEY) } catch { }
    }
  }
  if ([string]::IsNullOrWhiteSpace($apiKey) -and (Get-Command Get-EmTroLySavedLicenseKey -ErrorAction SilentlyContinue)) {
    try { $apiKey = (Get-EmTroLySavedLicenseKey).Trim() } catch { }
  }
  if ([string]::IsNullOrWhiteSpace($apiKey) -and $env:LOCALAPPDATA) {
    $licFallback = Join-Path $env:LOCALAPPDATA 'EmTroLyUI\license.key'
    if (Test-Path -LiteralPath $licFallback -PathType Leaf) {
      try { $apiKey = ([IO.File]::ReadAllText($licFallback, [System.Text.Encoding]::UTF8)).Trim() } catch { }
    }
  }
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    return [pscustomobject]@{ Invoked = $false; Reason = 'missing-api-key'; ExitCode = 2; Summary = 'Thiếu khóa API để chạy Codex tự sửa lỗi.' }
  }

  & $writeStatus "Phát hiện sự cố tại bước $Stage ($ErrorCode) — Đang chuẩn bị Codex CLI để tự động sửa lỗi (lần $Attempt/2)..."
  $codexBin = Ensure-AutoHealCodexBinary -PayloadRoot $PayloadRoot
  if ([string]::IsNullOrWhiteSpace($codexBin) -or -not (Test-Path -LiteralPath $codexBin -PathType Leaf)) {
    return [pscustomobject]@{ Invoked = $false; Reason = 'codex-unavailable'; ExitCode = 2; Summary = 'Chưa khởi tạo được công cụ Codex CLI tự sửa lỗi.' }
  }

  $tempDir = Join-Path $env:TEMP ('emtroly-autoheal-' + [guid]::NewGuid().ToString('N'))
  $acl = New-Object System.Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
  foreach ($id in @($user, $system)) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($id, [System.Security.AccessControl.FileSystemRights]::FullControl, $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
  }
  [void][IO.Directory]::CreateDirectory($tempDir, $acl)

  $secretsToMask = @($apiKey)
  if ($Settings -and $Settings.PSObject.Properties['telegram_token'] -and $Settings.telegram_token) {
    $secretsToMask += [string]$Settings.telegram_token
  }

  try {
    $codexHome = Join-Path $tempDir 'codex-home'
    [void][IO.Directory]::CreateDirectory($codexHome)
    $model = if ($Settings -and $Settings.PSObject.Properties['model'] -and $Settings.model -match '^[A-Za-z0-9._-]+$') { [string]$Settings.model } else { 'gpt-6.2-sol' }
    $baseUrl = if ($Settings -and $Settings.PSObject.Properties['base_url'] -and $Settings.base_url -match '^https://') { ([string]$Settings.base_url).Trim().TrimEnd('/') } else { 'https://codex.anhlaptrinh.vn/v1' }
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

    $emTroLyDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'EmTroLy' } else { '' }
    $ocHasLauncher = $OpenClawRoot -and (Test-Path -LiteralPath (Join-Path $OpenClawRoot 'openclaw-instance.ps1') -PathType Leaf)
    $workDir = if ($ocHasLauncher -and (Test-Path -LiteralPath $OpenClawRoot -PathType Container)) {
      $OpenClawRoot
    } elseif ($Stage -in @('editor', 'codex-cli') -and $emTroLyDir -and (Test-Path -LiteralPath $emTroLyDir -PathType Container)) {
      $emTroLyDir
    } elseif ($env:USERPROFILE -and (Test-Path -LiteralPath $env:USERPROFILE -PathType Container)) {
      $env:USERPROFILE
    } else {
      $tempDir
    }
    $summaryFile = Join-Path $tempDir 'last-message.txt'
    $prompt = Build-SafeAutoHealPrompt -Stage $Stage -ErrorCode $ErrorCode -ErrorDetail $ErrorDetail -OpenClawRoot $OpenClawRoot -PayloadRoot $PayloadRoot -Settings $Settings -Attempt $Attempt

    & $writeStatus "Codex CLI đang tự động chẩn đoán và khắc phục lỗi tại bước $Stage (lần $Attempt/2)..."

    $argParts = @(
      'exec',
      '--skip-git-repo-check',
      '--color', 'never',
      '--sandbox', 'danger-full-access',
      '-m', $model,
      '-C', ('"' + $workDir.Replace('"', '\"') + '"'),
      '-o', ('"' + $summaryFile.Replace('"', '\"') + '"'),
      '-'
    )
    $argLine = ($argParts -join ' ')

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($codexBin -match '\.(cmd|bat)$') {
      $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
      $psi.Arguments = '/d /s /c ""' + $codexBin + '" ' + $argLine + '"'
    } else {
      $psi.FileName = $codexBin
      $psi.Arguments = $argLine
    }
    $psi.WorkingDirectory = $workDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['CODEX_HOME'] = $codexHome
    $psi.EnvironmentVariables['NO_COLOR'] = '1'
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'
    try {
      $healPriority = @()
      if ($env:LOCALAPPDATA) {
        $depRootHeal = Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies'
        if (Test-Path -LiteralPath $depRootHeal -PathType Container) {
          foreach ($dd in @(Get-ChildItem -LiteralPath $depRootHeal -Directory -ErrorAction SilentlyContinue)) {
            if ($dd.Name -like 'node-v*' -or $dd.Name -like 'python*') { $healPriority += $dd.FullName }
          }
        }
        $healPriority += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Python\*') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
      }
      if ($env:ProgramFiles) { $healPriority += (Join-Path $env:ProgramFiles 'nodejs') }
      $rawHealPath = @($healPriority) + @(($env:Path -split ';'))
      $normHeal = @(); $waHeal = @()
      foreach ($hp in $rawHealPath) {
        if ([string]::IsNullOrWhiteSpace($hp)) { continue }
        if ($hp -like '*\WindowsApps*') { $waHeal += $hp } else { $normHeal += $hp }
      }
      $psi.EnvironmentVariables['PATH'] = (@($normHeal) + @($waHeal)) -join ';'
    } catch { }
    foreach ($rmName in @('OPENAI_API_KEY', 'ELECTRON_RUN_AS_NODE', 'VSCODE_IPC_HOOK_CLI', 'NODE_OPTIONS', 'VSCODE_DEV')) {
      [void]$psi.EnvironmentVariables.Remove($rmName)
    }

    [Console]::InputEncoding = $utf8NoBom
    [Console]::OutputEncoding = $utf8NoBom
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $stdinPipeFailed = $false
    try {
      $proc.StandardInput.WriteLine($prompt)
      $proc.StandardInput.Flush()
    } catch {
      $stdinPipeFailed = $true
    } finally {
      try { $proc.StandardInput.Close() } catch { }
    }
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
      try {
        $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        $tkPsi = New-Object System.Diagnostics.ProcessStartInfo
        $tkPsi.FileName = $taskkill
        $tkPsi.Arguments = "/PID $($proc.Id) /T /F"
        $tkPsi.UseShellExecute = $false
        $tkPsi.CreateNoWindow = $true
        $tkPsi.RedirectStandardOutput = $true
        $tkPsi.RedirectStandardError = $true
        $tkProc = [System.Diagnostics.Process]::Start($tkPsi)
        [void]$tkProc.WaitForExit(3000)
        $tkProc.Dispose()
      } catch { }
      try { $proc.Kill() } catch { }
      $proc.Dispose()
      return [pscustomobject]@{ Invoked = $true; ExitCode = 124; Summary = 'Hết thời gian chờ Codex CLI tự sửa lỗi.'; Transcript = 'Quá thời gian 300 giây khi chạy Codex CLI tự sửa lỗi.' }
    }

    $exitCode = $proc.ExitCode
    $rawOut = $outTask.GetAwaiter().GetResult()
    $rawErr = $errTask.GetAwaiter().GetResult()
    $proc.Dispose()

    $combinedRaw = ($rawOut + "`n" + $rawErr).Trim()
    $filteredLines = @($combinedRaw -split "`r?`n" | Where-Object {
      -not [string]::IsNullOrWhiteSpace($_) -and
      $_ -notmatch 'ERROR\s+codex_core::session::session:\s+failed to load skill\s+.*SKILL\.md' -and
      $_ -notmatch '^warning:\s+Model metadata for\s+.*\s+not found'
    })
    $safeTranscript = Remove-SensitiveStrings -Text (($filteredLines | Select-Object -Last 35) -join "`r`n") -Secrets $secretsToMask

    $summary = ''
    if (Test-Path -LiteralPath $summaryFile -PathType Leaf) {
      $summary = ([IO.File]::ReadAllText($summaryFile, [System.Text.Encoding]::UTF8)).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($summary)) {
      if ($filteredLines.Count -gt 0) {
        $summary = ($filteredLines | Select-Object -Last 3) -join ' '
      }
    }
    $safeSummary = Remove-SensitiveStrings -Text $summary -Secrets $secretsToMask
    if ($safeSummary.Length -gt 320) {
      $safeSummary = $safeSummary.Substring(0, 317) + '...'
    }

    $auditTargets = @()
    if ($OpenClawRoot -and (Test-Path -LiteralPath $OpenClawRoot -PathType Container)) {
      $auditTargets += (Join-Path $OpenClawRoot 'logs')
    }
    if ($env:LOCALAPPDATA) {
      $auditTargets += (Join-Path $env:LOCALAPPDATA 'EmTroLyUI\logs')
    }
    foreach ($auditDir in $auditTargets) {
      try {
        [void][IO.Directory]::CreateDirectory($auditDir)
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $auditLine = "[$stamp] stage=$Stage error=$ErrorCode attempt=$Attempt exit=$exitCode summary=$safeSummary`r`n"
        [IO.File]::AppendAllText((Join-Path $auditDir 'codex-autoheal.log'), $auditLine, $utf8NoBom)
      } catch { }
    }

    return [pscustomobject]@{
      Invoked    = $true
      ExitCode   = $exitCode
      Summary    = $safeSummary
      Transcript = $safeTranscript
    }
  } finally {
    if (Test-Path -LiteralPath $tempDir) {
      Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $apiKey = ''
  }
}
