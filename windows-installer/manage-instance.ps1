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

function Resolve-EmTroLyPythonExe {
  $candidates = @()
  if ($env:LOCALAPPDATA) {
    $candidates += (Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies\python313\python.exe')
    $candidates += (Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies\python312\python.exe')
  }
  foreach ($cmd in @(Get-Command python.exe -All -CommandType Application -ErrorAction SilentlyContinue)) {
    if ($cmd.Source -and $cmd.Source -notlike '*\WindowsApps\*') { $candidates += $cmd.Source }
  }
  if ($env:LOCALAPPDATA) {
    $candidates += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Python\*\python.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
  }
  if ($env:ProgramFiles) {
    $candidates += @(Get-ChildItem (Join-Path $env:ProgramFiles 'Python*\python.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
  }
  foreach ($exe in @($candidates | Where-Object { $_ } | Select-Object -Unique)) {
    if ($exe -notlike '*\WindowsApps\*' -and (Test-Path -LiteralPath $exe -PathType Leaf)) {
      try {
        & $exe -c 'import sys; sys.exit(0)' *> $null
        if ($LASTEXITCODE -eq 0) { return $exe }
      } catch { }
    }
  }
  return 'python'
}

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
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
  for ($attempt = 1; $attempt -le 12; $attempt++) {
    $fs = $null
    try {
      $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
      $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, $share)
      $fs.SetLength(0)
      if ($bytes.Length -gt 0) { $fs.Write($bytes, 0, $bytes.Length) }
      $fs.Flush()
      return
    } catch {
      if ($attempt -lt 12) { Start-Sleep -Milliseconds 25 }
    } finally {
      if ($null -ne $fs) { try { $fs.Dispose() } catch { } }
    }
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
  $openClawNpmFile = Join-Path $PayloadDir 'native\openclaw-npm.ps1'
  if (Test-Path -LiteralPath $openClawNpmFile -PathType Leaf) {
    . ([ScriptBlock]::Create([IO.File]::ReadAllText($openClawNpmFile, [System.Text.Encoding]::UTF8)))
  }
  $autoHealFile = Join-Path $PayloadDir 'windows-installer\auto-heal-codex.ps1'
  if (Test-Path -LiteralPath $autoHealFile -PathType Leaf) {
    . ([ScriptBlock]::Create([IO.File]::ReadAllText($autoHealFile, [System.Text.Encoding]::UTF8)))
  }
  $wizardHelperFile = Join-Path $PayloadDir 'windows-installer\wizard-helpers.ps1'
  if (Test-Path -LiteralPath $wizardHelperFile -PathType Leaf) {
    . ([ScriptBlock]::Create([IO.File]::ReadAllText($wizardHelperFile, [System.Text.Encoding]::UTF8)))
  }

  function Resolve-EmTroLyNodeBinary([string]$OpenClawRoot) {
    if (Get-Command -Name 'Resolve-EmTroLyNodeToolchains' -ErrorAction SilentlyContinue) {
      try {
        $tc = Resolve-EmTroLyNodeToolchains -PayloadRoot $PayloadDir -OpenClawRoot $OpenClawRoot
        if ($tc -and $tc.Primary -and $tc.Primary.NodeExe) {
          return [string]$tc.Primary.NodeExe
        }
      } catch { }
    }
    if ($OpenClawRoot) {
      $instFile = Join-Path $OpenClawRoot 'installer-instance.json'
      if (Test-Path -LiteralPath $instFile -PathType Leaf) {
        try {
          $inst = [IO.File]::ReadAllText($instFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
          if ($inst.node -and (Test-Path -LiteralPath ([string]$inst.node) -PathType Leaf)) {
            return [string]$inst.node
          }
        } catch { }
      }
    }
    if ($env:LOCALAPPDATA) {
      $depNodes = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies\node-v*\node.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
      if ($depNodes.Count -gt 0) { return $depNodes[0].FullName }
    }
    $cmd = @(Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -and $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1)
    if ($cmd.Count -gt 0 -and $cmd[0].Source) { return $cmd[0].Source }
    return ''
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
  $lastManagePrimaryError = ''
  $lastAutoHealDiagnosticError = ''

  try {
    function Remove-EmTroLyDirectoryTree([string]$TargetDir) {
      if ([string]::IsNullOrWhiteSpace($TargetDir) -or -not (Test-Path -LiteralPath $TargetDir)) { return }
      $itemCheck = Get-Item -LiteralPath $TargetDir -Force -ErrorAction SilentlyContinue
      if ($itemCheck -and ($itemCheck.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'unsafe-symlink-instance'
      }
      try {
        $cmdExeRm = Join-Path $env:SystemRoot 'System32\cmd.exe'
        if (Test-Path -LiteralPath $cmdExeRm -PathType Leaf) {
          $rmPsiTree = New-Object System.Diagnostics.ProcessStartInfo
          $rmPsiTree.FileName = $cmdExeRm
          $rmPsiTree.Arguments = '/d /s /c "rmdir /s /q "' + $TargetDir + '""'
          $rmPsiTree.UseShellExecute = $false
          $rmPsiTree.CreateNoWindow = $true
          $rmPsiTree.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
          $rmProcTree = [System.Diagnostics.Process]::Start($rmPsiTree)
          [void]$rmProcTree.WaitForExit(30000)
          $rmProcTree.Dispose()
        }
      } catch { }
      if (Test-Path -LiteralPath $TargetDir) {
        Remove-Item -LiteralPath $TargetDir -Recurse -Force -ErrorAction SilentlyContinue
      }
    }

    if ($action -notin @('update-config', 'install-zalo', 'reinstall-codex', 'health-restart', 'auto-heal', 'uninstall-instance', 'factory-reset', 'upgrade-openclaw')) {
      throw 'invalid-manage-action'
    }
    if ($action -notin @('reinstall-codex', 'auto-heal', 'uninstall-instance', 'factory-reset') -and -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
      throw 'instance-missing'
    }

    if ($action -eq 'factory-reset') {
      $localApp = $env:LOCALAPPDATA
      $emBase = if ($localApp) { Join-Path $localApp 'EmTroLy' } else { '' }
      $emUiDir = if ($localApp) { Join-Path $localApp 'EmTroLyUI' } else { '' }
      $altDir = if ($localApp) { Join-Path $localApp 'AnhLapTrinh\EmTroLy' } else { '' }
      $altParent = if ($localApp) { Join-Path $localApp 'AnhLapTrinh' } else { '' }
      $depDir = if ($localApp) { Join-Path $localApp 'MemberInstaller' } else { '' }
      $ocAppDir = if ($localApp) { Join-Path $localApp 'OpenClaw' } else { '' }
      $ocBinDir = if ($ocAppDir) { Join-Path $ocAppDir 'bin' } else { '' }

      foreach ($chkDir in @($root, $emBase, $emUiDir, $altDir, $depDir, $ocAppDir)) {
        if ($chkDir -and (Test-Path -LiteralPath $chkDir -PathType Container)) {
          $chkItem = Get-Item -LiteralPath $chkDir -Force -ErrorAction Stop
          if ($chkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'unsafe-symlink-instance'
          }
        }
      }

      Write-ManageStatus $StatusPath 'Đang dừng dịch vụ nền OpenClaw Gateway và các tiến trình của Em Trợ Lý...'
      if ($root -and (Test-Path -LiteralPath $root -PathType Container)) {
        try { [IO.File]::WriteAllText((Join-Path $root 'user-gateway.stop'), 'stop', $utf8NoBom) } catch { }
        if (Test-Path -LiteralPath (Join-Path $root 'openclaw-instance.ps1') -PathType Leaf) {
          try { [void](Invoke-EmTroLyGatewayInstance -Root $root -CliArgs @('gateway', 'stop')) } catch { }
        }
      }

      if ($env:EMTROLY_SKIP_PROCESS_SWEEP -ne '1') {
        try {
          $privIdePrefix = if ($localApp) { (Join-Path $localApp 'Programs\EmTroLy-Antigravity-IDE-').TrimEnd('\') } else { '' }
          $emAgDir = if ($emBase) { Join-Path $emBase 'Antigravity' } else { '' }
          $emProcs = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe' OR Name = 'codex.exe' OR Name = 'Antigravity IDE.exe' OR Name = 'Antigravity.exe'" -ErrorAction SilentlyContinue)
          foreach ($pr in $emProcs) {
            if (-not $pr.ProcessId -or [int]$pr.ProcessId -eq $PID) { continue }
            $pName = [string]$pr.Name
            $cmdLine = [string]$pr.CommandLine
            $exePath = [string]$pr.ExecutablePath
            $shouldKill = $false
            if ($pName -ieq 'node.exe') {
              foreach ($mk in @($root, $emBase, $depDir)) {
                if ($mk -and (($cmdLine -and $cmdLine.IndexOf($mk, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                              ($exePath -and $exePath.IndexOf($mk, [StringComparison]::OrdinalIgnoreCase) -ge 0))) {
                  $shouldKill = $true; break
                }
              }
            } elseif ($pName -ieq 'codex.exe') {
              if ($emBase -and (($exePath -and $exePath.IndexOf($emBase, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                                ($cmdLine -and $cmdLine.IndexOf($emBase, [StringComparison]::OrdinalIgnoreCase) -ge 0))) {
                $shouldKill = $true
              }
            } else {
              if (($privIdePrefix -and $exePath -and $exePath.StartsWith($privIdePrefix, [StringComparison]::OrdinalIgnoreCase)) -or
                  ($emAgDir -and $cmdLine -and $cmdLine.IndexOf($emAgDir, [StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                $shouldKill = $true
              }
            }
            if ($shouldKill) {
              Stop-Process -Id ([int]$pr.ProcessId) -Force -ErrorAction SilentlyContinue
            }
          }
        } catch { }
      }

      Write-ManageStatus $StatusPath 'Đang gỡ bỏ khởi động cùng Windows, lối tắt Desktop và lệnh CLI...'
      $startupDirReset = if ($env:EMTROLY_TEST_STARTUP_DIR) { $env:EMTROLY_TEST_STARTUP_DIR } else { [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup) }
      if ($startupDirReset -and (Test-Path -LiteralPath $startupDirReset -PathType Container)) {
        foreach ($vbs in @(Get-ChildItem -LiteralPath $startupDirReset -Filter 'OpenClaw-*.vbs' -File -ErrorAction SilentlyContinue)) {
          try {
            $vbsTxt = [IO.File]::ReadAllText($vbs.FullName, [Text.Encoding]::Unicode)
            if ((-not $root) -or $vbsTxt.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $vbs.Name -ieq 'OpenClaw-member-emtroly.vbs') {
              Remove-Item -LiteralPath $vbs.FullName -Force -ErrorAction SilentlyContinue
            }
          } catch { }
        }
      }

      $desktopDirs = @()
      if ($env:EMTROLY_TEST_DESKTOP_DIR) {
        $desktopDirs += $env:EMTROLY_TEST_DESKTOP_DIR
      } else {
        $sysDesktop = [Environment]::GetFolderPath('Desktop')
        if ($sysDesktop) { $desktopDirs += $sysDesktop }
        if ($env:USERPROFILE) { $desktopDirs += (Join-Path $env:USERPROFILE 'Desktop') }
      }
      foreach ($dDir in @($desktopDirs | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $dDir -PathType Container) {
          foreach ($lnkName in @('EmTroLy - Antigravity.lnk', 'Em Tro Ly - Anh Lap Trinh.lnk')) {
            $lnkTarget = Join-Path $dDir $lnkName
            if (Test-Path -LiteralPath $lnkTarget -PathType Leaf) {
              Remove-Item -LiteralPath $lnkTarget -Force -ErrorAction SilentlyContinue
            }
          }
        }
      }

      $programsMenu = if ($env:EMTROLY_TEST_PROGRAMS_DIR) { $env:EMTROLY_TEST_PROGRAMS_DIR } else { [Environment]::GetFolderPath('Programs') }
      if ($programsMenu -and (Test-Path -LiteralPath $programsMenu -PathType Container)) {
        $agStartLnk = Join-Path $programsMenu 'EmTroLy - Antigravity.lnk'
        if (Test-Path -LiteralPath $agStartLnk -PathType Leaf) {
          Remove-Item -LiteralPath $agStartLnk -Force -ErrorAction SilentlyContinue
        }
        $altMenuFolder = Join-Path $programsMenu 'Anh Lap Trinh'
        $appStartLnk = Join-Path $altMenuFolder 'Em Tro Ly - Anh Lap Trinh.lnk'
        if (Test-Path -LiteralPath $appStartLnk -PathType Leaf) {
          Remove-Item -LiteralPath $appStartLnk -Force -ErrorAction SilentlyContinue
        }
        if ((Test-Path -LiteralPath $altMenuFolder -PathType Container) -and @(Get-ChildItem -LiteralPath $altMenuFolder -Force -ErrorAction SilentlyContinue).Count -eq 0) {
          Remove-Item -LiteralPath $altMenuFolder -Force -ErrorAction SilentlyContinue
        }
      }

      if ($ocBinDir -and (Test-Path -LiteralPath $ocBinDir -PathType Container)) {
        foreach ($shimFile in @(Get-ChildItem -LiteralPath $ocBinDir -Filter '*.cmd' -File -ErrorAction SilentlyContinue)) {
          $sName = $shimFile.Name
          $shouldDeleteShim = ($sName -like 'openclaw*.cmd' -or $sName -ieq 'codex-emtroly.cmd' -or $sName -ieq 'emtroly-ui.cmd')
          if (-not $shouldDeleteShim -and $sName -ieq 'codex.cmd') {
            try {
              $shimContent = [IO.File]::ReadAllText($shimFile.FullName, [Text.Encoding]::UTF8)
              if ($shimContent -match 'EmTroLy|CODEX_HOME') { $shouldDeleteShim = $true }
            } catch { }
          }
          if ($shouldDeleteShim) {
            Remove-Item -LiteralPath $shimFile.FullName -Force -ErrorAction SilentlyContinue
          }
        }
        if (@(Get-ChildItem -LiteralPath $ocBinDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
          Remove-Item -LiteralPath $ocBinDir -Force -ErrorAction SilentlyContinue
          if ($env:EMTROLY_SKIP_REGISTRY_CLEANUP -ne '1') {
            try {
              $userEnvKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
              if ($userEnvKey) {
                try {
                  $rawPathVal = $userEnvKey.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                  if ($rawPathVal -is [string] -and -not [string]::IsNullOrWhiteSpace($rawPathVal)) {
                    $normOcBin = [Environment]::ExpandEnvironmentVariables($ocBinDir).Trim().Trim('"').TrimEnd('\')
                    $keptSegments = @()
                    $pathChanged = $false
                    foreach ($seg in @($rawPathVal -split ';')) {
                      if ([string]::IsNullOrWhiteSpace($seg)) { continue }
                      $normSeg = [Environment]::ExpandEnvironmentVariables($seg.Trim().Trim('"')).TrimEnd('\')
                      if ($normSeg -ieq $normOcBin) { $pathChanged = $true }
                      else { $keptSegments += $seg }
                    }
                    if ($pathChanged) {
                      $pathKind = $userEnvKey.GetValueKind('Path')
                      $userEnvKey.SetValue('Path', ($keptSegments -join ';'), $pathKind)
                    }
                  }
                } finally {
                  $userEnvKey.Dispose()
                }
              }
            } catch { }
          }
        }
        if ($ocAppDir -and (Test-Path -LiteralPath $ocAppDir -PathType Container) -and @(Get-ChildItem -LiteralPath $ocAppDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
          Remove-Item -LiteralPath $ocAppDir -Force -ErrorAction SilentlyContinue
        }
      }

      if ($localApp) {
        $progLocalDir = Join-Path $localApp 'Programs'
        if (Test-Path -LiteralPath $progLocalDir -PathType Container) {
          foreach ($privIde in @(Get-ChildItem -LiteralPath $progLocalDir -Directory -Filter 'EmTroLy-Antigravity-IDE-*' -ErrorAction SilentlyContinue)) {
            if ($privIde.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            Write-ManageStatus $StatusPath 'Đang gỡ bỏ bộ Antigravity IDE cài riêng của Em Trợ Lý...'
            $uninsPath = Join-Path $privIde.FullName 'unins000.exe'
            if ($env:EMTROLY_SKIP_UNINSTALLER_EXEC -ne '1' -and (Test-Path -LiteralPath $uninsPath -PathType Leaf)) {
              try {
                [void](Invoke-SafeSubProcess -FilePath $uninsPath -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -TimeoutSeconds 90)
              } catch { }
            }
            Remove-EmTroLyDirectoryTree $privIde.FullName
          }
        }
        if ($env:EMTROLY_SKIP_REGISTRY_CLEANUP -ne '1') {
          try {
            $agUnKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{AA73B3E3-C6C8-45C8-B1DC-4AE56C751432}_is1'
            if (Test-Path -LiteralPath $agUnKey) {
              $agUnProp = Get-ItemProperty -LiteralPath $agUnKey -ErrorAction SilentlyContinue
              $agLocStr = if ($agUnProp -and $agUnProp.InstallLocation) { [string]$agUnProp.InstallLocation } else { '' }
              $agCmdStr = if ($agUnProp -and $agUnProp.UninstallString) { [string]$agUnProp.UninstallString } else { '' }
              if ($agLocStr -match 'EmTroLy-Antigravity-IDE-' -or $agCmdStr -match 'EmTroLy-Antigravity-IDE-') {
                Remove-Item -LiteralPath $agUnKey -Recurse -Force -ErrorAction SilentlyContinue
              }
            }
          } catch { }
        }
      }

      if ($depDir -and (Test-Path -LiteralPath $depDir -PathType Container)) {
        Write-ManageStatus $StatusPath 'Đang gỡ bỏ gói môi trường tải riêng (Node.js, Python, FFmpeg)...'
        $privPythonExe = Join-Path $depDir 'dependencies\python313\python.exe'
        if ($env:EMTROLY_SKIP_UNINSTALLER_EXEC -ne '1' -and (Test-Path -LiteralPath $privPythonExe -PathType Leaf) -and
            (-not (Test-Path -LiteralPath (Join-Path $localApp 'Programs\Python\Python313\python.exe') -PathType Leaf))) {
          try {
            $pyEntries = @(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object {
              $_.DisplayName -eq 'Python 3.13.16 (64-bit)' -and $_.QuietUninstallString -match 'python-3\.13\.16-amd64\.exe'
            })
            foreach ($pyEnt in $pyEntries) {
              if ([string]$pyEnt.QuietUninstallString -match '^"([^"]+\.exe)"') {
                $pyInstallerCache = $Matches[1]
                if (Test-Path -LiteralPath $pyInstallerCache -PathType Leaf) {
                  [void](Invoke-SafeSubProcess -FilePath $pyInstallerCache -ArgumentList @('/uninstall', '/quiet') -TimeoutSeconds 90)
                }
              }
            }
          } catch { }
        }
        Remove-EmTroLyDirectoryTree $depDir
      }

      Write-ManageStatus $StatusPath 'Đang xóa sạch dữ liệu OpenClaw, Codex CLI, thông số lưu nháp và khóa kích hoạt trên máy...'
      if ($root -and (Test-Path -LiteralPath $root)) {
        Remove-EmTroLyDirectoryTree $root
        if (Test-Path -LiteralPath $root) { throw 'uninstall-cleanup-locked' }
      }
      if ($emBase -and (Test-Path -LiteralPath $emBase)) {
        Remove-EmTroLyDirectoryTree $emBase
        if (Test-Path -LiteralPath $emBase) { throw 'editor-data-recovery-failed' }
      }
      if ($localApp -and (Test-Path -LiteralPath $localApp -PathType Container)) {
        foreach ($failedItem in @(Get-ChildItem -LiteralPath $localApp -Directory -Filter 'EmTroLy.failed-*' -ErrorAction SilentlyContinue)) {
          if (-not ($failedItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-EmTroLyDirectoryTree $failedItem.FullName
          }
        }
      }
      if ($emUiDir -and (Test-Path -LiteralPath $emUiDir)) {
        $activePayloadNorm = if ($PayloadDir) { [IO.Path]::GetFullPath($PayloadDir).TrimEnd('\') } else { '' }
        $emUiNorm = [IO.Path]::GetFullPath($emUiDir).TrimEnd('\')
        if ($activePayloadNorm -ieq $emUiNorm) {
          Remove-Item -LiteralPath (Join-Path $emUiDir 'license.key') -Force -ErrorAction SilentlyContinue
        } else {
          Remove-EmTroLyDirectoryTree $emUiDir
        }
      }
      if ($altDir -and (Test-Path -LiteralPath $altDir -PathType Container)) {
        foreach ($stateLeaf in @('activation.dat', 'setup-draft.dat', 'signed-out.flag')) {
          $leafPath = Join-Path $altDir $stateLeaf
          if (Test-Path -LiteralPath $leafPath -PathType Leaf) {
            Remove-Item -LiteralPath $leafPath -Force -ErrorAction SilentlyContinue
          }
        }
        foreach ($stateSub in @('backups', 'bootstrap')) {
          $subPath = Join-Path $altDir $stateSub
          if (Test-Path -LiteralPath $subPath -PathType Container) {
            Remove-EmTroLyDirectoryTree $subPath
          }
        }
        if (@(Get-ChildItem -LiteralPath $altDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
          Remove-Item -LiteralPath $altDir -Force -ErrorAction SilentlyContinue
        }
        if ($altParent -and (Test-Path -LiteralPath $altParent -PathType Container) -and @(Get-ChildItem -LiteralPath $altParent -Force -ErrorAction SilentlyContinue).Count -eq 0) {
          Remove-Item -LiteralPath $altParent -Force -ErrorAction SilentlyContinue
        }
      }

      Write-ManageStatus $StatusPath 'Hoàn tất: Đã reset toàn bộ Em Trợ Lý về trạng thái trắng tinh từ đầu — giống hệt một người mới chưa từng cài ứng dụng!'
      exit 0
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
      if (-not [string]::IsNullOrWhiteSpace($groupId) -and $groupId -notmatch '^-[1-9][0-9]*$') { throw 'invalid-group' }
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
group_id = "" if sys.argv[6] == "__NONE__" else sys.argv[6].strip()
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

if group_id:
    acc["groups"] = {
        group_id: {
            "groupPolicy": "allowlist",
            "requireMention": False,
            "tools": {"allow": ["*"]},
            "toolsBySender": {"*": {"alsoAllow": ["exec", "process"]}},
        }
    }
else:
    acc["groups"] = {}

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
      $groupArg = if ([string]::IsNullOrWhiteSpace($groupId)) { '__NONE__' } else { $groupId }
      $pyExeManage = Resolve-EmTroLyPythonExe
      try {
        $accountOut = (& $pyExeManage $pyScript $configPath $assistantName $baseUrl $resolvedModel ($owners -join ',') $groupArg ([string]$port) | Out-String).Trim()
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
        & $pyExeManage $ensurePy @ownerArgs *> $null
        if ($LASTEXITCODE -ne 0) { throw 'owner-sync-failed' }
      }
      if (Test-Path -LiteralPath $finalizePy -PathType Leaf) {
        & $pyExeManage $finalizePy --config $configPath --owners ($owners -join ',') *> $null
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
          if (Get-Command -Name 'Sync-EmTroLyUserCodexHome' -ErrorAction Ignore) {
            [void](Sync-EmTroLyUserCodexHome -ApiKey $newApiKey -Model $resolvedModel -BaseUrl $baseUrl)
          }
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

      if (Get-Command Install-EmTroLyCodexCliFirst -ErrorAction SilentlyContinue) {
        $seedJobId = if ($env:LOCALAPPDATA -and (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'EmTroLy\installer-job.txt') -PathType Leaf)) {
          ([IO.File]::ReadAllText((Join-Path $env:LOCALAPPDATA 'EmTroLy\installer-job.txt'))).Trim()
        } else { '' }
        if ($seedJobId -cnotmatch '^[a-f0-9]{32}$') { $seedJobId = [guid]::NewGuid().ToString('N') }
        $seedSettings = [pscustomobject]@{ model = $model; base_url = $baseUrl; ai_api_key = $apiKey }
        try { [void](Install-EmTroLyCodexCliFirst -Settings $seedSettings -PayloadRoot $PayloadDir -StatusFile $StatusPath -EditorJobId $seedJobId -ForceConfigUpdate) } catch { }
      }

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
        if (Get-Command -Name 'Sync-EmTroLyUserCodexHome' -ErrorAction Ignore) {
          [void](Sync-EmTroLyUserCodexHome -ApiKey $apiKey -Model $model -BaseUrl $baseUrl)
        }
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $repRes = Invoke-SafeSubProcess -FilePath $psExe -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $repairScript) -TimeoutSeconds 120
        $modVerifyQuick = if (Get-Command Get-EmTroLyModularStatus -ErrorAction SilentlyContinue) { Get-EmTroLyModularStatus } else { $null }
        $hasAgyRuntimeCli = $env:USERPROFILE -and (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.gemini\bin\agy.exe') -PathType Leaf) -and ((Get-Item -LiteralPath (Join-Path $env:USERPROFILE '.gemini\bin\agy.exe')).Length -gt 0)
        $quickVerified = if ($modVerifyQuick) { ($modVerifyQuick.AntigravityInstalled -and $modVerifyQuick.CodexExtensionInstalled -and $hasAgyRuntimeCli) } else { ((Test-Path -LiteralPath $shortcutPath -PathType Leaf) -and $hasAgyRuntimeCli) }
        if ($repRes.ExitCode -eq 0 -and $quickVerified) {
          [void](Register-EmTroLyCodexCli -PayloadRoot $PayloadDir)
          if (Get-Command -Name 'Sync-EmTroLyAntigravityDefaultExtension' -ErrorAction Ignore) {
            try { [void](Sync-EmTroLyAntigravityDefaultExtension) } catch { }
          }
          if (Get-Command Install-EmTroLyAppShortcut -ErrorAction SilentlyContinue) {
            try { [void](Install-EmTroLyAppShortcut -PayloadRoot $PayloadDir) } catch { }
          }
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
  & $InstallerPath -Settings $s -StatusFile $StatusPath -AllowUpdateExisting
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

      $modVerifyFinal = if (Get-Command Get-EmTroLyModularStatus -ErrorAction SilentlyContinue) { Get-EmTroLyModularStatus } else { $null }
      if ($modVerifyFinal -and (-not $modVerifyFinal.AntigravityInstalled -or -not $modVerifyFinal.CodexExtensionInstalled)) {
        throw 'editor-extension-verification-failed'
      }
      [void](Register-EmTroLyCodexCli -PayloadRoot $PayloadDir)
      if (Get-Command -Name 'Sync-EmTroLyUserCodexHome' -ErrorAction Ignore) {
        try { [void](Sync-EmTroLyUserCodexHome -ApiKey $apiKey -Model $model -BaseUrl $baseUrl) } catch { }
      }
      if (Get-Command -Name 'Sync-EmTroLyAntigravityDefaultExtension' -ErrorAction Ignore) {
        try { [void](Sync-EmTroLyAntigravityDefaultExtension) } catch { }
      }
      if (Get-Command Install-EmTroLyAppShortcut -ErrorAction SilentlyContinue) {
        try { [void](Install-EmTroLyAppShortcut -PayloadRoot $PayloadDir) } catch { }
      }
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
      if ($healRes.PSObject.Properties['DiagnosticError'] -and $healRes.DiagnosticError) {
        $lastAutoHealDiagnosticError = [string]$healRes.DiagnosticError
      }
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
      $editorPendingNote = ''
      if (Get-Command Get-EmTroLyModularStatus -ErrorAction SilentlyContinue) {
        try {
          $modAfterHeal = Get-EmTroLyModularStatus
          if ($modAfterHeal -and (-not $modAfterHeal.AntigravityInstalled -or -not $modAfterHeal.CodexExtensionInstalled) -and $hintDetail -match '(?i)antigravity|editor|extension|shortcut|lối tắt') {
            $editorPendingNote = ' Lưu ý: Antigravity IDE / Codex Extension riêng vẫn chưa cài đủ — hãy bấm nút "Cài / Sửa Antigravity" trên màn Tổng quan để cài tự động.'
          }
        } catch { }
      }
      Write-ManageStatus $StatusPath "Hoàn tất: Codex CLI đã tự kiểm tra và sửa lỗi thành công!$summaryNote$editorPendingNote"
      exit 0
    }

    if ($action -eq 'upgrade-openclaw') {
      if (-not $state.OpenClawInstalled) { throw 'openclaw-not-installed' }
      $verInfo = if (Get-Command Get-EmTroLyOpenClawVersionInfo -ErrorAction SilentlyContinue) {
        Get-EmTroLyOpenClawVersionInfo -PayloadRoot $PayloadDir -OpenClawRoot $root
      } else { $null }
      $targetVer = if ($verInfo -and $verInfo.TargetVersion) { [string]$verInfo.TargetVersion } else { '2026.11.4' }
      $curVer = if ($verInfo -and $verInfo.InstalledVersion) { [string]$verInfo.InstalledVersion } else { '' }
      if ($verInfo -and $verInfo.IsUpToDate) {
        Write-ManageStatus $StatusPath "Hoàn tất: Trợ lý OpenClaw đã ở phiên bản mới nhất (v$curVer) — không cần nâng cấp."
        exit 0
      }

      Write-ManageStatus $StatusPath "Đang sao lưu cấu hình OpenClaw hiện tại (v$curVer) trước khi nâng cấp lên v$targetVer..."
      $backupDir = Join-Path $root ('backups\upgrade-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
      New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
      foreach ($bf in @('openclaw.json', 'installer-instance.json', 'openclaw-instance.ps1', 'windows-cli.json')) {
        $bSrc = Join-Path $root $bf
        if (Test-Path -LiteralPath $bSrc -PathType Leaf) {
          Copy-Item -LiteralPath $bSrc -Destination (Join-Path $backupDir $bf) -Force
        }
      }

      $nodeExe = Resolve-EmTroLyNodeBinary -OpenClawRoot $root
      if (-not $nodeExe) { throw 'node-not-found' }
      $nodeDir = Split-Path -Parent $nodeExe
      $npmCmd = Join-Path $nodeDir 'npm.cmd'
      if (-not (Test-Path -LiteralPath $npmCmd -PathType Leaf)) {
        $npmFound = @(Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($npmFound.Count -gt 0) { $npmCmd = $npmFound[0].Source }
      }
      if (-not $npmCmd -or -not (Test-Path -LiteralPath $npmCmd -PathType Leaf)) { throw 'npm-not-found' }

      $env:Path = "$nodeDir;$env:Path"
      $rtTarget = Join-Path $root ("runtime\$targetVer")
      New-Item -ItemType Directory -Path $rtTarget -Force | Out-Null
      $rtPkg = @{ name='member-openclaw-runtime'; version='1.0.0'; private=$true }
      [IO.File]::WriteAllText((Join-Path $rtTarget 'package.json'), ($rtPkg | ConvertTo-Json -Depth 4), $utf8NoBom)

      Write-ManageStatus $StatusPath "Đang tải và nâng cấp OpenClaw lên phiên bản v$targetVer (giữ nguyên toàn bộ dữ liệu cũ)..."
      if (Get-Command -Name 'Invoke-OpenClawNpmInstall' -ErrorAction SilentlyContinue) {
        $upgNpmRes = $null
        try {
          $upgNpmRes = Invoke-OpenClawNpmInstall `
            -RuntimeDir $rtTarget `
            -OpenClawRoot $root `
            -OpenClawVersion $targetVer `
            -LogsDir (Join-Path $root 'logs') `
            -NpmCacheRoot (Join-Path $root 'npm-cache') `
            -PayloadRoot $PayloadDir `
            -StatusCallback { param($msg) Write-ManageStatus $StatusPath $msg } `
            -LogCallback { param($msg) Write-ManageStatus $StatusPath $msg }
        } catch {
          $upgErr = [string]$_.Exception.Message
          $lastRes = Get-Variable -Name 'LastOpenClawNpmResult' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
          if ($lastRes -and $lastRes.LastOutput) {
            $lastManageTechDetail = [string]$lastRes.LastOutput
          }
          if ($upgErr -eq 'openclaw-npm-verification-failed' -or ($lastRes -and $lastRes.VerificationFailed)) {
            $lastManagePrimaryError = if ($lastRes -and $lastRes.ErrorMessage) { [string]$lastRes.ErrorMessage } else { 'OpenClaw npm verification failed: missing package.json or openclaw.cmd.' }
            if (-not $lastManageTechDetail) { $lastManageTechDetail = $lastManagePrimaryError }
            throw 'openclaw-npm-verification-failed'
          }
          if ($lastRes -and $lastRes.IsTlsError) {
            $lastManagePrimaryError = 'npm/OpenSSL không giải mã được dữ liệu HTTPS khi nâng cấp OpenClaw.'
          } elseif ($lastManageTechDetail) {
            $lastManagePrimaryError = ($lastManageTechDetail -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 8) -join ' | '
          } else {
            $lastManagePrimaryError = $upgErr
          }
          throw 'openclaw-upgrade-install-failed'
        }
        if ($upgNpmRes -and $upgNpmRes.UsedNodeExe) {
          $nodeExe = [string]$upgNpmRes.UsedNodeExe
          $nodeDir = Split-Path -Parent $nodeExe
          $env:Path = "$nodeDir;$env:Path"
        }
      } else {
        $upgExit = 1
        $upgCacheRoot = Join-Path $root 'npm-cache'
        $hadUpgCache = Test-Path Env:NPM_CONFIG_CACHE
        $oldUpgCache = if ($hadUpgCache) { $env:NPM_CONFIG_CACHE } else { $null }
        $hadUpgNodeOpts = Test-Path Env:NODE_OPTIONS
        $oldUpgNodeOpts = if ($hadUpgNodeOpts) { $env:NODE_OPTIONS } else { $null }
        $hadUpgIa32 = Test-Path Env:OPENSSL_ia32cap
        $oldUpgIa32 = if ($hadUpgIa32) { $env:OPENSSL_ia32cap } else { $null }
        try {
          for ($uTry = 1; $uTry -le 2; $uTry++) {
            $attemptCache = Join-Path $upgCacheRoot ("upgrade-attempt-$uTry")
            New-Item -ItemType Directory -Path $attemptCache -Force | Out-Null
            $env:NPM_CONFIG_CACHE = $attemptCache
            if ($uTry -ge 2) {
              $env:OPENSSL_ia32cap = '~0x200000200000000'
              $env:NODE_OPTIONS = '--tls-max-v1.2 --tls-cipher-list=ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:!AESGCM:!GCM'
              & $npmCmd install --prefix $rtTarget "openclaw@$targetVer" --no-audit --no-fund --maxsockets=1 --registry=https://registry.npmmirror.com/ *> $null
            } else {
              & $npmCmd install --prefix $rtTarget "openclaw@$targetVer" --no-audit --no-fund --maxsockets=2 --registry=https://registry.npmjs.org/ *> $null
            }
            $upgExit = $LASTEXITCODE
            if ($upgExit -eq 0) { break }
            if ($uTry -lt 2) { Start-Sleep -Seconds 2 }
          }
        } finally {
          if ($hadUpgCache) { $env:NPM_CONFIG_CACHE = $oldUpgCache } elseif (Test-Path Env:NPM_CONFIG_CACHE) { Remove-Item Env:NPM_CONFIG_CACHE -ErrorAction SilentlyContinue }
          if ($hadUpgNodeOpts) { $env:NODE_OPTIONS = $oldUpgNodeOpts } elseif (Test-Path Env:NODE_OPTIONS) { Remove-Item Env:NODE_OPTIONS -ErrorAction SilentlyContinue }
          if ($hadUpgIa32) { $env:OPENSSL_ia32cap = $oldUpgIa32 } elseif (Test-Path Env:OPENSSL_ia32cap) { Remove-Item Env:OPENSSL_ia32cap -ErrorAction SilentlyContinue }
        }
        if ($upgExit -ne 0) { throw 'openclaw-upgrade-install-failed' }
        $pkgCheck = Join-Path $rtTarget 'node_modules\openclaw\package.json'
        $cmdCheck = Join-Path $rtTarget 'node_modules\.bin\openclaw.cmd'
        if (-not (Test-Path -LiteralPath $pkgCheck -PathType Leaf) -or -not (Test-Path -LiteralPath $cmdCheck -PathType Leaf)) {
          throw 'openclaw-npm-verification-failed'
        }
      }

      $newCliEntry = Join-Path $rtTarget 'node_modules\openclaw\openclaw.mjs'
      if (-not (Test-Path -LiteralPath $newCliEntry -PathType Leaf)) { throw 'openclaw-upgrade-entry-missing' }

      $env:OPENCLAW_STATE_DIR = $root
      $env:OPENCLAW_CONFIG_PATH = $configPath
      $env:OPENCLAW_CLI_ENTRY = $newCliEntry
      if ($instance -and $instance.profile) { $env:OPENCLAW_PROFILE = [string]$instance.profile }

      Write-ManageStatus $StatusPath 'Đang đồng bộ cấu trúc dữ liệu và khởi động lại Gateway...'
      try { [void](Invoke-EmTroLyGatewayInstance -Root $root -CliArgs @('gateway', 'stop')) } catch { }
      try { & $nodeExe $newCliEntry doctor --fix --non-interactive --yes *> $null } catch { }

      $instProfile = if ($instance -and $instance.profile) { [string]$instance.profile } else { $state.AccountName }
      $gwPort = if ($state.GatewayPort -match '^[0-9]+$' -and [int]$state.GatewayPort -ge 1024) { [int]$state.GatewayPort } else { 19789 }
      $winInstHelper = Join-Path $PayloadDir 'native\windows-instance.ps1'
      if (Test-Path -LiteralPath $winInstHelper -PathType Leaf) {
        . $winInstHelper
        if (Get-Command Save-OpenClawInstanceLauncher -ErrorAction SilentlyContinue) {
          Save-OpenClawInstanceLauncher -Root $root -InstanceProfile $instProfile -CliEntry $newCliEntry -Port $gwPort
        }
      } else {
        $instMeta = if ($instance) { $instance } else { [pscustomobject]@{ profile = $instProfile; port = $gwPort } }
        $instMeta | Add-Member -NotePropertyName cli_entry -NotePropertyValue $newCliEntry -Force
        [IO.File]::WriteAllText((Join-Path $root 'installer-instance.json'), ($instMeta | ConvertTo-Json -Depth 6), $utf8NoBom)
      }

      $winCliHelper = Join-Path $PayloadDir 'native\windows-cli.ps1'
      if (Test-Path -LiteralPath $winCliHelper -PathType Leaf) {
        . $winCliHelper
        if (Get-Command Install-UserOpenClawCli -ErrorAction SilentlyContinue) {
          try { Install-UserOpenClawCli -Root $root -CliEntry $newCliEntry -Port $gwPort -Profile $instProfile } catch { }
        }
      }

      & $nodeExe $newCliEntry gateway restart *> $null
      if ($LASTEXITCODE -ne 0) {
        & $nodeExe $newCliEntry gateway install --port $gwPort --force *> $null
        & $nodeExe $newCliEntry gateway restart *> $null
      }
      $fromLabel = if ($curVer) { "v$curVer " } else { '' }
      Write-ManageStatus $StatusPath "Hoàn tất: Đã nâng cấp Trợ lý OpenClaw từ ${fromLabel}lên v$targetVer thành công (giữ nguyên cấu hình, Telegram & Zalo)!"
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
      'openclaw-upgrade-install-failed' = 'Không thể tải hoặc cài đặt OpenClaw bằng npm (nguyên nhân chính: lỗi kết nối/giải mã HTTPS npm/OpenSSL hoặc gián đoạn mạng).'
      'openclaw-npm-verification-failed' = 'npm kết thúc bình thường nhưng thiếu package.json hoặc openclaw.cmd trong thư mục runtime OpenClaw.'
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
      if (Get-Command -Name 'Get-EmTroLySavedLicenseKey' -ErrorAction Ignore) {
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
        timestamp             = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        stage                 = $action
        code                  = $errCode
        friendlyMessage       = $safeFriendly
        primaryInstallerError = if (Get-Command Remove-SensitiveStrings -ErrorAction SilentlyContinue) { Remove-SensitiveStrings -Text $lastManagePrimaryError -Secrets $secretsToScrub } else { $lastManagePrimaryError }
        autoHealSummary       = ''
        autoHealError         = if (Get-Command Remove-SensitiveStrings -ErrorAction SilentlyContinue) { Remove-SensitiveStrings -Text $lastAutoHealDiagnosticError -Secrets $secretsToScrub } else { $lastAutoHealDiagnosticError }
        technicalDetail       = $safeTech
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
