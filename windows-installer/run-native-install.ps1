[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SettingsFile,
  [Parameter(Mandatory=$true)][string]$PayloadRoot,
  [Parameter(Mandatory=$true)][string]$LogFile
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$expectedVersion = '2026.11.4'
. (Join-Path $PayloadRoot 'windows-installer\validation.ps1')

function Write-SafeStatus([string]$Text) {
  [IO.File]::WriteAllText($LogFile, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-TelegramApi {
  param(
    [Parameter(Mandatory=$true)][string]$Token,
    [Parameter(Mandatory=$true)][string]$Method,
    [object]$Body = $null
  )
  $httpMethod = if ($null -ne $Body) { 'Post' } else { 'Get' }
  $parameters = @{
    UseBasicParsing = $true
    Method = $httpMethod
    Uri = 'https://api.telegram.org/bot' + $Token + '/' + $Method
    TimeoutSec = 45
    MaximumRedirection = 0
  }
  if ($null -ne $Body) {
    $parameters.ContentType = 'application/json'
    $parameters.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
  }
  return Invoke-RestMethod @parameters
}

function Ensure-TelegramCommandMenu {
  param([Parameter(Mandatory=$true)][string]$Token)
  $required = @(
    @{ command = 'zaloqr'; description = 'Tao QR dang nhap Zalo' },
    @{ command = 'zalostatus'; description = 'Kiem tra trang thai Zalo' }
  )
  try {
    $currentResponse = Invoke-TelegramApi -Token $Token -Method 'getMyCommands'
    if (-not $currentResponse.ok) { throw 'getMyCommands failed' }
    $merged = New-Object System.Collections.Generic.List[object]
    foreach ($item in $required) { [void]$merged.Add($item) }
    foreach ($item in @($currentResponse.result)) {
      if (-not $item.command -or $item.command -in @('zaloqr','zalostatus')) { continue }
      if (@($merged | Where-Object { $_.command -eq $item.command }).Count -eq 0) { [void]$merged.Add(@{ command = [string]$item.command; description = [string]$item.description }) }
      if ($merged.Count -ge 100) { break }
    }
    $commandArray = @($merged | ForEach-Object { $_ })
    $setResponse = Invoke-TelegramApi -Token $Token -Method 'setMyCommands' -Body @{ commands = $commandArray }
    if (-not $setResponse.ok) { throw 'setMyCommands failed' }
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
      $verify = Invoke-TelegramApi -Token $Token -Method 'getMyCommands'
      $names = @($verify.result | ForEach-Object { [string]$_.command })
      if ('zaloqr' -in $names -and 'zalostatus' -in $names) { return }
      Start-Sleep -Seconds 2
    }
  } catch {
    throw 'telegram-command-menu-not-registered'
  }
  throw 'telegram-command-menu-not-registered'
}

function Test-FreshOpenClawCommand {
  param([string]$Root, [string]$Version)
  $probe = Join-Path $PayloadRoot 'windows-installer\verify-openclaw-command.ps1'
  if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) { throw 'cli-probe-missing' }
  $shell = if ($env:OS -eq 'Windows_NT') {
    Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  } else { Join-Path $PSHOME 'pwsh' }
  $oldRoot = $env:EMTROLY_PROBE_ROOT
  $oldVersion = $env:EMTROLY_PROBE_VERSION
  try {
    $env:EMTROLY_PROBE_ROOT = $Root
    $env:EMTROLY_PROBE_VERSION = $Version
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $probe + '"'
    $options = @{ FilePath = $shell; ArgumentList = $arguments; PassThru = $true }
    if ($env:OS -eq 'Windows_NT') { $options.WindowStyle = 'Hidden' }
    $process = Start-Process @options
    if (-not $process.WaitForExit(120000)) {
      Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
      throw 'cli-probe-timeout'
    }
    switch ($process.ExitCode) {
      0 { return }
      11 { throw 'cli-probe-conflict' }
      12 { throw 'cli-probe-path' }
      13 { throw 'cli-probe-version' }
      14 { throw 'cli-probe-status' }
      default { throw 'cli-probe-failed' }
    }
  } finally {
    $env:EMTROLY_PROBE_ROOT = $oldRoot
    $env:EMTROLY_PROBE_VERSION = $oldVersion
  }
}

$stage = 'input'
$settings = $null
$zaloStageFile = "$LogFile.zalo-stage"
$zaloDetailFile = "$zaloStageFile.detail"
try {
  try {
    $settings = [IO.File]::ReadAllText($SettingsFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
  } finally {
    Remove-Item -LiteralPath $SettingsFile -Force -ErrorAction SilentlyContinue
  }
  if ($env:OS -eq 'Windows_NT' -and ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64')) { throw 'unsupported-architecture' }
  Test-MemberInstallerSettings $settings
  $root = Join-Path $env:USERPROFILE 'openclaw'
  if (Test-Path -LiteralPath $root) { throw 'instance-exists' }
  if ($env:OS -eq 'Windows_NT' -and (Get-Command openclaw -ErrorAction SilentlyContinue)) { throw 'cli-probe-conflict' }
  $stage = 'editor-preflight'
  $editorInstaller = Join-Path $PayloadRoot 'windows-installer\install-antigravity-codex.ps1'
  if (-not (Test-Path -LiteralPath $editorInstaller -PathType Leaf)) { throw 'editor-module-missing' }
  & $editorInstaller -Settings $settings -StatusFile $LogFile -CheckOnly *> $null

  $stage = 'provider'
  Write-SafeStatus 'Đang kiểm tra API và model...'
  $baseUrl = ([string]$settings.base_url).TrimEnd('/')
  $headers = @{ Authorization = 'Bearer ' + [string]$settings.ai_api_key; Accept = 'application/json' }
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  try {
    $response = Invoke-RestMethod -UseBasicParsing -Method Get -Uri "$baseUrl/models" -Headers $headers -TimeoutSec 45 -MaximumRedirection 0
  } catch { throw 'provider-unavailable' }
  $ids = @($response.data | ForEach-Object { [string]$_.id } | Where-Object { $_ })
  $matching = @($ids | Where-Object { $_ -ieq [string]$settings.model })
  if ($matching.Count -eq 0) { throw 'provider-model-unavailable' }
  $settings.model = $matching[0]

  $stage = 'telegram'
  Write-SafeStatus 'Đang kiểm tra bot Telegram...'
  try {
    $telegram = Invoke-RestMethod -UseBasicParsing -Method Get -Uri ('https://api.telegram.org/bot' + [string]$settings.telegram_token + '/getMe') -TimeoutSec 45 -MaximumRedirection 0
  } catch { throw 'telegram-unavailable' }
  if (-not $telegram.ok -or -not $telegram.result.is_bot) { throw 'telegram-invalid-bot' }

  $stage = 'install'
  Write-SafeStatus 'Đang cài môi trường, module và Gateway. Vui lòng đợi...'
  $installer = Join-Path $PayloadRoot 'install-native-windows.ps1'
  if (-not (Test-Path -LiteralPath $installer)) { throw 'missing-payload' }
  $modules = @()
  if ([bool]$settings.configure_zalo) { $modules = @('zalo-personal') }
  $arguments = @{
    Name = [string]$settings.member; OwnerIds = [string]$settings.owner_ids
    GroupId = [string]$settings.group_id; AssistantName = [string]$settings.assistant_name
    BaseUrl = $baseUrl; Model = [string]$settings.model; Profile = 'basic-assistant-full'
    Modules = $modules; QrOwnerId = [string]$settings.qr_owner_id
    OpenClawVersion = '2026.11.4'; InstallMode = 'new'; InstallRoot = $root; GatewayPort = [int]$settings.gateway_port
    Audience = [string]$settings.audience; Addressing = [string]$settings.addressing
    Style = [string]$settings.style; UserInstall = $true; CredentialData = $settings
  }
  $global:LASTEXITCODE = 0
  $env:MEMBER_INSTALL_ZALO_STAGE_FILE = $zaloStageFile
  $env:MEMBER_INSTALL_STATUS_FILE = $LogFile
  & $installer @arguments *> $null
  if ($LASTEXITCODE -ne 0) { throw 'installer-failed' }
  foreach ($required in @('openclaw.json', 'installer-instance.json', 'openclaw-instance.ps1', 'windows-cli.json', 'workspace\skills\openclaw-zalo-reply-mention\SKILL.md', 'workspace\skills\openclaw-telegram-zalo-qr-delivery\SKILL.md', 'workspace\skills\cap-full-quyen-telegram-openclaw\SKILL.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $required))) { throw 'incomplete-installation' }
  }
  $instance = Get-Content -LiteralPath (Join-Path $root 'installer-instance.json') -Raw | ConvertFrom-Json
  $cliEntry = Join-Path $root ("runtime\$expectedVersion\node_modules\openclaw\openclaw.mjs")
  if (-not (Test-Path -LiteralPath $cliEntry)) { throw 'runtime-version-mismatch' }
  $env:OPENCLAW_STATE_DIR = $root
  $env:OPENCLAW_CONFIG_PATH = Join-Path $root 'openclaw.json'
  $env:OPENCLAW_PROFILE = [string]$instance.profile
  $versionText = (& node $cliEntry --version | Out-String)
  if ($LASTEXITCODE -ne 0 -or $versionText -notmatch [regex]::Escape($expectedVersion)) { throw 'runtime-version-mismatch' }
  $approvalState = (& node $cliEntry approvals get --json | Out-String) | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or $approvalState.file.agents.main.security -ne 'full' -or $approvalState.file.agents.main.ask -ne 'off') { throw 'approval-check-failed' }
  $config = [IO.File]::ReadAllText((Join-Path $root 'openclaw.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
  Test-MemberInstallerPermissions -Settings $settings -Config $config -ApprovalState $approvalState
  $health = (& node $cliEntry gateway health --json | Out-String) | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $health.ok) { throw 'gateway-health-failed' }
  if ('zalouser' -notin @($health.plugins.loaded)) { throw 'zalo-plugin-not-loaded' }
  if ('telegram-zalo-owner-login' -notin @($health.plugins.loaded)) { throw 'zalo-qr-plugin-not-loaded' }
  $plugins = (& node $cliEntry plugins list --json | Out-String) | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw 'zalo-plugin-not-loaded' }
  $zaloPlugin = @($plugins.plugins | Where-Object { $_.id -eq 'zalouser' })
  $qrPlugin = @($plugins.plugins | Where-Object { $_.id -eq 'telegram-zalo-owner-login' })
  if ($zaloPlugin.Count -ne 1 -or $zaloPlugin[0].status -ne 'loaded') { throw 'zalo-plugin-not-loaded' }
  if ($qrPlugin.Count -ne 1 -or $qrPlugin[0].status -ne 'loaded' -or $qrPlugin[0].enabled -ne $true) { throw 'zalo-qr-plugin-not-loaded' }
  $inspection = (& node $cliEntry plugins inspect telegram-zalo-owner-login --runtime --json | Out-String) | ConvertFrom-Json
  $qrTools = @($inspection.plugin.toolNames)
  foreach ($tool in @($inspection.tools)) { $qrTools += @($tool.names) }
  if ($LASTEXITCODE -ne 0 -or $inspection.plugin.status -ne 'loaded' -or $inspection.plugin.enabled -ne $true -or
      'zaloqr' -notin @($inspection.commands) -or 'zalostatus' -notin @($inspection.commands) -or
      'telegram_zalo_login_qr' -notin $qrTools) { throw 'zalo-qr-command-not-registered' }
  $stage = 'telegram-menu'
  Write-SafeStatus 'Đang đồng bộ menu Telegram: /zaloqr và /zalostatus...'
  Ensure-TelegramCommandMenu -Token ([string]$settings.telegram_token)
  $stage = 'command'
  Write-SafeStatus 'Đang kiểm tra lệnh openclaw trong PowerShell mới...'
  Test-FreshOpenClawCommand -Root $root -Version $expectedVersion
  $stage = 'editor'
  Write-SafeStatus 'Đang chuẩn bị Antigravity IDE và Codex Extension...'
  & $editorInstaller -Settings $settings -StatusFile $LogFile *> $null
  Write-SafeStatus 'SUCCESS: OpenClaw, lệnh Zalo, Antigravity IDE và Codex đã qua kiểm tra. Quét QR là bước sau khi cài.'
  exit 0
} catch {
  $code = [string]$_.Exception.Message
  $safeMessages = @{
    'invalid-member' = 'Ten member khong hop le.'
    'cli-probe-missing' = 'Thiếu công cụ kiểm tra lệnh OpenClaw.'
    'cli-probe-conflict' = 'Đã có lệnh openclaw khác. Bộ cài giữ nguyên lệnh cũ; cần xử lý xung đột trước khi dùng lệnh mặc định.'
    'cli-probe-path' = 'PowerShell mới không nhận đúng lệnh openclaw trong PATH.'
    'cli-probe-version' = 'Không xác minh được phiên bản của lệnh openclaw.'
    'cli-probe-status' = 'Lệnh openclaw status chưa chạy thành công trong PowerShell mới.'
    'cli-probe-timeout' = 'Hết thời gian kiểm tra lệnh openclaw trong PowerShell mới.'
    'cli-probe-failed' = 'Không kiểm tra được lệnh openclaw trong PowerShell mới.'
    'editor-module-missing' = 'Bộ cài thiếu mô-đun Antigravity và Codex.'
    'editor-data-exists' = 'Thư mục dữ liệu Em Trợ Lý đã tồn tại; bộ cài không ghi đè dữ liệu cũ.'
    'editor-shortcut-exists' = 'Shortcut Em Trợ Lý - Antigravity đã tồn tại; bộ cài không ghi đè.'
    'editor-desktop-missing' = 'Không tìm thấy Desktop hoặc Windows Script Host để tạo shortcut an toàn.'
    'editor-invalid-path' = 'Đường dẫn Windows chứa ký tự bộ cài chưa hỗ trợ; dữ liệu hiện có không bị ghi đè.'
    'editor-select-existing' = 'Máy có Antigravity. Hãy tích chọn dùng bản đã cài và chọn đúng Antigravity IDE.exe; bộ cài không ghi đè.'
    'editor-existing-not-found' = 'Không tìm thấy Antigravity IDE.exe đã chọn. Hãy chọn lại hoặc bỏ chọn để tải bản mới.'
    'editor-registry-ambiguous' = 'Có thông tin Antigravity cũ trong Windows nhưng không xác định được đường dẫn. Hãy kiểm tra ứng dụng đã cài; bộ cài không tự xóa dữ liệu.'
    'editor-provider-unsupported' = 'Codex hiện chỉ hỗ trợ provider codex.anhlaptrinh.vn/v1 trong bộ cài này.'
    'editor-download-failed' = 'Không tải được Antigravity IDE hoặc Codex Extension. Kiểm tra Internet và dung lượng trống.'
    'editor-download-checksum' = 'Tệp tải về không khớp mã kiểm tra; đã dừng để bảo vệ máy.'
    'editor-signature-invalid' = 'Không xác minh được chữ ký Google của Antigravity IDE.'
    'editor-install-failed' = 'Antigravity IDE chưa cài được.'
    'editor-cli-missing' = 'Không tìm thấy công cụ dòng lệnh Antigravity IDE.'
    'editor-version-unsupported' = 'Antigravity IDE có sẵn không tương thích với Codex trong bộ cài này; bộ cài không thay đổi phần mềm cũ.'
    'editor-extension-install-failed' = 'Không cài được Codex Extension vào thư mục riêng.'
    'editor-extension-verification-failed' = 'Không xác minh được phiên bản Codex Extension trong thư mục riêng.'
    'editor-codex-missing' = 'Codex Extension thiếu chương trình Codex cho Windows.'
    'editor-codex-probe-failed' = 'Codex chưa hoàn thành yêu cầu kiểm tra. Kiểm tra API key, model, mạng và quyền chạy Codex.'
    'editor-activation-missing' = 'Bộ cài thiếu công cụ kiểm tra kích hoạt Codex Extension.'
    'editor-activation-failed' = 'Antigravity chưa kích hoạt được Codex Extension. Cài đặt chưa hoàn tất.'
    'editor-process-timeout' = 'Hết thời gian cài hoặc kiểm tra Antigravity/Codex.'
    'editor-shortcut-failed' = 'Không tạo được shortcut Antigravity riêng trên Desktop.'
    'unsupported-architecture' = 'Bo cai nay chi ho tro Windows x64, khong ho tro ARM64 hoac 32-bit.'
    'missing-assistant-name' = 'Thieu ten tro ly.'
    'invalid-owners' = 'Telegram Owner IDs khong hop le.'
    'invalid-group' = 'Telegram Group ID phai la so am.'
    'invalid-telegram-token' = 'Dinh dang Telegram bot token khong hop le.'
    'missing-api-key' = 'Thieu provider API key.'
    'invalid-model' = 'Model khong thuoc danh sach duoc ho tro.'
    'invalid-base-url' = 'Provider URL phai la HTTPS va khong chua tai khoan, query hay fragment.'
    'invalid-port' = 'Gateway port phai la 0 hoac tu 1024 den 65000.'
    'full-access-consent-required' = 'Can xac nhan da hieu canh bao Full Exec.'
    'invalid-qr-owner' = 'QR owner phai nam trong Owner IDs.'
    'zalo-required' = 'Bo cai nay yeu cau cai plugin Zalo.'
    'instance-exists' = 'Instance cung ten da ton tai; khong ghi de.'
    'provider-unavailable' = 'Khong kiem tra duoc API. Hay kiem tra URL, API key va Internet.'
    'provider-model-unavailable' = 'Provider khong cong bo model da chon tai /models.'
    'telegram-unavailable' = 'Khong kiem tra duoc Telegram bot. Hay kiem tra token va Internet.'
    'telegram-invalid-bot' = 'Telegram khong xac nhan day la bot hop le.'
    'Node.js/npm dependency verification failed.' = 'Node.js hoac npm chua san sang. Bo cai da thu tai Node portable nhung khong xac minh duoc.'
    'Node.js download failed.' = 'Khong tai duoc Node.js tu nodejs.org. Hay kiem tra Internet va quyen tai file.'
    'Python download failed.' = 'Khong tai duoc Python tu python.org. Hay kiem tra Internet va quyen tai file.'
    'FFmpeg download failed.' = 'Khong tai duoc FFmpeg. Hay kiem tra Internet va quyen tai file.'
    'Python dependency verification failed.' = 'Python chua san sang sau khi bo cai thu tai va cai dat.'
    'FFmpeg dependency verification failed.' = 'FFmpeg chua san sang sau khi bo cai thu cai dat.'
    'OpenClaw CLI PATH helper is missing.' = 'Bo cai thieu cong cu dang ky lenh openclaw.'
    'OpenClaw CLI PATH installation failed.' = 'Khong the dang ky lenh openclaw vao PATH cua tai khoan Windows.'
    'OpenClaw CLI shim was not created.' = 'Khong tim thay lenh OpenClaw vua dang ky.'
    'OpenClaw CLI shim verification failed.' = 'Lenh OpenClaw da tao nhung khong xac minh duoc phien ban.'
    'FFmpeg checksum verification failed.' = 'Khong xac minh duoc goi FFmpeg da tai. Hay thu lai voi Internet on dinh.'
    'Portable Node checksum verification failed.' = 'Khong xac minh duoc goi Node portable da tai. Hay thu lai voi Internet on dinh.'
    'Python installer signature verification failed.' = 'Khong xac minh duoc chu ky bo cai Python da tai.'
    'Private OpenClaw installation failed.' = 'Khong cai duoc goi OpenClaw qua npm. Hay kiem tra Internet va quyen ghi.'
    'missing-payload' = 'Bo cai thieu file runtime.'
    'installer-failed' = 'OpenClaw installer tra ve loi.'
    'incomplete-installation' = 'InstalIer chua tao du file can thiet.'
    'runtime-version-mismatch' = 'Runtime OpenClaw cai dat khong dung phien ban 2026.11.4.'
    'approval-check-failed' = 'Khong xac minh duoc Full Exec approval cua agent main.'
    'owner-permissions-check-failed' = 'Khong xac minh duoc quyen cua tat ca Telegram Owner IDs. Cai dat chua hoan tat.'
    'gateway-health-failed' = 'Gateway da cai nhung chua tra ve health/RPC thanh cong.'
    'zalo-qr-plugin-not-loaded' = 'Gateway chua tai plugin /zaloqr; cai dat Zalo chua hoan tat.'
    'zalo-plugin-not-loaded' = 'Gateway chua tai plugin Zalo Personal; cai dat chua hoan tat.'
    'zalo-qr-command-not-registered' = 'Plugin QR chua dang ky day du /zaloqr va /zalostatus; cai dat chua hoan tat.'
    'telegram-command-menu-not-registered' = 'Telegram chua hien menu /zaloqr va /zalostatus. Hay kiem tra Internet/Telegram API va cai lai; instance dang do duoc giu nguyen.'
  }
  $message = if ($safeMessages.ContainsKey($code)) { $safeMessages[$code] } else { "That bai tai buoc $stage; lien he ho tro, khong ghi de instance dang do." }
  if ($safeMessages.ContainsKey($code) -and $code -cmatch '^[a-z0-9-]+$') { $message += " Mã chẩn đoán: $code." }
  if ($stage -eq 'install' -and (Test-Path -LiteralPath $zaloStageFile)) {
    $zaloStep = [IO.File]::ReadAllText($zaloStageFile, [Text.Encoding]::ASCII).Trim()
    if ($zaloStep -in @('preflight','version','plugin-inspect','plugin-install','plugin-enable','plugin-doctor','plugin-source','gateway-stop','zalo-config','qr-install','mention-patch','gateway-start','verify')) {
      $message = "Cai dat Zalo chua hoan tat tai buoc $zaloStep. Khong ghi de instance; gui ma buoc nay cho ho tro."
      if (Test-Path -LiteralPath $zaloDetailFile) {
        $zaloDetail = [IO.File]::ReadAllText($zaloDetailFile, [Text.Encoding]::ASCII).Trim()
        if ($zaloDetail -in @('cli-error','permission-denied','gateway-unavailable','plugin-busy','approval-required','plugin-not-found','plugin-version-mismatch','plugin-not-loaded','invalid-response')) {
          $message += " Ma chan doan: $zaloDetail."
        }
      }
    }
  }
  try { Write-SafeStatus $message } catch { }
  exit 1
} finally {
  Remove-Item -LiteralPath $SettingsFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $zaloStageFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $zaloDetailFile -Force -ErrorAction SilentlyContinue
  Remove-Item Env:MEMBER_INSTALL_ZALO_STAGE_FILE -ErrorAction SilentlyContinue
  $settings = $null
  $headers = $null
  $config = $null
}
