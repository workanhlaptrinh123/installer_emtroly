[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PayloadRoot)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Em Trợ Lý - Cài đặt'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(780, 620)
$form.MinimumSize = New-Object System.Drawing.Size(780, 620)
$form.MaximizeBox = $false
$form.FormBorderStyle = 'FixedDialog'

$tab = New-Object System.Windows.Forms.TabControl
$tab.Location = New-Object System.Drawing.Point(12, 12)
$tab.Size = New-Object System.Drawing.Size(740, 490)
$form.Controls.Add($tab)

function New-Page([string]$Title) {
  $page = New-Object System.Windows.Forms.TabPage
  $page.Text = $Title
  $page.BackColor = [System.Drawing.Color]::White
  [void]$tab.TabPages.Add($page)
  return $page
}

function Add-Label([System.Windows.Forms.Control]$Page, [string]$Text, [int]$X, [int]$Y, [int]$Width = 210, [int]$Height = 24) {
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Location = New-Object System.Drawing.Point($X, $Y)
  $label.Size = New-Object System.Drawing.Size($Width, $Height)
  [void]$Page.Controls.Add($label)
}

function Add-TextBox([System.Windows.Forms.Control]$Page, [string]$Default, [int]$Y, [bool]$Password = $false) {
  $box = New-Object System.Windows.Forms.TextBox
  $box.Location = New-Object System.Drawing.Point(250, $Y)
  $box.Size = New-Object System.Drawing.Size(450, 25)
  $box.Text = $Default
  $box.Font = New-Object System.Drawing.Font('Segoe UI', 10)
  if ($Password) { $box.UseSystemPasswordChar = $true }
  [void]$Page.Controls.Add($box)
  return $box
}

function Add-Note([System.Windows.Forms.Control]$Page, [string]$Text, [int]$Y) {
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Location = New-Object System.Drawing.Point(24, $Y)
  $label.Size = New-Object System.Drawing.Size(680, 52)
  $label.AutoSize = $false
  [void]$Page.Controls.Add($label)
}

$connect = New-Page 'Kết nối'
Add-Label $connect 'Tên trợ lý' 24 72
$assistantBox = Add-TextBox $connect 'Trợ lý OpenClaw' 69
Add-Label $connect 'Provider Base URL (HTTPS)' 24 116
$baseUrlBox = Add-TextBox $connect 'https://codex.anhlaptrinh.vn/v1' 113
$baseUrlBox.ReadOnly = $true
Add-Label $connect 'Model' 24 160
$modelBox = Add-TextBox $connect 'gpt-6.1-sol' 157
Add-Label $connect 'Telegram Owner IDs' 24 204
$ownersBox = Add-TextBox $connect '' 201
Add-Label $connect 'Telegram Group ID' 24 248
$groupBox = Add-TextBox $connect '' 245
Add-Label $connect 'Gateway port (0 = tự động)' 24 292
$portBox = Add-TextBox $connect '0' 289
Add-Note $connect 'Owner IDs là số Telegram dương, ngăn cách bằng dấu phẩy. Group ID phải là số âm.' 342

$secret = New-Page 'Bảo mật'
Add-Label $secret 'Telegram Bot Token' 24 42
$tokenBox = Add-TextBox $secret '' 39 $true
Add-Label $secret 'Provider API Key' 24 92
$apiKeyBox = Add-TextBox $secret '' 89 $true
Add-Note $secret 'API key dùng chung cho OpenClaw và Codex; token và key được lưu riêng trên máy. Không chia sẻ thông tin bí mật.' 150
Add-Note $secret 'Bot phải được tạo bằng BotFather. Nếu dùng trong nhóm, kiểm tra /setprivacy của đúng bot.' 245

$profile = New-Page 'Hồ sơ'
Add-Label $profile 'Đối tượng phục vụ (tùy chọn)' 24 42
$audienceBox = Add-TextBox $profile '' 39
Add-Label $profile 'Cách xưng hô (tùy chọn)' 24 92
$addressingBox = Add-TextBox $profile '' 89
Add-Label $profile 'Phong cách trả lời (tùy chọn)' 24 142
$styleBox = Add-TextBox $profile '' 139
Add-Note $profile 'Bộ cài gồm OpenClaw, Zalo, Antigravity IDE và Codex với dữ liệu riêng. Cần Internet để tải các thành phần.' 210
$fullAccessCheck = New-Object System.Windows.Forms.CheckBox
$fullAccessCheck.Text = 'Tôi hiểu và đồng ý cấp Full Exec cho owner và nhóm đã nhập'
$fullAccessCheck.Location = New-Object System.Drawing.Point(24, 290)
$fullAccessCheck.Size = New-Object System.Drawing.Size(650, 30)
$fullAccessCheck.Checked = $false
[void]$profile.Controls.Add($fullAccessCheck)
Add-Note $profile 'Full Exec có thể đọc, sửa, xóa file và chạy lệnh trên máy. Chỉ cấp quyền cho những người bạn tin tưởng.' 330

$editorPage = New-Page 'Antigravity'
$existingEditorCheck = New-Object System.Windows.Forms.CheckBox
$existingEditorCheck.Text = 'Máy đã có Antigravity IDE - dùng bản đang cài'
$existingEditorCheck.Location = New-Object System.Drawing.Point(24, 42)
$existingEditorCheck.Size = New-Object System.Drawing.Size(650, 30)
[void]$editorPage.Controls.Add($existingEditorCheck)
Add-Label $editorPage 'Tệp Antigravity IDE.exe' 24 102
$existingEditorBox = Add-TextBox $editorPage '' 99
$existingEditorBox.Size = New-Object System.Drawing.Size(345, 25)
$existingEditorBox.Enabled = $false
$existingEditorBrowse = New-Object System.Windows.Forms.Button
$existingEditorBrowse.Text = 'Chọn tệp...'
$existingEditorBrowse.Location = New-Object System.Drawing.Point(605, 97)
$existingEditorBrowse.Size = New-Object System.Drawing.Size(95, 28)
$existingEditorBrowse.Enabled = $false
[void]$editorPage.Controls.Add($existingEditorBrowse)
$existingEditorCheck.Add_CheckedChanged({
  $existingEditorBox.Enabled = $existingEditorCheck.Checked
  $existingEditorBrowse.Enabled = $existingEditorCheck.Checked
  if ($existingEditorCheck.Checked -and [string]::IsNullOrWhiteSpace($existingEditorBox.Text)) {
    $defaultEditor = Join-Path $env:LOCALAPPDATA 'Programs\Antigravity IDE\Antigravity IDE.exe'
    if (Test-Path -LiteralPath $defaultEditor -PathType Leaf) { $existingEditorBox.Text = $defaultEditor }
  }
})
$existingEditorBrowse.Add_Click({
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Title = 'Chọn Antigravity IDE.exe đã cài'
  $dialog.Filter = 'Antigravity IDE.exe|Antigravity IDE.exe|Tệp EXE|*.exe'
  try {
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $existingEditorBox.Text = $dialog.FileName }
  } finally { $dialog.Dispose() }
})
Add-Note $editorPage 'Nếu chưa có, bỏ chọn để bộ cài tải Antigravity IDE. Codex và cấu hình Em Trợ Lý vẫn được cài riêng.' 165
Add-Note $editorPage 'Bản đã cài phải là Antigravity IDE tương thích và có chữ ký Google hợp lệ. Bộ cài không xóa dữ liệu ứng dụng cũ.' 245

$zalo = New-Page 'Zalo'
$zaloCheck = New-Object System.Windows.Forms.CheckBox
$zaloCheck.Text = 'Cài plugin Zalo và lệnh /zaloqr (bắt buộc)'
$zaloCheck.Location = New-Object System.Drawing.Point(24, 42)
$zaloCheck.Size = New-Object System.Drawing.Size(650, 30)
$zaloCheck.Checked = $true
$zaloCheck.Enabled = $false
[void]$zalo.Controls.Add($zaloCheck)
Add-Label $zalo 'QR owner ID (tùy chọn)' 24 92
$qrOwnerBox = Add-TextBox $zalo '' 89
Add-Note $zalo 'Sau khi cài, owner nhắn /zaloqr trong Telegram riêng để nhận mã; dùng /zalostatus để kiểm tra kết nối.' 150
Add-Note $zalo 'Không cần quét QR trong lúc cài. Owner cần nhấn /start trước khi yêu cầu mã.' 250

$installPage = New-Page 'Cài đặt'
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Sẵn sàng. Bấm Cài đặt để bắt đầu.'
$statusLabel.Location = New-Object System.Drawing.Point(24, 42)
$statusLabel.Size = New-Object System.Drawing.Size(680, 68)
$statusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
[void]$installPage.Controls.Add($statusLabel)
Add-Note $installPage 'Bộ cài kiểm tra provider, Telegram, Gateway, plugin Zalo và lệnh QR. Quét QR là bước sau khi cài.' 130
Add-Note $installPage 'Windows x64 cần Internet và PowerShell 5.1. Gateway chạy ẩn trong tài khoản Windows, không dùng Docker.' 215

$backButton = New-Object System.Windows.Forms.Button
$backButton.Text = 'Quay lại'
$backButton.Location = New-Object System.Drawing.Point(360, 520)
$backButton.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($backButton)
$nextButton = New-Object System.Windows.Forms.Button
$nextButton.Text = 'Tiếp'
$nextButton.Location = New-Object System.Drawing.Point(480, 520)
$nextButton.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($nextButton)
$installButton = New-Object System.Windows.Forms.Button
$installButton.Text = 'Cài đặt'
$installButton.Location = New-Object System.Drawing.Point(600, 520)
$installButton.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($installButton)
$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = 'Hủy'
$cancelButton.Location = New-Object System.Drawing.Point(240, 520)
$cancelButton.Size = New-Object System.Drawing.Size(100, 32)
$form.Controls.Add($cancelButton)

$pages = @($connect, $secret, $profile, $editorPage, $zalo, $installPage)
$job = $null
$secretFile = $null
$statusFile = $null
$privateDir = $null
$safeLog = $null
$installRunning = $false
$resultCode = 1

function Show-Error([string]$Message) {
  [System.Windows.Forms.MessageBox]::Show($form, $Message, 'Không thể tiếp tục', 'OK', 'Warning') | Out-Null
}

function Test-Page([int]$Index) {
  if ($Index -eq 0) {
    if ([string]::IsNullOrWhiteSpace($baseUrlBox.Text) -or $baseUrlBox.Text -notmatch '^https://') { Show-Error 'Provider Base URL phải bắt đầu bằng https://.'; return $false }
    if ($modelBox.Text -notin @('gpt-6.1-sol','gpt-6.1-terra','gpt-6-astra')) { Show-Error 'Model phải là gpt-6.1-sol, gpt-6.1-terra hoặc gpt-6-astra.'; return $false }
    if ($ownersBox.Text -notmatch '^[1-9][0-9]*(,[1-9][0-9]*)*$') { Show-Error 'Owner IDs không hợp lệ.'; return $false }
    if ($groupBox.Text -notmatch '^-[1-9][0-9]*$') { Show-Error 'Group ID phải là số âm.'; return $false }
    $port = 0
    if (-not [int]::TryParse($portBox.Text, [ref]$port) -or ($port -ne 0 -and ($port -lt 1024 -or $port -gt 65000))) { Show-Error 'Gateway port phải là 0 hoặc từ 1024 đến 65000.'; return $false }
  }
  if ($Index -eq 1) {
    if ([string]::IsNullOrWhiteSpace($tokenBox.Text)) { Show-Error 'Hãy nhập Telegram Bot Token.'; return $false }
    if ([string]::IsNullOrWhiteSpace($apiKeyBox.Text)) { Show-Error 'Hãy nhập Provider API Key.'; return $false }
  }
  if ($Index -eq 2 -and -not $fullAccessCheck.Checked) {
    Show-Error 'Hãy xác nhận bạn hiểu và chấp nhận Full Exec cho owner và nhóm tin cậy.'
    return $false
  }
  if ($Index -eq 3 -and $existingEditorCheck.Checked -and -not (Test-Path -LiteralPath $existingEditorBox.Text.Trim() -PathType Leaf)) {
    Show-Error 'Hãy chọn tệp Antigravity IDE.exe đã cài trên máy.'
    return $false
  }
  if ($Index -eq 4 -and $zaloCheck.Checked) {
    if ([string]::IsNullOrWhiteSpace($qrOwnerBox.Text)) {
      $qrOwnerBox.Text = (($ownersBox.Text -split ',')[0]).Trim()
    }
    if ($qrOwnerBox.Text -notmatch '^[1-9][0-9]*$') { Show-Error 'QR owner ID phải là số dương.'; return $false }
    if ((',' + $ownersBox.Text + ',') -notmatch (',' + [regex]::Escape($qrOwnerBox.Text) + ',')) { Show-Error 'QR owner ID phải nằm trong danh sách Owner IDs.'; return $false }
  }
  return $true
}

function Set-Buttons {
  $isLast = $tab.SelectedIndex -eq ($tab.TabPages.Count - 1)
  $backButton.Enabled = (-not $installRunning -and $tab.SelectedIndex -gt 0)
  $nextButton.Enabled = (-not $installRunning -and -not $isLast)
  $installButton.Enabled = (-not $installRunning -and $isLast)
  $cancelButton.Enabled = -not $installRunning
}

function Cleanup-Secret {
  if ($script:privateDir -and (Test-Path -LiteralPath $script:privateDir)) {
    Remove-Item -LiteralPath $script:privateDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Start-Install {
  if (-not (Test-Page 0) -or -not (Test-Page 1) -or -not (Test-Page 2) -or -not (Test-Page 3) -or -not (Test-Page 4)) { return }
  $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Các Owner IDs và mọi thành viên trong nhóm Telegram đã chọn có thể yêu cầu đọc, sửa, xóa file và chạy lệnh trên máy. Bạn có tin tưởng họ?', 'Xác nhận Full Exec', 'YesNo', 'Warning')
  if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  if ($zaloCheck.Checked) {
    $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Zalo dùng danh sách cho phép. Sau khi cài, owner nhắn /zaloqr trong Telegram riêng để nhận QR. Bạn đồng ý?', 'Xác nhận Zalo', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  }
  $script:installRunning = $true
  Set-Buttons
  $statusLabel.Text = 'Đang kiểm tra và cài OpenClaw, có thể mất vài phút...'
  try {
  $settings = [ordered]@{
    member = 'emtroly'
    assistant_name = $assistantBox.Text.Trim()
    base_url = $baseUrlBox.Text.Trim().TrimEnd('/')
    model = $modelBox.Text.Trim()
    owner_ids = $ownersBox.Text.Trim()
    group_id = $groupBox.Text.Trim()
    gateway_port = $portBox.Text.Trim()
    audience = $audienceBox.Text.Trim()
    addressing = $addressingBox.Text.Trim()
    style = $styleBox.Text.Trim()
    accept_full_access = [bool]$fullAccessCheck.Checked
    configure_zalo = [bool]$zaloCheck.Checked
    use_existing_antigravity = [bool]$existingEditorCheck.Checked
    antigravity_exe = $existingEditorBox.Text.Trim()
    qr_owner_id = $qrOwnerBox.Text.Trim()
    telegram_token = $tokenBox.Text
    ai_api_key = $apiKeyBox.Text
  }
  $script:privateDir = Join-Path $env:TEMP ('openclaw-member-' + [guid]::NewGuid().ToString('N'))
  $acl = New-Object System.Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
  $propagate = [System.Security.AccessControl.PropagationFlags]::None
  $allow = [System.Security.AccessControl.AccessControlType]::Allow
  $full = [System.Security.AccessControl.FileSystemRights]::FullControl
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
  $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($user, $full, $inherit, $propagate, $allow)))
  $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, $full, $inherit, $propagate, $allow)))
  [void][IO.Directory]::CreateDirectory($script:privateDir, $acl)
  $script:secretFile = Join-Path $script:privateDir 'settings.json'
  $script:safeLog = Join-Path $script:privateDir 'status.txt'
  $json = $settings | ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($script:secretFile, $json, (New-Object Text.UTF8Encoding($false)))
  $runner = Join-Path $PayloadRoot 'windows-installer\run-native-install.ps1'
  $settingsPath = $script:secretFile
  $rootPath = $PayloadRoot
  $logPath = $script:safeLog
  $shellPath = Join-Path $PSHOME 'powershell.exe'
  $script:job = Start-Job -ScriptBlock {
    param($shellPath, $runnerPath, $settingsPath, $payloadPath, $logPath)
    $code = 1
    try {
      $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
        $runnerPath + '" -SettingsFile "' + $settingsPath +
        '" -PayloadRoot "' + $payloadPath + '" -LogFile "' + $logPath + '"'
      $child = Start-Process -FilePath $shellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
      $deadline = (Get-Date).AddMinutes(60)
      while ($true) {
        $child.Refresh()
        if ($child.HasExited) { break }
        if ((Get-Date) -ge $deadline) {
          Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
          throw 'Installer runner timed out.'
        }
        Start-Sleep -Milliseconds 250
      }
      $code = $child.ExitCode
    } catch { $code = 1 }
    return $code
  } -ArgumentList $shellPath, $runner, $settingsPath, $rootPath, $logPath
  $tokenBox.Clear()
  $apiKeyBox.Clear()
  $timer.Start()
  } catch {
    Cleanup-Secret
    $script:installRunning = $false
    Set-Buttons
    Show-Error 'Không thể tạo thư mục tạm hoặc khởi động bộ cài. Hãy kiểm tra quyền của tài khoản Windows.'
  }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
  if (-not $script:installRunning) { return }
  if ($script:safeLog -and (Test-Path -LiteralPath $script:safeLog)) {
    try { $statusLabel.Text = [IO.File]::ReadAllText($script:safeLog, [Text.Encoding]::UTF8) } catch { }
  }
  if ($script:job.State -in @('Completed', 'Failed', 'Stopped')) {
    $code = 1
    try {
      $returned = @(Receive-Job -Job $script:job -ErrorAction Stop)
      if ($returned.Count -eq 1) { [int]::TryParse([string]$returned[0], [ref]$code) | Out-Null }
    } catch { $code = 1 }
    $timer.Stop()
    Remove-Job -Job $script:job -Force -ErrorAction SilentlyContinue
    $detail = $statusLabel.Text
    Cleanup-Secret
    $script:installRunning = $false
    $script:resultCode = $code
    if ($code -eq 0) {
      $statusLabel.Text = 'Cài OpenClaw, Antigravity và Codex hoàn tất.'
      $cliNotice = 'Mở PowerShell mới, sau đó chạy: openclaw status.'
      $cliInfoPath = Join-Path (Join-Path $env:USERPROFILE 'openclaw') 'windows-cli.json'
      if (Test-Path -LiteralPath $cliInfoPath) {
        try {
          $cliInfo = [IO.File]::ReadAllText($cliInfoPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
          if (-not $cliInfo.default -and $cliInfo.command -match '^openclaw-member-[a-f0-9]{12}$') {
            $cliNotice = "Lệnh openclaw cũ được giữ nguyên. Mở PowerShell mới, sau đó chạy: $($cliInfo.command) status."
          }
        } catch { $cliNotice = 'Mở PowerShell mới. Nếu đã có lệnh openclaw, xem windows-cli.json để biết tên lệnh riêng.' }
      }
      $successMessage = "OpenClaw và Codex đã qua kiểm tra. Mở shortcut Em Trợ Lý - Antigravity trên Desktop để dùng Codex riêng.`n`nNhắn /zaloqr trong Telegram riêng và dùng /zalostatus sau khi quét QR.`n`n$cliNotice`n`nGateway chạy ẩn khi người dùng Windows đăng nhập."
      [System.Windows.Forms.MessageBox]::Show($form, $successMessage, 'Cài đặt hoàn tất', 'OK', 'Information') | Out-Null
      $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
      $form.Close()
    } else {
      $statusLabel.Text = 'Cài đặt chưa thành công. Dữ liệu đã tạo được giữ nguyên.'
      Show-Error ("Cài đặt chưa thành công. $detail`n`nNếu thư mục đã được tạo một phần, hãy kiểm tra trước khi thử lại.")
    }
    Set-Buttons
  }
})

$tab.Add_SelectedIndexChanged({ Set-Buttons })
$backButton.Add_Click({ if ($tab.SelectedIndex -gt 0) { $tab.SelectedIndex-- } })
$nextButton.Add_Click({ if (Test-Page $tab.SelectedIndex) { $tab.SelectedIndex++ } })
$installButton.Add_Click({ Start-Install })
$cancelButton.Add_Click({ Cleanup-Secret; $script:resultCode = 2; $form.Close() })
$form.Add_FormClosing({ if ($script:installRunning) { $_.Cancel = $true; Show-Error 'Cài đặt đang chạy; vui lòng đợi đến khi hoàn tất.' } })

Set-Buttons
[void]$form.ShowDialog()
Cleanup-Secret
exit $script:resultCode
