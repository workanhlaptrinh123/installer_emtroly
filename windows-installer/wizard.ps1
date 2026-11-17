[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PayloadRoot)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'installer_emtroly - Cai dat'
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

$connect = New-Page 'Ket noi'
Add-Label $connect 'Ten member (chu thuong)' 24 28
$nameBox = Add-TextBox $connect 'member01' 25
Add-Label $connect 'Ten tro ly' 24 72
$assistantBox = Add-TextBox $connect 'Tro ly OpenClaw' 69
Add-Label $connect 'Provider Base URL (HTTPS)' 24 116
$baseUrlBox = Add-TextBox $connect 'https://codex.anhlaptrinh.vn/v1' 113
Add-Label $connect 'Model' 24 160
$modelBox = Add-TextBox $connect 'gpt-6.1-sol' 157
Add-Label $connect 'Telegram Owner IDs' 24 204
$ownersBox = Add-TextBox $connect '' 201
Add-Label $connect 'Telegram Group ID' 24 248
$groupBox = Add-TextBox $connect '' 245
Add-Label $connect 'Gateway port (0 = tu dong)' 24 292
$portBox = Add-TextBox $connect '0' 289
Add-Note $connect 'Owner IDs la so Telegram duong tinh, ngan cach bang dau phay. Group ID phai la so am de tao group allowlist.' 342

$secret = New-Page 'Bao mat'
Add-Label $secret 'Telegram Bot Token' 24 42
$tokenBox = Add-TextBox $secret '' 39 $true
Add-Label $secret 'Provider API Key' 24 92
$apiKeyBox = Add-TextBox $secret '' 89 $true
Add-Note $secret 'Token va API key duoc luu rieng trong instance tren may de bot hoat dong. File trung gian duoc bao ve, xoa sau khi doc; khong dua secret vao command line hay log.' 150
Add-Note $secret 'Bot phai duoc tao boi BotFather. Neu dung trong group, sau cai vao BotFather -> /setprivacy -> Disable cho dung bot.' 245

$profile = New-Page 'Ho so'
Add-Label $profile 'Doi tuong phuc vu (tuy chon)' 24 42
$audienceBox = Add-TextBox $profile '' 39
Add-Label $profile 'Cach xung ho (tuy chon)' 24 92
$addressingBox = Add-TextBox $profile '' 89
Add-Label $profile 'Phong cach tra loi (tuy chon)' 24 142
$styleBox = Add-TextBox $profile '' 139
Add-Note $profile 'Profile basic-assistant-full se cai Telegram, media, tai lieu, web va cac skill Zalo V6 da dong goi.' 210
$fullAccessCheck = New-Object System.Windows.Forms.CheckBox
$fullAccessCheck.Text = 'Toi hieu va dong y cap Full Exec cho cac Owner IDs/group da nhap (mac dinh bat)'
$fullAccessCheck.Location = New-Object System.Drawing.Point(24, 290)
$fullAccessCheck.Size = New-Object System.Drawing.Size(650, 30)
$fullAccessCheck.Checked = $true
[void]$profile.Controls.Add($fullAccessCheck)
Add-Note $profile 'Full Exec co the doc, sua, xoa file va chay lenh tren may. Chi them bot vao group gom nhung nguoi duoc phep toan quyen.' 330

$zalo = New-Page 'Zalo'
$zaloCheck = New-Object System.Windows.Forms.CheckBox
$zaloCheck.Text = 'Cai plugin Zalo va lenh /zaloqr (bat buoc)'
$zaloCheck.Location = New-Object System.Drawing.Point(24, 42)
$zaloCheck.Size = New-Object System.Drawing.Size(650, 30)
$zaloCheck.Checked = $true
$zaloCheck.Enabled = $false
[void]$zalo.Controls.Add($zaloCheck)
Add-Label $zalo 'QR owner ID (tuy chon)' 24 92
$qrOwnerBox = Add-TextBox $zalo '' 89
Add-Note $zalo 'Sau khi cai, owner nhan /zaloqr trong Telegram rieng de nhan ma; /zalostatus duoc cai san de kiem tra sau khi anh quet QR.' 150
Add-Note $zalo 'Bo cai chi xac minh plugin va lenh QR da san sang, khong tu dong quet QR. Owner can nhan /start truoc; viec dang nhap Zalo kiem tra rieng bang /zalostatus.' 250

$installPage = New-Page 'Cai dat'
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'San sang. Bam Cai dat de bat dau.'
$statusLabel.Location = New-Object System.Drawing.Point(24, 42)
$statusLabel.Size = New-Object System.Drawing.Size(680, 68)
$statusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
[void]$installPage.Controls.Add($statusLabel)
Add-Note $installPage 'Installer se kiem tra provider /models, Telegram getMe, Gateway, plugin Zalo, /zaloqr va /zalostatus. Quet QR la buoc sau khi cai.' 130
Add-Note $installPage 'May Windows x64 can Internet va PowerShell 5.1. OpenClaw chay user-scope, gateway tu khoi dong an khi user dang nhap; khong dung Docker.' 215

$backButton = New-Object System.Windows.Forms.Button
$backButton.Text = 'Quay lai'
$backButton.Location = New-Object System.Drawing.Point(360, 520)
$backButton.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($backButton)
$nextButton = New-Object System.Windows.Forms.Button
$nextButton.Text = 'Tiep'
$nextButton.Location = New-Object System.Drawing.Point(480, 520)
$nextButton.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($nextButton)
$installButton = New-Object System.Windows.Forms.Button
$installButton.Text = 'Cai dat'
$installButton.Location = New-Object System.Drawing.Point(600, 520)
$installButton.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($installButton)
$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = 'Huy'
$cancelButton.Location = New-Object System.Drawing.Point(240, 520)
$cancelButton.Size = New-Object System.Drawing.Size(100, 32)
$form.Controls.Add($cancelButton)

$pages = @($connect, $secret, $profile, $zalo, $installPage)
$job = $null
$secretFile = $null
$statusFile = $null
$privateDir = $null
$safeLog = $null
$installRunning = $false
$resultCode = 1

function Show-Error([string]$Message) {
  [System.Windows.Forms.MessageBox]::Show($form, $Message, 'Khong the tiep tuc', 'OK', 'Warning') | Out-Null
}

function Test-Page([int]$Index) {
  if ($Index -eq 0) {
    if ([string]::IsNullOrWhiteSpace($nameBox.Text) -or $nameBox.Text -notmatch '^[a-z][a-z0-9_-]{0,63}$') { Show-Error 'Ten member phai viet thuong, bat dau bang chu cai.'; return $false }
    if ([string]::IsNullOrWhiteSpace($baseUrlBox.Text) -or $baseUrlBox.Text -notmatch '^https://') { Show-Error 'Provider Base URL phai bat dau bang https://.'; return $false }
    if ($modelBox.Text -notin @('gpt-6.1-sol','gpt-6.1-terra','gpt-6-astra')) { Show-Error 'Model phai la gpt-6.1-sol, gpt-6.1-terra hoac gpt-6-astra.'; return $false }
    if ($ownersBox.Text -notmatch '^[1-9][0-9]*(,[1-9][0-9]*)*$') { Show-Error 'Owner IDs khong hop le.'; return $false }
    if ($groupBox.Text -notmatch '^-[1-9][0-9]*$') { Show-Error 'Group ID phai la so am.'; return $false }
    $port = 0
    if (-not [int]::TryParse($portBox.Text, [ref]$port) -or ($port -ne 0 -and ($port -lt 1024 -or $port -gt 65000))) { Show-Error 'Gateway port phai la 0 hoac tu 1024 den 65000.'; return $false }
  }
  if ($Index -eq 1) {
    if ([string]::IsNullOrWhiteSpace($tokenBox.Text)) { Show-Error 'Hay nhap Telegram Bot Token.'; return $false }
    if ([string]::IsNullOrWhiteSpace($apiKeyBox.Text)) { Show-Error 'Hay nhap Provider API Key.'; return $false }
  }
  if ($Index -eq 2 -and -not $fullAccessCheck.Checked) {
    Show-Error 'Hay xac nhan ban hieu va chap nhan Full Exec cho owner/group tin cay.'
    return $false
  }
  if ($Index -eq 3 -and $zaloCheck.Checked) {
    if ([string]::IsNullOrWhiteSpace($qrOwnerBox.Text)) {
      $qrOwnerBox.Text = (($ownersBox.Text -split ',')[0]).Trim()
    }
    if ($qrOwnerBox.Text -notmatch '^[1-9][0-9]*$') { Show-Error 'QR owner ID phai la so duong.'; return $false }
    if ((',' + $ownersBox.Text + ',') -notmatch (',' + [regex]::Escape($qrOwnerBox.Text) + ',')) { Show-Error 'QR owner ID phai nam trong danh sach Owner IDs.'; return $false }
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
  if (-not (Test-Page 0) -or -not (Test-Page 1) -or -not (Test-Page 2) -or -not (Test-Page 3)) { return }
  $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Cac Owner IDs va moi thanh vien trong nhom Telegram da chon co the yeu cau doc, sua, xoa file va chay lenh tren may. Ban dong y va tin cay ho?', 'Xac nhan Full Exec', 'YesNo', 'Warning')
  if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  if ($zaloCheck.Checked) {
    $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Zalo duoc cai voi DM va nhom theo danh sach cho phep. Sau khi cai, owner nhan /zaloqr trong Telegram rieng de nhan QR. Ban dong y?', 'Xac nhan Zalo', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  }
  $script:installRunning = $true
  Set-Buttons
  $statusLabel.Text = 'Dang kiem tra va cai OpenClaw... co the mat vai phut.'
  try {
  $settings = [ordered]@{
    member = $nameBox.Text.Trim()
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
      $deadline = (Get-Date).AddMinutes(30)
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
    Show-Error 'Khong the tao thu muc tam rieng hoac khoi dong installer. Hay kiem tra quyen cua user Windows.'
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
      $statusLabel.Text = 'Cai dat hoan tat. /zaloqr va /zalostatus da san sang.'
      [System.Windows.Forms.MessageBox]::Show($form, 'OpenClaw da qua cac buoc kiem tra local. Hay nhan /zaloqr trong chat rieng Telegram, quet ma tren dien thoai va dung /zalostatus de kiem tra Zalo. Gateway chay an khi user Windows dang nhap.', 'Hoan tat buoc local', 'OK', 'Information') | Out-Null
      $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
      $form.Close()
    } else {
      $statusLabel.Text = 'Cai dat chua thanh cong. Instance dang do duoc giu nguyen.'
      Show-Error ("Cai dat chua thanh cong. $detail`n`nNeu instance da duoc tao mot phan, hay lien he ho tro thay vi ghi de.")
    }
    Set-Buttons
  }
})

$tab.Add_SelectedIndexChanged({ Set-Buttons })
$backButton.Add_Click({ if ($tab.SelectedIndex -gt 0) { $tab.SelectedIndex-- } })
$nextButton.Add_Click({ if (Test-Page $tab.SelectedIndex) { $tab.SelectedIndex++ } })
$installButton.Add_Click({ Start-Install })
$cancelButton.Add_Click({ Cleanup-Secret; $script:resultCode = 2; $form.Close() })
$form.Add_FormClosing({ if ($script:installRunning) { $_.Cancel = $true; Show-Error 'Cai dat dang chay; vui long doi den khi hoan tat.' } })

Set-Buttons
[void]$form.ShowDialog()
Cleanup-Secret
exit $script:resultCode
