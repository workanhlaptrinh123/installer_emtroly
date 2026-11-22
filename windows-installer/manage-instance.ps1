[CmdletBinding()]
param(
  [switch]$RunManageWorker,
  [string]$WorkerRequestFile = '',
  [string]$WorkerPayloadRoot = '',
  [string]$WorkerLogFile = ''
)

function Read-EmTroLyProfileFields([string]$ProfilePath) {
  $result = @{ Audience = ''; Addressing = ''; Style = '' }
  if (-not $ProfilePath -or -not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
    return $result
  }
  try {
    $lines = [IO.File]::ReadAllLines($ProfilePath, [System.Text.Encoding]::UTF8)
    foreach ($line in $lines) {
      if ($line -match '^Doi tuong phuc vu:\s*(.*)$') { $result.Audience = $Matches[1].Trim() }
      elseif ($line -match '^Cach xung ho:\s*(.*)$') { $result.Addressing = $Matches[1].Trim() }
      elseif ($line -match '^Phong cach tra loi:\s*(.*)$') { $result.Style = $Matches[1].Trim() }
    }
  } catch { }
  return $result
}

function Get-EmTroLyInstalledState {
  $root = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'openclaw' } else { '' }
  $configPath = if ($root) { Join-Path $root 'openclaw.json' } else { '' }
  $codexInfo = if (Get-Command Find-EmTroLyCodexCli -ErrorAction SilentlyContinue) {
    Find-EmTroLyCodexCli
  } else {
    [pscustomobject]@{ Available = $false; Executable = ''; CodexHome = ''; Source = 'none'; Label = '' }
  }

  if (-not $configPath -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
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
    $cfg = [IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
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
    if ($cfg.gateway -and $cfg.gateway.port) {
      $gatewayPort = [string]$cfg.gateway.port
    }
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
        if ($txt -match '^telegram:([1-9][0-9]*)$' -and $Matches[1] -notin $ownersList) {
          $ownersList += $Matches[1]
        }
      }
    }
    if ($ownersList.Count -eq 0 -and $cfg.channels -and $cfg.channels.telegram -and $cfg.channels.telegram.allowFrom) {
      foreach ($item in @($cfg.channels.telegram.allowFrom)) {
        $txt = ([string]$item).Trim()
        if ($txt -match '^[1-9][0-9]*$' -and $txt -notin $ownersList) {
          $ownersList += $txt
        }
      }
    }
    $ownerIds = ($ownersList -join ',')
  } catch { }

  $profileFields = Read-EmTroLyProfileFields (Join-Path $root 'workspace\CUSTOMER_PROFILE.md')
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
    Audience          = $profileFields.Audience
    Addressing        = $profileFields.Addressing
    Style             = $profileFields.Style
    HasTelegramToken  = [bool]$hasToken
    HasProviderSecret = [bool]$hasSecret
    ZaloInstalled     = [bool]$hasZalo
    CodexInstalled    = [bool]$codexInfo.Available
  }
}

function Write-ManageStatus([string]$Path, [string]$Text) {
  if ($Path) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
  }
}

function Protect-EmTroLySecretFile([string]$FilePath) {
  $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  & icacls $FilePath /inheritance:r /grant:r "${currentUser}:(F)" '*S-1-5-18:(F)' *> $null
  if ($LASTEXITCODE -ne 0) { throw 'secret-acl-failed' }
}

function Sync-EmTroLyTelegramMenu([string]$Token) {
  $required = @(
    @{ command = 'zaloqr'; description = 'Tạo mã QR đăng nhập Zalo' },
    @{ command = 'zalostatus'; description = 'Kiểm tra trạng thái Zalo' }
  )
  $currentResponse = Invoke-RestMethod -UseBasicParsing -Method Get -Uri ("https://api.telegram.org/bot$Token/getMyCommands") -TimeoutSec 45 -MaximumRedirection 0
  if (-not $currentResponse.ok) { throw 'telegram-command-menu-not-registered' }
  $currentNames = @($currentResponse.result | ForEach-Object { $_.command })
  if ('zaloqr' -in $currentNames -and 'zalostatus' -in $currentNames) { return }
  $merged = New-Object System.Collections.Generic.List[object]
  foreach ($item in $required) { [void]$merged.Add($item) }
  foreach ($item in @($currentResponse.result)) {
    if (-not $item.command -or $item.command -in @('zaloqr', 'zalostatus')) { continue }
    if (@($merged | Where-Object { $_.command -eq $item.command }).Count -eq 0) {
      [void]$merged.Add(@{ command = [string]$item.command; description = [string]$item.description })
    }
    if ($merged.Count -ge 100) { break }
  }
  $bodyJson = (@{ commands = @($merged | ForEach-Object { $_ }) } | ConvertTo-Json -Depth 8 -Compress)
  $setResp = Invoke-RestMethod -UseBasicParsing -Method Post -Uri ("https://api.telegram.org/bot$Token/setMyCommands") -ContentType 'application/json; charset=utf-8' -Body $bodyJson -TimeoutSec 45 -MaximumRedirection 0
  if (-not $setResp.ok) { throw 'telegram-command-menu-not-registered' }
}

function Invoke-SafeSubProcess {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][string[]]$ArgumentList,
    [int]$TimeoutSeconds = 300,
    [switch]$CaptureStdout
  )
  $quoted = (@($ArgumentList | ForEach-Object {
    $s = [string]$_
    if ($s -match '[\s"]') { '"' + $s.Replace('"', '\"') + '"' } else { $s }
  }) -join ' ')
  if ($CaptureStdout) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $quoted
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
      try { $p.Kill() } catch { }
      $p.Dispose()
      throw 'subprocess-timeout'
    }
    $rc = $p.ExitCode
    $stdout = if ($outTask.Wait(3000)) { $outTask.Result } else { '' }
    $p.Dispose()
    return [pscustomobject]@{ ExitCode = $rc; Stdout = $stdout }
  }
  # No stdout/stderr pipes: prevents long-lived detached daemons (gateway run) from deadlocking WaitForExit
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = $quoted
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $proc = [Diagnostics.Process]::Start($psi)
  if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    try { $proc.Kill() } catch { }
    $proc.Dispose()
    throw 'subprocess-timeout'
  }
  $code = $proc.ExitCode
  $proc.Dispose()
  return [pscustomobject]@{ ExitCode = $code; Stdout = '' }
}

function Invoke-EmTroLyGatewayInstance([string]$Root, [string[]]$CliArgs) {
  $instanceLauncher = Join-Path $Root 'openclaw-instance.ps1'
  if (-not (Test-Path -LiteralPath $instanceLauncher -PathType Leaf)) { throw 'instance-launcher-missing' }
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = Join-Path $PSHOME 'pwsh' }
  $quotedArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $instanceLauncher) + $CliArgs
  $needsOutput = ($CliArgs.Count -ge 2 -and $CliArgs[1] -eq 'status')
  $res = if ($needsOutput) {
    Invoke-SafeSubProcess -FilePath $psExe -ArgumentList $quotedArgs -TimeoutSeconds 45 -CaptureStdout
  } else {
    Invoke-SafeSubProcess -FilePath $psExe -ArgumentList $quotedArgs -TimeoutSeconds 180
  }
  if ($res.ExitCode -ne 0) { throw 'gateway-command-failed' }
  return $res.Stdout
}

function Invoke-ManageWorkerMain {
  param(
    [Parameter(Mandatory=$true)][string]$RequestPath,
    [Parameter(Mandatory=$true)][string]$PayloadDir,
    [Parameter(Mandatory=$true)][string]$StatusPath
  )
  $ErrorActionPreference = 'Stop'
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  $validationFile = Join-Path $PayloadDir 'windows-installer\validation.ps1'
  if (Test-Path -LiteralPath $validationFile -PathType Leaf) {
    . ([ScriptBlock]::Create([IO.File]::ReadAllText($validationFile, [System.Text.Encoding]::UTF8)))
  }
  $codexFile = Join-Path $PayloadDir 'windows-installer\codex-cli.ps1'
  if (Test-Path -LiteralPath $codexFile -PathType Leaf) {
    . ([ScriptBlock]::Create([IO.File]::ReadAllText($codexFile, [System.Text.Encoding]::UTF8)))
  }
  $autoHealFile = Join-Path $PayloadDir 'windows-installer\auto-heal-codex.ps1'
  if (Test-Path -LiteralPath $autoHealFile -PathType Leaf) {
    . ([ScriptBlock]::Create([IO.File]::ReadAllText($autoHealFile, [System.Text.Encoding]::UTF8)))
  }
  $wizardHelperFile = Join-Path $PayloadDir 'windows-installer\wizard-helpers.ps1'
  if (Test-Path -LiteralPath $wizardHelperFile -PathType Leaf) {
    . ([ScriptBlock]::Create([IO.File]::ReadAllText($wizardHelperFile, [System.Text.Encoding]::UTF8)))
  }

  $req = $null
  try {
    $req = [IO.File]::ReadAllText($RequestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  } finally {
    Remove-Item -LiteralPath $RequestPath -Force -ErrorAction SilentlyContinue
  }

  $action = [string]$req.action
  $root = Join-Path $env:USERPROFILE 'openclaw'
  $configPath = Join-Path $root 'openclaw.json'
  $instancePath = Join-Path $root 'installer-instance.json'
  $lastManageTechDetail = ''

  try {
    if ($action -notin @('update-config', 'install-zalo', 'reinstall-codex', 'health-restart', 'auto-heal', 'uninstall-instance')) {
      throw 'invalid-manage-action'
    }
    if ($action -notin @('reinstall-codex', 'auto-heal', 'uninstall-instance') -and -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
      throw 'instance-missing'
    }

    if ($action -eq 'uninstall-instance') {
      if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Write-ManageStatus $StatusPath 'Hoàn tất: Trên máy hiện không còn thư mục trợ lý OpenClaw — bạn có thể cài đặt mới ngay!'
        exit 0
      }
      $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
      if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'unsafe-symlink-instance'
      }

      Write-ManageStatus $StatusPath 'Đang dừng dịch vụ nền Gateway...'
      [IO.File]::WriteAllText((Join-Path $root 'user-gateway.stop'), 'stop', $utf8NoBom)
      if (Test-Path -LiteralPath (Join-Path $root 'openclaw-instance.ps1') -PathType Leaf) {
        try { [void](Invoke-EmTroLyGatewayInstance -Root $root -CliArgs @('gateway', 'stop')) } catch { }
      }
      try {
        $runningNodes = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue | Where-Object {
          $_.CommandLine -and $_.CommandLine.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        foreach ($rn in $runningNodes) {
          if ($rn.ProcessId) { Stop-Process -Id ([int]$rn.ProcessId) -Force -ErrorAction SilentlyContinue }
        }
      } catch { }

      Write-ManageStatus $StatusPath 'Đang sao lưu cấu hình an toàn trước khi gỡ bỏ...'
      $stampUn = Get-Date -Format 'yyyyMMdd-HHmmss'
      $backupBase = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "AnhLapTrinh\EmTroLy\backups\uninstall-$stampUn" } else { Join-Path $env:TEMP "emtroly-uninstall-$stampUn" }
      [void][IO.Directory]::CreateDirectory($backupBase)
      foreach ($pair in @(
        @{ Src = $configPath; Dst = (Join-Path $backupBase 'openclaw.json') },
        @{ Src = (Join-Path $root 'workspace\CUSTOMER_PROFILE.md'); Dst = (Join-Path $backupBase 'CUSTOMER_PROFILE.md') }
      )) {
        if (Test-Path -LiteralPath $pair.Src -PathType Leaf) {
          Copy-Item -LiteralPath $pair.Src -Destination $pair.Dst -Force
          if (Get-Command Set-EmTroLyPrivateFileAcl -ErrorAction SilentlyContinue) {
            Set-EmTroLyPrivateFileAcl $pair.Dst
          }
        }
      }

      $startupDir = if ($env:EMTROLY_TEST_STARTUP_DIR) { $env:EMTROLY_TEST_STARTUP_DIR } else { [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup) }
      if ($startupDir -and (Test-Path -LiteralPath $startupDir -PathType Container)) {
        foreach ($vbs in @(Get-ChildItem -LiteralPath $startupDir -Filter 'OpenClaw-*.vbs' -File -ErrorAction SilentlyContinue)) {
          try {
            $vbsTxt = [IO.File]::ReadAllText($vbs.FullName, [Text.Encoding]::Unicode)
            if ($vbsTxt.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
              Remove-Item -LiteralPath $vbs.FullName -Force -ErrorAction SilentlyContinue
            }
          } catch { }
        }
      }

      if ($env:LOCALAPPDATA) {
        $ocBinDir = Join-Path $env:LOCALAPPDATA 'OpenClaw\bin'
        if (Test-Path -LiteralPath $ocBinDir -PathType Container) {
          foreach ($cmdFile in @(Get-ChildItem -LiteralPath $ocBinDir -Filter 'openclaw*.cmd' -File -ErrorAction SilentlyContinue)) {
            try {
              $cmdTxt = [IO.File]::ReadAllText($cmdFile.FullName, [Text.Encoding]::UTF8)
              if ($cmdTxt.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Remove-Item -LiteralPath $cmdFile.FullName -Force -ErrorAction SilentlyContinue
              }
            } catch { }
          }
        }
      }

      Write-ManageStatus $StatusPath 'Đang dọn sạch thư mục trợ lý OpenClaw (giữ nguyên Antigravity & Codex để cài lại siêu nhanh)...'
      try {
        $cmdExeUn = Join-Path $env:SystemRoot 'System32\cmd.exe'
        if (Test-Path -LiteralPath $cmdExeUn -PathType Leaf) {
          $rmPsiUn = New-Object System.Diagnostics.ProcessStartInfo
          $rmPsiUn.FileName = $cmdExeUn
          $rmPsiUn.Arguments = '/d /s /c "rmdir /s /q "' + $root + '""'
          $rmPsiUn.UseShellExecute = $false
          $rmPsiUn.CreateNoWindow = $true
          $rmPsiUn.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
          $rmProcUn = [System.Diagnostics.Process]::Start($rmPsiUn)
          [void]$rmProcUn.WaitForExit(30000)
          $rmProcUn.Dispose()
        }
      } catch { }
      if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
      }
      if (Test-Path -LiteralPath $root) {
        throw 'uninstall-cleanup-locked'
      }

      Write-ManageStatus $StatusPath "Hoàn tất: Đã dừng dịch vụ, sao lưu cấu hình ($backupBase) và gỡ bỏ trợ lý OpenClaw sạch sẽ! Bạn có thể bấm Cài đặt mới ngay."
      exit 0
    }

    $instance = if (Test-Path -LiteralPath $instancePath -PathType Leaf) {
      [IO.File]::ReadAllText($instancePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } else { $null }
    $cliEntry = if ($instance -and $instance.cli_entry -and (Test-Path -LiteralPath ([string]$instance.cli_entry) -PathType Leaf)) {
      [string]$instance.cli_entry
    } else {
      Join-Path $root 'runtime\2026.11.4\node_modules\openclaw\openclaw.mjs'
    }

    if ($action -eq 'update-config') {
      if (Get-Command Normalize-EmTroLyCustomerInputs -ErrorAction SilentlyContinue) {
        $req = Normalize-EmTroLyCustomerInputs -Inputs $req
      }
      $assistantName = ([string]$req.assistant_name).Trim()
      $baseUrl = ([string]$req.base_url).Trim().TrimEnd('/')
      $model = ([string]$req.model).Trim()
      $ownerIdsRaw = ([string]$req.owner_ids).Trim()
      $groupId = ([string]$req.group_id).Trim()
      $portRaw = ([string]$req.gateway_port).Trim()
      $newToken = ([string]$req.telegram_token).Trim()
      $newApiKey = ([string]$req.ai_api_key).Trim()
      $audience = ([string]$req.audience).Trim()
      $addressing = ([string]$req.addressing).Trim()
      $style = ([string]$req.style).Trim()

      if ([string]::IsNullOrWhiteSpace($assistantName)) { throw 'missing-assistant-name' }
      if ($baseUrl -cne 'https://codex.anhlaptrinh.vn/v1') { throw 'invalid-base-url' }
      $uri = $null
      if (-not [uri]::TryCreate($baseUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'invalid-base-url'
      }
      if ($model -notin @('gpt-6.2-sol', 'GPT-6.1-terra', 'gpt-6.2-astra')) { throw 'invalid-model' }
      if ($ownerIdsRaw -notmatch '^[1-9][0-9]*(,[1-9][0-9]*)*$') { throw 'invalid-owners' }
      $owners = @($ownerIdsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
      if ($groupId -notmatch '^-[1-9][0-9]*$') { throw 'invalid-group' }
      $port = 0
      if (-not [int]::TryParse($portRaw, [ref]$port) -or ($port -ne 0 -and ($port -lt 1024 -or $port -gt 65000))) { throw 'invalid-port' }

      $tokenPath = Join-Path $root 'telegram.token'
      $secretPath = Join-Path $root 'member-provider.secret'

      if (-not [string]::IsNullOrWhiteSpace($newToken)) {
        if ($newToken -notmatch '^[0-9]{5,}:[A-Za-z0-9_-]{20,}$') { throw 'invalid-telegram-token' }
        Write-ManageStatus $StatusPath 'Đang kiểm tra Telegram Bot Token mới...'
        try {
          $tgCheck = Invoke-RestMethod -UseBasicParsing -Method Get -Uri ("https://api.telegram.org/bot$newToken/getMe") -TimeoutSec 45 -MaximumRedirection 0
        } catch { throw 'telegram-unavailable' }
        if (-not $tgCheck.ok -or -not $tgCheck.result.is_bot) { throw 'telegram-invalid-bot' }
      } elseif (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
        throw 'invalid-telegram-token'
      }

      $activeApiKey = $newApiKey
      if ([string]::IsNullOrWhiteSpace($activeApiKey) -and (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
        $activeApiKey = ([IO.File]::ReadAllText($secretPath, [System.Text.Encoding]::UTF8)).Trim()
      }
      $resolvedModel = $model
      if (-not [string]::IsNullOrWhiteSpace($newApiKey)) {
        Write-ManageStatus $StatusPath 'Đang kiểm tra khóa API và mô hình mới...'
        $headers = @{ Authorization = "Bearer $newApiKey"; Accept = 'application/json' }
        try {
          $modelsResp = Invoke-RestMethod -UseBasicParsing -Method Get -Uri "$baseUrl/models" -Headers $headers -TimeoutSec 45 -MaximumRedirection 0
        } catch { throw 'provider-unavailable' }
        $ids = @($modelsResp.data | ForEach-Object { [string]$_.id } | Where-Object { $_ })
        $matched = @($ids | Where-Object { $_ -ieq $model })
        if ($matched.Count -eq 0) { throw 'provider-model-unavailable' }
        $resolvedModel = $matched[0]
      }

      Write-ManageStatus $StatusPath 'Đang sao lưu cấu hình hiện tại trước khi cập nhật...'
      $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
      $backupDir = Join-Path $root ("backups\quick-edit-$stamp")
      [void][IO.Directory]::CreateDirectory($backupDir)
      Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupDir 'openclaw.json') -Force
      $profileFile = Join-Path $root 'workspace\CUSTOMER_PROFILE.md'
      if (Test-Path -LiteralPath $profileFile -PathType Leaf) {
        Copy-Item -LiteralPath $profileFile -Destination (Join-Path $backupDir 'CUSTOMER_PROFILE.md') -Force
      }

      Write-ManageStatus $StatusPath 'Đang cập nhật thông tin kết nối, quyền Owner và hồ sơ...'
      $pyScript = Join-Path $backupDir 'patch_config.py'
      $pyCode = @'
import json, sys
from pathlib import Path

cfg_path = Path(sys.argv[1])
assistant_name = sys.argv[2]
base_url = sys.argv[3]
model = sys.argv[4]
owners = [x.strip() for x in sys.argv[5].split(",") if x.strip()]
group_id = sys.argv[6]
port = int(sys.argv[7])

data = json.loads(cfg_path.read_text(encoding="utf-8"))
agents = data.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
defaults.setdefault("model", {})["primary"] = f"customer/{model}"
entries = agents.setdefault("entries", {})
main = entries.setdefault("main", {})
main["name"] = assistant_name

providers = data.setdefault("models", {}).setdefault("providers", {})
cust = providers.setdefault("customer", {})
cust["baseUrl"] = base_url
cust["models"] = [{"id": model, "name": model}]
if "openai" in providers and isinstance(providers["openai"], dict):
    providers["openai"]["baseUrl"] = base_url

if port >= 1024:
    data.setdefault("gateway", {})["port"] = port

tg = data.setdefault("channels", {}).setdefault("telegram", {})
account_name = tg.get("defaultAccount") or "emtroly"
accounts = tg.setdefault("accounts", {})
if account_name not in accounts or not isinstance(accounts[account_name], dict):
    first_keys = list(accounts.keys())
    if first_keys:
        account_name = first_keys[0]
    else:
        accounts[account_name] = {"enabled": True}

acc = accounts[account_name]
tg["allowFrom"] = list(owners)
acc["allowFrom"] = list(owners)
tg.setdefault("execApprovals", {})["approvers"] = list(owners)
acc.setdefault("execApprovals", {})["approvers"] = list(owners)

acc["groups"] = {
    group_id: {
        "groupPolicy": "allowlist",
        "requireMention": False,
        "tools": {"allow": ["*"]},
        "toolsBySender": {"*": {"alsoAllow": ["exec", "process"]}},
    }
}

data.setdefault("commands", {})["ownerAllowFrom"] = [f"telegram:{o}" for o in owners]
for kind in ("exec", "plugin"):
    pol = data.setdefault("approvals", {}).setdefault(kind, {})
    pol["enabled"] = True
    pol["mode"] = "targets"
    pol["agentFilter"] = ["main"]
    non_tg = [
        t for t in pol.get("targets", [])
        if isinstance(t, dict) and t.get("channel") != "telegram"
    ]
    tg_targets = [{"channel": "telegram", "accountId": account_name, "to": o} for o in owners]
    pol["targets"] = non_tg + tg_targets

cfg_path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(account_name)
'@
      [IO.File]::WriteAllText($pyScript, $pyCode, $utf8NoBom)
      try {
        $accountOut = (& python $pyScript $configPath $assistantName $baseUrl $resolvedModel ($owners -join ',') $groupId ([string]$port) | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'config-patch-failed' }
      } finally {
        Remove-Item -LiteralPath $pyScript -Force -ErrorAction SilentlyContinue
      }
      $accountName = if ($accountOut) { ($accountOut -split "`r?`n")[-1].Trim() } else { 'emtroly' }

      $env:OPENCLAW_STATE_DIR = $root
      $env:OPENCLAW_CONFIG_PATH = $configPath
      $env:OPENCLAW_CLI_ENTRY = $cliEntry
      Remove-Item Env:OPENCLAW_BIN -ErrorAction SilentlyContinue
      if ($instance -and $instance.profile) { $env:OPENCLAW_PROFILE = [string]$instance.profile }

      $ensurePy = Join-Path $PayloadDir 'native\skills\tao-tro-ly-openclaw-windows-macos-linux\scripts\ensure_default_telegram_owner.py'
      $finalizePy = Join-Path $PayloadDir 'native\finalize_permissions.py'
      if (Test-Path -LiteralPath $ensurePy -PathType Leaf) {
        $ownerArgs = @('--openclaw-root', $root, '--account-id', $accountName, '--agent-id', 'main', '--apply', '--backup-dir', (Join-Path $backupDir 'owner'))
        foreach ($o in $owners) { $ownerArgs += @('--owner-id', $o) }
        & python $ensurePy @ownerArgs *> $null
        if ($LASTEXITCODE -ne 0) { throw 'owner-sync-failed' }
      }
      if (Test-Path -LiteralPath $finalizePy -PathType Leaf) {
        & python $finalizePy --config $configPath --owners ($owners -join ',') *> $null
        if ($LASTEXITCODE -ne 0) { throw 'permission-sync-failed' }
      }

      if (Test-Path -LiteralPath $cliEntry -PathType Leaf) {
        $approvalsJson = @{
          version = 1
          defaults = @{ security='allowlist'; ask='on-miss'; askFallback='deny'; autoAllowSkills=$false }
          agents = @{ main=@{ security='full'; ask='off'; askFallback='full'; autoAllowSkills=$true; allowlist=@() } }
        } | ConvertTo-Json -Depth 8 -Compress
        $approvalsJson | & node $cliEntry approvals set --stdin --json *> $null
        if ($LASTEXITCODE -ne 0) { throw 'approval-check-failed' }
        & node $cliEntry config validate --json *> $null
        if ($LASTEXITCODE -ne 0) {
          Copy-Item -LiteralPath (Join-Path $backupDir 'openclaw.json') -Destination $configPath -Force
          throw 'config-validation-failed'
        }
        $approvalState = (& node $cliEntry approvals get --json | Out-String) | ConvertFrom-Json
        $updatedCfg = [IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $checkSettings = [pscustomobject]@{ member = $accountName; owner_ids = ($owners -join ',') }
        Test-MemberInstallerPermissions -Settings $checkSettings -Config $updatedCfg -ApprovalState $approvalState
      }

      if (-not [string]::IsNullOrWhiteSpace($newToken)) {
        [IO.File]::WriteAllText($tokenPath, "$newToken`n", $utf8NoBom)
        Protect-EmTroLySecretFile $tokenPath
        if (Test-Path -LiteralPath (Join-Path $root 'workspace\skills\telegram-zalo-owner-login\SKILL.md') -PathType Leaf) {
          try { Sync-EmTroLyTelegramMenu -Token $newToken } catch { }
        }
      }

      if (-not [string]::IsNullOrWhiteSpace($newApiKey)) {
        [IO.File]::WriteAllText($secretPath, "$newApiKey`n", $utf8NoBom)
        Protect-EmTroLySecretFile $secretPath
        if (Get-Command Save-EmTroLyLicenseKey -ErrorAction SilentlyContinue) {
          try { Save-EmTroLyLicenseKey -ApiKey $newApiKey } catch { }
        }
      }

      $emCodexDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'EmTroLy\Codex' } else { '' }
      if ($emCodexDir -and (Test-Path -LiteralPath $emCodexDir -PathType Container)) {
        $codexCfgPath = Join-Path $emCodexDir 'config.toml'
        if (Test-Path -LiteralPath $codexCfgPath -PathType Leaf) {
          $codexToml = @"
model_provider = "router"
model = "$resolvedModel"
model_context_window = 272000
model_auto_compact_token_limit = 200000
cli_auth_credentials_store = "file"

[model_providers.router]
name = "router"
base_url = "$baseUrl"
wire_api = "responses"
requires_openai_auth = true
"@
          [IO.File]::WriteAllText($codexCfgPath, $codexToml, $utf8NoBom)
        }
        if (-not [string]::IsNullOrWhiteSpace($newApiKey)) {
          $codexAuth = @{ OPENAI_API_KEY = $newApiKey } | ConvertTo-Json -Compress
          [IO.File]::WriteAllText((Join-Path $emCodexDir 'auth.json'), $codexAuth, $utf8NoBom)
        }
      }

      [void][IO.Directory]::CreateDirectory((Join-Path $root 'workspace'))
      $customerProfile = "# Ho so tro ly`n`nTen tro ly: $assistantName`n`nDoi tuong phuc vu: $audience`n`nCach xung ho: $addressing`n`nPhong cach tra loi: $style`n"
      [IO.File]::WriteAllText($profileFile, $customerProfile, $utf8NoBom)

      if (Test-Path -LiteralPath (Join-Path $root 'openclaw-instance.ps1') -PathType Leaf) {
        Write-ManageStatus $StatusPath 'Đang khởi động lại Gateway để áp dụng cấu hình mới...'
        [void](Invoke-EmTroLyGatewayInstance -Root $root -CliArgs @('gateway', 'restart'))
      }

      Write-ManageStatus $StatusPath 'Hoàn tất: Đã cập nhật cấu hình mới và khởi động lại trợ lý thành công!'
      exit 0
    }

    if ($action -eq 'install-zalo') {
      $state = Get-EmTroLyInstalledState
      $owners = @($state.OwnerIds -split ',' | Where-Object { $_ -match '^[1-9][0-9]*$' })
      if ($owners.Count -eq 0) { throw 'invalid-owners' }
      $qrOwner = ([string]$req.qr_owner_id).Trim()
      if ([string]::IsNullOrWhiteSpace($qrOwner)) { $qrOwner = $owners[0] }
      if ($qrOwner -notin $owners) { throw 'invalid-qr-owner' }

      $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
      if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = Join-Path $PSHOME 'pwsh' }

      $moduleMgr = Join-Path $root 'module-manager.ps1'
      if (Test-Path -LiteralPath $moduleMgr -PathType Leaf) {
        Write-ManageStatus $StatusPath 'Đang bổ sung bộ kỹ năng Zalo và mã QR...'
        $prevSkip = $env:OPENCLAW_SKIP_MODULE_RESTART
        try {
          $env:OPENCLAW_SKIP_MODULE_RESTART = '1'
          [void](Invoke-SafeSubProcess -FilePath $psExe -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $moduleMgr, '-Command', 'install', '-Module', 'zalo-qr-basic') -TimeoutSeconds 180)
        } finally {
          if ($null -ne $prevSkip) { $env:OPENCLAW_SKIP_MODULE_RESTART = $prevSkip }
          else { Remove-Item Env:OPENCLAW_SKIP_MODULE_RESTART -ErrorAction SilentlyContinue }
        }
      }

      Write-ManageStatus $StatusPath 'Đang cài đặt plugin Zalo và đăng ký lệnh /zaloqr, /zalostatus...'
      $zaloOnboard = Join-Path $PayloadDir 'zalo\onboard-zalouser-windows.ps1'
      $zaloConfigure = Join-Path $PayloadDir 'zalo\configure-zalo.py'
      $zaloQr = Join-Path $root 'workspace\skills\openclaw-zalo-qr-login\scripts\send_zalo_qr_to_telegram_owner.mjs'
      $zaloRes = Invoke-SafeSubProcess -FilePath $psExe -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $zaloOnboard,
        '-Root', $root, '-TelegramAccount', $state.AccountName, '-OwnerId', $qrOwner,
        '-ConfigureScript', $zaloConfigure, '-QrScript', $zaloQr, '-Quick'
      ) -TimeoutSeconds 300
      if ($zaloRes.ExitCode -ne 0) { throw 'zalo-plugin-not-loaded' }

      $tokenFile = Join-Path $root 'telegram.token'
      $tgToken = if (-not [string]::IsNullOrWhiteSpace([string]$req.telegram_token)) {
        ([string]$req.telegram_token).Trim()
      } elseif (Test-Path -LiteralPath $tokenFile -PathType Leaf) {
        ([IO.File]::ReadAllText($tokenFile, [System.Text.Encoding]::UTF8)).Trim()
      } else { '' }
      $menuNote = ''
      if ($tgToken) {
        Write-ManageStatus $StatusPath 'Đang đồng bộ lệnh /zaloqr và /zalostatus lên menu Telegram...'
        try {
          Sync-EmTroLyTelegramMenu -Token $tgToken
        } catch {
          $menuNote = ' (Lưu ý: menu Telegram tạm chưa đồng bộ do mạng, nhưng lệnh /zaloqr đã sẵn sàng sử dụng.)'
        }
      }
      Write-ManageStatus $StatusPath "Hoàn tất: Đã cài đặt và đồng bộ Zalo (/zaloqr, /zalostatus) thành công!$menuNote"
      exit 0
    }

    if ($action -eq 'reinstall-codex') {
      $state = Get-EmTroLyInstalledState
      $model = if (-not [string]::IsNullOrWhiteSpace([string]$req.model)) { ([string]$req.model).Trim() } else { $state.Model }
      $baseUrl = if (-not [string]::IsNullOrWhiteSpace([string]$req.base_url)) { ([string]$req.base_url).Trim().TrimEnd('/') } else { $state.BaseUrl }
      $apiKey = ([string]$req.ai_api_key).Trim()
      if ([string]::IsNullOrWhiteSpace($apiKey) -and $root) {
        $secFile = Join-Path $root 'member-provider.secret'
        if (Test-Path -LiteralPath $secFile -PathType Leaf) {
          $apiKey = ([IO.File]::ReadAllText($secFile, [System.Text.Encoding]::UTF8)).Trim()
        }
      }
      if ([string]::IsNullOrWhiteSpace($apiKey) -and $env:LOCALAPPDATA) {
        $codexAuthFile = Join-Path $env:LOCALAPPDATA 'EmTroLy\Codex\auth.json'
        if (Test-Path -LiteralPath $codexAuthFile -PathType Leaf) {
          try { $apiKey = [string](([IO.File]::ReadAllText($codexAuthFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).OPENAI_API_KEY) } catch { }
        }
      }
      if ([string]::IsNullOrWhiteSpace($apiKey) -and (Get-Command Get-EmTroLySavedLicenseKey -ErrorAction SilentlyContinue)) {
        try { $apiKey = (Get-EmTroLySavedLicenseKey).Trim() } catch { }
      }
      if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'missing-api-key' }

      $codexState = Find-EmTroLyCodexCli
      $repairScript = Join-Path $PayloadDir 'windows-installer\repair-antigravity-shortcut.ps1'
      $shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'EmTroLy - Antigravity.lnk'
      if ($codexState.Available -and $codexState.Source -eq 'emtroly' -and $env:LOCALAPPDATA -and (Test-Path -LiteralPath $repairScript -PathType Leaf)) {
        Write-ManageStatus $StatusPath 'Đang đồng bộ khóa API, mô hình cho Codex CLI và kiểm tra Antigravity IDE...'
        $emCodex = Join-Path $env:LOCALAPPDATA 'EmTroLy\Codex'
        [void][IO.Directory]::CreateDirectory($emCodex)
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
        [IO.File]::WriteAllText((Join-Path $emCodex 'config.toml'), $cfgToml, $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $emCodex 'auth.json'), (@{ OPENAI_API_KEY = $apiKey } | ConvertTo-Json -Compress), $utf8NoBom)
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $repRes = Invoke-SafeSubProcess -FilePath $psExe -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $repairScript) -TimeoutSeconds 120
        if ($repRes.ExitCode -eq 0 -and (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
          [void](Register-EmTroLyCodexCli -PayloadRoot $PayloadDir)
          Write-ManageStatus $StatusPath 'Hoàn tất: Đã cập nhật cấu hình Codex CLI, đăng ký lệnh codex và khôi phục lối tắt Antigravity IDE!'
          exit 0
        }
      }

      Write-ManageStatus $StatusPath 'Đang tải và cài đặt Antigravity IDE + Codex Extension riêng cho Em Trợ Lý...'
      $jobFile = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'EmTroLy\installer-job.txt' } else { '' }
      $jobId = if ($jobFile -and (Test-Path -LiteralPath $jobFile -PathType Leaf)) {
        ([IO.File]::ReadAllText($jobFile)).Trim()
      } else { '' }
      if ($jobId -cnotmatch '^[a-f0-9]{32}$') { $jobId = [guid]::NewGuid().ToString('N') }
      $editorInstaller = Join-Path $PayloadDir 'windows-installer\install-antigravity-codex.ps1'
      if (-not (Test-Path -LiteralPath $editorInstaller -PathType Leaf)) { throw 'editor-module-missing' }

      $edTempDir = Join-Path $env:TEMP ('emtroly-reinstall-ed-' + [guid]::NewGuid().ToString('N'))
      New-CodexPrivateDirectory $edTempDir
      try {
        $edSettingsPath = Join-Path $edTempDir 'ed-settings.json'
        $edErrPath = Join-Path $edTempDir 'ed-err.txt'
        $edDriverPath = Join-Path $edTempDir 'run-ed.ps1'
        $edPayload = @{
          model = $model
          base_url = $baseUrl
          ai_api_key = $apiKey
          job_id = $jobId
        } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($edSettingsPath, $edPayload, $utf8NoBom)
        $driverCode = @'
param($InstallerPath, $SettingsJsonPath, $StatusPath, $ErrPath)
$ErrorActionPreference = 'Stop'
try {
  $s = [IO.File]::ReadAllText($SettingsJsonPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
  Remove-Item -LiteralPath $SettingsJsonPath -Force -ErrorAction SilentlyContinue
  & $InstallerPath -Settings $s -StatusFile $StatusPath
  exit 0
} catch {
  [IO.File]::WriteAllText($ErrPath, [string]$_.Exception.Message, (New-Object Text.UTF8Encoding($false)))
  exit 1
}
'@
        [IO.File]::WriteAllText($edDriverPath, $driverCode, (New-Object System.Text.UTF8Encoding($true)))
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $edRun = Invoke-SafeSubProcess -FilePath $psExe -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $edDriverPath, '-InstallerPath', $editorInstaller, '-SettingsJsonPath', $edSettingsPath, '-StatusPath', $StatusPath, '-ErrPath', $edErrPath) -TimeoutSeconds 2400
        if ($edRun.ExitCode -ne 0) {
          $thrownCode = if (Test-Path -LiteralPath $edErrPath -PathType Leaf) { ([IO.File]::ReadAllText($edErrPath, [Text.Encoding]::UTF8)).Trim() } else { 'editor-install-failed' }
          if (-not $thrownCode) { $thrownCode = 'editor-install-failed' }
          throw $thrownCode
        }
      } finally {
        Remove-Item -LiteralPath $edTempDir -Recurse -Force -ErrorAction SilentlyContinue
      }

      [void](Register-EmTroLyCodexCli -PayloadRoot $PayloadDir)
      Write-ManageStatus $StatusPath 'Hoàn tất: Đã cài đặt xong Antigravity IDE, Codex Extension và lệnh Codex CLI (lối tắt EmTroLy - Antigravity đã có trên Desktop)!'
      exit 0
    }

    if ($action -eq 'health-restart') {
      Write-ManageStatus $StatusPath 'Đang khởi động lại Gateway và kiểm tra sức khỏe các thành phần...'
      [void](Invoke-EmTroLyGatewayInstance -Root $root -CliArgs @('gateway', 'restart'))
      $healthRaw = Invoke-EmTroLyGatewayInstance -Root $root -CliArgs @('gateway', 'status')
      $health = $healthRaw | ConvertFrom-Json
      if (-not $health.ok) { throw 'gateway-health-failed' }

      $botInfo = 'Chưa kiểm tra'
      $tokenFile = Join-Path $root 'telegram.token'
      if (Test-Path -LiteralPath $tokenFile -PathType Leaf) {
        $tok = ([IO.File]::ReadAllText($tokenFile, [System.Text.Encoding]::UTF8)).Trim()
        if ($tok) {
          try {
            $me = Invoke-RestMethod -UseBasicParsing -Method Get -Uri ("https://api.telegram.org/bot$tok/getMe") -TimeoutSec 25 -MaximumRedirection 0
            if ($me.ok -and $me.result.username) { $botInfo = '@' + $me.result.username }
          } catch { $botInfo = 'Không kết nối được Telegram' }
        }
      }
      $loadedPlugins = @($health.plugins.loaded)
      $zaloSummary = if ('zalouser' -in $loadedPlugins) { 'Đã bật' } else { 'Chưa cài' }
      $codexSummary = if ((Find-EmTroLyCodexCli).Available) { 'Sẵn sàng' } else { 'Chưa cài' }
      Write-ManageStatus $StatusPath "Hoàn tất: Gateway hoạt động tốt · Bot Telegram: $botInfo · Zalo: $zaloSummary · Codex CLI: $codexSummary."
      exit 0
    }

    if ($action -eq 'auto-heal') {
      if ((Test-Path -LiteralPath $root -PathType Container) -and -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Write-ManageStatus $StatusPath 'Phát hiện thư mục OpenClaw cài dở chưa hoàn tất — đang tự động dọn sạch để sẵn sàng cài mới...'
        $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
        if (Test-Path -LiteralPath $cmdExe -PathType Leaf) {
          $rmPsi = New-Object System.Diagnostics.ProcessStartInfo
          $rmPsi.FileName = $cmdExe
          $rmPsi.Arguments = '/d /s /c "rmdir /s /q "' + $root + '""'
          $rmPsi.UseShellExecute = $false
          $rmPsi.CreateNoWindow = $true
          $rmPsi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
          $rmProc = [System.Diagnostics.Process]::Start($rmPsi)
          [void]$rmProc.WaitForExit(30000)
          $rmProc.Dispose()
        }
        if (Test-Path -LiteralPath $root) {
          Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-ManageStatus $StatusPath 'Hoàn tất: Đã tự động dọn sạch thư mục OpenClaw cài dở trước đó! Bây giờ bạn chỉ cần về mục Cài đặt nhanh và bấm Cài đặt trọn gói A–Z.'
        exit 0
      }

      $state = Get-EmTroLyInstalledState
      $resolvedKey = ([string]$req.ai_api_key).Trim()
      if ([string]::IsNullOrWhiteSpace($resolvedKey) -and (Get-Command Get-EmTroLySavedLicenseKey -ErrorAction SilentlyContinue)) {
        try { $resolvedKey = (Get-EmTroLySavedLicenseKey).Trim() } catch { }
      }
      $healSettings = [pscustomobject]@{
        model          = if (-not [string]::IsNullOrWhiteSpace([string]$req.model)) { ([string]$req.model).Trim() } else { $state.Model }
        base_url       = if (-not [string]::IsNullOrWhiteSpace([string]$req.base_url)) { ([string]$req.base_url).Trim().TrimEnd('/') } else { $state.BaseUrl }
        owner_ids      = if (-not [string]::IsNullOrWhiteSpace([string]$req.owner_ids)) { ([string]$req.owner_ids).Trim() } else { $state.OwnerIds }
        group_id       = if (-not [string]::IsNullOrWhiteSpace([string]$req.group_id)) { ([string]$req.group_id).Trim() } else { $state.GroupId }
        gateway_port   = if (-not [string]::IsNullOrWhiteSpace([string]$req.gateway_port)) { ([string]$req.gateway_port).Trim() } else { $state.GatewayPort }
        configure_zalo = $state.ZaloInstalled
        ai_api_key     = $resolvedKey
        telegram_token = ([string]$req.telegram_token).Trim()
      }
      $hintDetail = if ($req.PSObject.Properties['error_detail'] -and $req.error_detail) { [string]$req.error_detail } else { 'Người dùng yêu cầu tự động kiểm tra toàn diện log, cấu hình, PATH, Gateway và sửa mọi lỗi tồn đọng.' }
      $healRes = Invoke-CodexAutoHeal -Stage 'manual-diagnose-repair' -ErrorCode 'user-requested-auto-heal' -ErrorDetail $hintDetail -OpenClawRoot $root -PayloadRoot $PayloadDir -Settings $healSettings -StatusFile $StatusPath -Attempt 1
      if ($healRes.PSObject.Properties['Transcript'] -and $healRes.Transcript) {
        $lastManageTechDetail = [string]$healRes.Transcript
      } elseif ($healRes.Summary) {
        $lastManageTechDetail = [string]$healRes.Summary
      }
      if (-not $healRes.Invoked) {
        if ($healRes.PSObject.Properties['Reason'] -and $healRes.Reason -eq 'missing-api-key') {
          throw 'missing-api-key'
        }
        throw 'codex-autoheal-unavailable'
      }
      if ($healRes.ExitCode -ne 0) {
        throw 'codex-autoheal-failed'
      }
      if (Test-Path -LiteralPath (Join-Path $root 'openclaw-instance.ps1') -PathType Leaf) {
        Write-ManageStatus $StatusPath 'Đang kiểm tra lại trạng thái Gateway sau khi Codex sửa lỗi...'
        [void](Invoke-EmTroLyGatewayInstance -Root $root -CliArgs @('gateway', 'restart'))
        $healthCheck = (Invoke-EmTroLyGatewayInstance -Root $root -CliArgs @('gateway', 'status')) | ConvertFrom-Json
        if (-not $healthCheck.ok) { throw 'gateway-health-failed' }
      }
      $summaryNote = if ($healRes.Summary) { " ($($healRes.Summary))" } else { '' }
      Write-ManageStatus $StatusPath "Hoàn tất: Codex CLI đã tự kiểm tra và sửa lỗi thành công!$summaryNote"
      exit 0
    }
  } catch {
    $errCode = [string]$_.Exception.Message
    $errMap = @{
      'missing-assistant-name' = 'Vui lòng nhập tên trợ lý.'
      'invalid-base-url' = 'Địa chỉ máy chủ AI phải bắt đầu bằng https:// hợp lệ.'
      'invalid-model' = 'Mô hình AI đã chọn không được hỗ trợ.'
      'invalid-owners' = 'Telegram Owner IDs không hợp lệ (nhập số dương, cách nhau bởi dấu phẩy).'
      'invalid-group' = 'Telegram Group ID phải là số âm (ví dụ: -1001234567890).'
      'invalid-port' = 'Cổng Gateway phải là 0 hoặc từ 1024 đến 65000.'
      'invalid-telegram-token' = 'Telegram Bot Token mới không đúng định dạng.'
      'telegram-unavailable' = 'Không kết nối được Telegram để kiểm tra Token mới. Token cũ vẫn được giữ nguyên.'
      'telegram-invalid-bot' = 'Telegram báo Token mới không hợp lệ. Token cũ vẫn được giữ nguyên.'
      'provider-unavailable' = 'Không kết nối được máy chủ AI với khóa API mới. Khóa cũ vẫn được giữ nguyên.'
      'provider-model-unavailable' = 'Máy chủ AI không hỗ trợ mô hình đã chọn.'
      'missing-api-key' = 'Chưa tìm thấy khóa API. Hãy kiểm tra Provider API Key ở mục Cấu hình nhanh rồi thử lại.'
      'codex-autoheal-unavailable' = 'Chưa tìm thấy hoặc chưa tải được Codex CLI để tự sửa lỗi. Hãy kiểm tra kết nối Internet.'
      'codex-autoheal-failed' = 'Codex CLI chưa thể tự khắc phục hết lỗi này — xem chi tiết nguyên nhân ngay bên dưới.'
      'invalid-qr-owner' = 'QR Owner ID phải nằm trong danh sách Owner IDs.'
      'config-validation-failed' = 'Cấu hình mới không hợp lệ; hệ thống đã tự khôi phục bản cấu hình cũ an toàn.'
      'gateway-command-failed' = 'Đã lưu cấu hình nhưng chưa khởi động lại được Gateway. Hãy thử bấm Kiểm tra & Khởi động lại.'
      'subprocess-timeout' = 'Quá thời gian chờ xử lý tác vụ nền. Hãy kiểm tra lại trạng thái Gateway hoặc thử lại.'
      'gateway-health-failed' = 'Gateway chưa phản hồi trạng thái sẵn sàng.'
      'zalo-plugin-not-loaded' = 'Chưa hoàn tất cài đặt hoặc kích hoạt plugin Zalo.'
      'editor-data-recovery-failed' = 'Không thể dọn thư mục cài dở của Antigravity/Codex. Hãy đóng các cửa sổ Antigravity đang mở rồi thử lại.'
      'editor-download-failed' = 'Không tải được Antigravity IDE hoặc Codex Extension. Hãy kiểm tra kết nối Internet và ổ đĩa trống.'
      'editor-download-checksum' = 'Gói tải Antigravity/Codex không khớp mã kiểm tra SHA-256.'
      'editor-install-failed' = 'Bộ cài Antigravity IDE chưa hoàn tất. Hãy đóng Antigravity đang chạy rồi thử lại.'
      'editor-extension-install-failed' = 'Không cài được tiện ích Codex Extension vào Antigravity IDE.'
      'editor-codex-probe-failed' = 'Codex CLI chưa vượt qua bước kiểm tra API Key. Hãy kiểm tra khóa API và mạng.'
      'editor-activation-failed' = 'Antigravity IDE chưa kích hoạt được tiện ích Codex Extension.'
      'editor-version-unsupported' = 'Phiên bản Antigravity trên máy chưa tương thích cấu trúc chuẩn.'
      'uninstall-cleanup-locked' = 'Một tệp trong thư mục OpenClaw đang được mở bởi chương trình khác. Hãy đóng các cửa sổ đang mở thư mục openclaw rồi thử lại.'
    }
    $friendly = if ($errMap.ContainsKey($errCode)) { $errMap[$errCode] } else { "Không thể hoàn tất thao tác ($errCode). Dữ liệu cũ vẫn được giữ an toàn." }
    try {
      $posTrace = if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) { ([string]$_.InvocationInfo.PositionMessage -replace "\r?\n", ' | ').Trim() } else { '' }
      $techCombined = @()
      if ($lastManageTechDetail) { $techCombined += $lastManageTechDetail }
      if ($posTrace) { $techCombined += ('Vị trí: ' + $posTrace) }
      if ($techCombined.Count -eq 0) { $techCombined += ("Mã chẩn đoán: $errCode") }
      $secretsToScrub = @()
      if ($req) {
        if ($req.PSObject.Properties['telegram_token'] -and $req.telegram_token) { $secretsToScrub += [string]$req.telegram_token }
        if ($req.PSObject.Properties['ai_api_key'] -and $req.ai_api_key) { $secretsToScrub += [string]$req.ai_api_key }
      }
      foreach ($sf in @((Join-Path $root 'telegram.token'), (Join-Path $root 'member-provider.secret'))) {
        if (Test-Path -LiteralPath $sf -PathType Leaf) {
          try { $sv = ([IO.File]::ReadAllText($sf, [System.Text.Encoding]::UTF8)).Trim(); if ($sv) { $secretsToScrub += $sv } } catch { }
        }
      }
      if (Get-Command Get-EmTroLySavedLicenseKey -ErrorAction SilentlyContinue) {
        try { $sl = Get-EmTroLySavedLicenseKey; if ($sl) { $secretsToScrub += $sl } } catch { }
      }
      $rawTech = ($techCombined -join "`r`n")
      $safeFriendly = if (Get-Command Remove-SensitiveStrings -ErrorAction SilentlyContinue) {
        Remove-SensitiveStrings -Text $friendly -Secrets $secretsToScrub
      } else { $friendly }
      $safeTech = if (Get-Command Remove-SensitiveStrings -ErrorAction SilentlyContinue) {
        Remove-SensitiveStrings -Text $rawTech -Secrets $secretsToScrub
      } else { $rawTech }
      $diagManage = [ordered]@{
        timestamp       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        stage           = $action
        code            = $errCode
        friendlyMessage = $safeFriendly
        autoHealSummary = ''
        technicalDetail = $safeTech
      }
      [IO.File]::WriteAllText("$StatusPath.diag.json", ($diagManage | ConvertTo-Json -Depth 5), $utf8NoBom)
      $friendly = $safeFriendly
    } catch { }
    Write-ManageStatus $StatusPath $friendly
    exit 1
  }
}

if ($RunManageWorker) {
  Invoke-ManageWorkerMain -RequestPath $WorkerRequestFile -PayloadDir $WorkerPayloadRoot -StatusPath $WorkerLogFile
}
