# Smart Helpers cho giao diện Em Trợ Lý (Windows 11 WPF):
# - Đọc phiên bản ứng dụng từ MANIFEST.txt
# - Tự động lấy Telegram Owner ID & Group ID từ Bot Token (getUpdates)
# - Kiểm tra nhanh kết nối Telegram Bot + Provider API Key trước khi cài
# - Kiểm tra điều kiện hệ thống (Pre-flight: Windows x64, ổ cứng >= 2GB, kết nối mạng)
# - Trạng thái Dashboard thực (Gateway port, Telegram, Zalo, Codex/Antigravity)
# - Xuất báo cáo hỗ trợ kỹ thuật (đã tự động ẩn sạch Token & API Key)
# - Tạo lối tắt ứng dụng Quản lý "Em Tro Ly - Anh Lap Trinh" trên Desktop & Start Menu

function Get-EmTroLyAppVersion {
  param([string]$PayloadRoot = '')
  $installerVer = '2026.11.21'
  $openClawVer = '2026.11.4'
  if ($PayloadRoot) {
    $manifestPath = Join-Path $PayloadRoot 'MANIFEST.txt'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
      try {
        foreach ($line in [IO.File]::ReadAllLines($manifestPath, [System.Text.Encoding]::UTF8)) {
          if ($line -match '^installer_version=(.+)$') { $installerVer = $Matches[1].Trim() }
          elseif ($line -match '^openclaw=(.+)$') { $openClawVer = $Matches[1].Trim() }
        }
      } catch { }
    }
  }
  return [pscustomobject]@{
    InstallerVersion = $installerVer
    OpenClawVersion  = $openClawVer
    Display          = "v$installerVer · OpenClaw $openClawVer"
  }
}

function Get-SafeProp($Obj, [string]$Name) {
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IDictionary]) {
    if ($Obj.Contains($Name)) { return $Obj[$Name] }
    return $null
  }
  $p = $Obj.PSObject.Properties[$Name]
  if ($p) { return $p.Value }
  return $null
}

function Get-TelegramIdsFromBotUpdates {
  param([Parameter(Mandatory=$true)][string]$TelegramToken)
  $tok = $TelegramToken.Trim()
  if ($tok -notmatch '^[0-9]{5,}:[A-Za-z0-9_-]{20,}$') {
    return [pscustomobject]@{
      Ok               = $false
      BotUsername      = ''
      SuggestedOwnerId = ''
      SuggestedGroupId = ''
      Owners           = @()
      Groups           = @()
      Message          = 'Telegram Bot Token chưa đúng định dạng (ví dụ: 123456789:ABCdef...).'
    }
  }
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  try {
    $me = Invoke-RestMethod -UseBasicParsing -Method Get -Uri ("https://api.telegram.org/bot$tok/getMe") -TimeoutSec 15 -MaximumRedirection 0
    $meRes = Get-SafeProp $me 'result'
    if (-not (Get-SafeProp $me 'ok') -or -not (Get-SafeProp $meRes 'is_bot')) {
      return [pscustomobject]@{ Ok = $false; BotUsername = ''; SuggestedOwnerId = ''; SuggestedGroupId = ''; Owners = @(); Groups = @(); Message = 'Telegram không xác nhận đây là Bot hợp lệ.' }
    }
    $meUser = Get-SafeProp $meRes 'username'
    $meFirst = Get-SafeProp $meRes 'first_name'
    $botUser = if ($meUser) { '@' + [string]$meUser } else { [string]$meFirst }
    $updates = Invoke-RestMethod -UseBasicParsing -Method Get -Uri ("https://api.telegram.org/bot$tok/getUpdates?limit=50") -TimeoutSec 15 -MaximumRedirection 0
    $ownerMap = [ordered]@{}
    $groupMap = [ordered]@{}

    foreach ($upd in @(Get-SafeProp $updates 'result')) {
      $candidates = @()
      foreach ($prop in @('message', 'edited_message', 'channel_post', 'my_chat_member', 'chat_member')) {
        $val = Get-SafeProp $upd $prop
        if ($val) { $candidates += $val }
      }
      $cbq = Get-SafeProp $upd 'callback_query'
      if ($cbq) {
        $cbFrom = Get-SafeProp $cbq 'from'
        if ($cbFrom) { $candidates += [pscustomobject]@{ from = $cbFrom; chat = $null } }
        $cbMsg = Get-SafeProp $cbq 'message'
        if ($cbMsg) { $candidates += $cbMsg }
      }
      foreach ($item in $candidates) {
        $fromObj = Get-SafeProp $item 'from'
        if ($fromObj -and (-not (Get-SafeProp $fromObj 'is_bot'))) {
          $uid = [string](Get-SafeProp $fromObj 'id')
          if ($uid -match '^[1-9][0-9]*$' -and -not $ownerMap.Contains($uid)) {
            $nameParts = @()
            $fn = Get-SafeProp $fromObj 'first_name'
            $un = Get-SafeProp $fromObj 'username'
            if ($fn) { $nameParts += [string]$fn }
            if ($un) { $nameParts += ('@' + [string]$un) }
            $ownerMap[$uid] = if ($nameParts.Count -gt 0) { ($nameParts -join ' ') } else { $uid }
          }
        }
        $chatObj = Get-SafeProp $item 'chat'
        if ($chatObj) {
          $cid = [string](Get-SafeProp $chatObj 'id')
          if ($cid -match '^-[1-9][0-9]*$' -and -not $groupMap.Contains($cid)) {
            $title = Get-SafeProp $chatObj 'title'
            $groupMap[$cid] = if ($title) { [string]$title } else { 'Nhóm Telegram' }
          } elseif ($cid -match '^[1-9][0-9]*$' -and [string](Get-SafeProp $chatObj 'type') -eq 'private' -and -not $ownerMap.Contains($cid)) {
            $cu = Get-SafeProp $chatObj 'username'
            $cf = Get-SafeProp $chatObj 'first_name'
            $pName = if ($cu) { '@' + [string]$cu } elseif ($cf) { [string]$cf } else { $cid }
            $ownerMap[$cid] = $pName
          }
        }
      }
    }

    $ownerItems = @($ownerMap.Keys | ForEach-Object { [pscustomobject]@{ Id = $_; Label = $ownerMap[$_] } })
    $groupItems = @($groupMap.Keys | ForEach-Object { [pscustomobject]@{ Id = $_; Label = $groupMap[$_] } })
    $firstOwner = if ($ownerItems.Count -gt 0) { [string]$ownerItems[0].Id } else { '' }
    $firstGroup = if ($groupItems.Count -gt 0) { [string]$groupItems[0].Id } else { '' }

    if ($ownerItems.Count -eq 0 -and $groupItems.Count -eq 0) {
      return [pscustomobject]@{
        Ok               = $true
        BotUsername      = $botUser
        SuggestedOwnerId = ''
        SuggestedGroupId = ''
        Owners           = @()
        Groups           = @()
        Message          = "Đã tìm thấy bot $botUser nhưng chưa có tin nhắn gần đây. Hãy mở Telegram nhắn /start cho $botUser (và nhắn 1 tin trong nhóm có bot), sau đó bấm lại nút này!"
      }
    }

    $summaryParts = @("Bot $botUser hợp lệ.")
    if ($firstOwner) { $summaryParts += "Owner ID: $firstOwner ($($ownerMap[$firstOwner]))." }
    if ($firstGroup) { $summaryParts += "Group ID: $firstGroup ($($groupMap[$firstGroup]))." }
    else { $summaryParts += 'Chưa thấy tin nhắn nhóm (hãy thêm bot vào nhóm rồi nhắn 1 tin nếu cần lấy Group ID).' }

    return [pscustomobject]@{
      Ok               = $true
      BotUsername      = $botUser
      SuggestedOwnerId = $firstOwner
      SuggestedGroupId = $firstGroup
      Owners           = $ownerItems
      Groups           = $groupItems
      Message          = ($summaryParts -join ' ')
    }
  } catch {
    return [pscustomobject]@{
      Ok               = $false
      BotUsername      = ''
      SuggestedOwnerId = ''
      SuggestedGroupId = ''
      Owners           = @()
      Groups           = @()
      Message          = 'Không kết nối được Telegram API hoặc Bot Token không đúng. Hãy kiểm tra lại Token và Internet.'
    }
  }
}

function Test-EmTroLyLiveCredentials {
  param(
    [string]$TelegramToken = '',
    [string]$BaseUrl = 'https://codex.anhlaptrinh.vn/v1',
    [string]$ApiKey = '',
    [string]$Model = 'gpt-6.2-sol',
    [string]$OpenClawRoot = ''
  )
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $tok = $TelegramToken.Trim()
  $key = $ApiKey.Trim()
  if ([string]::IsNullOrWhiteSpace($tok) -and $OpenClawRoot) {
    $tPath = Join-Path $OpenClawRoot 'telegram.token'
    if (Test-Path -LiteralPath $tPath -PathType Leaf) {
      try { $tok = ([IO.File]::ReadAllText($tPath, [System.Text.Encoding]::UTF8)).Trim() } catch { }
    }
  }
  if ([string]::IsNullOrWhiteSpace($key) -and $OpenClawRoot) {
    $kPath = Join-Path $OpenClawRoot 'member-provider.secret'
    if (Test-Path -LiteralPath $kPath -PathType Leaf) {
      try { $key = ([IO.File]::ReadAllText($kPath, [System.Text.Encoding]::UTF8)).Trim() } catch { }
    }
  }

  $tgOk = $false
  $tgText = 'Chưa nhập Bot Token'
  if ($tok -match '^[0-9]{5,}:[A-Za-z0-9_-]{20,}$') {
    try {
      $me = Invoke-RestMethod -UseBasicParsing -Method Get -Uri ("https://api.telegram.org/bot$tok/getMe") -TimeoutSec 15 -MaximumRedirection 0
      if ($me.ok -and $me.result.is_bot) {
        $tgOk = $true
        $tgText = 'Bot @' + [string]$me.result.username + ' sẵn sàng'
      } else {
        $tgText = 'Token không phải bot hợp lệ'
      }
    } catch {
      $tgText = 'Không kết nối được Telegram hoặc sai Token'
    }
  } elseif (-not [string]::IsNullOrWhiteSpace($tok)) {
    $tgText = 'Token sai định dạng'
  }

  $apiOk = $false
  $apiText = 'Chưa nhập API Key'
  $cleanBase = $BaseUrl.Trim().TrimEnd('/')
  if (-not [string]::IsNullOrWhiteSpace($key) -and $cleanBase -match '^https://') {
    try {
      $headers = @{ Authorization = "Bearer $key"; Accept = 'application/json' }
      $resp = Invoke-RestMethod -UseBasicParsing -Method Get -Uri "$cleanBase/models" -Headers $headers -TimeoutSec 15 -MaximumRedirection 0
      $ids = @($resp.data | ForEach-Object { [string]$_.id } | Where-Object { $_ })
      $matched = @($ids | Where-Object { $_ -ieq $Model })
      if ($matched.Count -gt 0) {
        $apiOk = $true
        $apiText = "API hợp lệ · Model $($matched[0]) sẵn sàng"
      } else {
        $apiText = "Kết nối được API nhưng thiếu model $Model"
      }
    } catch {
      $apiText = 'API Key không hợp lệ hoặc không kết nối được máy chủ AI'
    }
  }

  return [pscustomobject]@{
    AllOk       = ($tgOk -and $apiOk)
    TelegramOk  = $tgOk
    TelegramMsg = $tgText
    ApiOk       = $apiOk
    ApiMsg      = $apiText
    Summary     = "Telegram: $tgText · AI: $apiText"
  }
}

function Test-EmTroLyTcpEndpoint {
  param([string]$TargetHost, [int]$Port = 443, [int]$TimeoutMs = 3500)
  $tcp = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $tcp.BeginConnect($TargetHost, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
    $tcp.EndConnect($iar)
    return $true
  } catch {
    return $false
  } finally {
    try { $tcp.Close() } catch { }
  }
}

function Test-EmTroLyPreflightChecks {
  $results = @()

  $isX64 = ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'ARM64')
  $results += [pscustomobject]@{
    Name   = 'Hệ điều hành Windows 64-bit (x64)'
    Ok     = $isX64
    Detail = if ($isX64) { 'Hỗ trợ đầy đủ (AMD64)' } else { 'Yêu cầu Windows 64-bit x64' }
  }

  $freeGb = 0.0
  $diskOk = $true
  $driveLetter = 'C'
  try {
    if ($env:USERPROFILE -and $env:USERPROFILE.Length -ge 2) { $driveLetter = $env:USERPROFILE.Substring(0, 1) }
    $drv = New-Object System.IO.DriveInfo($driveLetter)
    $freeGb = [Math]::Round(($drv.AvailableFreeSpace / 1GB), 1)
    $diskOk = ($freeGb -ge 2.0)
  } catch { }
  $results += [pscustomobject]@{
    Name   = "Dung lượng trống ổ đĩa ${driveLetter}:"
    Ok     = $diskOk
    Detail = if ($diskOk) { "Còn trống $freeGb GB (đạt yêu cầu >= 2 GB)" } else { "Chỉ còn $freeGb GB (cần tối thiểu 2 GB để cài trọn gói)" }
  }

  $tgReach = Test-EmTroLyTcpEndpoint -TargetHost 'api.telegram.org' -Port 443
  $results += [pscustomobject]@{
    Name   = 'Kết nối máy chủ Telegram (api.telegram.org)'
    Ok     = $tgReach
    Detail = if ($tgReach) { 'Thông suốt (HTTPS 443)' } else { 'Bị chặn hoặc mất mạng — kiểm tra VPN / tường lửa' }
  }

  $aiReach = Test-EmTroLyTcpEndpoint -TargetHost 'codex.anhlaptrinh.vn' -Port 443
  $results += [pscustomobject]@{
    Name   = 'Kết nối máy chủ AI (codex.anhlaptrinh.vn)'
    Ok     = $aiReach
    Detail = if ($aiReach) { 'Thông suốt (HTTPS 443)' } else { 'Không kết nối được máy chủ AI' }
  }

  $nodeReach = Test-EmTroLyTcpEndpoint -TargetHost 'nodejs.org' -Port 443
  $results += [pscustomobject]@{
    Name   = 'Kết nối tải gói môi trường (nodejs.org)'
    Ok     = $nodeReach
    Detail = if ($nodeReach) { 'Thông suốt (HTTPS 443)' } else { 'Không truy cập được nodejs.org' }
  }

  return $results
}

function Get-EmTroLyLiveDashboardStatus {
  $st = if (Get-Command Get-EmTroLyInstalledState -ErrorAction SilentlyContinue) {
    Get-EmTroLyInstalledState
  } else { $null }
  if (-not $st) { return $null }

  $portNum = 0
  [void][int]::TryParse([string]$st.GatewayPort, [ref]$portNum)
  $gatewayOnline = $false
  if ($st.OpenClawInstalled -and $portNum -ge 1024) {
    $gatewayOnline = Test-EmTroLyTcpEndpoint -TargetHost '127.0.0.1' -Port $portNum -TimeoutMs 450
  }

  $ownerCount = @($st.OwnerIds -split ',' | Where-Object { $_ -match '^[1-9][0-9]*$' }).Count
  $desktopDir = [Environment]::GetFolderPath('Desktop')
  $hasAntigravityShortcut = ($desktopDir -and (Test-Path -LiteralPath (Join-Path $desktopDir 'EmTroLy - Antigravity.lnk') -PathType Leaf))

  $zaloCredDir = if ($st.Root) { Join-Path $st.Root 'credentials\zalouser' } else { '' }
  $legacyLinked = ($zaloCredDir -and (Test-Path -LiteralPath $zaloCredDir -PathType Container) -and @(Get-ChildItem -LiteralPath $zaloCredDir -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0)

  $zaloLinked = [bool]$legacyLinked
  $zaloConnected = [bool]$legacyLinked
  $hasZaloStatusCache = $false
  $zaloStatusPath = if ($st.Root) { Join-Path $st.Root 'state\emtroly-zalo-status.json' } else { '' }
  if ($zaloStatusPath -and (Test-Path -LiteralPath $zaloStatusPath -PathType Leaf)) {
    try {
      $zObj = [IO.File]::ReadAllText($zaloStatusPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      $hasZaloStatusCache = $true
      $isLinked = ($zObj.linked -eq $true -or $zObj.connected -eq $true)
      if ($isLinked) {
        $zaloLinked = $true
        $zaloConnected = ($zObj.connected -eq $true -or $gatewayOnline)
      }
    } catch { }
  }

  $gwUrl = if ($portNum -ge 1024) { "http://127.0.0.1:$portNum/" } else { '' }
  return [pscustomobject]@{
    State                  = $st
    GatewayOnline          = $gatewayOnline
    GatewayPort            = $portNum
    GatewayUrl             = $gwUrl
    OwnerCount             = $ownerCount
    HasAntigravityShortcut = $hasAntigravityShortcut
    ZaloLinked             = [bool]$zaloLinked
    ZaloConnected          = [bool]$zaloConnected
    HasZaloStatusCache     = [bool]$hasZaloStatusCache
  }
}

function Export-EmTroLySupportReport {
  param(
    [string]$OutputPath = '',
    [string]$PayloadRoot = ''
  )
  $desktop = [Environment]::GetFolderPath('Desktop')
  if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $targetDir = if ($desktop -and (Test-Path -LiteralPath $desktop -PathType Container)) { $desktop } else { $env:TEMP }
    $OutputPath = Join-Path $targetDir "BaoCao-HoTro-EmTroLy-$stamp.txt"
  }

  $root = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'openclaw' } else { '' }
  $ver = Get-EmTroLyAppVersion -PayloadRoot $PayloadRoot
  $secrets = @()
  foreach ($secFile in @('telegram.token', 'member-provider.secret')) {
    if ($root) {
      $fp = Join-Path $root $secFile
      if (Test-Path -LiteralPath $fp -PathType Leaf) {
        try {
          $v = ([IO.File]::ReadAllText($fp, [System.Text.Encoding]::UTF8)).Trim()
          if ($v) { $secrets += $v }
        } catch { }
      }
    }
  }
  if ($env:LOCALAPPDATA) {
    $authPath = Join-Path $env:LOCALAPPDATA 'EmTroLy\Codex\auth.json'
    if (Test-Path -LiteralPath $authPath -PathType Leaf) {
      try {
        $ak = [string](([IO.File]::ReadAllText($authPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).OPENAI_API_KEY)
        if ($ak) { $secrets += $ak }
      } catch { }
    }
  }
  if (Get-Command Get-EmTroLySavedLicenseKey -ErrorAction SilentlyContinue) {
    try {
      $savedLicKey = Get-EmTroLySavedLicenseKey
      if ($savedLicKey) { $secrets += $savedLicKey }
    } catch { }
  }
  if (Get-Command Get-EmTroLySavedSetupDraft -ErrorAction SilentlyContinue) {
    try {
      $savedDraft = Get-EmTroLySavedSetupDraft
      if ($savedDraft) {
        if ($savedDraft.telegram_token) { $secrets += [string]$savedDraft.telegram_token }
        if ($savedDraft.ai_api_key) { $secrets += [string]$savedDraft.ai_api_key }
      }
    } catch { }
  }

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('============================================================')
  [void]$sb.AppendLine('  BAO CAO HO TRO KY THUAT - ANH LAP TRINH (EM TRO LY)')
  [void]$sb.AppendLine('  (Da tu dong an toan bo Bot Token, API Key & Gateway Token)')
  [void]$sb.AppendLine('============================================================')
  [void]$sb.AppendLine("Thoi diem xuat : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
  [void]$sb.AppendLine("Phien ban app  : $($ver.Display)")
  [void]$sb.AppendLine("Windows OS     : $([Environment]::OSVersion.VersionString) ($($env:PROCESSOR_ARCHITECTURE))")
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('[1] TRANG THAI CAI DAT')
  if (Get-Command Get-EmTroLyInstalledState -ErrorAction SilentlyContinue) {
    $st = Get-EmTroLyInstalledState
    [void]$sb.AppendLine("  OpenClaw da cai : $($st.OpenClawInstalled)")
    [void]$sb.AppendLine("  Ten tro ly      : $($st.AssistantName)")
    [void]$sb.AppendLine("  Model           : $($st.Model)")
    [void]$sb.AppendLine("  Gateway Port    : $($st.GatewayPort)")
    [void]$sb.AppendLine("  Co Bot Token    : $($st.HasTelegramToken)")
    [void]$sb.AppendLine("  Co API Secret   : $($st.HasProviderSecret)")
    [void]$sb.AppendLine("  Zalo da cai     : $($st.ZaloInstalled)")
    [void]$sb.AppendLine("  Codex CLI       : $($st.CodexInstalled)")
  }
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('[2] CONG CU TRONG PATH')
  foreach ($tool in @('node.exe', 'npm.cmd', 'python.exe', 'ffmpeg.exe', 'openclaw.cmd', 'codex.cmd', 'codex.exe')) {
    $cmd = @(Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    $loc = if ($cmd.Count -gt 0) { $cmd[0].Source } else { '(khong tim thay)' }
    [void]$sb.AppendLine("  $($tool.PadRight(14)) : $loc")
  }
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('[3] KIEM TRA KET NOI & O CUNG (PRE-FLIGHT)')
  foreach ($chk in (Test-EmTroLyPreflightChecks)) {
    $mark = if ($chk.Ok) { '[OK]' } else { '[WARN]' }
    [void]$sb.AppendLine("  $mark $($chk.Name): $($chk.Detail)")
  }
  [void]$sb.AppendLine('')

  $gwLogPath = if ($root) { Join-Path $root 'user-gateway.log' } else { '' }
  $healLogPath = if ($root) { Join-Path $root 'logs\codex-autoheal.log' } else { '' }
  foreach ($logInfo in @(
    @{ Title = '[4] NHAT KY GATEWAY (40 DONG CUOI)'; Path = $gwLogPath },
    @{ Title = '[5] NHAT KY CODEX AUTO-HEAL (30 DONG CUOI)'; Path = $healLogPath }
  )) {
    [void]$sb.AppendLine($logInfo.Title)
    if ($logInfo.Path -and (Test-Path -LiteralPath $logInfo.Path -PathType Leaf)) {
      try {
        $lines = @(Get-Content -LiteralPath $logInfo.Path -Tail 40 -ErrorAction SilentlyContinue)
        if ($lines.Count -eq 0) { [void]$sb.AppendLine('  (trong)') }
        foreach ($l in $lines) { [void]$sb.AppendLine('  ' + $l) }
      } catch { [void]$sb.AppendLine('  (khong doc duoc tep)') }
    } else {
      [void]$sb.AppendLine('  (chua co tep nhat ky)')
    }
    [void]$sb.AppendLine('')
  }

  $rawReport = $sb.ToString()
  $safeReport = if (Get-Command Remove-SensitiveStrings -ErrorAction SilentlyContinue) {
    Remove-SensitiveStrings -Text $rawReport -Secrets $secrets
  } else {
    $tmp = $rawReport
    foreach ($sec in $secrets) {
      if ($sec -and $sec.Length -ge 6) { $tmp = $tmp.Replace($sec, '[REDACTED_SECRET]') }
    }
    $tmp = [regex]::Replace($tmp, '[0-9]{5,}:[A-Za-z0-9_-]{20,}', '[REDACTED_TELEGRAM_TOKEN]')
    $tmp = [regex]::Replace($tmp, 'sk-[A-Za-z0-9_-]{12,}', '[REDACTED_API_KEY]')
    $tmp = [regex]::Replace($tmp, '("token"\s*:\s*")[0-9a-fA-F]{24,}(")', '$1[REDACTED_GATEWAY_TOKEN]$2')
    $tmp
  }

  [IO.File]::WriteAllText($OutputPath, $safeReport, (New-Object System.Text.UTF8Encoding($false)))
  return $OutputPath
}

function Install-EmTroLyAppShortcut {
  param([string]$PayloadRoot = '')
  if (-not $env:LOCALAPPDATA) { return [pscustomobject]@{ Created = $false; Path = '' } }
  $emUiDir = Join-Path $env:LOCALAPPDATA 'EmTroLyUI'
  $emWinDir = Join-Path $emUiDir 'windows-installer'
  [void][IO.Directory]::CreateDirectory($emWinDir)

  if ($PayloadRoot -and (Test-Path -LiteralPath $PayloadRoot -PathType Container)) {
    foreach ($name in @('wizard.ps1', 'wizard-helpers.ps1', 'codex-cli.ps1', 'auto-heal-codex.ps1', 'manage-instance.ps1', 'validation.ps1')) {
      $srcFile = Join-Path $PayloadRoot ('windows-installer\' + $name)
      if (Test-Path -LiteralPath $srcFile -PathType Leaf) {
        $txt = [IO.File]::ReadAllText($srcFile, [System.Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $emWinDir $name), $txt, (New-Object System.Text.UTF8Encoding($true)))
      }
    }
    $qrBridgeSrc = Join-Path $PayloadRoot 'windows-installer\zalo-qr-session.mjs'
    if (Test-Path -LiteralPath $qrBridgeSrc -PathType Leaf) {
      Copy-Item -LiteralPath $qrBridgeSrc -Destination (Join-Path $emWinDir 'zalo-qr-session.mjs') -Force
    }
    foreach ($rootFile in @('alt.png', 'MANIFEST.txt')) {
      $srcRoot = Join-Path $PayloadRoot $rootFile
      if (Test-Path -LiteralPath $srcRoot -PathType Leaf) {
        Copy-Item -LiteralPath $srcRoot -Destination (Join-Path $emUiDir $rootFile) -Force
      }
    }
    $icoSrc = Join-Path $PayloadRoot 'windows-installer\alt.ico'
    if (Test-Path -LiteralPath $icoSrc -PathType Leaf) {
      Copy-Item -LiteralPath $icoSrc -Destination (Join-Path $emWinDir 'alt.ico') -Force
    }
  }

  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $wscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
  $wizardDst = Join-Path $emWinDir 'wizard.ps1'
  $icoDst = Join-Path $emWinDir 'alt.ico'
  $vbsPath = Join-Path $emUiDir 'launch-emtroly-ui.vbs'
  $desktopDir = [Environment]::GetFolderPath('Desktop')
  $startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'Anh Lap Trinh'
  $createdPath = ''

  if ((Test-Path -LiteralPath $wizardDst -PathType Leaf) -and (Test-Path -LiteralPath $wscriptExe -PathType Leaf) -and $desktopDir -and (Test-Path -LiteralPath $desktopDir -PathType Container)) {
    try {
      $vbsBody = @"
Option Explicit
Dim shell, command
Set shell = CreateObject("WScript.Shell")
shell.CurrentDirectory = "$($emUiDir.Replace('"','""'))"
command = Chr(34) & "$($psExe.Replace('"','""'))" & Chr(34) & " -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & "$($wizardDst.Replace('"','""'))" & Chr(34) & " -PayloadRoot " & Chr(34) & "$($emUiDir.Replace('"','""'))" & Chr(34)
shell.Run command, 0, False
Set shell = Nothing
"@
      [IO.File]::WriteAllText($vbsPath, $vbsBody, [System.Text.Encoding]::Unicode)

      $wsh = New-Object -ComObject WScript.Shell
      $targets = @((Join-Path $desktopDir 'Em Tro Ly - Anh Lap Trinh.lnk'))
      if ($startMenuDir) {
        [void][IO.Directory]::CreateDirectory($startMenuDir)
        $targets += (Join-Path $startMenuDir 'Em Tro Ly - Anh Lap Trinh.lnk')
      }
      foreach ($lnkPath in $targets) {
        for ($scTry = 1; $scTry -le 3; $scTry++) {
          try {
            $sc = $wsh.CreateShortcut($lnkPath)
            $sc.TargetPath = $wscriptExe
            $sc.Arguments = '//B //Nologo "' + $vbsPath + '"'
            $sc.WorkingDirectory = $emUiDir
            $sc.Description = 'Anh Lap Trinh - Em Tro Ly (Quan ly, Cau hinh & Codex CLI)'
            if (Test-Path -LiteralPath $icoDst -PathType Leaf) {
              $sc.IconLocation = "$icoDst,0"
            }
            $sc.Save()
            break
          } catch {
            if ($scTry -lt 3) { Start-Sleep -Milliseconds (400 * $scTry) }
          }
        }
      }
      $createdPath = $targets[0]
    } catch { }
  }
  return [pscustomobject]@{
    Created = (-not [string]::IsNullOrWhiteSpace($createdPath))
    Path    = $createdPath
  }
}

function Get-EmTroLyMachineBindingId {
  if (-not [string]::IsNullOrWhiteSpace($env:EMTROLY_TEST_MACHINE_ID)) {
    return $env:EMTROLY_TEST_MACHINE_ID.Trim()
  }
  try {
    $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name 'MachineGuid' -ErrorAction Stop
    if ($reg -and $reg.MachineGuid) {
      return ([string]$reg.MachineGuid).Trim()
    }
  } catch { }
  return ("{0}|{1}" -f $env:COMPUTERNAME, $env:USERNAME)
}

function Get-EmTroLyActivationFilePath {
  if (-not $env:LOCALAPPDATA) { return '' }
  return (Join-Path $env:LOCALAPPDATA 'AnhLapTrinh\EmTroLy\activation.dat')
}

function Get-EmTroLySetupDraftFilePath {
  if (-not $env:LOCALAPPDATA) { return '' }
  return (Join-Path $env:LOCALAPPDATA 'AnhLapTrinh\EmTroLy\setup-draft.dat')
}

function Save-EmTroLySetupDraft {
  param([Parameter(Mandatory=$true)]$Draft)
  $draftFile = Get-EmTroLySetupDraftFilePath
  if ([string]::IsNullOrWhiteSpace($draftFile)) { return $false }
  try {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $machineId = Get-EmTroLyMachineBindingId
    $payload = [ordered]@{
      machine            = $machineId
      savedAt            = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
      telegram_token     = ([string](Get-SafeProp $Draft 'telegram_token')).Trim()
      ai_api_key         = ([string](Get-SafeProp $Draft 'ai_api_key')).Trim()
      owner_ids          = ([string](Get-SafeProp $Draft 'owner_ids')).Trim()
      group_id           = ([string](Get-SafeProp $Draft 'group_id')).Trim()
      model              = ([string](Get-SafeProp $Draft 'model')).Trim()
      assistant_name     = ([string](Get-SafeProp $Draft 'assistant_name')).Trim()
      base_url           = ([string](Get-SafeProp $Draft 'base_url')).Trim().TrimEnd('/')
      gateway_port       = ([string](Get-SafeProp $Draft 'gateway_port')).Trim()
      qr_owner_id        = ([string](Get-SafeProp $Draft 'qr_owner_id')).Trim()
      audience           = ([string](Get-SafeProp $Draft 'audience')).Trim()
      addressing         = ([string](Get-SafeProp $Draft 'addressing')).Trim()
      style              = ([string](Get-SafeProp $Draft 'style')).Trim()
      configure_zalo     = [bool](Get-SafeProp $Draft 'configure_zalo')
      skip_editor        = [bool](Get-SafeProp $Draft 'skip_editor')
      accept_full_access = [bool](Get-SafeProp $Draft 'accept_full_access')
    }
    $plainJson = $payload | ConvertTo-Json -Depth 4 -Compress
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($plainJson)
    $entropyBytes = [System.Text.Encoding]::UTF8.GetBytes("EmTroLy-SetupDraft-v1|$machineId")
    $cipherBytes = [System.Security.Cryptography.ProtectedData]::Protect(
      $plainBytes,
      $entropyBytes,
      [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $encoded = [Convert]::ToBase64String($cipherBytes)
    $draftDir = Split-Path -Parent $draftFile
    [void][IO.Directory]::CreateDirectory($draftDir)
    $tmpFile = "$draftFile.tmp"
    [IO.File]::WriteAllText($tmpFile, "$encoded`n", [System.Text.Encoding]::ASCII)
    Set-EmTroLyPrivateFileAcl $tmpFile
    Move-Item -LiteralPath $tmpFile -Destination $draftFile -Force
    Set-EmTroLyPrivateFileAcl $draftFile
    return $true
  } catch {
    return $false
  }
}

function Get-EmTroLySavedSetupDraft {
  $draftFile = Get-EmTroLySetupDraftFilePath
  if ([string]::IsNullOrWhiteSpace($draftFile) -or -not (Test-Path -LiteralPath $draftFile -PathType Leaf)) {
    return $null
  }
  try {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $machineId = Get-EmTroLyMachineBindingId
    $rawCipher = ([IO.File]::ReadAllText($draftFile, [System.Text.Encoding]::ASCII)).Trim()
    if ([string]::IsNullOrWhiteSpace($rawCipher)) { return $null }
    $cipherBytes = [Convert]::FromBase64String($rawCipher)
    $entropyBytes = [System.Text.Encoding]::UTF8.GetBytes("EmTroLy-SetupDraft-v1|$machineId")
    $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
      $cipherBytes,
      $entropyBytes,
      [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $obj = [System.Text.Encoding]::UTF8.GetString($plainBytes) | ConvertFrom-Json
    if ($obj -and ([string]$obj.machine -ceq $machineId)) {
      return $obj
    }
  } catch { }
  return $null
}

function Clear-EmTroLySavedSetupDraft {
  $draftFile = Get-EmTroLySetupDraftFilePath
  if ($draftFile -and (Test-Path -LiteralPath $draftFile -PathType Leaf)) {
    Remove-Item -LiteralPath $draftFile -Force -ErrorAction SilentlyContinue
  }
}

function Protect-EmTroLyMachineActivationPayload([string]$ApiKey) {
  Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
  $machineId = Get-EmTroLyMachineBindingId
  $payloadJson = (@{
    key         = $ApiKey.Trim()
    machine     = $machineId
    activatedAt = [DateTimeOffset]::UtcNow.ToString('o')
  } | ConvertTo-Json -Compress)
  $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($payloadJson)
  $entropyBytes = [System.Text.Encoding]::UTF8.GetBytes("EmTroLy-Machine-v1|$machineId")
  $cipherBytes = [System.Security.Cryptography.ProtectedData]::Protect(
    $plainBytes,
    $entropyBytes,
    [System.Security.Cryptography.DataProtectionScope]::CurrentUser
  )
  return [Convert]::ToBase64String($cipherBytes)
}

function Unprotect-EmTroLyMachineActivationPayload([string]$Base64Cipher) {
  if ([string]::IsNullOrWhiteSpace($Base64Cipher)) { return '' }
  try {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $machineId = Get-EmTroLyMachineBindingId
    $cipherBytes = [Convert]::FromBase64String($Base64Cipher.Trim())
    $entropyBytes = [System.Text.Encoding]::UTF8.GetBytes("EmTroLy-Machine-v1|$machineId")
    $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
      $cipherBytes,
      $entropyBytes,
      [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $obj = [System.Text.Encoding]::UTF8.GetString($plainBytes) | ConvertFrom-Json
    if ($obj -and ([string]$obj.machine -ceq $machineId) -and (-not [string]::IsNullOrWhiteSpace([string]$obj.key))) {
      return ([string]$obj.key).Trim()
    }
  } catch { }
  return ''
}

function Get-EmTroLySavedLicenseKey {
  $actFile = Get-EmTroLyActivationFilePath
  if ($actFile -and (Test-Path -LiteralPath $actFile -PathType Leaf)) {
    try {
      $rawCipher = ([IO.File]::ReadAllText($actFile, [System.Text.Encoding]::ASCII)).Trim()
      $unsealed = Unprotect-EmTroLyMachineActivationPayload -Base64Cipher $rawCipher
      if ($unsealed) { return $unsealed }
    } catch { }
  }

  $legacyKey = ''
  if ($env:LOCALAPPDATA) {
    $licFile = Join-Path $env:LOCALAPPDATA 'EmTroLyUI\license.key'
    if (Test-Path -LiteralPath $licFile -PathType Leaf) {
      try {
        $v = ([IO.File]::ReadAllText($licFile, [System.Text.Encoding]::UTF8)).Trim()
        if ($v) { $legacyKey = $v }
      } catch { }
    }
  }
  if (-not $legacyKey -and $env:USERPROFILE) {
    $secFile = Join-Path $env:USERPROFILE 'openclaw\member-provider.secret'
    if (Test-Path -LiteralPath $secFile -PathType Leaf) {
      try {
        $v2 = ([IO.File]::ReadAllText($secFile, [System.Text.Encoding]::UTF8)).Trim()
        if ($v2) { $legacyKey = $v2 }
      } catch { }
    }
  }
  if (-not $legacyKey -and $env:LOCALAPPDATA) {
    $authFile = Join-Path $env:LOCALAPPDATA 'EmTroLy\Codex\auth.json'
    if (Test-Path -LiteralPath $authFile -PathType Leaf) {
      try {
        $aObj = [IO.File]::ReadAllText($authFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $v3 = ([string]$aObj.OPENAI_API_KEY).Trim()
        if ($v3) { $legacyKey = $v3 }
      } catch { }
    }
  }
  if ($legacyKey) {
    try { Save-EmTroLyLicenseKey -ApiKey $legacyKey } catch { }
    return $legacyKey
  }
  return ''
}

function Set-EmTroLyPrivateFileAcl([string]$FilePath) {
  if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return }
  try {
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $sysSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    foreach ($sid in @($userSid, $sysSid)) {
      $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sid,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
      )
      $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $FilePath -AclObject $acl -ErrorAction SilentlyContinue
  } catch { }
}

function Save-EmTroLyLicenseKey {
  param([Parameter(Mandatory=$true)][string]$ApiKey)
  $cleanKey = $ApiKey.Trim()
  if ([string]::IsNullOrWhiteSpace($cleanKey)) { return }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

  if ($env:LOCALAPPDATA) {
    $sealedSaved = $false
    $actFile = Get-EmTroLyActivationFilePath
    if ($actFile) {
      try {
        $actDir = Split-Path -Parent $actFile
        [void][IO.Directory]::CreateDirectory($actDir)
        $sealed = Protect-EmTroLyMachineActivationPayload -ApiKey $cleanKey
        [IO.File]::WriteAllText($actFile, "$sealed`n", [System.Text.Encoding]::ASCII)
        Set-EmTroLyPrivateFileAcl $actFile
        $sealedSaved = $true
      } catch { }
    }

    $uiDir = Join-Path $env:LOCALAPPDATA 'EmTroLyUI'
    $licFile = Join-Path $uiDir 'license.key'
    if ($sealedSaved) {
      # DPAPI machine-bound activation succeeded: remove legacy plaintext license.key to avoid plain key on disk
      if (Test-Path -LiteralPath $licFile -PathType Leaf) {
        Remove-Item -LiteralPath $licFile -Force -ErrorAction SilentlyContinue
      }
    } else {
      [void][IO.Directory]::CreateDirectory($uiDir)
      [IO.File]::WriteAllText($licFile, "$cleanKey`n", $utf8NoBom)
      Set-EmTroLyPrivateFileAcl $licFile
    }

    $authFile = Join-Path $env:LOCALAPPDATA 'EmTroLy\Codex\auth.json'
    if (Test-Path -LiteralPath $authFile -PathType Leaf) {
      try {
        $authJson = @{ OPENAI_API_KEY = $cleanKey } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($authFile, $authJson, $utf8NoBom)
      } catch { }
    }
  }

  if ($env:USERPROFILE) {
    $secFile = Join-Path $env:USERPROFILE 'openclaw\member-provider.secret'
    if (Test-Path -LiteralPath $secFile -PathType Leaf) {
      try {
        [IO.File]::WriteAllText($secFile, "$cleanKey`n", $utf8NoBom)
        Set-EmTroLyPrivateFileAcl $secFile
      } catch { }
    }
  }
}

function Invoke-EmTroLyRevokeLockdown {
  if ($env:LOCALAPPDATA) {
    $actFile = Get-EmTroLyActivationFilePath
    if ($actFile) {
      Remove-Item -LiteralPath $actFile -Force -ErrorAction SilentlyContinue
    }
    $licFile = Join-Path $env:LOCALAPPDATA 'EmTroLyUI\license.key'
    Remove-Item -LiteralPath $licFile -Force -ErrorAction SilentlyContinue
  }
  if ($env:USERPROFILE) {
    $instLauncher = Join-Path $env:USERPROFILE 'openclaw\openclaw-instance.ps1'
    if (Test-Path -LiteralPath $instLauncher -PathType Leaf) {
      try {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $psExe -PathType Leaf) {
          $psi = New-Object System.Diagnostics.ProcessStartInfo
          $psi.FileName = $psExe
          $psi.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $instLauncher + '" gateway stop'
          $psi.UseShellExecute = $false
          $psi.CreateNoWindow = $true
          $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
          [void][System.Diagnostics.Process]::Start($psi)
        }
      } catch { }
    }
  }
}

function Test-EmTroLyLicenseKey {
  param(
    [string]$ApiKey = '',
    [string]$AuthorityBaseUrl = ''
  )
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $trimmedKey = if ($null -ne $ApiKey) { $ApiKey.Trim() } else { '' }
  if ([string]::IsNullOrWhiteSpace($trimmedKey)) {
    return [pscustomobject]@{
      Valid        = $false
      Revoked      = $false
      NetworkError = $false
      Models       = @()
      Message      = 'Vui lòng nhập Khóa kích hoạt (Provider API Key) do Anh Lập Trình cấp.'
    }
  }

  $targetBase = if (-not [string]::IsNullOrWhiteSpace($AuthorityBaseUrl)) {
    $AuthorityBaseUrl.Trim().TrimEnd('/')
  } elseif (-not [string]::IsNullOrWhiteSpace($env:EMTROLY_LICENSE_API_BASE)) {
    $env:EMTROLY_LICENSE_API_BASE.Trim().TrimEnd('/')
  } else {
    'https://codex.anhlaptrinh.vn/v1'
  }

  $isTestLocal = (-not [string]::IsNullOrWhiteSpace($env:EMTROLY_LICENSE_API_BASE)) -and ($targetBase -match '^http://127\.0\.0\.1:\d+')
  if (-not $isTestLocal -and $targetBase -cne 'https://codex.anhlaptrinh.vn/v1') {
    return [pscustomobject]@{
      Valid        = $false
      Revoked      = $true
      NetworkError = $false
      Models       = @()
      Message      = 'Chỉ chấp nhận khóa bản quyền chính thức từ máy chủ codex.anhlaptrinh.vn.'
    }
  }

  try {
    $headers = @{ Authorization = "Bearer $trimmedKey"; Accept = 'application/json' }
    $resp = Invoke-RestMethod -UseBasicParsing -Method Get -Uri "$targetBase/models" -Headers $headers -TimeoutSec 15 -MaximumRedirection 0
    $ids = @($resp.data | ForEach-Object { [string]$_.id } | Where-Object { $_ })
    if ($ids.Count -eq 0) {
      return [pscustomobject]@{
        Valid        = $false
        Revoked      = $true
        NetworkError = $false
        Models       = @()
        Message      = 'Khóa kích hoạt chưa được cấp quyền mô hình trên hệ thống Anh Lập Trình.'
      }
    }
    return [pscustomobject]@{
      Valid        = $true
      Revoked      = $false
      NetworkError = $false
      Models       = $ids
      Message      = 'Đã xác thực bản quyền thành công trên hệ thống Anh Lập Trình.'
    }
  } catch {
    $statusCode = 0
    try {
      if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
        $statusCode = [int]$_.Exception.Response.StatusCode
      }
    } catch { }
    if ($statusCode -in @(401, 403)) {
      return [pscustomobject]@{
        Valid        = $false
        Revoked      = $true
        NetworkError = $false
        Models       = @()
        Message      = 'Khóa kích hoạt không hợp lệ hoặc đã bị thu hồi quyền sử dụng. Vui lòng liên hệ Anh Lập Trình.'
      }
    }
    return [pscustomobject]@{
      Valid        = $false
      Revoked      = $false
      NetworkError = $true
      Models       = @()
      Message      = 'Không kết nối được máy chủ xác thực codex.anhlaptrinh.vn (hoặc khóa sai). Hãy kiểm tra mạng rồi thử lại.'
    }
  }
}
