[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SettingsFile,
  [Parameter(Mandatory=$true)][string]$PayloadRoot,
  [Parameter(Mandatory=$true)][string]$LogFile,
  [switch]$EditorOnly
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
    $parameters.ContentType = 'application/json; charset=utf-8'
    $parameters.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
  }
  return Invoke-RestMethod @parameters
}

function Ensure-TelegramCommandMenu {
  param([Parameter(Mandatory=$true)][string]$Token)
  $required = @(
    @{ command = 'zaloqr'; description = 'Tạo mã QR đăng nhập Zalo' },
    @{ command = 'zalostatus'; description = 'Kiểm tra trạng thái Zalo' }
  )
  try {
    $currentResponse = Invoke-TelegramApi -Token $Token -Method 'getMyCommands'
    if (-not $currentResponse.ok) { throw 'getMyCommands failed' }
    $currentNames = @($currentResponse.result | ForEach-Object { $_.command })
    if ('zaloqr' -in $currentNames -and 'zalostatus' -in $currentNames) { return }
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

$botReady = $false
$locked = $false
$mutex = $null
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
  $root = Join-Path $env:USERPROFILE 'openclaw'
  $pending = Join-Path $root 'installer-codex-pending.json'
  if (-not $EditorOnly) {
    Test-MemberInstallerSettings $settings
    if (Test-Path -LiteralPath $root) { throw 'instance-exists' }
    if ($env:OS -eq 'Windows_NT' -and (Get-Command openclaw -ErrorAction SilentlyContinue)) { throw 'cli-probe-conflict' }
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
    if ([bool]$settings.configure_zalo) { $modules = @('zalo-qr-basic') }
    $arguments = @{
      Name = [string]$settings.member; OwnerIds = [string]$settings.owner_ids
      GroupId = [string]$settings.group_id; AssistantName = [string]$settings.assistant_name
      BaseUrl = $baseUrl; Model = [string]$settings.model; Profile = 'installer-basic'
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
    foreach ($required in @(
      'openclaw.json', 'installer-instance.json', 'openclaw-instance.ps1', 'windows-cli.json',
      'workspace\skills\openclaw-telegram-zalo-qr-delivery\SKILL.md',
      'workspace\skills\telegram-zalo-owner-login\SKILL.md',
      'workspace\skills\core-openclaw-zalo\SKILL.md',
      'workspace\skills\openclaw-zalo-qr-login\SKILL.md',
      'workspace\skills\core-openclaw-telegram\SKILL.md',
      'workspace\skills\cap-full-quyen-telegram-openclaw\SKILL.md',
      'workspace\skills\reliable-media-delivery\SKILL.md',
      'workspace\skills\imagegen\SKILL.md',
      'workspace\skills\core-openclaw-media\SKILL.md',
      'workspace\skills\openclaw-docx-reader\SKILL.md',
      'workspace\skills\openclaw-python-docx-telegram\SKILL.md'
    )) {
      if (-not (Test-Path -LiteralPath (Join-Path $root $required))) { throw 'incomplete-installation' }
    }
    $instance = Get-Content -LiteralPath (Join-Path $root 'installer-instance.json') -Encoding UTF8 -Raw | ConvertFrom-Json
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
    $stage = 'command'
    Write-SafeStatus 'Đang kiểm tra lệnh openclaw trong PowerShell mới...'
    Test-FreshOpenClawCommand -Root $root -Version $expectedVersion
    $stage = 'zalo-verify'
    Write-SafeStatus 'Đang kiểm tra Gateway và lệnh Zalo...'
    $health = (& node $cliEntry gateway health --json | Out-String) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $health.ok) { throw 'gateway-health-failed' }
    if ('zalouser' -notin @($health.plugins.loaded)) { throw 'zalo-plugin-not-loaded' }
    if ('telegram-zalo-owner-login' -notin @($health.plugins.loaded)) { throw 'zalo-qr-plugin-not-loaded' }
    $inspection = (& node $cliEntry plugins inspect telegram-zalo-owner-login --runtime --json | Out-String) | ConvertFrom-Json
    $qrTools = @($inspection.plugin.toolNames)
    foreach ($tool in @($inspection.tools)) { $qrTools += @($tool.names) }
    if ($LASTEXITCODE -ne 0 -or $inspection.plugin.status -ne 'loaded' -or $inspection.plugin.enabled -ne $true -or
        'zaloqr' -notin @($inspection.commands) -or 'zalostatus' -notin @($inspection.commands) -or
        'telegram_zalo_login_qr' -notin $qrTools) { throw 'zalo-qr-command-not-registered' }
    $stage = 'telegram-menu'
    Write-SafeStatus 'Đang đồng bộ menu Telegram: /zaloqr và /zalostatus...'
    Ensure-TelegramCommandMenu -Token ([string]$settings.telegram_token)
    if ($settings.skip_editor) {
      Write-SafeStatus 'Hoàn tất: OpenClaw, /zaloqr, /zalostatus, tạo ảnh và kỹ năng DOCX/Excel/PowerPoint cơ bản đã sẵn sàng.'
      exit 0
    }
    $botReady = $true
    $job = @{ id = [guid]::NewGuid().ToString('N'); model = $settings.model }
    $tmp = "$pending.$($job.id).tmp"
    [IO.File]::WriteAllText($tmp, ($job | ConvertTo-Json -Compress))
    [IO.File]::Move($tmp, $pending)
  }
  $stage = 'editor'
  $job = [IO.File]::ReadAllText($pending) | ConvertFrom-Json
  if ($job.id -cnotmatch '^[a-f0-9]{32}$' -or $job.model -notin @('gpt-6.1-sol','gpt-6.1-terra','gpt-6-astra')) { throw 'invalid-editor-job' }
  $botReady = $true
  $mutex = New-Object Threading.Mutex($false, ('EmTroLy-Codex-' + $job.id))
  try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
  if (-not $locked) { throw 'editor-busy' }
  if (-not (Test-Path -LiteralPath $pending)) { throw 'invalid-editor-job' }
  $editorInstaller = Join-Path $PayloadRoot 'windows-installer\install-antigravity-codex.ps1'
  if (-not (Test-Path -LiteralPath $editorInstaller -PathType Leaf)) { throw 'editor-module-missing' }
  $editorSettings = [pscustomobject]@{ model=$job.model; base_url='https://codex.anhlaptrinh.vn/v1'; ai_api_key=$settings.ai_api_key; job_id=$job.id }
  Write-SafeStatus 'Trợ lý đã sẵn sàng. Đang chuẩn bị Antigravity và Codex...'
  & $editorInstaller -Settings $editorSettings -StatusFile $LogFile *> $null
  Remove-Item -LiteralPath $pending -ErrorAction Stop
  Write-SafeStatus 'Hoàn tất: OpenClaw, /zaloqr, /zalostatus, tạo ảnh và kỹ năng DOCX/Excel/PowerPoint cơ bản đã sẵn sàng. Mở lối tắt Em Trợ Lý - Antigravity để dùng Codex riêng.'
  exit 0
} catch {
  $code = [string]$_.Exception.Message
  $safeMessages = @{
    'invalid-editor-job' = 'Không tìm thấy phiên cài Codex hợp lệ.'
    'editor-busy' = 'Một cửa sổ khác đang cài Codex. Hãy đợi cửa sổ đó hoàn tất.'
    'invalid-member' = 'Tên trợ lý không hợp lệ.'
    'cli-probe-missing' = 'Thiếu công cụ kiểm tra lệnh OpenClaw.'
    'cli-probe-conflict' = 'Đã có lệnh openclaw khác. Bộ cài giữ nguyên lệnh cũ; cần xử lý xung đột trước khi dùng lệnh mặc định.'
    'cli-probe-path' = 'PowerShell mới không nhận đúng lệnh openclaw trong PATH.'
    'cli-probe-version' = 'Không xác minh được phiên bản của lệnh openclaw.'
    'cli-probe-status' = 'Lệnh openclaw status chưa chạy thành công trong PowerShell mới.'
    'cli-probe-timeout' = 'Hết thời gian kiểm tra lệnh openclaw trong PowerShell mới.'
    'cli-probe-failed' = 'Không kiểm tra được lệnh openclaw trong PowerShell mới.'
    'editor-module-missing' = 'Bộ cài thiếu mô-đun Antigravity và Codex.'
    'editor-data-exists' = 'Thư mục dữ liệu Em Trợ Lý đã tồn tại; bộ cài không ghi đè dữ liệu cũ.'
    'editor-data-recovery-failed' = 'Không thể tự lưu thư mục Em Trợ Lý cài dở. Hãy đóng Antigravity rồi thử lại.'
    'editor-desktop-missing' = 'Không tìm thấy Desktop hoặc Windows Script Host để tạo shortcut an toàn.'
    'editor-invalid-path' = 'Đường dẫn Windows chứa ký tự bộ cài chưa hỗ trợ; dữ liệu hiện có không bị ghi đè.'
    'editor-select-existing' = 'Máy có Antigravity. Hãy tích “Máy đã có Antigravity IDE” để chỉ cài OpenClaw và Zalo.'
    'editor-registry-ambiguous' = 'Có thông tin Antigravity cũ trong Windows nhưng không xác định được đường dẫn. Hãy kiểm tra ứng dụng đã cài; bộ cài không tự xóa dữ liệu.'
    'editor-provider-unsupported' = 'Codex hiện chỉ hỗ trợ provider codex.anhlaptrinh.vn/v1 trong bộ cài này.'
    'editor-download-failed' = 'Không tải được Antigravity IDE hoặc Codex Extension. Kiểm tra Internet và dung lượng trống.'
    'editor-download-checksum' = 'Tệp tải về không khớp mã kiểm tra; đã dừng để bảo vệ máy.'
    'editor-installer-signature-invalid' = 'Không xác minh được chữ ký hoặc mã kiểm tra của bộ cài Antigravity IDE.'
    'editor-installed-signature-invalid' = 'Antigravity IDE sau khi cài không đúng cấu trúc hoặc phiên bản được hỗ trợ.'
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
    'unsupported-architecture' = 'Bộ cài yêu cầu Windows x64, không hỗ trợ ARM64 hoặc Windows 32 bit.'
    'missing-assistant-name' = 'Chưa nhập tên trợ lý.'
    'invalid-owners' = 'Danh sách Telegram Owner IDs không hợp lệ.'
    'invalid-group' = 'ID nhóm Telegram phải là số âm.'
    'invalid-telegram-token' = 'Token bot Telegram không đúng định dạng.'
    'missing-api-key' = 'Chưa nhập khóa API của nhà cung cấp.'
    'invalid-model' = 'Mô hình đã chọn không được hỗ trợ.'
    'invalid-base-url' = 'URL nhà cung cấp phải dùng HTTPS, không chứa tài khoản, truy vấn hoặc phần neo.'
    'invalid-port' = 'Cổng Gateway phải là 0 hoặc từ 1024 đến 65000.'
    'full-access-consent-required' = 'Cần xác nhận đã hiểu cảnh báo Full Exec.'
    'invalid-qr-owner' = 'QR owner phải thuộc danh sách Telegram Owner IDs.'
    'zalo-required' = 'Bộ cài yêu cầu bật plugin Zalo.'
    'instance-exists' = 'Thư mục OpenClaw đã tồn tại; dữ liệu cũ được giữ nguyên.'
    'provider-unavailable' = 'Không kết nối được API. Hãy kiểm tra URL, khóa API và kết nối Internet.'
    'provider-model-unavailable' = 'Nhà cung cấp không công bố mô hình đã chọn tại /models.'
    'telegram-unavailable' = 'Không kết nối được bot Telegram. Hãy kiểm tra token và kết nối Internet.'
    'telegram-invalid-bot' = 'Telegram không xác nhận đây là bot hợp lệ.'
    'Node.js/npm dependency verification failed.' = 'Không xác minh được Node.js và npm sau khi chuẩn bị môi trường.'
    'Node.js download failed.' = 'Không tải được Node.js từ nodejs.org. Hãy kiểm tra kết nối Internet và quyền tải tệp.'
    'Python download failed.' = 'Không tải được Python từ python.org. Hãy kiểm tra kết nối Internet và quyền tải tệp.'
    'FFmpeg download failed.' = 'Không tải được FFmpeg. Hãy kiểm tra kết nối Internet và quyền tải tệp.'
    'Python dependency verification failed.' = 'Python chưa sẵn sàng sau khi cài đặt.'
    'FFmpeg dependency verification failed.' = 'FFmpeg chưa sẵn sàng sau khi cài đặt.'
    'OpenClaw CLI PATH helper is missing.' = 'Bộ cài thiếu công cụ đăng ký lệnh openclaw.'
    'OpenClaw CLI PATH installation failed.' = 'Không đăng ký được lệnh openclaw vào PATH của tài khoản Windows.'
    'OpenClaw CLI shim was not created.' = 'Không tìm thấy lệnh openclaw vừa đăng ký.'
    'OpenClaw CLI shim verification failed.' = 'Đã tạo lệnh openclaw nhưng không xác minh được phiên bản.'
    'FFmpeg checksum verification failed.' = 'Mã kiểm tra của gói FFmpeg không khớp. Bộ cài đã dừng.'
    'Portable Node checksum verification failed.' = 'Mã kiểm tra của gói Node.js không khớp. Bộ cài đã dừng.'
    'Python installer signature verification failed.' = 'Không xác minh được chữ ký số của bộ cài Python.'
    'Private OpenClaw installation failed.' = 'Không cài được OpenClaw qua npm. Hãy kiểm tra kết nối Internet và quyền ghi tệp.'
    'missing-payload' = 'Bộ cài thiếu thành phần OpenClaw.'
    'installer-failed' = 'Bước cài OpenClaw trả về lỗi.'
    'incomplete-installation' = 'Bộ cài chưa tạo đủ các tệp cần thiết.'
    'runtime-version-mismatch' = 'Phiên bản OpenClaw đã cài không phải 2026.11.4.'
    'approval-check-failed' = 'Không xác minh được quyền Full Exec của trợ lý chính.'
    'owner-permissions-check-failed' = 'Không xác minh được quyền của tất cả Telegram Owner IDs đã nhập.'
    'gateway-health-failed' = 'Gateway đã cài nhưng chưa phản hồi khi kiểm tra kết nối.'
    'zalo-qr-plugin-not-loaded' = 'Gateway chưa nạp plugin cung cấp lệnh /zaloqr.'
    'zalo-plugin-not-loaded' = 'Gateway chưa nạp plugin Zalo Personal.'
    'zalo-qr-command-not-registered' = 'Plugin Zalo chưa đăng ký đủ lệnh /zaloqr và /zalostatus.'
    'telegram-command-menu-not-registered' = 'Chưa xác nhận được /zaloqr và /zalostatus trong menu Telegram. Hãy kiểm tra kết nối Telegram; dữ liệu đã tạo được giữ nguyên.'
  }
  $message = if ($safeMessages.ContainsKey($code)) { $safeMessages[$code] } else { "Chưa hoàn tất bước $stage. Dữ liệu đã tạo được giữ nguyên." }
  if ($safeMessages.ContainsKey($code) -and $code -cmatch '^[a-z0-9-]+$') { $message += " Mã chẩn đoán: $code." }
  if ($stage -eq 'install' -and (Test-Path -LiteralPath $zaloStageFile)) {
    $zaloStep = [IO.File]::ReadAllText($zaloStageFile, [Text.Encoding]::ASCII).Trim()
    if ($zaloStep -in @('preflight','version','plugin-inspect','plugin-install','plugin-enable','plugin-doctor','plugin-source','gateway-stop','zalo-config','qr-install','mention-patch','gateway-start','verify')) {
      $message = "Chưa hoàn tất cài đặt Zalo (bước: $zaloStep). Dữ liệu đã tạo được giữ nguyên."
      if (Test-Path -LiteralPath $zaloDetailFile) {
        $zaloDetail = [IO.File]::ReadAllText($zaloDetailFile, [Text.Encoding]::ASCII).Trim()
        if ($zaloDetail -in @('cli-error','permission-denied','gateway-unavailable','plugin-busy','approval-required','plugin-not-found','plugin-version-mismatch','plugin-not-loaded','invalid-response')) {
          $message += " Mã chẩn đoán: $zaloDetail."
        }
      }
    }
  }
  if ($botReady) {
    Write-SafeStatus ("Trợ lý đã sẵn sàng. Codex chưa cài xong. " + $message)
    exit 3
  }
  try { Write-SafeStatus $message } catch { }
  exit 1
} finally {
  if ($locked) { $mutex.ReleaseMutex() }
  if ($mutex) { $mutex.Dispose() }
  Remove-Item -LiteralPath $SettingsFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $zaloStageFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $zaloDetailFile -Force -ErrorAction SilentlyContinue
  Remove-Item Env:MEMBER_INSTALL_ZALO_STAGE_FILE -ErrorAction SilentlyContinue
  $settings = $null
  $headers = $null
  $config = $null
}
