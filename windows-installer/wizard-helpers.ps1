# Smart Helpers cho giao diện Em Trợ Lý (Windows 11 WPF):
# - Đọc phiên bản ứng dụng từ MANIFEST.txt
# - Tự động lấy Telegram Owner ID & Group ID từ Bot Token (getUpdates)
# - Kiểm tra nhanh kết nối Telegram Bot + Provider API Key trước khi cài
# - Kiểm tra điều kiện hệ thống (Pre-flight: Windows x64, ổ cứng >= 2GB, kết nối mạng)
# - Trạng thái Dashboard thực (Gateway port, Telegram, Zalo, Codex/Antigravity)
# - Xuất báo cáo hỗ trợ kỹ thuật (đã tự động ẩn sạch Token & API Key)
# - Tạo lối tắt ứng dụng Quản lý "Em Tro Ly - Anh Lap Trinh" trên Desktop & Start Menu

function Write-EmTroLySharedStatusFile {
  param(
    [string]$Path = '',
    [string]$Text = '',
    [int]$MaxAttempts = 12,
    [int]$RetryDelayMs = 25
  )
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $fs = $null
    try {
      $parent = Split-Path -Parent $Path
      if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($parent)
      }
      $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
      $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, $share)
      $fs.SetLength(0)
      if ($bytes.Length -gt 0) {
        $fs.Write($bytes, 0, $bytes.Length)
      }
      $fs.Flush()
      return $true
    } catch {
      if ($attempt -lt $MaxAttempts) {
        Start-Sleep -Milliseconds $RetryDelayMs
      }
    } finally {
      if ($null -ne $fs) {
        try { $fs.Dispose() } catch { }
      }
    }
  }
  return $false
}

function Read-EmTroLySharedUtf8File {
  param(
    [string]$Path = '',
    [int]$MaxAttempts = 5,
    [int]$RetryDelayMs = 20
  )
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ''
  }
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $fs = $null
    $sr = $null
    try {
      $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
      $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
      $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
      return $sr.ReadToEnd()
    } catch {
      if ($attempt -lt $MaxAttempts) {
        Start-Sleep -Milliseconds $RetryDelayMs
      }
    } finally {
      if ($null -ne $sr) {
        try { $sr.Dispose() } catch { }
      } elseif ($null -ne $fs) {
        try { $fs.Dispose() } catch { }
      }
    }
  }
  return ''
}

if (-not (Get-Command -Name 'Get-EmTroLyInstalledState' -ErrorAction Ignore)) {
  function Get-EmTroLyInstalledState {
    $root = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'openclaw' } else { '' }
    $configPath = if ($root) { Join-Path $root 'openclaw.json' } else { '' }
    $installingMarker = if ($root) { Join-Path $root '.emtroly-installing.json' } else { '' }
    $codexInfo = if (Get-Command -Name 'Find-EmTroLyCodexCli' -ErrorAction Ignore) {
      Find-EmTroLyCodexCli
    } else {
      [pscustomobject]@{ Available = $false; Executable = ''; CodexHome = ''; Source = 'none'; Label = '' }
    }
    if (-not $configPath -or -not (Test-Path -LiteralPath $configPath -PathType Leaf) -or ($installingMarker -and (Test-Path -LiteralPath $installingMarker -PathType Leaf))) {
      return [pscustomobject]@{
        OpenClawInstalled = $false
        Root              = $root
        AccountName       = 'emtroly'
        AssistantName     = 'Trợ lý OpenClaw'
        BaseUrl           = 'https://codex.anhlaptrinh.vn/v1'
        Model             = 'gpt-6.2-sol'
        OwnerIds          = ''
        GroupId           = ''
        GatewayPort       = '0'
        Audience          = ''
        Addressing        = ''
        Style             = ''
        HasTelegramToken  = $false
        HasProviderSecret = (-not [string]::IsNullOrWhiteSpace($codexInfo.CodexHome))
        ZaloInstalled     = $false
        CodexInstalled    = [bool]$codexInfo.Available
      }
    }
    $assistantName = 'Trợ lý OpenClaw'
    $baseUrl = 'https://codex.anhlaptrinh.vn/v1'
    $model = 'gpt-6.2-sol'
    $ownerIds = ''
    $groupId = ''
    $gatewayPort = '0'
    $accountName = 'emtroly'
    try {
      $cfg = (Read-EmTroLySharedUtf8File -Path $configPath) | ConvertFrom-Json
      if ($cfg.agents -and $cfg.agents.entries -and $cfg.agents.entries.main -and $cfg.agents.entries.main.name) {
        $assistantName = [string]$cfg.agents.entries.main.name
      }
      if ($cfg.models -and $cfg.models.providers -and $cfg.models.providers.customer) {
        if ($cfg.models.providers.customer.baseUrl) {
          $baseUrl = ([string]$cfg.models.providers.customer.baseUrl).TrimEnd('/')
        }
        if ($cfg.models.providers.customer.models -and @($cfg.models.providers.customer.models).Count -gt 0) {
          $mId = [string]@($cfg.models.providers.customer.models)[0].id
          if ($mId) { $model = $mId }
        }
      }
      if ($cfg.agents -and $cfg.agents.defaults -and $cfg.agents.defaults.model -and $cfg.agents.defaults.model.primary) {
        $primary = [string]$cfg.agents.defaults.model.primary
        if ($primary -match '^customer/(.+)$') { $model = $Matches[1] }
      }
      if ($cfg.gateway -and $cfg.gateway.port) { $gatewayPort = [string]$cfg.gateway.port }
      if ($cfg.channels -and $cfg.channels.telegram) {
        if ($cfg.channels.telegram.defaultAccount) {
          $accountName = [string]$cfg.channels.telegram.defaultAccount
        } elseif ($cfg.channels.telegram.accounts) {
          $accProps = @($cfg.channels.telegram.accounts.PSObject.Properties | Select-Object -First 1)
          if ($accProps.Count -gt 0) { $accountName = [string]$accProps[0].Name }
        }
        if ($cfg.channels.telegram.accounts -and $cfg.channels.telegram.accounts.$accountName -and $cfg.channels.telegram.accounts.$accountName.groups) {
          $grpProps = @($cfg.channels.telegram.accounts.$accountName.groups.PSObject.Properties | Where-Object { $_.Name -match '^-[1-9][0-9]*$' } | Select-Object -First 1)
          if ($grpProps.Count -gt 0) { $groupId = [string]$grpProps[0].Name }
        }
      }
      $ownersList = @()
      if ($cfg.commands -and $cfg.commands.ownerAllowFrom) {
        foreach ($item in @($cfg.commands.ownerAllowFrom)) {
          $txt = [string]$item
          if ($txt -match '^telegram:([1-9][0-9]*)$' -and $Matches[1] -notin $ownersList) { $ownersList += $Matches[1] }
        }
      }
      if ($ownersList.Count -eq 0 -and $cfg.channels -and $cfg.channels.telegram -and $cfg.channels.telegram.allowFrom) {
        foreach ($item in @($cfg.channels.telegram.allowFrom)) {
          $txt = ([string]$item).Trim()
          if ($txt -match '^[1-9][0-9]*$' -and $txt -notin $ownersList) { $ownersList += $txt }
        }
      }
      $ownerIds = ($ownersList -join ',')
    } catch { }
    $tokenFile = Join-Path $root 'telegram.token'
    $secretFile = Join-Path $root 'member-provider.secret'
    $hasToken = (Test-Path -LiteralPath $tokenFile -PathType Leaf) -and ((Get-Item -LiteralPath $tokenFile).Length -gt 5)
    $hasSecret = ((Test-Path -LiteralPath $secretFile -PathType Leaf) -and ((Get-Item -LiteralPath $secretFile).Length -gt 3)) -or
      (-not [string]::IsNullOrWhiteSpace($codexInfo.CodexHome))
    $hasZalo = (Test-Path -LiteralPath (Join-Path $root 'workspace\skills\telegram-zalo-owner-login\SKILL.md') -PathType Leaf)
    return [pscustomobject]@{
      OpenClawInstalled = $true
      Root              = $root
      AccountName       = $accountName
      AssistantName     = $assistantName
      BaseUrl           = $baseUrl
      Model             = $model
      OwnerIds          = $ownerIds
      GroupId           = $groupId
      GatewayPort       = $gatewayPort
      Audience          = ''
      Addressing        = ''
      Style             = ''
      HasTelegramToken  = [bool]$hasToken
      HasProviderSecret = [bool]$hasSecret
      ZaloInstalled     = [bool]$hasZalo
      CodexInstalled    = [bool]$codexInfo.Available
    }
  }
}

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

function Remove-EmTroLyInvisibleChars([string]$Value) {
  if ($null -eq $Value) { return '' }
  return ([regex]::Replace($Value, '[\u200B\u200C\u200D\u2060\uFEFF\u00A0]', '')).Trim()
}

function Normalize-EmTroLyTelegramToken([string]$RawToken) {
  $clean = Remove-EmTroLyInvisibleChars $RawToken
  $clean = [regex]::Replace($clean, '\s+', '')
  if ($clean -match '^(?i)bot([0-9]{5,}:[A-Za-z0-9_-]{20,})$') {
    return $Matches[1]
  }
  return $clean
}

function Normalize-EmTroLyCustomerInputs {
  param([Parameter(Mandatory=$true)]$Inputs)
  $tok = Normalize-EmTroLyTelegramToken ([string](Get-SafeProp $Inputs 'telegram_token'))
  $apiKey = [regex]::Replace((Remove-EmTroLyInvisibleChars ([string](Get-SafeProp $Inputs 'ai_api_key'))), '\s+', '')

  $rawOwners = Remove-EmTroLyInvisibleChars ([string](Get-SafeProp $Inputs 'owner_ids'))
  $ownerSeen = New-Object 'System.Collections.Generic.HashSet[string]'
  $ownerList = New-Object 'System.Collections.Generic.List[string]'
  foreach ($part in @([regex]::Split($rawOwners, '[,;\s]+'))) {
    $trimmed = $part.Trim()
    if ($trimmed -and $ownerSeen.Add($trimmed)) {
      [void]$ownerList.Add($trimmed)
    }
  }
  $ownersClean = ($ownerList -join ',')

  $rawGroup = Remove-EmTroLyInvisibleChars ([string](Get-SafeProp $Inputs 'group_id'))
  $groupClean = [regex]::Replace($rawGroup, '\s+', '')
  $groupClean = [regex]::Replace($groupClean, '^[\u2010\u2011\u2012\u2013\u2014\u2212]+', '-')

  $rawUrl = Remove-EmTroLyInvisibleChars ([string](Get-SafeProp $Inputs 'base_url'))
  if ($rawUrl -match '^\[[^\]]*\]\((https?://[^)\s]+)\)$') { $rawUrl = $Matches[1].Trim() }
  $baseUrlClean = $rawUrl.TrimEnd('/')

  $rawPort = [regex]::Replace((Remove-EmTroLyInvisibleChars ([string](Get-SafeProp $Inputs 'gateway_port'))), '\s+', '')
  if ([string]::IsNullOrWhiteSpace($rawPort)) { $rawPort = '0' }

  $qrOwnerClean = [regex]::Replace((Remove-EmTroLyInvisibleChars ([string](Get-SafeProp $Inputs 'qr_owner_id'))), '\s+', '')
  $cfgZaloVal = Get-SafeProp $Inputs 'configure_zalo'
  $cfgZalo = if ($null -eq $cfgZaloVal) { $true } else { [bool]$cfgZaloVal }
  if ($cfgZalo -and [string]::IsNullOrWhiteSpace($qrOwnerClean) -and $ownerList.Count -gt 0 -and $ownerList[0] -match '^[1-9][0-9]*$') {
    $qrOwnerClean = [string]$ownerList[0]
  }

  $memberRaw = (Remove-EmTroLyInvisibleChars ([string](Get-SafeProp $Inputs 'member'))).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($memberRaw)) { $memberRaw = 'emtroly' }

  return [pscustomobject]@{
    member             = $memberRaw
    assistant_name     = Remove-EmTroLyInvisibleChars ([string](Get-SafeProp $Inputs 'assistant_name'))
    telegram_token     = $tok
    ai_api_key         = $apiKey
    owner_ids          = $ownersClean
    group_id           = $groupClean
    base_url           = $baseUrlClean
    model              = Remove-EmTroLyInvisibleChars ([string](Get-SafeProp $Inputs 'model'))
    gateway_port       = $rawPort
    qr_owner_id        = $qrOwnerClean
    audience           = Remove-EmTroLyInvisibleChars ([string](Get-SafeProp $Inputs 'audience'))
    addressing         = Remove-EmTroLyInvisibleChars ([string](Get-SafeProp $Inputs 'addressing'))
    style              = Remove-EmTroLyInvisibleChars ([string](Get-SafeProp $Inputs 'style'))
    configure_zalo     = $cfgZalo
    skip_editor        = [bool](Get-SafeProp $Inputs 'skip_editor')
    accept_full_access = [bool](Get-SafeProp $Inputs 'accept_full_access')
  }
}

function Get-EmTroLyTelegramPrivacyNote($MeResult) {
  $canRead = Get-SafeProp $MeResult 'can_read_all_group_messages'
  if ($null -ne $canRead -and $canRead -eq $false) {
    return 'Lưu ý: Bot đang bật Privacy Mode — hãy mở @BotFather gõ /setprivacy → chọn Bot → Disable (hoặc cấp quyền Admin nhóm cho Bot) để Bot đọc được tin nhắn trong nhóm.'
  }
  return ''
}

function Get-TelegramIdsFromBotUpdates {
  param([Parameter(Mandatory=$true)][string]$TelegramToken)
  $tok = Normalize-EmTroLyTelegramToken $TelegramToken
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
    $privWarning = Get-EmTroLyTelegramPrivacyNote $meRes
    $canReadAll = (Get-SafeProp $meRes 'can_read_all_group_messages') -eq $true
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
      $emptyMsg = "Đã tìm thấy bot $botUser nhưng chưa có tin nhắn gần đây. Hãy mở Telegram nhắn /start cho $botUser (hoặc nhắn trong nhóm nếu muốn gắn nhóm), sau đó bấm lại nút này!"
      if ($privWarning) { $emptyMsg += " $privWarning" }
      return [pscustomobject]@{
        Ok                      = $true
        BotUsername             = $botUser
        SuggestedOwnerId        = ''
        SuggestedGroupId        = ''
        Owners                  = @()
        Groups                  = @()
        CanReadAllGroupMessages = $canReadAll
        PrivacyWarning          = $privWarning
        Message                 = $emptyMsg
      }
    }

    $summaryParts = @("Bot $botUser hợp lệ.")
    if ($firstOwner) { $summaryParts += "Owner ID: $firstOwner ($($ownerMap[$firstOwner]))." }
    if ($firstGroup) {
      $summaryParts += "Group ID: $firstGroup ($($groupMap[$firstGroup]))."
      if ($privWarning) { $summaryParts += $privWarning }
    } else {
      $summaryParts += 'Group ID: bỏ qua (không bắt buộc — có thể thêm nhóm sau bất cứ lúc nào).'
    }

    return [pscustomobject]@{
      Ok                      = $true
      BotUsername             = $botUser
      SuggestedOwnerId        = $firstOwner
      SuggestedGroupId        = $firstGroup
      Owners                  = $ownerItems
      Groups                  = $groupItems
      CanReadAllGroupMessages = $canReadAll
      PrivacyWarning          = $privWarning
      Message                 = ($summaryParts -join ' ')
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
  $tok = Normalize-EmTroLyTelegramToken $TelegramToken
  $key = [regex]::Replace((Remove-EmTroLyInvisibleChars $ApiKey), '\s+', '')
  if ([string]::IsNullOrWhiteSpace($tok) -and $OpenClawRoot) {
    $tPath = Join-Path $OpenClawRoot 'telegram.token'
    if (Test-Path -LiteralPath $tPath -PathType Leaf) {
      try { $tok = Normalize-EmTroLyTelegramToken ([IO.File]::ReadAllText($tPath, [System.Text.Encoding]::UTF8)) } catch { }
    }
  }
  if ([string]::IsNullOrWhiteSpace($key) -and $OpenClawRoot) {
    $kPath = Join-Path $OpenClawRoot 'member-provider.secret'
    if (Test-Path -LiteralPath $kPath -PathType Leaf) {
      try { $key = [regex]::Replace((Remove-EmTroLyInvisibleChars ([IO.File]::ReadAllText($kPath, [System.Text.Encoding]::UTF8))), '\s+', '') } catch { }
    }
  }

  $tgOk = $false
  $tgText = 'Chưa nhập Bot Token'
  $privWarn = ''
  if ($tok -match '^[0-9]{5,}:[A-Za-z0-9_-]{20,}$') {
    try {
      $me = Invoke-RestMethod -UseBasicParsing -Method Get -Uri ("https://api.telegram.org/bot$tok/getMe") -TimeoutSec 15 -MaximumRedirection 0
      if ($me.ok -and $me.result.is_bot) {
        $tgOk = $true
        $tgText = 'Bot @' + [string]$me.result.username + ' sẵn sàng'
        $privWarn = Get-EmTroLyTelegramPrivacyNote $me.result
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

  $summaryMsg = "Telegram: $tgText · AI: $apiText"
  if ($privWarn) { $summaryMsg += " · $privWarn" }
  return [pscustomobject]@{
    AllOk          = ($tgOk -and $apiOk)
    TelegramOk     = $tgOk
    TelegramMsg    = $tgText
    PrivacyWarning = $privWarn
    ApiOk          = $apiOk
    ApiMsg         = $apiText
    Summary        = $summaryMsg
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
  $st = if (Get-Command -Name 'Get-EmTroLyInstalledState' -ErrorAction Ignore) {
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
  $progMenu = [Environment]::GetFolderPath('Programs')
  $hasAntigravityShortcut = ($desktopDir -and (Test-Path -LiteralPath (Join-Path $desktopDir 'EmTroLy - Antigravity.lnk') -PathType Leaf)) -or
    ($progMenu -and (Test-Path -LiteralPath (Join-Path $progMenu 'EmTroLy - Antigravity.lnk') -PathType Leaf))
  $modSt = if (Get-Command -Name 'Get-EmTroLyModularStatus' -ErrorAction Ignore) { Get-EmTroLyModularStatus } else { $null }
  $codexCliReady = if ($modSt) { [bool]$modSt.CodexCliInstalled } else { [bool]$st.CodexInstalled }
  $ideReady = if ($modSt) { [bool]$modSt.AntigravityInstalled } else { $hasAntigravityShortcut }
  $codexExtReady = if ($modSt) { [bool]$modSt.CodexExtensionInstalled } else { $hasAntigravityShortcut }

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
  $ocVerDash = if (Get-Command -Name 'Get-EmTroLyOpenClawVersionInfo' -ErrorAction Ignore) {
    Get-EmTroLyOpenClawVersionInfo -OpenClawRoot ([string]$st.Root)
  } else { $null }
  return [pscustomobject]@{
    State                    = $st
    GatewayOnline            = $gatewayOnline
    GatewayPort              = $portNum
    GatewayUrl               = $gwUrl
    OwnerCount               = $ownerCount
    HasAntigravityShortcut   = $hasAntigravityShortcut
    CodexCliInstalled        = $codexCliReady
    AntigravityInstalled     = $ideReady
    CodexExtensionInstalled  = $codexExtReady
    OpenClawInstalledVersion = if ($ocVerDash) { [string]$ocVerDash.InstalledVersion } else { '' }
    OpenClawTargetVersion    = if ($ocVerDash) { [string]$ocVerDash.TargetVersion } else { '2026.11.4' }
    OpenClawNeedsUpgrade     = if ($ocVerDash) { [bool]$ocVerDash.NeedsUpgrade } else { $false }
    ZaloLinked               = [bool]$zaloLinked
    ZaloConnected            = [bool]$zaloConnected
    HasZaloStatusCache       = [bool]$hasZaloStatusCache
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
  if (Get-Command -Name 'Get-EmTroLySavedLicenseKey' -ErrorAction Ignore) {
    try {
      $savedLicKey = Get-EmTroLySavedLicenseKey
      if ($savedLicKey) { $secrets += $savedLicKey }
    } catch { }
  }
  if (Get-Command -Name 'Get-EmTroLySavedSetupDraft' -ErrorAction Ignore) {
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
  if (Get-Command -Name 'Get-EmTroLyInstalledState' -ErrorAction Ignore) {
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
    $cmd = @(Get-Command $tool -CommandType Application -ErrorAction Ignore | Select-Object -First 1)
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
  $instLogPath = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'EmTroLyUI\logs\install-latest.log' } else { '' }
  foreach ($logInfo in @(
    @{ Title = '[4] NHAT KY GATEWAY (40 DONG CUOI)'; Path = $gwLogPath; Tail = 40 },
    @{ Title = '[5] NHAT KY CODEX AUTO-HEAL (30 DONG CUOI)'; Path = $healLogPath; Tail = 30 },
    @{ Title = '[6] NHAT KY CAI DAT GAN NHAT (60 DONG CUOI)'; Path = $instLogPath; Tail = 60 }
  )) {
    [void]$sb.AppendLine($logInfo.Title)
    if ($logInfo.Path -and (Test-Path -LiteralPath $logInfo.Path -PathType Leaf)) {
      try {
        $lines = @(Get-Content -LiteralPath $logInfo.Path -Tail $logInfo.Tail -ErrorAction SilentlyContinue)
        if ($lines.Count -eq 0) { [void]$sb.AppendLine('  (trong)') }
        foreach ($l in $lines) { [void]$sb.AppendLine('  ' + $l) }
      } catch { [void]$sb.AppendLine('  (khong doc duoc tep)') }
    } else {
      [void]$sb.AppendLine('  (chua co tep nhat ky)')
    }
    [void]$sb.AppendLine('')
  }

  $rawReport = $sb.ToString()
  $safeReport = if (Get-Command -Name 'Remove-SensitiveStrings' -ErrorAction Ignore) {
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
    $isSameUiRoot = $false
    try {
      $isSameUiRoot = ([IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\') -ieq [IO.Path]::GetFullPath($emUiDir).TrimEnd('\'))
    } catch { }
    if (-not $isSameUiRoot) {
      $utf8Bom = New-Object System.Text.UTF8Encoding($true)
      foreach ($name in @(
        'wizard.ps1', 'wizard-helpers.ps1', 'codex-cli.ps1', 'auto-heal-codex.ps1',
        'manage-instance.ps1', 'validation.ps1', 'repair-antigravity-shortcut.ps1',
        'install-antigravity-codex.ps1', 'run-native-install.ps1', 'verify-openclaw-command.ps1'
      )) {
        $srcFile = Join-Path $PayloadRoot ('windows-installer\' + $name)
        if (Test-Path -LiteralPath $srcFile -PathType Leaf) {
          $txt = [IO.File]::ReadAllText($srcFile, [System.Text.Encoding]::UTF8)
          [IO.File]::WriteAllText((Join-Path $emWinDir $name), $txt, $utf8Bom)
        }
      }
      foreach ($assetName in @('zalo-qr-session.mjs', 'alt.ico', 'launch-wizard.vbs')) {
        $assetSrc = Join-Path $PayloadRoot ('windows-installer\' + $assetName)
        if (Test-Path -LiteralPath $assetSrc -PathType Leaf) {
          Copy-Item -LiteralPath $assetSrc -Destination (Join-Path $emWinDir $assetName) -Force
        }
      }
      $probeSrcDir = Join-Path $PayloadRoot 'windows-installer\activation-probe'
      if (Test-Path -LiteralPath $probeSrcDir -PathType Container) {
        $probeDstDir = Join-Path $emWinDir 'activation-probe'
        [void][IO.Directory]::CreateDirectory($probeDstDir)
        Copy-Item -Path (Join-Path $probeSrcDir '*') -Destination $probeDstDir -Recurse -Force
      }
      foreach ($rootFile in @('alt.png', 'MANIFEST.txt', 'configure.py')) {
        $srcRoot = Join-Path $PayloadRoot $rootFile
        if (Test-Path -LiteralPath $srcRoot -PathType Leaf) {
          Copy-Item -LiteralPath $srcRoot -Destination (Join-Path $emUiDir $rootFile) -Force
        }
      }
      $nativePsSrc = Join-Path $PayloadRoot 'install-native-windows.ps1'
      if (Test-Path -LiteralPath $nativePsSrc -PathType Leaf) {
        $nativePsTxt = [IO.File]::ReadAllText($nativePsSrc, [System.Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $emUiDir 'install-native-windows.ps1'), $nativePsTxt, $utf8Bom)
      }
      foreach ($subFolder in @('native', 'modules', 'profiles', 'zalo')) {
        $subSrc = Join-Path $PayloadRoot $subFolder
        if (Test-Path -LiteralPath $subSrc -PathType Container) {
          $subDst = Join-Path $emUiDir $subFolder
          [void][IO.Directory]::CreateDirectory($subDst)
          Copy-Item -Path (Join-Path $subSrc '*') -Destination $subDst -Recurse -Force
        }
      }
    }
  }

  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $wscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
  $wizardDst = Join-Path $emWinDir 'wizard.ps1'
  $icoDst = Join-Path $emWinDir 'alt.ico'
  $vbsPath = Join-Path $emUiDir 'launch-emtroly-ui.vbs'
  $desktopDir = [Environment]::GetFolderPath('Desktop')
  $programsBase = [Environment]::GetFolderPath('Programs')
  $startMenuDir = if ($programsBase) { Join-Path $programsBase 'Anh Lap Trinh' } else { '' }
  $createdPath = ''

  $hasAnyTargetDir = ($desktopDir -and (Test-Path -LiteralPath $desktopDir -PathType Container)) -or
    ($programsBase -and (Test-Path -LiteralPath $programsBase -PathType Container))
  $wshDisabled = $false
  foreach ($wshReg in @('HKCU:\Software\Microsoft\Windows Script Host\Settings', 'HKLM:\Software\Microsoft\Windows Script Host\Settings')) {
    try {
      $wshProp = Get-ItemProperty -Path $wshReg -Name 'Enabled' -ErrorAction SilentlyContinue
      if ($null -ne $wshProp -and [int]$wshProp.Enabled -eq 0) { $wshDisabled = $true; break }
    } catch { }
  }

  if ((Test-Path -LiteralPath $wizardDst -PathType Leaf) -and ((Test-Path -LiteralPath $wscriptExe -PathType Leaf) -or (Test-Path -LiteralPath $psExe -PathType Leaf)) -and $hasAnyTargetDir) {
    try {
      $useVbsLauncher = (-not $wshDisabled) -and (Test-Path -LiteralPath $wscriptExe -PathType Leaf)
      if ($useVbsLauncher) {
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
      }

      $wsh = New-Object -ComObject WScript.Shell
      $targets = @()
      if ($desktopDir -and (Test-Path -LiteralPath $desktopDir -PathType Container)) {
        $targets += (Join-Path $desktopDir 'Em Tro Ly - Anh Lap Trinh.lnk')
      }
      if ($startMenuDir) {
        [void][IO.Directory]::CreateDirectory($startMenuDir)
        $targets += (Join-Path $startMenuDir 'Em Tro Ly - Anh Lap Trinh.lnk')
      }
      foreach ($lnkPath in $targets) {
        for ($scTry = 1; $scTry -le 3; $scTry++) {
          try {
            $sc = $wsh.CreateShortcut($lnkPath)
            if ($useVbsLauncher) {
              $sc.TargetPath = $wscriptExe
              $sc.Arguments = '//B //Nologo "' + $vbsPath + '"'
            } else {
              $sc.TargetPath = $psExe
              $sc.Arguments = '-STA -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $wizardDst + '" -PayloadRoot "' + $emUiDir + '"'
            }
            $sc.WorkingDirectory = $emUiDir
            $sc.Description = 'Anh Lap Trinh - Em Tro Ly (Quan ly, Cau hinh & Codex CLI)'
            if (Test-Path -LiteralPath $icoDst -PathType Leaf) {
              $sc.IconLocation = "$icoDst,0"
            }
            $sc.Save()
            if (-not $createdPath) { $createdPath = $lnkPath }
            break
          } catch {
            if ($scTry -lt 3) { Start-Sleep -Milliseconds (400 * $scTry) }
          }
        }
      }
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

function Get-EmTroLySignedOutFlagPath {
  if (-not $env:LOCALAPPDATA) { return '' }
  return (Join-Path $env:LOCALAPPDATA 'AnhLapTrinh\EmTroLy\signed-out.flag')
}

function Test-EmTroLyLicenseSignedOut {
  $flag = Get-EmTroLySignedOutFlagPath
  return (-not [string]::IsNullOrWhiteSpace($flag) -and (Test-Path -LiteralPath $flag -PathType Leaf))
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
  if (Test-EmTroLyLicenseSignedOut) { return '' }
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
    [IO.File]::SetAccessControl($FilePath, $acl)
  } catch { }
}

function Save-EmTroLyLicenseKey {
  param([Parameter(Mandatory=$true)][string]$ApiKey)
  $cleanKey = $ApiKey.Trim()
  if ([string]::IsNullOrWhiteSpace($cleanKey)) { return }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

  if ($env:LOCALAPPDATA) {
    $signOutFlag = Get-EmTroLySignedOutFlagPath
    if ($signOutFlag -and (Test-Path -LiteralPath $signOutFlag -PathType Leaf)) {
      Remove-Item -LiteralPath $signOutFlag -Force -ErrorAction SilentlyContinue
    }
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

function Invoke-EmTroLyLicenseSignOut {
  # UI-only license sign-out: keeps running OpenClaw Gateway & installed Codex CLI intact,
  # but forces re-entering a valid codex.anhlaptrinh.vn API token on the app UI (even across restarts).
  if ($env:LOCALAPPDATA) {
    $actFile = Get-EmTroLyActivationFilePath
    if ($actFile -and (Test-Path -LiteralPath $actFile -PathType Leaf)) {
      Remove-Item -LiteralPath $actFile -Force -ErrorAction SilentlyContinue
    }
    $licFile = Join-Path $env:LOCALAPPDATA 'EmTroLyUI\license.key'
    if (Test-Path -LiteralPath $licFile -PathType Leaf) {
      Remove-Item -LiteralPath $licFile -Force -ErrorAction SilentlyContinue
    }
    $flagFile = Get-EmTroLySignedOutFlagPath
    if ($flagFile) {
      try {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $flagFile))
        $flagBody = (@{ signedOutAt = [DateTimeOffset]::UtcNow.ToString('o') } | ConvertTo-Json -Compress) + "`n"
        [IO.File]::WriteAllText($flagFile, $flagBody, (New-Object System.Text.UTF8Encoding($false)))
        Set-EmTroLyPrivateFileAcl $flagFile
      } catch { }
    }
    $existingDraft = Get-EmTroLySavedSetupDraft
    if ($existingDraft -and $existingDraft.ai_api_key) {
      $existingDraft.ai_api_key = ''
      [void](Save-EmTroLySetupDraft -Draft $existingDraft)
    }
  }
}

function Test-EmTroLyHasAnyFootprint {
  if ($env:USERPROFILE) {
    if (Test-Path -LiteralPath (Join-Path $env:USERPROFILE 'openclaw')) { return $true }
  }
  if ($env:LOCALAPPDATA) {
    foreach ($rel in @(
      'EmTroLy',
      'MemberInstaller',
      'EmTroLyUI\license.key',
      'AnhLapTrinh\EmTroLy\activation.dat',
      'AnhLapTrinh\EmTroLy\setup-draft.dat',
      'AnhLapTrinh\EmTroLy\signed-out.flag'
    )) {
      if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA $rel)) { return $true }
    }
    $ocBin = Join-Path $env:LOCALAPPDATA 'OpenClaw\bin'
    if ((Test-Path -LiteralPath $ocBin -PathType Container) -and
        @(Get-ChildItem -LiteralPath $ocBin -Filter '*.cmd' -File -ErrorAction SilentlyContinue).Count -gt 0) {
      return $true
    }
    $progLocal = Join-Path $env:LOCALAPPDATA 'Programs'
    if ((Test-Path -LiteralPath $progLocal -PathType Container) -and
        @(Get-ChildItem -LiteralPath $progLocal -Directory -Filter 'EmTroLy-Antigravity-IDE-*' -ErrorAction SilentlyContinue).Count -gt 0) {
      return $true
    }
  }
  $deskDir = if ($env:EMTROLY_TEST_DESKTOP_DIR) { $env:EMTROLY_TEST_DESKTOP_DIR } else { [Environment]::GetFolderPath('Desktop') }
  if ($deskDir -and (Test-Path -LiteralPath $deskDir -PathType Container)) {
    foreach ($lnk in @('EmTroLy - Antigravity.lnk', 'Em Tro Ly - Anh Lap Trinh.lnk')) {
      if (Test-Path -LiteralPath (Join-Path $deskDir $lnk) -PathType Leaf) { return $true }
    }
  }
  $progMenu = if ($env:EMTROLY_TEST_PROGRAMS_DIR) { $env:EMTROLY_TEST_PROGRAMS_DIR } else { [Environment]::GetFolderPath('Programs') }
  if ($progMenu -and (Test-Path -LiteralPath $progMenu -PathType Container)) {
    if (Test-Path -LiteralPath (Join-Path $progMenu 'EmTroLy - Antigravity.lnk') -PathType Leaf) { return $true }
    if (Test-Path -LiteralPath (Join-Path $progMenu 'Anh Lap Trinh\Em Tro Ly - Anh Lap Trinh.lnk') -PathType Leaf) { return $true }
  }
  return $false
}

function Get-EmTroLyModularStatus {
  $codexInstalled = $false
  $codexDetail = 'Chưa cài đặt — chỉ cần bấm Cài phần này (~20 giây, không cần Telegram)'
  $emBase = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'EmTroLy' } else { '' }
  if (Get-Command -Name 'Find-EmTroLyCodexCli' -ErrorAction Ignore) {
    $cInfo = Find-EmTroLyCodexCli
    $hasCfg = $emBase -and (Test-Path -LiteralPath (Join-Path $emBase 'Codex\config.toml') -PathType Leaf)
    if ($cInfo.Available -and ($cInfo.Source -eq 'emtroly' -or $hasCfg)) {
      $codexInstalled = $true
      $shortExec = [string]$cInfo.Executable
      if ($shortExec -match '\\EmTroLy\\Antigravity\\Extensions\\') {
        $codexDetail = 'Đã sẵn sàng (Bản cô lập Em Trợ Lý · lệnh codex)'
      } elseif ($shortExec -match '\\EmTroLy\\CodexCli\\') {
        $codexDetail = 'Đã sẵn sàng (Bản độc lập Em Trợ Lý · lệnh codex)'
      } else {
        $codexDetail = "Đã sẵn sàng ($shortExec)"
      }
    } elseif ($cInfo.Available) {
      $codexInstalled = $true
      $codexDetail = "Đã có trên máy ($($cInfo.Executable))"
    }
  }

  $ideInstalled = $false
  $idePath = ''
  $ideVer = ''
  $ideCandidates = @()
  if ($emBase) {
    $recFile = Join-Path $emBase 'editor-app-path.txt'
    if (Test-Path -LiteralPath $recFile -PathType Leaf) {
      try {
        $recVal = ([IO.File]::ReadAllText($recFile, [System.Text.Encoding]::UTF8)).Trim()
        if ($recVal) { $ideCandidates += $recVal }
      } catch { }
    }
  }
  if ($env:LOCALAPPDATA) {
    $progLocal = Join-Path $env:LOCALAPPDATA 'Programs'
    if (Test-Path -LiteralPath $progLocal -PathType Container) {
      foreach ($d in @(Get-ChildItem -LiteralPath $progLocal -Directory -Filter 'EmTroLy-Antigravity-IDE-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $ideCandidates += $d.FullName
      }
      $ideCandidates += (Join-Path $progLocal 'Antigravity IDE')
      $ideCandidates += (Join-Path $progLocal 'Antigravity')
    }
  }
  foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($pf) {
      $ideCandidates += (Join-Path $pf 'Antigravity IDE')
      $ideCandidates += (Join-Path $pf 'Antigravity')
    }
  }
  foreach ($candDir in @($ideCandidates | Select-Object -Unique)) {
    if (-not $candDir -or -not (Test-Path -LiteralPath $candDir -PathType Container)) { continue }
    $prodJson = Join-Path $candDir 'resources\app\product.json'
    $exeA = Join-Path $candDir 'Antigravity IDE.exe'
    $exeB = Join-Path $candDir 'Antigravity.exe'
    if ((Test-Path -LiteralPath $prodJson -PathType Leaf) -and ((Test-Path -LiteralPath $exeA -PathType Leaf) -or (Test-Path -LiteralPath $exeB -PathType Leaf))) {
      try {
        $prod = [IO.File]::ReadAllText($prodJson, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($prod.applicationName -in @('antigravity-ide', 'antigravity')) {
          $ideInstalled = $true
          $idePath = $candDir
          $ideVer = [string]$prod.version
          break
        }
      } catch { }
    }
  }
  $ideDetail = if ($ideInstalled) {
    if ($idePath -match '\\EmTroLy-Antigravity-IDE-') {
      "Đã cài đặt sẵn sàng (v$ideVer · Bản riêng Em Trợ Lý)"
    } elseif ($env:LOCALAPPDATA -and $idePath.StartsWith($env:LOCALAPPDATA, [StringComparison]::OrdinalIgnoreCase)) {
      $relIde = '%LOCALAPPDATA%' + $idePath.Substring($env:LOCALAPPDATA.Length)
      "Đã cài đặt (v$ideVer · $relIde)"
    } else {
      "Đã cài đặt (v$ideVer · $idePath)"
    }
  } else {
    'Chưa cài đặt — tự tải và cài đặt Antigravity IDE chuẩn Google (~190 MB)'
  }

  $extInstalled = $false
  $extVer = ''
  if ($emBase) {
    $extRoot = Join-Path $emBase 'Antigravity\Extensions'
    if (Test-Path -LiteralPath $extRoot -PathType Container) {
      foreach ($ed in @(Get-ChildItem -LiteralPath $extRoot -Directory -Filter 'openai.chatgpt-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $pkgPath = Join-Path $ed.FullName 'package.json'
        $binPath = Join-Path $ed.FullName 'bin\windows-x86_64\codex.exe'
        if ((Test-Path -LiteralPath $pkgPath -PathType Leaf) -and (Test-Path -LiteralPath $binPath -PathType Leaf)) {
          try {
            $pkg = [IO.File]::ReadAllText($pkgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($pkg.publisher -eq 'openai' -and $pkg.name -eq 'chatgpt') {
              $extInstalled = $true
              $extVer = [string]$pkg.version
              break
            }
          } catch { }
        }
      }
    }
  }
  $desktopDir = [Environment]::GetFolderPath('Desktop')
  $progMenu = [Environment]::GetFolderPath('Programs')
  $hasShortcut = ($desktopDir -and (Test-Path -LiteralPath (Join-Path $desktopDir 'EmTroLy - Antigravity.lnk') -PathType Leaf)) -or
    ($progMenu -and (Test-Path -LiteralPath (Join-Path $progMenu 'EmTroLy - Antigravity.lnk') -PathType Leaf))
  $extDetail = if ($extInstalled -and $hasShortcut) {
    "Đã cài đặt (v$extVer · Đã có lối tắt EmTroLy - Antigravity)"
  } elseif ($extInstalled) {
    "Đã cài v$extVer (chưa thấy lối tắt Desktop — bấm Cài lại để khôi phục)"
  } else {
    'Chưa cài đặt — cài tiện ích Codex vào Antigravity riêng & tạo lối tắt Desktop'
  }

  $ocState = if (Get-Command -Name 'Get-EmTroLyInstalledState' -ErrorAction Ignore) { Get-EmTroLyInstalledState } else { $null }
  $ocInstalled = ($ocState -and [bool]$ocState.OpenClawInstalled)
  $zaloInstalled = ($ocState -and [bool]$ocState.ZaloInstalled)
  $ocVerInfo = if (Get-Command -Name 'Get-EmTroLyOpenClawVersionInfo' -ErrorAction Ignore) {
    Get-EmTroLyOpenClawVersionInfo -OpenClawRoot $(if ($ocState) { [string]$ocState.Root } else { '' })
  } else { $null }
  $ocCurVer = if ($ocVerInfo) { [string]$ocVerInfo.InstalledVersion } else { '' }
  $ocTargetVer = if ($ocVerInfo) { [string]$ocVerInfo.TargetVersion } else { '2026.11.4' }
  $ocNeedsUpgrade = ($ocInstalled -and $ocVerInfo -and [bool]$ocVerInfo.NeedsUpgrade)
  $ocDetail = if ($ocInstalled) {
    $zTxt = if ($zaloInstalled) { 'Có Zalo QR' } else { 'Không kèm Zalo' }
    if ($ocNeedsUpgrade) {
      "Đã cài v$ocCurVer (có bản mới v$ocTargetVer — bấm Nâng cấp để cập nhật, giữ nguyên dữ liệu cũ)"
    } elseif ($ocCurVer) {
      "Đã cài đặt v$ocCurVer ($($ocState.AssistantName) · Cổng $($ocState.GatewayPort) · $zTxt)"
    } else {
      "Đã cài đặt ($($ocState.AssistantName) · Cổng $($ocState.GatewayPort) · $zTxt)"
    }
  } else {
    "Chưa cài đặt — cài Node.js, Python, FFmpeg, OpenClaw $ocTargetVer & Gateway"
  }

  return [pscustomobject]@{
    CodexCliInstalled        = $codexInstalled
    CodexCliDetail           = $codexDetail
    AntigravityInstalled     = $ideInstalled
    AntigravityPath          = $idePath
    AntigravityDetail        = $ideDetail
    CodexExtensionInstalled  = ($extInstalled -and $hasShortcut)
    CodexExtensionDetail     = $extDetail
    OpenClawInstalled        = $ocInstalled
    OpenClawInstalledVersion = $ocCurVer
    OpenClawTargetVersion    = $ocTargetVer
    OpenClawNeedsUpgrade     = [bool]$ocNeedsUpgrade
    ZaloInstalled            = $zaloInstalled
    OpenClawDetail           = $ocDetail
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

function Resolve-EmTroLyAppCatalogPath([string]$PayloadRoot = '') {
  $candidates = @()
  if ($PayloadRoot) {
    $candidates += (Join-Path $PayloadRoot 'profiles\apps-catalog.json')
    $candidates += (Join-Path $PayloadRoot 'apps-catalog.json')
  }
  if ($PSScriptRoot) {
    $parent = Split-Path -Parent $PSScriptRoot
    if ($parent) {
      $candidates += (Join-Path $parent 'profiles\apps-catalog.json')
      $candidates += (Join-Path $parent 'apps-catalog.json')
    }
  }
  foreach ($cand in @($candidates | Select-Object -Unique)) {
    if ($cand -and (Test-Path -LiteralPath $cand -PathType Leaf)) {
      return $cand
    }
  }
  return ''
}

function Test-EmTroLyCatalogAppInstalled {
  param(
    [Parameter(Mandatory=$true)]$App,
    $ModularStatus = $null,
    $InstalledState = $null
  )
  $actType = if ($App.PSObject.Properties['action_type']) { ([string]$App.action_type).Trim().ToLowerInvariant() } else { '' }
  if ($actType -eq 'modular') {
    $comps = @()
    if ($App.PSObject.Properties['components'] -and $App.components) {
      $comps = @($App.components | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
    }
    if ($comps.Count -gt 0 -and $ModularStatus) {
      $allReady = $true
      foreach ($c in $comps) {
        switch ($c) {
          'codex-cli'       { if (-not [bool]$ModularStatus.CodexCliInstalled) { $allReady = $false } }
          'antigravity-ide' { if (-not [bool]$ModularStatus.AntigravityInstalled) { $allReady = $false } }
          'codex-extension' { if (-not [bool]$ModularStatus.CodexExtensionInstalled) { $allReady = $false } }
          'openclaw'        { if (-not [bool]$ModularStatus.OpenClawInstalled) { $allReady = $false } }
          default           { $allReady = $false }
        }
      }
      return $allReady
    }
    return $false
  }
  if ($actType -eq 'zalo-plugin') {
    if ($InstalledState -and [bool]$InstalledState.ZaloInstalled) { return $true }
    if ($ModularStatus -and [bool]$ModularStatus.ZaloInstalled) { return $true }
    return $false
  }
  if ($App.PSObject.Properties['detect_path'] -and -not [string]::IsNullOrWhiteSpace([string]$App.detect_path)) {
    $expanded = [Environment]::ExpandEnvironmentVariables([string]$App.detect_path)
    if ($expanded -and (Test-Path -LiteralPath $expanded)) { return $true }
  }
  if ($App.PSObject.Properties['detect_command'] -and -not [string]::IsNullOrWhiteSpace([string]$App.detect_command)) {
    $cmdName = ([string]$App.detect_command).Trim()
    if (@(Get-Command $cmdName -CommandType Application -ErrorAction Ignore).Count -gt 0) {
      return $true
    }
  }
  return $false
}

function Get-EmTroLyAppCatalog {
  param(
    [string]$PayloadRoot = ''
  )
  $catalogPath = Resolve-EmTroLyAppCatalogPath -PayloadRoot $PayloadRoot
  $rawObj = $null
  if ($catalogPath) {
    try {
      $rawObj = [IO.File]::ReadAllText($catalogPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch { $rawObj = $null }
  }

  $ms = if (Get-Command -Name 'Get-EmTroLyModularStatus' -ErrorAction Ignore) { Get-EmTroLyModularStatus } else { $null }
  $st = if (Get-Command -Name 'Get-EmTroLyInstalledState' -ErrorAction Ignore) { Get-EmTroLyInstalledState } else { $null }

  $categories = if ($rawObj -and $rawObj.PSObject.Properties['categories'] -and $rawObj.categories) {
    @($rawObj.categories)
  } else {
    @(
      [pscustomobject]@{ id = 'all'; label = 'Tất cả' },
      [pscustomobject]@{ id = 'core'; label = 'Lập trình & Trợ lý' },
      [pscustomobject]@{ id = 'installed'; label = 'Đã cài' }
    )
  }

  $combos = @()
  if ($rawObj -and $rawObj.PSObject.Properties['combos'] -and $rawObj.combos) {
    foreach ($cb in @($rawObj.combos)) {
      $cbInstalled = Test-EmTroLyCatalogAppInstalled -App $cb -ModularStatus $ms -InstalledState $st
      $combos += [pscustomobject]@{
        Id           = [string]$cb.id
        Name         = [string]$cb.name
        Badge        = if ($cb.PSObject.Properties['badge']) { [string]$cb.badge } else { '' }
        Description  = [string]$cb.description
        ButtonLabel  = if ($cb.PSObject.Properties['button_label']) { [string]$cb.button_label } else { 'Cài cả gói' }
        ActionType   = if ($cb.PSObject.Properties['action_type']) { [string]$cb.action_type } else { 'modular' }
        Components   = if ($cb.PSObject.Properties['components']) { @($cb.components | ForEach-Object { [string]$_ }) } else { @() }
        Installed    = [bool]$cbInstalled
      }
    }
  }

  $apps = @()
  if ($rawObj -and $rawObj.PSObject.Properties['apps'] -and $rawObj.apps) {
    foreach ($ap in @($rawObj.apps)) {
      $isInst = Test-EmTroLyCatalogAppInstalled -App $ap -ModularStatus $ms -InstalledState $st
      $actType = if ($ap.PSObject.Properties['action_type']) { ([string]$ap.action_type).Trim().ToLowerInvariant() } else { 'coming_soon' }
      $apps += [pscustomobject]@{
        Id             = [string]$ap.id
        Name           = [string]$ap.name
        Category       = if ($ap.PSObject.Properties['category']) { [string]$ap.category } else { 'core' }
        Badge          = if ($ap.PSObject.Properties['badge']) { [string]$ap.badge } else { '' }
        Description    = [string]$ap.description
        Version        = if ($ap.PSObject.Properties['version']) { [string]$ap.version } else { '' }
        IconBg         = if ($ap.PSObject.Properties['icon_bg']) { [string]$ap.icon_bg } else { '#EFF6FF' }
        IconFg         = if ($ap.PSObject.Properties['icon_fg']) { [string]$ap.icon_fg } else { '#2563EB' }
        IconPath       = if ($ap.PSObject.Properties['icon_path']) { [string]$ap.icon_path } else { 'M 4,8 L 20,8 L 20,19 L 4,19 Z' }
        ActionType     = $actType
        Components     = if ($ap.PSObject.Properties['components']) { @($ap.components | ForEach-Object { [string]$_ }) } else { @() }
        InstallScript  = if ($ap.PSObject.Properties['install_script']) { [string]$ap.install_script } else { '' }
        LaunchUrl      = if ($ap.PSObject.Properties['launch_url']) { [string]$ap.launch_url } else { '' }
        LaunchShortcut = if ($ap.PSObject.Properties['launch_shortcut']) { [string]$ap.launch_shortcut } else { '' }
        OpenView       = if ($ap.PSObject.Properties['open_view']) { [string]$ap.open_view } else { '' }
        Note           = if ($ap.PSObject.Properties['note']) { [string]$ap.note } else { '' }
        Installed      = [bool]$isInst
      }
    }
  }

  return [pscustomobject]@{
    CatalogPath = $catalogPath
    Categories  = $categories
    Combos      = $combos
    Apps        = $apps
  }
}

function Compare-EmTroLyVersion {
  param(
    [string]$Current = '',
    [string]$Target = ''
  )
  $parseParts = {
    param([string]$Raw)
    $clean = ([string]$Raw).Trim().TrimStart('v', 'V')
    $main = ($clean -split '[-+]')[0]
    $nums = @()
    foreach ($seg in @($main -split '\.')) {
      $val = 0
      if ([int]::TryParse($seg, [ref]$val)) { $nums += $val }
      else { $nums += 0 }
    }
    while ($nums.Count -lt 3) { $nums += 0 }
    return ,$nums
  }
  $a = & $parseParts $Current
  $b = & $parseParts $Target
  $maxLen = [Math]::Max($a.Count, $b.Count)
  for ($i = 0; $i -lt $maxLen; $i++) {
    $av = if ($i -lt $a.Count) { [int]$a[$i] } else { 0 }
    $bv = if ($i -lt $b.Count) { [int]$b[$i] } else { 0 }
    if ($av -lt $bv) { return -1 }
    if ($av -gt $bv) { return 1 }
  }
  return 0
}

function Get-EmTroLyOpenClawVersionInfo {
  param(
    [string]$PayloadRoot = '',
    [string]$OpenClawRoot = ''
  )
  $targetVer = '2026.11.4'
  try {
    $appVer = Get-EmTroLyAppVersion -PayloadRoot $PayloadRoot
    if ($appVer -and -not [string]::IsNullOrWhiteSpace([string]$appVer.OpenClawVersion)) {
      $targetVer = ([string]$appVer.OpenClawVersion).Trim()
    }
  } catch { }

  $root = if (-not [string]::IsNullOrWhiteSpace($OpenClawRoot)) {
    $OpenClawRoot
  } elseif ($env:USERPROFILE) {
    Join-Path $env:USERPROFILE 'openclaw'
  } else { '' }

  $installed = ($root -and (Test-Path -LiteralPath (Join-Path $root 'openclaw.json') -PathType Leaf))
  $curVer = ''
  if ($installed) {
    # 1. Check installer-instance.json -> cli_entry -> package.json
    $instJson = Join-Path $root 'installer-instance.json'
    if (Test-Path -LiteralPath $instJson -PathType Leaf) {
      try {
        $instObj = [IO.File]::ReadAllText($instJson, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($instObj -and $instObj.cli_entry) {
          $pkgPath = Join-Path (Split-Path -Parent ([string]$instObj.cli_entry)) 'package.json'
          if (Test-Path -LiteralPath $pkgPath -PathType Leaf) {
            $pkg = [IO.File]::ReadAllText($pkgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($pkg -and $pkg.version) { $curVer = ([string]$pkg.version).Trim() }
          }
        }
      } catch { }
    }
    # 2. Fallback: scan runtime\*\node_modules\openclaw\package.json (newest first)
    if (-not $curVer) {
      $rtBase = Join-Path $root 'runtime'
      if (Test-Path -LiteralPath $rtBase -PathType Container) {
        foreach ($rtDir in @(Get-ChildItem -LiteralPath $rtBase -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
          $pCand = Join-Path $rtDir.FullName 'node_modules\openclaw\package.json'
          if (Test-Path -LiteralPath $pCand -PathType Leaf) {
            try {
              $pObj = [IO.File]::ReadAllText($pCand, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
              if ($pObj -and $pObj.version) { $curVer = ([string]$pObj.version).Trim(); break }
            } catch { }
          }
          if ($rtDir.Name -match '^\d+\.\d+\.\d+') {
            $curVer = $rtDir.Name
            break
          }
        }
      }
    }
  }

  $needsUpgrade = $false
  $isUpToDate = $false
  if ($installed -and $curVer) {
    $cmp = Compare-EmTroLyVersion -Current $curVer -Target $targetVer
    $needsUpgrade = ($cmp -lt 0)
    $isUpToDate = ($cmp -ge 0)
  }

  return [pscustomobject]@{
    Installed        = [bool]$installed
    InstalledVersion = $curVer
    TargetVersion    = $targetVer
    NeedsUpgrade     = [bool]$needsUpgrade
    IsUpToDate       = [bool]$isUpToDate
    Root             = $root
  }
}

function Set-EmTroLyTlsSecurityProtocol {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]3072 -bor [Net.SecurityProtocolType]12288
  } catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  }
}

function Test-EmTroLyTrustedGitHubUrl {
  param(
    [string]$Url = '',
    [bool]$AllowLoopback = $false
  )
  if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
  $parsed = $null
  if (-not [uri]::TryCreate($Url.Trim(), [System.UriKind]::Absolute, [ref]$parsed)) { return $false }
  if ($AllowLoopback -and $parsed.Scheme -ieq 'http' -and $parsed.Host -ieq '127.0.0.1') {
    return $true
  }
  if ($parsed.Scheme -ine 'https') { return $false }
  $hostLower = ([string]$parsed.Host).ToLowerInvariant()
  if ($hostLower -eq 'github.com' -or
      $hostLower -eq 'api.github.com' -or
      $hostLower.EndsWith('.github.com') -or
      $hostLower.EndsWith('.githubusercontent.com')) {
    return $true
  }
  return $false
}

function Get-EmTroLyAppUpdateInfo {
  param(
    [string]$PayloadRoot = '',
    [string]$CurrentVersion = '',
    [string]$Repo = 'workanhlaptrinh123/installer_emtroly',
    [string]$ApiBaseUrl = ''
  )
  Set-EmTroLyTlsSecurityProtocol
  $curVer = if (-not [string]::IsNullOrWhiteSpace($CurrentVersion)) {
    $CurrentVersion.Trim().TrimStart('v', 'V')
  } else {
    (Get-EmTroLyAppVersion -PayloadRoot $PayloadRoot).InstallerVersion
  }

  $effectiveApiBase = if (-not [string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
    $ApiBaseUrl.Trim().TrimEnd('/')
  } elseif (-not [string]::IsNullOrWhiteSpace($env:EMTROLY_UPDATE_API_BASE)) {
    $env:EMTROLY_UPDATE_API_BASE.Trim().TrimEnd('/')
  } else {
    "https://api.github.com/repos/$Repo/releases"
  }

  $allowLoopback = ((-not [string]::IsNullOrWhiteSpace($ApiBaseUrl)) -or (-not [string]::IsNullOrWhiteSpace($env:EMTROLY_UPDATE_API_BASE))) -and
    ($effectiveApiBase -match '^http://127\.0\.0\.1:\d+')

  if (-not (Test-EmTroLyTrustedGitHubUrl -Url "$effectiveApiBase/latest" -AllowLoopback $allowLoopback)) {
    return [pscustomobject]@{
      Ok             = $false
      HasUpdate      = $false
      BuildingAssets = $false
      CurrentVersion = $curVer
      LatestVersion  = ''
      TagName        = ''
      DownloadUrl    = ''
      Sha256Url      = ''
      ReleasePageUrl = ''
      AssetSizeBytes = 0L
      ReleaseNotes   = ''
      Message        = 'Địa chỉ máy chủ kiểm tra cập nhật không hợp lệ (chỉ chấp nhận GitHub chính thức).'
    }
  }

  $latestVer = ''
  $tagName = ''
  $downloadUrl = ''
  $sha256Url = ''
  $releasePageUrl = "https://github.com/$Repo/releases/latest"
  $assetSize = 0L
  $releaseNotes = ''
  $apiErrMsg = ''

  try {
    $headers = @{
      'User-Agent' = 'AnhLapTrinh-EmTroLy-Updater/1.0'
      'Accept'     = 'application/vnd.github+json'
    }
    $rel = Invoke-RestMethod -UseBasicParsing -Method Get -Uri "$effectiveApiBase/latest" -Headers $headers -TimeoutSec 12 -MaximumRedirection 3
    if ($rel -and $rel.tag_name) {
      $tagName = ([string]$rel.tag_name).Trim()
      $latestVer = $tagName.TrimStart('v', 'V')
      if ($rel.html_url) { $releasePageUrl = ([string]$rel.html_url).Trim() }
      if ($rel.body) {
        $cleanNotes = ([string]$rel.body).Trim()
        if ($cleanNotes.Length -gt 500) { $cleanNotes = $cleanNotes.Substring(0, 500).TrimEnd() + '...' }
        $releaseNotes = $cleanNotes
      }
      $exeAsset = @($rel.assets | Where-Object { $_.name -eq 'emtroly.exe' } | Select-Object -First 1)
      $shaAsset = @($rel.assets | Where-Object { $_.name -eq 'emtroly.exe.sha256' } | Select-Object -First 1)
      if ($exeAsset.Count -gt 0 -and $exeAsset[0].browser_download_url) {
        $downloadUrl = ([string]$exeAsset[0].browser_download_url).Trim()
        if ($exeAsset[0].size) { $assetSize = [long]$exeAsset[0].size }
      }
      if ($shaAsset.Count -gt 0 -and $shaAsset[0].browser_download_url) {
        $sha256Url = ([string]$shaAsset[0].browser_download_url).Trim()
      }
    }
  } catch {
    $apiErrMsg = [string]$_.Exception.Message
  }

  # Automatic CDN fallback if GitHub REST API rate-limits anonymous IPs (HTTP 403 / 429)
  if ([string]::IsNullOrWhiteSpace($latestVer) -and -not $allowLoopback -and $effectiveApiBase -eq "https://api.github.com/repos/$Repo/releases") {
    try {
      $cdnBase = "https://github.com/$Repo/releases/latest/download"
      $manifestResp = Invoke-WebRequest -UseBasicParsing -Method Get -Uri "$cdnBase/MANIFEST.txt" -Headers @{ 'User-Agent' = 'AnhLapTrinh-EmTroLy-Updater/1.0' } -TimeoutSec 12
      $manifestTxt = if ($manifestResp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($manifestResp.Content) } else { [string]$manifestResp.Content }
      $verMatch = [regex]::Match($manifestTxt, '(?m)^installer_version=([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$')
      if ($verMatch.Success) {
        $latestVer = $verMatch.Groups[1].Value.Trim()
        $tagName = "v$latestVer"
        $downloadUrl = "https://github.com/$Repo/releases/download/$tagName/emtroly.exe"
        $sha256Url = "https://github.com/$Repo/releases/download/$tagName/emtroly.exe.sha256"
        $releasePageUrl = "https://github.com/$Repo/releases/tag/$tagName"
      }
    } catch { }
  }

  if ([string]::IsNullOrWhiteSpace($latestVer) -or $latestVer -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$') {
    return [pscustomobject]@{
      Ok             = $false
      HasUpdate      = $false
      BuildingAssets = $false
      CurrentVersion = $curVer
      LatestVersion  = ''
      TagName        = ''
      DownloadUrl    = ''
      Sha256Url      = ''
      ReleasePageUrl = $releasePageUrl
      AssetSizeBytes = 0L
      ReleaseNotes   = ''
      Message        = 'Không kiểm tra được phiên bản mới trên GitHub. Vui lòng kiểm tra kết nối mạng rồi thử lại.'
    }
  }

  $cmp = Compare-EmTroLyVersion -Current $curVer -Target $latestVer
  if ($cmp -lt 0) {
    $validUrls = (Test-EmTroLyTrustedGitHubUrl -Url $downloadUrl -AllowLoopback $allowLoopback) -and
                 (Test-EmTroLyTrustedGitHubUrl -Url $sha256Url -AllowLoopback $allowLoopback)
    if (-not $validUrls) {
      return [pscustomobject]@{
        Ok             = $true
        HasUpdate      = $false
        BuildingAssets = $true
        CurrentVersion = $curVer
        LatestVersion  = $latestVer
        TagName        = $(if ($tagName) { $tagName } else { "v$latestVer" })
        DownloadUrl    = ''
        Sha256Url      = ''
        ReleasePageUrl = $releasePageUrl
        AssetSizeBytes = 0L
        ReleaseNotes   = $releaseNotes
        Message        = "Phiên bản mới v$latestVer vừa được tạo trên GitHub và đang hoàn tất đóng gói — vui lòng thử lại sau ít phút."
      }
    }
    return [pscustomobject]@{
      Ok             = $true
      HasUpdate      = $true
      BuildingAssets = $false
      CurrentVersion = $curVer
      LatestVersion  = $latestVer
      TagName        = $(if ($tagName) { $tagName } else { "v$latestVer" })
      DownloadUrl    = $downloadUrl
      Sha256Url      = $sha256Url
      ReleasePageUrl = $releasePageUrl
      AssetSizeBytes = $assetSize
      ReleaseNotes   = $releaseNotes
      Message        = "Đã có phiên bản mới Em Trợ Lý v$latestVer trên GitHub (phiên bản hiện tại: v$curVer)."
    }
  }

  return [pscustomobject]@{
    Ok             = $true
    HasUpdate      = $false
    BuildingAssets = $false
    CurrentVersion = $curVer
    LatestVersion  = $latestVer
    TagName        = $(if ($tagName) { $tagName } else { "v$latestVer" })
    DownloadUrl    = $downloadUrl
    Sha256Url      = $sha256Url
    ReleasePageUrl = $releasePageUrl
    AssetSizeBytes = $assetSize
    ReleaseNotes   = $releaseNotes
    Message        = "Bạn đang sử dụng phiên bản Em Trợ Lý mới nhất (v$curVer)."
  }
}

function Install-EmTroLyAppUpdate {
  param(
    [Parameter(Mandatory=$true)]$UpdateInfo,
    [string]$StatusFile = '',
    [string]$OutDir = '',
    [switch]$AllowLoopback
  )
  Set-EmTroLyTlsSecurityProtocol
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $writeProgress = {
    param([string]$Txt)
    if (-not [string]::IsNullOrWhiteSpace($StatusFile)) {
      [void](Write-EmTroLySharedStatusFile -Path $StatusFile -Text $Txt)
    }
  }

  $loopbackOk = [bool]$AllowLoopback -or ((-not [string]::IsNullOrWhiteSpace($env:EMTROLY_UPDATE_API_BASE)) -and ($env:EMTROLY_UPDATE_API_BASE -match '^http://127\.0\.0\.1:\d+'))
  $dlUrl = ([string](Get-SafeProp $UpdateInfo 'DownloadUrl')).Trim()
  $shaUrl = ([string](Get-SafeProp $UpdateInfo 'Sha256Url')).Trim()
  $verRaw = ([string](Get-SafeProp $UpdateInfo 'LatestVersion')).Trim().TrimStart('v', 'V')
  if (-not $verRaw -or $verRaw -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$') {
    throw 'Thông tin phiên bản cập nhật không hợp lệ.'
  }
  if (-not (Test-EmTroLyTrustedGitHubUrl -Url $dlUrl -AllowLoopback $loopbackOk) -or
      -not (Test-EmTroLyTrustedGitHubUrl -Url $shaUrl -AllowLoopback $loopbackOk)) {
    throw 'Đường dẫn tải bản cập nhật không thuộc máy chủ GitHub chính thức.'
  }

  & $writeProgress "Đang xác minh mã kiểm tra an toàn SHA-256 cho bản v$verRaw..."
  $shaResp = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $shaUrl -Headers @{ 'User-Agent' = 'AnhLapTrinh-EmTroLy-Updater/1.0' } -TimeoutSec 25
  $shaContent = if ($shaResp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($shaResp.Content) } else { [string]$shaResp.Content }
  $shaMatch = [regex]::Match($shaContent, '(?i)\b([a-f0-9]{64})\b')
  if (-not $shaMatch.Success) {
    throw 'Không đọc được mã kiểm tra toàn vẹn SHA-256 chính thức từ GitHub Release.'
  }
  $expectedHash = $shaMatch.Groups[1].Value.ToLowerInvariant()

  $isDefaultCache = [string]::IsNullOrWhiteSpace($OutDir)
  $workDir = if (-not $isDefaultCache) {
    [IO.Path]::GetFullPath($OutDir)
  } elseif ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'AnhLapTrinh\EmTroLy\bootstrap'
  } else {
    Join-Path ([IO.Path]::GetTempPath()) 'EmTroLy-Updates'
  }
  [void][IO.Directory]::CreateDirectory($workDir)
  $safeVer = [regex]::Replace($verRaw, '[^0-9A-Za-z._-]', '')
  $targetExe = Join-Path $workDir "emtroly-v$safeVer.exe"

  if (Test-Path -LiteralPath $targetExe -PathType Leaf) {
    $existingHash = (Get-FileHash -LiteralPath $targetExe -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($existingHash -eq $expectedHash) {
      & $writeProgress "Đã xác minh bản cập nhật v$verRaw sẵn sàng (100%)!"
      try { Unblock-File -LiteralPath $targetExe -ErrorAction SilentlyContinue } catch { }
      return [pscustomobject]@{
        Ok      = $true
        ExePath = $targetExe
        Sha256  = $expectedHash
        Version = $verRaw
      }
    }
  }

  $tmpExe = "$targetExe.part-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
  try {
    $req = [System.Net.HttpWebRequest]::Create([uri]$dlUrl)
    $req.Method = 'GET'
    $req.AllowAutoRedirect = $true
    $req.UserAgent = 'AnhLapTrinh-EmTroLy-Updater/1.0'
    $req.Timeout = 600000
    $req.ReadWriteTimeout = 120000

    $resp = $req.GetResponse()
    try {
      if (-not (Test-EmTroLyTrustedGitHubUrl -Url ([string]$resp.ResponseUri) -AllowLoopback $loopbackOk)) {
        throw "Máy chủ chuyển hướng tải về không hợp lệ: $($resp.ResponseUri.Host)"
      }
      $totalBytes = [long]$resp.ContentLength
      if ($totalBytes -le 0) {
        $hintSize = [long](Get-SafeProp $UpdateInfo 'AssetSizeBytes')
        if ($hintSize -gt 0) { $totalBytes = $hintSize }
      }
      $inStream = $resp.GetResponseStream()
      try {
        $outStream = New-Object System.IO.FileStream($tmpExe, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 262144)
        try {
          $buffer = New-Object byte[] 65536
          $readTotal = 0L
          $lastTick = [Environment]::TickCount - 500
          while (($n = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outStream.Write($buffer, 0, $n)
            $readTotal += $n
            $now = [Environment]::TickCount
            if (($now - $lastTick) -ge 150 -or ($totalBytes -gt 0 -and $readTotal -ge $totalBytes)) {
              $lastTick = $now
              $mbDone = ($readTotal / 1MB).ToString('0.0')
              if ($totalBytes -gt 0) {
                $pct = [int][Math]::Min(96L, [Math]::Max(5L, [long](($readTotal * 96L) / $totalBytes)))
                $mbAll = ($totalBytes / 1MB).ToString('0.0')
                & $writeProgress "Đang tải bản cập nhật v$verRaw... $pct% ($mbDone / $mbAll MB)"
              } else {
                & $writeProgress "Đang tải bản cập nhật v$verRaw... ($mbDone MB)"
              }
            }
          }
        } finally {
          $outStream.Dispose()
        }
      } finally {
        $inStream.Dispose()
      }
    } finally {
      $resp.Close()
    }

    & $writeProgress "Đang kiểm tra mã toàn vẹn SHA-256 của bản v$verRaw... 98%"
    $actualHash = (Get-FileHash -LiteralPath $tmpExe -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
      throw 'Mã kiểm tra SHA-256 của bản cập nhật không khớp. Đã hủy để bảo vệ an toàn máy tính.'
    }

    Move-Item -LiteralPath $tmpExe -Destination $targetExe -Force
    try { Unblock-File -LiteralPath $targetExe -ErrorAction SilentlyContinue } catch { }

    if ($isDefaultCache) {
      $targetLeaf = Split-Path -Leaf $targetExe
      foreach ($oldFile in @(Get-ChildItem -LiteralPath $workDir -Filter 'emtroly-*.exe' -File -ErrorAction SilentlyContinue)) {
        if ($oldFile.Name -ine $targetLeaf) {
          Remove-Item -LiteralPath $oldFile.FullName -Force -ErrorAction SilentlyContinue
        }
      }
    }

    & $writeProgress "Đã tải xong & xác minh an toàn bản v$verRaw (100%)! Đang mở phiên bản mới..."
    return [pscustomobject]@{
      Ok      = $true
      ExePath = $targetExe
      Sha256  = $expectedHash
      Version = $verRaw
    }
  } finally {
    if (Test-Path -LiteralPath $tmpExe -PathType Leaf) {
      Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue
    }
  }
}

function Start-EmTroLyUpdatedInstallerHandoff {
  param(
    [Parameter(Mandatory=$true)][string]$InstallerExePath,
    [int]$WaitParentPid = 0
  )
  if (-not (Test-Path -LiteralPath $InstallerExePath -PathType Leaf)) {
    throw 'Không tìm thấy tệp bộ cài mới để khởi chạy.'
  }
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $workDir = Split-Path -Parent ([IO.Path]::GetFullPath($InstallerExePath))
  $escapedExe = $InstallerExePath.Replace("'", "''")
  $escapedDir = $workDir.Replace("'", "''")
  $cmdScript = "if ($WaitParentPid -gt 0) { try { Wait-Process -Id $WaitParentPid -Timeout 12 -ErrorAction SilentlyContinue } catch {} }; Start-Sleep -Milliseconds 250; Start-Process -FilePath '$escapedExe' -WorkingDirectory '$escapedDir'"
  $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmdScript))
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $psi.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $encoded"
  $psi.WorkingDirectory = $workDir
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  [void][System.Diagnostics.Process]::Start($psi)
}

function Sync-EmTroLyInstalledUiIfNewer {
  param([string]$PayloadRoot = '')
  if (-not $env:LOCALAPPDATA -or [string]::IsNullOrWhiteSpace($PayloadRoot) -or -not (Test-Path -LiteralPath $PayloadRoot -PathType Container)) {
    return $false
  }
  $emUiDir = Join-Path $env:LOCALAPPDATA 'EmTroLyUI'
  $installedWizard = Join-Path $emUiDir 'windows-installer\wizard.ps1'
  if (-not (Test-Path -LiteralPath $installedWizard -PathType Leaf)) {
    return $false
  }
  try {
    if ([IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\') -ieq [IO.Path]::GetFullPath($emUiDir).TrimEnd('\')) {
      return $false
    }
    $curUiVer = (Get-EmTroLyAppVersion -PayloadRoot $emUiDir).InstallerVersion
    $newPayloadVer = (Get-EmTroLyAppVersion -PayloadRoot $PayloadRoot).InstallerVersion
    if ((Compare-EmTroLyVersion -Current $curUiVer -Target $newPayloadVer) -lt 0) {
      [void](Install-EmTroLyAppShortcut -PayloadRoot $PayloadRoot)
      return $true
    }
  } catch { }
  return $false
}
