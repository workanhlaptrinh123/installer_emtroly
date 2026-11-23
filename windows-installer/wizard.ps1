[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$PayloadRoot,
  [switch]$CodexMode,
  [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:singleInstanceMutex = $null
if (-not $SmokeTest -and $env:EMTROLY_ALLOW_MULTI_INSTANCE -ne '1') {
  $mutexName = if (-not [string]::IsNullOrWhiteSpace($env:EMTROLY_TEST_MUTEX_NAME)) {
    $env:EMTROLY_TEST_MUTEX_NAME.Trim()
  } else {
    'Local\EmTroLy-Wizard-SingleInstance'
  }
  $createdNew = $false
  $script:singleInstanceMutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
  if (-not $createdNew) {
    try { $script:singleInstanceMutex.Dispose() } catch { }
    $activatedExisting = $false
    try {
      if (-not ('EmTroLySingleInstanceFocus' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class EmTroLySingleInstanceFocus {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  public static bool ActivateExistingWindow(uint currentPid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((hWnd, lParam) => {
      uint pid;
      GetWindowThreadProcessId(hWnd, out pid);
      if (pid == currentPid || pid == 0) return true;
      if (!IsWindowVisible(hWnd) && !IsIconic(hWnd)) return true;
      var sb = new StringBuilder(256);
      if (GetWindowText(hWnd, sb, sb.Capacity) > 0) {
        string title = sb.ToString();
        if (title.StartsWith("Em Trợ Lý", StringComparison.OrdinalIgnoreCase)) {
          found = hWnd;
          return false;
        }
      }
      return true;
    }, IntPtr.Zero);
    if (found == IntPtr.Zero) return false;
    ShowWindow(found, IsIconic(found) ? 9 : 5);
    BringWindowToTop(found);
    SetForegroundWindow(found);
    return true;
  }
}
"@ -ErrorAction Stop
      }
      $activatedExisting = [EmTroLySingleInstanceFocus]::ActivateExistingWindow([uint32]$PID)
    } catch { }
    if (-not $activatedExisting -and $env:EMTROLY_SUPPRESS_SINGLE_INSTANCE_MSGBOX -ne '1') {
      [void][System.Windows.MessageBox]::Show(
        'Ứng dụng Em Trợ Lý đang mở sẵn trên màn hình. Hãy kiểm tra thanh tác vụ (Taskbar) bên dưới.',
        'Em Trợ Lý đang chạy',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
      )
    }
    exit 0
  }
}

function Resolve-HelperScript([string]$FileName) {
  $p = if ($PSScriptRoot) { Join-Path $PSScriptRoot $FileName } else { '' }
  if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Leaf)) {
    $p = Join-Path $PayloadRoot ('windows-installer\' + $FileName)
  }
  return $p
}

$codexHelperPath = Resolve-HelperScript 'codex-cli.ps1'
. ([ScriptBlock]::Create([IO.File]::ReadAllText($codexHelperPath, [System.Text.Encoding]::UTF8)))

$manageHelperPath = Resolve-HelperScript 'manage-instance.ps1'
. ([ScriptBlock]::Create([IO.File]::ReadAllText($manageHelperPath, [System.Text.Encoding]::UTF8)))

$autoHealHelperPath = Resolve-HelperScript 'auto-heal-codex.ps1'
if (Test-Path -LiteralPath $autoHealHelperPath -PathType Leaf) {
  . ([ScriptBlock]::Create([IO.File]::ReadAllText($autoHealHelperPath, [System.Text.Encoding]::UTF8)))
}

$wizardHelperPath = Resolve-HelperScript 'wizard-helpers.ps1'
if (Test-Path -LiteralPath $wizardHelperPath -PathType Leaf) {
  . ([ScriptBlock]::Create([IO.File]::ReadAllText($wizardHelperPath, [System.Text.Encoding]::UTF8)))
}

$uiFontFamily  = 'Segoe UI'
$appVersionObj = if (Get-Command Get-EmTroLyAppVersion -ErrorAction SilentlyContinue) {
  Get-EmTroLyAppVersion -PayloadRoot $PayloadRoot
} else {
  [pscustomobject]@{ InstallerVersion = '2026.11.21'; Display = 'v2026.11.21 · OpenClaw 2026.11.4' }
}

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Em Trợ Lý - Cài đặt"
        Width="1040" Height="760"
        MinWidth="980" MinHeight="700"
        WindowStartupLocation="CenterScreen"
        Background="#F4F7FB"
        FontFamily="Segoe UI"
        FontSize="13.5"
        Foreground="#0F172A"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType">

  <Window.Resources>
    <SolidColorBrush x:Key="BgCanvas" Color="#F4F7FB"/>
    <SolidColorBrush x:Key="BgCard" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="BgSubtle" Color="#F8FAFC"/>
    <SolidColorBrush x:Key="BgInfo" Color="#EFF6FF"/>
    <SolidColorBrush x:Key="BgSuccess" Color="#ECFDF5"/>
    <SolidColorBrush x:Key="BgWarn" Color="#FFFBEB"/>
    <SolidColorBrush x:Key="BgDanger" Color="#FEF2F2"/>
    <SolidColorBrush x:Key="BorderBrushLight" Color="#E2E8F0"/>
    <SolidColorBrush x:Key="BorderBrushInfo" Color="#BFDBFE"/>
    <SolidColorBrush x:Key="BorderBrushDanger" Color="#FECACA"/>
    <SolidColorBrush x:Key="PrimaryBrush" Color="#2563EB"/>
    <SolidColorBrush x:Key="PrimaryHover" Color="#1D4ED8"/>
    <SolidColorBrush x:Key="DangerBrush" Color="#DC2626"/>
    <SolidColorBrush x:Key="DangerHover" Color="#B91C1C"/>
    <SolidColorBrush x:Key="SuccessBrush" Color="#059669"/>
    <SolidColorBrush x:Key="WarnBrush" Color="#D97706"/>
    <SolidColorBrush x:Key="TextMain" Color="#0F172A"/>
    <SolidColorBrush x:Key="TextSub" Color="#64748B"/>

    <Style x:Key="CardBorder" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource BgCard}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrushLight}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="16,13"/>
    </Style>

    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource PrimaryBrush}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Height" Value="38"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource PrimaryHover}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.48"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SecondaryBtn" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource BgCard}"/>
      <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrushLight}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#F1F5F9"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SoftAccentBtn" TargetType="Button" BasedOn="{StaticResource SecondaryBtn}">
      <Setter Property="Background" Value="{StaticResource BgInfo}"/>
      <Setter Property="Foreground" Value="{StaticResource PrimaryBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrushInfo}"/>
    </Style>

    <Style x:Key="SoftDangerBtn" TargetType="Button" BasedOn="{StaticResource SecondaryBtn}">
      <Setter Property="Background" Value="{StaticResource BgDanger}"/>
      <Setter Property="Foreground" Value="{StaticResource DangerBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrushDanger}"/>
    </Style>

    <Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource PrimaryBtn}">
      <Setter Property="Background" Value="{StaticResource DangerBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource DangerHover}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.48"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#334155"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="Height" Value="42"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#F1F5F9"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ModernInput" TargetType="TextBox">
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#CBD5E1"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7">
              <ScrollViewer x:Name="PART_ContentHost" Margin="2,0" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#2563EB"/>
                <Setter TargetName="bd" Property="BorderThickness" Value="1.5"/>
              </Trigger>
              <Trigger Property="IsReadOnly" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#F8FAFC"/>
                <Setter Property="Foreground" Value="#475569"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ModernPassword" TargetType="PasswordBox">
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#CBD5E1"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7">
              <ScrollViewer x:Name="PART_ContentHost" Margin="2,0" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#2563EB"/>
                <Setter TargetName="bd" Property="BorderThickness" Value="1.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#334155"/>
      <Setter Property="Margin" Value="0,0,0,5"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="238"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- LEFT SIDEBAR -->
    <Border Grid.Column="0" Background="#FFFFFF" BorderBrush="#E2E8F0" BorderThickness="0,0,1,0">
      <DockPanel LastChildFill="True" Margin="14,16,14,16">
        <!-- Brand Logo -->
        <StackPanel DockPanel.Dock="Top" Margin="2,0,2,18">
          <Border Background="#FFFFFF" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="10" Padding="10,8" Margin="0,0,0,10">
            <Image x:Name="LogoImage" Height="46" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
          </Border>
          <TextBlock Text="Em Trợ Lý" FontSize="18" FontWeight="Bold" Foreground="#0F172A" Margin="4,0,0,0"/>
          <TextBlock Text="Trọn gói AI · Telegram · Zalo · Codex" FontSize="11.5" Foreground="#64748B" Margin="4,2,0,0"/>
        </StackPanel>

        <!-- Bottom Status & Version -->
        <StackPanel DockPanel.Dock="Bottom" Margin="2,12,2,0">
          <!-- License Verified Badge + Sign-out Option -->
          <Border x:Name="SidebarLicensePill" Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1" CornerRadius="8" Padding="10,6" Margin="0,0,0,4" Cursor="Hand" ToolTip="Bấm để đổi khóa kích hoạt bản quyền" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal">
              <Border Width="18" Height="18" CornerRadius="9" Background="#2563EB" VerticalAlignment="Center" Margin="0,0,8,0">
                <Path Data="M 4,9.2 L 7.4,12.5 L 14,5.6" Stroke="#FFFFFF" StrokeThickness="2.1" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
              </Border>
              <TextBlock Text="Bản quyền: Đã kích hoạt" FontSize="11.5" FontWeight="Bold" Foreground="#1E40AF" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Button x:Name="SidebarSignOutLicenseBtn" Style="{StaticResource SoftDangerBtn}" Content="Thoát bản quyền" Height="28" FontSize="11.5" Padding="10,2" Margin="0,0,0,6" Visibility="Collapsed" ToolTip="Thoát bản quyền giao diện (bắt buộc nhập lại Token codex.anhlaptrinh.vn, không dừng bot đang chạy)"/>
          <!-- Zalo Connected Icon Pill (Visible when installed & Zalo enabled) -->
          <Border x:Name="SidebarZaloPill" Background="#ECFDF5" BorderBrush="#6EE7B7" BorderThickness="1" CornerRadius="8" Padding="10,7" Margin="0,0,0,6" Cursor="Hand" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal">
              <Border x:Name="SidebarZaloIconCircle" Width="18" Height="18" CornerRadius="9" Background="#10B981" VerticalAlignment="Center" Margin="0,0,8,0">
                <Grid>
                  <Path x:Name="SidebarZaloCheckIcon" Data="M 4,9.2 L 7.4,12.5 L 14,5.6" Stroke="#FFFFFF" StrokeThickness="2.1" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                  <Ellipse x:Name="SidebarZaloPendingDot" Width="6" Height="6" Fill="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
                </Grid>
              </Border>
              <TextBlock x:Name="SidebarZaloText" Text="Zalo: Đã kết nối" FontSize="12" FontWeight="Bold" Foreground="#065F46" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Border x:Name="SidebarStatusPill" Background="#F1F5F9" CornerRadius="8" Padding="10,8" Margin="0,0,0,8">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="SidebarStatusDot" Width="8" Height="8" Fill="#94A3B8" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBlock x:Name="SidebarStatusText" Text="Chưa cài đặt" FontSize="12" FontWeight="SemiBold" Foreground="#475569"/>
            </StackPanel>
          </Border>
          <TextBlock x:Name="VersionText" Text="v2026.11.21 · Anh Lập Trình" FontSize="11" Foreground="#94A3B8" Margin="4,0,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>

        <!-- Navigation Buttons -->
        <StackPanel>
          <Button x:Name="NavHomeBtn" Style="{StaticResource NavBtn}" Content="  Cài đặt nhanh" Margin="0,0,0,4"/>
          <Button x:Name="NavModularBtn" Style="{StaticResource NavBtn}" Content="  Cài từng phần" Margin="0,0,0,4"/>
          <Button x:Name="NavConfigBtn" Style="{StaticResource NavBtn}" Content="  Tiến trình cài đặt" Margin="0,0,0,4"/>
          <Button x:Name="NavCodexBtn" Style="{StaticResource NavBtn}" Content="  Công cụ Codex CLI" Margin="0,0,0,4"/>
          <Button x:Name="NavDiagBtn" Style="{StaticResource NavBtn}" Content="  Chẩn đoán &amp; Hỗ trợ" Margin="0,0,0,4"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- RIGHT WORKSPACE -->
    <DockPanel Grid.Column="1" LastChildFill="True">
      <!-- Top Header -->
      <Border DockPanel.Dock="Top" Background="#FFFFFF" BorderBrush="#E2E8F0" BorderThickness="0,0,0,1" Padding="24,14">
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <Border x:Name="HeaderZaloBadge" Background="#ECFDF5" BorderBrush="#6EE7B7" BorderThickness="1" CornerRadius="16" Padding="11,5" Margin="0,0,10,0" VerticalAlignment="Center" Cursor="Hand" Visibility="Collapsed">
              <StackPanel Orientation="Horizontal">
                <Border Width="16" Height="16" CornerRadius="8" Background="#10B981" VerticalAlignment="Center" Margin="0,0,6,0">
                  <Path Data="M 3.5,8.2 L 6.6,11.2 L 12.6,5" Stroke="#FFFFFF" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                </Border>
                <TextBlock Text="Đã kết nối Zalo" FontSize="12" FontWeight="Bold" Foreground="#065F46" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <Button x:Name="HeaderQuickBtn" Style="{StaticResource SoftAccentBtn}" Content="Mở Codex CLI" VerticalAlignment="Center" MinWidth="136"/>
          </StackPanel>
          <StackPanel VerticalAlignment="Center">
            <TextBlock x:Name="HeaderTitle" Text="Cài đặt nhanh trọn gói A–Z" FontSize="19" FontWeight="Bold" Foreground="#0F172A"/>
            <TextBlock x:Name="HeaderSubtitle" Text="Nhập 4 thông tin cơ bản bên dưới rồi bấm Cài đặt — mọi thứ còn lại hoàn toàn tự động" FontSize="12.5" Foreground="#64748B" Margin="0,2,0,0"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <!-- Bottom Sticky Action Bar -->
      <Border DockPanel.Dock="Bottom" Background="#FFFFFF" BorderBrush="#E2E8F0" BorderThickness="0,1,0,0" Padding="24,12">
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="StopTaskBtn" Style="{StaticResource SoftDangerBtn}" Content="Dừng lại" MinWidth="112" Margin="0,0,10,0" Visibility="Collapsed"/>
            <Button x:Name="CancelBtn" Style="{StaticResource SecondaryBtn}" Content="Thoát" MinWidth="98" Margin="0,0,10,0"/>
            <Button x:Name="PrimaryActionBtn" Style="{StaticResource PrimaryBtn}" Content="Cài đặt trọn gói A–Z" MinWidth="172"/>
          </StackPanel>
          <TextBlock x:Name="FooterHintText" Text="Mẹo: Dán Bot Token rồi bấm Lấy ID tự động để khỏi cần tìm tay." FontSize="12.5" Foreground="#64748B" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,14,0"/>
        </DockPanel>
      </Border>

      <!-- CENTER CONTENT VIEWS -->
      <Grid Margin="22,16,22,16">

        <!-- VIEW A: LIVE 4-CARD DASHBOARD (Manage Mode Overview) -->
        <ScrollViewer x:Name="ViewDashboard" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel>
            <!-- Hero Summary Banner -->
            <Border Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1" CornerRadius="12" Padding="18,14" Margin="0,0,0,14">
              <DockPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                  <Button x:Name="DashOpenWebBtn" Style="{StaticResource SoftAccentBtn}" Content="Mở Dashboard Web" Margin="0,0,8,0"/>
                  <Button x:Name="DashRefreshBtn" Style="{StaticResource SecondaryBtn}" Content="Làm mới"/>
                </StackPanel>
                <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
                  <TextBlock x:Name="DashHeroTitle" Text="Trợ lý OpenClaw đang sẵn sàng trên máy" FontSize="15.5" FontWeight="Bold" Foreground="#1E3A8A"/>
                  <TextBlock x:Name="DashHeroSub" Text="Model: gpt-6.2-sol · Owner IDs: —" FontSize="12.5" Foreground="#3B82F6" Margin="0,3,0,0"/>
                </StackPanel>
              </DockPanel>
            </Border>

            <!-- 2x2 Status Cards -->
            <UniformGrid Columns="2" Margin="0,0,0,14">
              <!-- Card 1: Gateway -->
              <Border Style="{StaticResource CardBorder}" Margin="0,0,7,12">
                <DockPanel>
                  <Button x:Name="DashRestartBtn" DockPanel.Dock="Bottom" Style="{StaticResource SecondaryBtn}" Content="Kiểm tra &amp; Khởi động lại" HorizontalAlignment="Left" Margin="0,12,0,0"/>
                  <StackPanel>
                    <DockPanel Margin="0,0,0,6">
                      <Border x:Name="CardGwBadge" DockPanel.Dock="Right" Background="#ECFDF5" BorderBrush="#A7F3D0" BorderThickness="1" CornerRadius="10" Padding="8,2" VerticalAlignment="Center">
                        <TextBlock x:Name="CardGwBadgeText" Text="✓ Đang chạy" FontSize="11.5" FontWeight="Bold" Foreground="#065F46"/>
                      </Border>
                      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="CardGwDot" Width="10" Height="10" Fill="#059669" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <TextBlock Text="OpenClaw Gateway" FontSize="14.5" FontWeight="Bold"/>
                      </StackPanel>
                    </DockPanel>
                    <TextBlock x:Name="CardGwStatus" Text="Đang kiểm tra..." FontSize="12.5" Foreground="#475569" TextWrapping="Wrap"/>
                  </StackPanel>
                </DockPanel>
              </Border>

              <!-- Card 2: Telegram -->
              <Border Style="{StaticResource CardBorder}" Margin="7,0,0,12">
                <DockPanel>
                  <Button x:Name="DashEditConfigBtn" DockPanel.Dock="Bottom" Style="{StaticResource SoftAccentBtn}" Content="Đổi Owner ID / Bot Token" HorizontalAlignment="Left" Margin="0,12,0,0"/>
                  <StackPanel>
                    <DockPanel Margin="0,0,0,6">
                      <Border x:Name="CardTgBadge" DockPanel.Dock="Right" Background="#ECFDF5" BorderBrush="#A7F3D0" BorderThickness="1" CornerRadius="10" Padding="8,2" VerticalAlignment="Center">
                        <TextBlock x:Name="CardTgBadgeText" Text="✓ Đã kết nối" FontSize="11.5" FontWeight="Bold" Foreground="#065F46"/>
                      </Border>
                      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="CardTgDot" Width="10" Height="10" Fill="#059669" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <TextBlock Text="Kết nối Telegram Bot" FontSize="14.5" FontWeight="Bold"/>
                      </StackPanel>
                    </DockPanel>
                    <TextBlock x:Name="CardTgStatus" Text="Đang kiểm tra..." FontSize="12.5" Foreground="#475569" TextWrapping="Wrap"/>
                  </StackPanel>
                </DockPanel>
              </Border>

              <!-- Card 3: Zalo -->
              <Border x:Name="CardZaloBorder" Style="{StaticResource CardBorder}" Margin="0,0,7,0">
                <DockPanel>
                  <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,12,0,0">
                    <Button x:Name="DashZaloQrBtn" Style="{StaticResource SoftAccentBtn}" Content="Quét QR Zalo" Margin="0,0,8,0"/>
                    <Button x:Name="DashZaloBtn" Style="{StaticResource SecondaryBtn}" Content="Cài / Đồng bộ lại"/>
                  </StackPanel>
                  <StackPanel>
                    <DockPanel Margin="0,0,0,6">
                      <Border x:Name="CardZaloBadge" DockPanel.Dock="Right" Background="#ECFDF5" BorderBrush="#6EE7B7" BorderThickness="1" CornerRadius="11" Padding="9,3" VerticalAlignment="Center">
                        <StackPanel Orientation="Horizontal">
                          <Border x:Name="CardZaloBadgeIcon" Width="14" Height="14" CornerRadius="7" Background="#10B981" VerticalAlignment="Center" Margin="0,0,5,0">
                            <Path Data="M 3,7.2 L 5.8,9.8 L 11,4.4" Stroke="#FFFFFF" StrokeThickness="1.9" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                          </Border>
                          <TextBlock x:Name="CardZaloBadgeText" Text="Đã kết nối" FontSize="11.5" FontWeight="Bold" Foreground="#065F46" VerticalAlignment="Center"/>
                        </StackPanel>
                      </Border>
                      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="CardZaloDot" Width="10" Height="10" Fill="#059669" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <TextBlock Text="Zalo cá nhân (/zaloqr)" FontSize="14.5" FontWeight="Bold"/>
                      </StackPanel>
                    </DockPanel>
                    <TextBlock x:Name="CardZaloStatus" Text="Đang kiểm tra..." FontSize="12.5" Foreground="#475569" TextWrapping="Wrap"/>
                  </StackPanel>
                </DockPanel>
              </Border>

              <!-- Card 4: Antigravity & Codex -->
              <Border Style="{StaticResource CardBorder}" Margin="7,0,0,0">
                <DockPanel>
                  <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,12,0,0">
                    <Button x:Name="DashCodexRepairBtn" Style="{StaticResource SecondaryBtn}" Content="Cài / Sửa Antigravity" Padding="12,7" Margin="0,0,8,0"/>
                    <Button x:Name="DashOpenCodexBtn" Style="{StaticResource SoftAccentBtn}" Content="Dùng Codex CLI" Padding="12,7"/>
                  </StackPanel>
                  <StackPanel>
                    <DockPanel Margin="0,0,0,6">
                      <Border x:Name="CardCodexBadge" DockPanel.Dock="Right" Background="#ECFDF5" BorderBrush="#A7F3D0" BorderThickness="1" CornerRadius="10" Padding="8,2" VerticalAlignment="Center">
                        <TextBlock x:Name="CardCodexBadgeText" Text="✓ Sẵn sàng" FontSize="11.5" FontWeight="Bold" Foreground="#065F46"/>
                      </Border>
                      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse x:Name="CardCodexDot" Width="10" Height="10" Fill="#059669" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <TextBlock Text="Antigravity IDE &amp; Codex CLI" FontSize="14.5" FontWeight="Bold"/>
                      </StackPanel>
                    </DockPanel>
                    <TextBlock x:Name="CardCodexStatus" Text="Đang kiểm tra..." FontSize="12.5" Foreground="#475569" TextWrapping="Wrap"/>
                  </StackPanel>
                </DockPanel>
              </Border>
            </UniformGrid>

            <!-- Quick Maintenance Strip -->
            <Border Style="{StaticResource CardBorder}">
              <DockPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                  <Button x:Name="DashAutoHealBtn" Style="{StaticResource PrimaryBtn}" Content="Tự sửa lỗi bằng Codex" Margin="0,0,8,0"/>
                  <Button x:Name="DashExportBtn" Style="{StaticResource SecondaryBtn}" Content="Xuất báo cáo hỗ trợ"/>
                </StackPanel>
                <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
                  <TextBlock Text="Sửa lỗi tự động &amp; Hỗ trợ nhanh" FontSize="14" FontWeight="Bold"/>
                  <TextBlock Text="Trợ lý gặp trục trặc? Để Codex CLI tự kiểm tra log và khắc phục ngay, không mất dữ liệu cũ." FontSize="12.5" Foreground="#64748B" Margin="0,2,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </DockPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- VIEW B: SETUP & QUICK-EDIT FORM (Shared single source of truth!) -->
        <ScrollViewer x:Name="ViewSetupForm" VerticalScrollBarVisibility="Auto" Visibility="Visible">
          <StackPanel>
            <!-- Mode Notice Banner (Visible in Manage Mode) -->
            <Border x:Name="ManageEditBanner" Background="#ECFDF5" BorderBrush="#A7F3D0" BorderThickness="1" CornerRadius="10" Padding="14,10" Margin="0,0,0,12" Visibility="Collapsed">
              <TextBlock Text="✓ Chế độ Chỉnh sửa nhanh: Chỉ cần sửa ô bạn muốn đổi rồi bấm Lưu thay đổi (~3 giây). Bot Token &amp; API Key có thể để trống để giữ nguyên mã cũ." FontSize="12.5" FontWeight="SemiBold" Foreground="#065F46" TextWrapping="Wrap"/>
            </Border>

            <!-- Saved Draft Notice Banner (Visible in Fresh Install when previous inputs were restored) -->
            <Border x:Name="SavedDraftBanner" Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1" CornerRadius="10" Padding="14,9" Margin="0,0,0,12" Visibility="Collapsed">
              <DockPanel>
                <Button x:Name="ClearSavedDraftBtn" DockPanel.Dock="Right" Style="{StaticResource SecondaryBtn}" Content="Xóa thông số đã lưu" Height="28" Padding="10,2" FontSize="12" Margin="10,0,0,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="SavedDraftBannerText" Text="✓ Đã tự động điền lại các thông số bạn đã nhập ở lần trước (lưu mã hóa an toàn trên máy)." FontSize="12.5" FontWeight="SemiBold" Foreground="#1E40AF" TextWrapping="Wrap" VerticalAlignment="Center"/>
              </DockPanel>
            </Border>

            <!-- Card 1: 4 Essential Inputs -->
            <Border Style="{StaticResource CardBorder}" Margin="0,0,0,12">
              <StackPanel>
                <DockPanel Margin="0,0,0,12">
                  <CheckBox x:Name="ShowSecretCheck" DockPanel.Dock="Right" Content="Hiện mã bí mật" VerticalAlignment="Center" FontSize="12.5" Foreground="#475569"/>
                  <TextBlock Text="1. Thông tin kết nối bắt buộc" FontSize="15" FontWeight="Bold"/>
                </DockPanel>

                <!-- Bot Token + Auto-fetch IDs -->
                <TextBlock x:Name="TokenFieldLabel" Style="{StaticResource FieldLabel}" Text="Telegram Bot Token (tạo qua @BotFather)"/>
                <Grid Margin="0,0,0,10">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <Grid Grid.Column="0">
                    <PasswordBox x:Name="TokenPwdBox" Style="{StaticResource ModernPassword}"/>
                    <TextBox x:Name="TokenPlainBox" Style="{StaticResource ModernInput}" Visibility="Collapsed"/>
                  </Grid>
                  <Button x:Name="AutoFetchIdBtn" Grid.Column="1" Style="{StaticResource SoftAccentBtn}" Content="Lấy ID tự động" Margin="10,0,0,0" MinWidth="136"/>
                </Grid>

                <!-- API Key + Test Connection -->
                <TextBlock x:Name="ApiKeyFieldLabel" Style="{StaticResource FieldLabel}" Text="Provider API Key (dùng chung cho OpenClaw &amp; Codex CLI)"/>
                <Grid Margin="0,0,0,10">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <Grid Grid.Column="0">
                    <PasswordBox x:Name="ApiKeyPwdBox" Style="{StaticResource ModernPassword}"/>
                    <TextBox x:Name="ApiKeyPlainBox" Style="{StaticResource ModernInput}" Visibility="Collapsed"/>
                  </Grid>
                  <Button x:Name="TestConnBtn" Grid.Column="1" Style="{StaticResource SecondaryBtn}" Content="Kiểm tra kết nối" Margin="10,0,0,0" MinWidth="136"/>
                </Grid>

                <!-- Live Verification Feedback Pill -->
                <Border x:Name="LiveCheckBanner" Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="8" Padding="12,8" Margin="0,0,0,12" Visibility="Collapsed">
                  <TextBlock x:Name="LiveCheckText" Text="" FontSize="12.5" Foreground="#334155" TextWrapping="Wrap"/>
                </Border>

                <!-- 2-Column Row: Owner IDs & Group ID -->
                <Grid Margin="0,0,0,10">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="14"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0">
                    <TextBlock Style="{StaticResource FieldLabel}" Text="Telegram Owner IDs (số dương, cách bởi dấu phẩy)"/>
                    <TextBox x:Name="OwnersBox" Style="{StaticResource ModernInput}"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2">
                    <TextBlock Style="{StaticResource FieldLabel}" Text="Telegram Group ID (số âm, ví dụ: -1001234567890)"/>
                    <TextBox x:Name="GroupBox" Style="{StaticResource ModernInput}"/>
                  </StackPanel>
                </Grid>

                <!-- Model Selection -->
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="14"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0">
                    <TextBlock Style="{StaticResource FieldLabel}" Text="Mô hình AI mặc định (Model)"/>
                    <ComboBox x:Name="ModelBox" Height="36" FontFamily="Segoe UI" FontSize="13.5" Padding="10,6" VerticalContentAlignment="Center"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2">
                    <TextBlock Style="{StaticResource FieldLabel}" Text="Tên trợ lý hiển thị"/>
                    <TextBox x:Name="AssistantBox" Style="{StaticResource ModernInput}" Text="Trợ lý OpenClaw"/>
                  </StackPanel>
                </Grid>
              </StackPanel>
            </Border>

            <!-- Card 2: Options & Consent -->
            <Border x:Name="InstallOptionsCard" Style="{StaticResource CardBorder}" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock Text="2. Tùy chọn cài đặt trọn gói A–Z" FontSize="15" FontWeight="Bold" Margin="0,0,0,10"/>
                <CheckBox x:Name="ZaloCheck" Content="Cài đặt Zalo cá nhân &amp; lệnh quét mã /zaloqr (bỏ tích nếu không cần Zalo)" FontSize="13.5" FontWeight="SemiBold" Margin="0,0,0,8"/>
                <Border Background="#ECFDF5" BorderBrush="#A7F3D0" BorderThickness="1" CornerRadius="8" Padding="11,7" Margin="0,0,0,10">
                  <TextBlock Text="✓ Ưu tiên cài đặt Codex CLI → Antigravity IDE → Codex Extension trước tiên để nếu gặp lỗi trong lúc cài, Codex CLI sẽ tự động khắc phục ngay." FontSize="12.5" FontWeight="SemiBold" Foreground="#065F46" TextWrapping="Wrap"/>
                </Border>
                <Border Background="#FFFBEB" BorderBrush="#FDE68A" BorderThickness="1" CornerRadius="8" Padding="12,10">
                  <StackPanel>
                    <CheckBox x:Name="FullAccessCheck" Content="Tôi hiểu và đồng ý cấp quyền Full Exec cho Owner &amp; nhóm Telegram đã chọn" FontSize="13" FontWeight="Bold" Foreground="#92400E"/>
                    <TextBlock Text="Quyền Full Exec cho phép trợ lý đọc, sửa tệp và chạy lệnh trên máy theo yêu cầu. Chỉ thêm người tin cậy vào nhóm." FontSize="12" Foreground="#B45309" Margin="22,4,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Border>

            <!-- Card 3: Collapsible Advanced Settings -->
            <Border Style="{StaticResource CardBorder}">
              <Expander x:Name="AdvancedExpander" Header="Tùy chỉnh nâng cao (Hồ sơ giao tiếp, cổng Gateway, QR Owner, URL máy chủ)" FontSize="13.5" FontWeight="SemiBold" Foreground="#334155" IsExpanded="False">
                <StackPanel Margin="0,12,0,0">
                  <Grid Margin="0,0,0,10">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="2*"/>
                      <ColumnDefinition Width="14"/>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="14"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="Địa chỉ máy chủ AI (HTTPS)"/>
                      <TextBox x:Name="BaseUrlBox" Style="{StaticResource ModernInput}" Text="https://codex.anhlaptrinh.vn/v1" IsReadOnly="True"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="Cổng Gateway (0 = tự động)"/>
                      <TextBox x:Name="PortBox" Style="{StaticResource ModernInput}" Text="0"/>
                    </StackPanel>
                    <StackPanel Grid.Column="4">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="Owner ID nhận QR Zalo"/>
                      <TextBox x:Name="QrOwnerBox" Style="{StaticResource ModernInput}"/>
                    </StackPanel>
                  </Grid>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="12"/>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="12"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="Đối tượng phục vụ (tùy chọn)"/>
                      <TextBox x:Name="AudienceBox" Style="{StaticResource ModernInput}"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="Cách xưng hô (tùy chọn)"/>
                      <TextBox x:Name="AddressingBox" Style="{StaticResource ModernInput}"/>
                    </StackPanel>
                    <StackPanel Grid.Column="4">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="Phong cách trả lời (tùy chọn)"/>
                      <TextBox x:Name="StyleBox" Style="{StaticResource ModernInput}"/>
                    </StackPanel>
                  </Grid>
                  <CheckBox x:Name="ExistingEditorCheck" Content="Bỏ qua cài đặt Antigravity IDE (vẫn luôn cài đặt Codex CLI để tự sửa lỗi cài đặt)" FontSize="12.5" Foreground="#64748B" Margin="0,12,0,0"/>
                </StackPanel>
              </Expander>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- VIEW C: LIVE 5-STEP PROGRESS CHECKLIST & AUTO-HEAL -->
        <ScrollViewer x:Name="ViewProgress" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel>
            <!-- Status Banner + Progress Bar -->
            <Border x:Name="ProgressCard" Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1" CornerRadius="12" Padding="18,16" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock x:Name="CoreReadyText" Text="" FontSize="13" FontWeight="SemiBold" Foreground="#059669" Margin="0,0,0,4" Visibility="Collapsed"/>
                <DockPanel Margin="0,0,0,10">
                  <TextBlock x:Name="ProgressPercentText" DockPanel.Dock="Right" Text="0%" FontSize="15" FontWeight="Bold" Foreground="#2563EB" VerticalAlignment="Center"/>
                  <TextBlock x:Name="StatusText" Text="Mọi thứ đã sẵn sàng. Bấm Cài đặt trọn gói A–Z để bắt đầu." FontSize="14.5" FontWeight="Bold" Foreground="#0F172A" TextWrapping="Wrap" Margin="0,0,12,0"/>
                </DockPanel>
                <ProgressBar x:Name="InstallProgressBar" Height="10" Minimum="0" Maximum="100" Value="0" Foreground="#2563EB" Background="#DBEAFE" BorderThickness="0"/>
              </StackPanel>
            </Border>

            <!-- 5-Step Checklist Card -->
            <Border x:Name="InstallChecklistCard" Style="{StaticResource CardBorder}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Tiến trình tự động từ A–Z" FontSize="14.5" FontWeight="Bold" Margin="0,0,0,12"/>
                <Grid Margin="0,0,0,9">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="Step1Icon" Grid.Column="0" Text="○" FontSize="15" FontWeight="Bold" Foreground="#94A3B8" VerticalAlignment="Center"/>
                  <TextBlock x:Name="Step1Text" Grid.Column="1" Text="Bước 1 · Kiểm tra kết nối API &amp; Bot Telegram" FontSize="13.5" Foreground="#334155" VerticalAlignment="Center"/>
                  <TextBlock x:Name="Step1Badge" Grid.Column="2" Text="Chờ thực hiện" FontSize="12" Foreground="#94A3B8" VerticalAlignment="Center"/>
                </Grid>
                <Grid Margin="0,0,0,9">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="Step2Icon" Grid.Column="0" Text="○" FontSize="15" FontWeight="Bold" Foreground="#94A3B8" VerticalAlignment="Center"/>
                  <TextBlock x:Name="Step2Text" Grid.Column="1" Text="Bước 2 · Ưu tiên cài Codex CLI → Antigravity IDE → Codex Extension" FontSize="13.5" Foreground="#334155" VerticalAlignment="Center"/>
                  <TextBlock x:Name="Step2Badge" Grid.Column="2" Text="Chờ thực hiện" FontSize="12" Foreground="#94A3B8" VerticalAlignment="Center"/>
                </Grid>
                <Grid Margin="0,0,0,9">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="Step3Icon" Grid.Column="0" Text="○" FontSize="15" FontWeight="Bold" Foreground="#94A3B8" VerticalAlignment="Center"/>
                  <TextBlock x:Name="Step3Text" Grid.Column="1" Text="Bước 3 · Chuẩn bị môi trường (Node.js, Python, FFmpeg)" FontSize="13.5" Foreground="#334155" VerticalAlignment="Center"/>
                  <TextBlock x:Name="Step3Badge" Grid.Column="2" Text="Chờ thực hiện" FontSize="12" Foreground="#94A3B8" VerticalAlignment="Center"/>
                </Grid>
                <Grid Margin="0,0,0,9">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="Step4Icon" Grid.Column="0" Text="○" FontSize="15" FontWeight="Bold" Foreground="#94A3B8" VerticalAlignment="Center"/>
                  <TextBlock x:Name="Step4Text" Grid.Column="1" Text="Bước 4 · Cài OpenClaw, tạo ảnh, kỹ năng văn phòng &amp; Gateway" FontSize="13.5" Foreground="#334155" VerticalAlignment="Center"/>
                  <TextBlock x:Name="Step4Badge" Grid.Column="2" Text="Chờ thực hiện" FontSize="12" Foreground="#94A3B8" VerticalAlignment="Center"/>
                </Grid>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="Step5Icon" Grid.Column="0" Text="○" FontSize="15" FontWeight="Bold" Foreground="#94A3B8" VerticalAlignment="Center"/>
                  <TextBlock x:Name="Step5Text" Grid.Column="1" Text="Bước 5 · Cài đặt Zalo cá nhân &amp; lệnh /zaloqr, /zalostatus" FontSize="13.5" Foreground="#334155" VerticalAlignment="Center"/>
                  <TextBlock x:Name="Step5Badge" Grid.Column="2" Text="Chờ thực hiện" FontSize="12" Foreground="#94A3B8" VerticalAlignment="Center"/>
                </Grid>
              </StackPanel>
            </Border>

            <!-- Auto-Heal Note + Retry/Manual Auto-Heal Controls -->
            <Border x:Name="AutoHealNoteBorder" Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="10" Padding="14,10" Margin="0,0,0,12">
              <TextBlock x:Name="AutoHealProgressNote" Text="Tự động sửa lỗi (Auto-Heal): Bộ cài luôn cài đặt Codex CLI trước tiên — nếu gặp sự cố ở bất kỳ bước nào tiếp theo, Codex CLI sẽ tự chẩn đoán và khắc phục ngay." FontSize="12.5" Foreground="#475569" TextWrapping="Wrap"/>
            </Border>

            <!-- Retry Codex Key Panel (Only when $retryEditor) -->
            <Border x:Name="RetryEditorPanel" Style="{StaticResource CardBorder}" Margin="0,0,0,12" Visibility="Collapsed">
              <StackPanel>
                <TextBlock Style="{StaticResource FieldLabel}" Text="Nhập Khóa API để tiếp tục cài Antigravity &amp; Codex CLI:"/>
                <PasswordBox x:Name="RetryKeyPwdBox" Style="{StaticResource ModernPassword}"/>
              </StackPanel>
            </Border>

            <!-- Rich In-Place Error & Diagnostic Card (Shown directly in GUI on any install / auto-heal failure) -->
            <Border x:Name="InstallFailureActions" Background="#FFFFFF" BorderBrush="#FCA5A5" BorderThickness="1.5" CornerRadius="12" Padding="18,15" Margin="0,0,0,12" Visibility="Collapsed">
              <StackPanel>
                <!-- Header Row: Badge + Quick Copy / Open Codex CLI -->
                <DockPanel Margin="0,0,0,10">
                  <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="BtnCopyErrorDetail" Style="{StaticResource SecondaryBtn}" Content="Sao chép lỗi" Height="30" Padding="11,3" FontSize="12" Margin="0,0,8,0"/>
                    <Button x:Name="BtnOpenCodexFromError" Style="{StaticResource SoftAccentBtn}" Content="Mở Công cụ Codex CLI →" Height="30" Padding="11,3" FontSize="12"/>
                  </StackPanel>
                  <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Background="#FEF2F2" BorderBrush="#FECACA" BorderThickness="1" CornerRadius="12" Padding="10,3" Margin="0,0,8,0">
                      <StackPanel Orientation="Horizontal">
                        <Ellipse Width="7" Height="7" Fill="#DC2626" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <TextBlock Text="CHI TIẾT SỰ CỐ &amp; CHẨN ĐOÁN" FontSize="11" FontWeight="Bold" Foreground="#B91C1C" VerticalAlignment="Center"/>
                      </StackPanel>
                    </Border>
                    <Border x:Name="ErrorStepPill" Background="#FFFBEB" BorderBrush="#FDE68A" BorderThickness="1" CornerRadius="10" Padding="8,2" VerticalAlignment="Center">
                      <TextBlock x:Name="ErrorStepText" Text="Cần kiểm tra" FontSize="11.5" FontWeight="SemiBold" Foreground="#B45309"/>
                    </Border>
                  </StackPanel>
                </DockPanel>

                <!-- Friendly Cause Explanation -->
                <TextBlock x:Name="ErrorSummaryHeading" Text="Nguyên nhân ghi nhận trên máy:" FontSize="13.5" FontWeight="Bold" Foreground="#991B1B" TextWrapping="Wrap" Margin="0,0,0,8"/>

                <!-- Scrollable Technical & Codex Log Viewer -->
                <Border Background="#FFF8F8" BorderBrush="#FECACA" BorderThickness="1" CornerRadius="8" Padding="2" Margin="0,0,0,11">
                  <TextBox x:Name="ErrorDetailBox" FontFamily="Segoe UI" FontSize="12.5" Foreground="#1E293B" Background="Transparent" BorderThickness="0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" MaxHeight="126" Padding="10,7"/>
                </Border>

                <!-- Action Buttons -->
                <WrapPanel>
                  <Button x:Name="BtnInstallAutoHeal" Style="{StaticResource PrimaryBtn}" Content="Tự sửa lỗi bằng Codex" Margin="0,0,10,6"/>
                  <Button x:Name="BtnBackToSetup" Style="{StaticResource SecondaryBtn}" Content="Quay lại kiểm tra cấu hình" Margin="0,0,10,6"/>
                  <Button x:Name="BtnProgressExport" Style="{StaticResource SecondaryBtn}" Content="Xuất báo cáo hỗ trợ (.txt)" Margin="0,0,0,6"/>
                </WrapPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- VIEW D: CODEX CLI WORKSPACE -->
        <Grid x:Name="ViewCodex" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <!-- Workspace Bar -->
          <Border Grid.Row="0" Style="{StaticResource CardBorder}" Margin="0,0,0,12" Padding="16,12">
            <StackPanel>
              <DockPanel Margin="0,0,0,8">
                <TextBlock x:Name="CodexStateText" DockPanel.Dock="Right" Text="Đang kiểm tra Codex CLI..." FontSize="12.5" FontWeight="SemiBold" Foreground="#059669" VerticalAlignment="Center"/>
                <TextBlock Text="Thư mục làm việc của Codex CLI" FontSize="13.5" FontWeight="Bold"/>
              </DockPanel>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="CodexDirBox" Grid.Column="0" Style="{StaticResource ModernInput}"/>
                <Button x:Name="CodexBrowseBtn" Grid.Column="1" Style="{StaticResource SecondaryBtn}" Content="Chọn thư mục..." Margin="8,0,0,0"/>
                <Button x:Name="CodexOpenDirBtn" Grid.Column="2" Style="{StaticResource SecondaryBtn}" Content="Mở" Margin="6,0,0,0" MinWidth="56"/>
                <Button x:Name="CodexTerminalBtn" Grid.Column="3" Style="{StaticResource SoftAccentBtn}" Content="Mở cửa sổ lệnh" Margin="6,0,0,0"/>
              </Grid>
            </StackPanel>
          </Border>

          <!-- Prompt Input Card -->
          <Border Grid.Row="1" Style="{StaticResource CardBorder}" Margin="0,0,0,12" Padding="16,12">
            <StackPanel>
              <DockPanel Margin="0,0,0,8">
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                  <Button x:Name="PresetConfigBtn" Style="{StaticResource SoftAccentBtn}" Content="Kiểm tra cấu hình" Height="28" Padding="10,2" FontSize="12" Margin="0,0,6,0"/>
                  <Button x:Name="PresetSkillBtn" Style="{StaticResource SoftAccentBtn}" Content="Sửa kỹ năng" Height="28" Padding="10,2" FontSize="12" Margin="0,0,6,0"/>
                  <Button x:Name="PresetFixBtn" Style="{StaticResource SoftAccentBtn}" Content="Tự tìm &amp; sửa lỗi" Height="28" Padding="10,2" FontSize="12"/>
                </StackPanel>
                <TextBlock Text="Yêu cầu tiếng Việt cho Codex CLI" FontSize="13.5" FontWeight="Bold" VerticalAlignment="Center"/>
              </DockPanel>
              <TextBox x:Name="CodexPromptBox" FontFamily="Segoe UI" FontSize="13.5" Height="74" TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" Padding="10,8" BorderBrush="#CBD5E1" BorderThickness="1"/>
              <DockPanel Margin="0,10,0,0">
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                  <Button x:Name="CodexClearBtn" Style="{StaticResource SecondaryBtn}" Content="Xóa kết quả" Margin="0,0,8,0"/>
                  <Button x:Name="CodexStopBtn" Style="{StaticResource SoftDangerBtn}" Content="Dừng" Margin="0,0,8,0" IsEnabled="False"/>
                  <Button x:Name="CodexRunBtn" Style="{StaticResource PrimaryBtn}" Content="Thực hiện bằng Codex"/>
                </StackPanel>
                <CheckBox x:Name="CodexWriteCheck" Content="Cho phép Codex sửa tệp trực tiếp" IsChecked="True" VerticalAlignment="Center" FontSize="12.5" Foreground="#334155"/>
              </DockPanel>
            </StackPanel>
          </Border>

          <!-- Streaming Output Card -->
          <Border Grid.Row="2" Style="{StaticResource CardBorder}" Padding="14,12">
            <DockPanel>
              <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                <Button x:Name="CodexRefreshBtn" DockPanel.Dock="Right" Style="{StaticResource SecondaryBtn}" Content="Làm mới" Height="28" Padding="10,2" FontSize="12"/>
                <TextBlock Text="Kết quả thực hiện" FontSize="13" FontWeight="Bold" VerticalAlignment="Center"/>
              </DockPanel>
              <TextBox x:Name="CodexOutputBox" FontFamily="Segoe UI" FontSize="13" Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="1" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Padding="10,8"/>
            </DockPanel>
          </Border>
        </Grid>

        <!-- VIEW E: DIAGNOSTICS, PRE-FLIGHT & SUPPORT -->
        <ScrollViewer x:Name="ViewDiagnostics" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel>
            <!-- Pre-flight Check Card -->
            <Border Style="{StaticResource CardBorder}" Margin="0,0,0,14">
              <StackPanel>
                <DockPanel Margin="0,0,0,12">
                  <Button x:Name="RunPreflightBtn" DockPanel.Dock="Right" Style="{StaticResource SoftAccentBtn}" Content="Kiểm tra hệ thống ngay"/>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Kiểm tra máy &amp; kết nối mạng (Pre-flight)" FontSize="15" FontWeight="Bold"/>
                    <TextBlock Text="Kiểm tra Windows x64, ổ đĩa trống và đường truyền tới Telegram / AI / Node.js" FontSize="12.5" Foreground="#64748B" Margin="0,2,0,0"/>
                  </StackPanel>
                </DockPanel>
                <StackPanel x:Name="PreflightListPanel">
                  <TextBlock Text="Bấm nút Kiểm tra hệ thống ngay để quét nhanh tình trạng máy." FontSize="13" Foreground="#64748B"/>
                </StackPanel>
              </StackPanel>
            </Border>

            <!-- Auto-Heal & Component Tools -->
            <Border Style="{StaticResource CardBorder}" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Tự động sửa lỗi &amp; Khôi phục từng phần" FontSize="15" FontWeight="Bold" Margin="0,0,0,6"/>
                <TextBlock Text="An toàn tuyệt đối: giữ nguyên dữ liệu cấu hình và lịch sử trò chuyện cũ trên máy." FontSize="12.5" Foreground="#64748B" Margin="0,0,0,12"/>
                <WrapPanel>
                  <Button x:Name="DiagAutoHealBtn" Style="{StaticResource PrimaryBtn}" Content="Tự sửa lỗi bằng Codex" Margin="0,0,10,8"/>
                  <Button x:Name="DiagRestartBtn" Style="{StaticResource SecondaryBtn}" Content="Khởi động lại Gateway" Margin="0,0,10,8"/>
                  <Button x:Name="DiagZaloQrBtn" Style="{StaticResource SoftAccentBtn}" Content="Lấy mã QR Zalo" Margin="0,0,10,8"/>
                  <Button x:Name="DiagZaloBtn" Style="{StaticResource SecondaryBtn}" Content="Cài / Đồng bộ Zalo" Margin="0,0,10,8"/>
                  <Button x:Name="DiagCodexBtn" Style="{StaticResource SecondaryBtn}" Content="Cài / Sửa Antigravity &amp; Codex" Margin="0,0,10,8"/>
                  <Button x:Name="DiagUninstallBtn" Style="{StaticResource SoftDangerBtn}" Content="Gỡ trợ lý để cài lại" Margin="0,0,10,8"/>
                </WrapPanel>
              </StackPanel>
            </Border>

            <!-- Support Export & Desktop Shortcut -->
            <Border Style="{StaticResource CardBorder}">
              <StackPanel>
                <TextBlock Text="Hỗ trợ kỹ thuật &amp; Lối tắt ứng dụng" FontSize="15" FontWeight="Bold" Margin="0,0,0,6"/>
                <TextBlock Text="File báo cáo hỗ trợ đã tự động ẩn toàn bộ Bot Token, API Key và Gateway Token trước khi xuất." FontSize="12.5" Foreground="#64748B" Margin="0,0,0,12"/>
                <WrapPanel>
                  <Button x:Name="DiagExportBtn" Style="{StaticResource SoftAccentBtn}" Content="Xuất báo cáo hỗ trợ (.txt)" Margin="0,0,10,6"/>
                  <Button x:Name="DiagShortcutBtn" Style="{StaticResource SecondaryBtn}" Content="Tạo lối tắt trên Desktop" Margin="0,0,10,6"/>
                  <Button x:Name="DiagChangeLicenseBtn" Style="{StaticResource SecondaryBtn}" Content="Đổi khóa bản quyền" Margin="0,0,10,6"/>
                  <Button x:Name="DiagSignOutLicenseBtn" Style="{StaticResource SoftDangerBtn}" Content="Thoát bản quyền" Margin="0,0,0,6"/>
                </WrapPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- VIEW G: MODULAR STEP-BY-STEP COMPONENT INSTALLER -->
        <ScrollViewer x:Name="ViewModular" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel>
            <!-- Top Info & Shared Model Selector -->
            <Border Style="{StaticResource CardBorder}" Padding="16,14" Margin="0,0,0,12">
              <DockPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="Model:" FontSize="12.5" FontWeight="SemiBold" Foreground="#334155" VerticalAlignment="Center" Margin="0,0,8,0"/>
                  <ComboBox x:Name="ModModelBox" Width="148" Height="32" FontFamily="Segoe UI" FontSize="12.5" Padding="8,4" VerticalContentAlignment="Center" Margin="0,0,8,0"/>
                  <Button x:Name="ModSelectAllBtn" Style="{StaticResource SecondaryBtn}" Content="Chọn phần 1–3" Height="32" Padding="10,4" FontSize="12" Margin="0,0,8,0"/>
                  <Button x:Name="ModRefreshBtn" Style="{StaticResource SoftAccentBtn}" Content="Làm mới" Height="32" Padding="10,4" FontSize="12"/>
                </StackPanel>
                <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
                  <TextBlock Text="Cài đặt thủ công từng thành phần độc lập" FontSize="14.5" FontWeight="Bold" Foreground="#0F172A"/>
                  <TextBlock Text="Phần 1, 2, 3 dùng thẳng Token codex.anhlaptrinh.vn đã kích hoạt (không cần Telegram)." FontSize="12" Foreground="#475569" Margin="0,2,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </DockPanel>
            </Border>

            <!-- Component 1: Codex CLI -->
            <Border Style="{StaticResource CardBorder}" Padding="16,13" Margin="0,0,0,10">
              <DockPanel>
                <Button x:Name="ModInstall1Btn" DockPanel.Dock="Right" Style="{StaticResource SoftAccentBtn}" Content="Cài phần này" MinWidth="126" VerticalAlignment="Center" Margin="12,0,0,0"/>
                <CheckBox x:Name="ModCheck1" DockPanel.Dock="Left" IsChecked="True" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <StackPanel>
                  <DockPanel>
                    <Border x:Name="ModBadge1" DockPanel.Dock="Right" Background="#F1F5F9" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="10" Padding="9,2" VerticalAlignment="Center">
                      <TextBlock x:Name="ModBadgeText1" Text="Chưa cài" FontSize="11.5" FontWeight="Bold" Foreground="#475569"/>
                    </Border>
                    <TextBlock Text="1. Codex CLI riêng (codex)" FontSize="14" FontWeight="Bold" Foreground="#0F172A"/>
                  </DockPanel>
                  <TextBlock x:Name="ModDetail1" Text="Giải nén &amp; cấu hình lệnh codex chuẩn codex.anhlaptrinh.vn/v1 (~20 giây, không cần Telegram)." FontSize="12" Foreground="#64748B" Margin="0,4,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </DockPanel>
            </Border>

            <!-- Component 2: Antigravity IDE -->
            <Border Style="{StaticResource CardBorder}" Padding="16,13" Margin="0,0,0,10">
              <DockPanel>
                <Button x:Name="ModInstall2Btn" DockPanel.Dock="Right" Style="{StaticResource SoftAccentBtn}" Content="Cài phần này" MinWidth="126" VerticalAlignment="Center" Margin="12,0,0,0"/>
                <CheckBox x:Name="ModCheck2" DockPanel.Dock="Left" IsChecked="False" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <StackPanel>
                  <DockPanel>
                    <Border x:Name="ModBadge2" DockPanel.Dock="Right" Background="#F1F5F9" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="10" Padding="9,2" VerticalAlignment="Center">
                      <TextBlock x:Name="ModBadgeText2" Text="Chưa cài" FontSize="11.5" FontWeight="Bold" Foreground="#475569"/>
                    </Border>
                    <TextBlock Text="2. Antigravity IDE riêng" FontSize="14" FontWeight="Bold" Foreground="#0F172A"/>
                  </DockPanel>
                  <TextBlock x:Name="ModDetail2" Text="Kiểm tra hoặc tải bộ cài chính thức Google Antigravity IDE (~190 MB, xác thực chữ ký số Google LLC)." FontSize="12" Foreground="#64748B" Margin="0,4,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </DockPanel>
            </Border>

            <!-- Component 3: Codex Extension in Antigravity -->
            <Border Style="{StaticResource CardBorder}" Padding="16,13" Margin="0,0,0,10">
              <DockPanel>
                <Button x:Name="ModInstall3Btn" DockPanel.Dock="Right" Style="{StaticResource SoftAccentBtn}" Content="Cài phần này" MinWidth="126" VerticalAlignment="Center" Margin="12,0,0,0"/>
                <CheckBox x:Name="ModCheck3" DockPanel.Dock="Left" IsChecked="False" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <StackPanel>
                  <DockPanel>
                    <Border x:Name="ModBadge3" DockPanel.Dock="Right" Background="#F1F5F9" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="10" Padding="9,2" VerticalAlignment="Center">
                      <TextBlock x:Name="ModBadgeText3" Text="Chưa cài" FontSize="11.5" FontWeight="Bold" Foreground="#475569"/>
                    </Border>
                    <TextBlock Text="3. Codex Extension trong Antigravity" FontSize="14" FontWeight="Bold" Foreground="#0F172A"/>
                  </DockPanel>
                  <TextBlock x:Name="ModDetail3" Text="Cài tiện ích openai.chatgpt vào Antigravity riêng, khóa auto-update và tạo lối tắt EmTroLy - Antigravity trên Desktop." FontSize="12" Foreground="#64748B" Margin="0,4,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </DockPanel>
            </Border>

            <!-- Component 4: OpenClaw + Optional Zalo -->
            <Border Style="{StaticResource CardBorder}" Padding="16,13">
              <StackPanel>
                <DockPanel>
                  <Button x:Name="ModInstall4Btn" DockPanel.Dock="Right" Style="{StaticResource SoftAccentBtn}" Content="Cài phần này" MinWidth="126" VerticalAlignment="Center" Margin="12,0,0,0"/>
                  <CheckBox x:Name="ModCheck4" DockPanel.Dock="Left" IsChecked="False" VerticalAlignment="Center" Margin="0,0,12,0"/>
                  <StackPanel>
                    <DockPanel>
                      <Border x:Name="ModBadge4" DockPanel.Dock="Right" Background="#F1F5F9" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="10" Padding="9,2" VerticalAlignment="Center">
                        <TextBlock x:Name="ModBadgeText4" Text="Chưa cài" FontSize="11.5" FontWeight="Bold" Foreground="#475569"/>
                      </Border>
                      <TextBlock Text="4. Trợ lý OpenClaw riêng (Telegram &amp; Zalo)" FontSize="14" FontWeight="Bold" Foreground="#0F172A"/>
                    </DockPanel>
                    <TextBlock x:Name="ModDetail4" Text="Cài đặt Node.js, Python, FFmpeg, OpenClaw 2026.11.4 &amp; Gateway Watchdog độc lập." FontSize="12" Foreground="#64748B" Margin="0,4,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                </DockPanel>

                <!-- Inline Telegram Fields for OpenClaw Modular Setup -->
                <Border x:Name="ModOpenClawInputsBox" Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="28,10,0,0">
                  <StackPanel>
                    <DockPanel Margin="0,0,0,8">
                      <CheckBox x:Name="ModZaloCheck" DockPanel.Dock="Right" Content="Kèm plugin Zalo QR (/zaloqr)" IsChecked="True" FontSize="12" FontWeight="SemiBold" Foreground="#0F172A" VerticalAlignment="Center"/>
                      <TextBlock Text="Thông số Telegram (chỉ bắt buộc khi cài Phần 4 · OpenClaw):" FontSize="12" FontWeight="Bold" Foreground="#334155" VerticalAlignment="Center"/>
                    </DockPanel>
                    <Grid Margin="0,0,0,8">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <PasswordBox x:Name="ModTokenPwdBox" Grid.Column="0" Style="{StaticResource ModernPassword}" Height="32"/>
                      <Button x:Name="ModAutoFetchBtn" Grid.Column="1" Style="{StaticResource SecondaryBtn}" Content="Lấy ID tự động" Height="32" Padding="10,2" FontSize="12" Margin="8,0,0,0"/>
                    </Grid>
                    <Grid Margin="0,0,0,6">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="10"/>
                        <ColumnDefinition Width="*"/>
                      </Grid.ColumnDefinitions>
                      <StackPanel Grid.Column="0">
                        <TextBlock Text="Telegram Owner IDs (số dương)" FontSize="11.5" Foreground="#475569" Margin="0,0,0,3"/>
                        <TextBox x:Name="ModOwnersBox" Style="{StaticResource ModernInput}" Height="32"/>
                      </StackPanel>
                      <StackPanel Grid.Column="2">
                        <TextBlock Text="Telegram Group ID (số âm)" FontSize="11.5" Foreground="#475569" Margin="0,0,0,3"/>
                        <TextBox x:Name="ModGroupBox" Style="{StaticResource ModernInput}" Height="32"/>
                      </StackPanel>
                    </Grid>
                    <TextBlock x:Name="ModTgStatusNote" Text="" FontSize="11.5" Foreground="#065F46" TextWrapping="Wrap" Visibility="Collapsed"/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- VIEW F: LIVE ZALO QR LOGIN (Dual GUI + Telegram Owner Delivery) -->
        <ScrollViewer x:Name="ViewZaloQr" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel>
            <Border Style="{StaticResource CardBorder}" Padding="24,22">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="268"/>
                  <ColumnDefinition Width="24"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <!-- Left QR / Connected Icon Frame -->
                <Border x:Name="ZaloQrFrame" Grid.Column="0" Width="264" Height="264" Background="#FFFFFF" BorderBrush="#BFDBFE" BorderThickness="1.5" CornerRadius="14" Padding="14" VerticalAlignment="Top">
                  <Grid>
                    <Image x:Name="ZaloQrImage" Width="232" Height="232" Stretch="Uniform" RenderOptions.BitmapScalingMode="NearestNeighbor" Visibility="Collapsed"/>
                    <StackPanel x:Name="ZaloQrLoadingBox" VerticalAlignment="Center" HorizontalAlignment="Center">
                      <TextBlock Text="Đang tạo mã QR..." FontSize="14.5" FontWeight="Bold" Foreground="#2563EB" HorizontalAlignment="Center"/>
                      <TextBlock Text="Vui lòng đợi ~3 giây" FontSize="12" Foreground="#64748B" HorizontalAlignment="Center" Margin="0,6,0,0"/>
                    </StackPanel>
                    <StackPanel x:Name="ZaloQrSuccessBox" VerticalAlignment="Center" HorizontalAlignment="Center" Visibility="Collapsed">
                      <Border Width="88" Height="88" CornerRadius="44" Background="#ECFDF5" BorderBrush="#6EE7B7" BorderThickness="2" HorizontalAlignment="Center" Margin="0,0,0,12">
                        <Border Width="64" Height="64" CornerRadius="32" Background="#10B981" HorizontalAlignment="Center" VerticalAlignment="Center">
                          <Path Data="M 18,33 L 28,43 L 46,22" Stroke="#FFFFFF" StrokeThickness="4.2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                        </Border>
                      </Border>
                      <TextBlock Text="Đã kết nối Zalo!" FontSize="16.5" FontWeight="Bold" Foreground="#065F46" HorizontalAlignment="Center"/>
                      <Border Background="#D1FAE5" BorderBrush="#6EE7B7" BorderThickness="1" CornerRadius="12" Padding="10,3" HorizontalAlignment="Center" Margin="0,8,0,0">
                        <StackPanel Orientation="Horizontal">
                          <Ellipse Width="7" Height="7" Fill="#059669" VerticalAlignment="Center" Margin="0,0,6,0"/>
                          <TextBlock Text="Đang trực tuyến" FontSize="11.5" FontWeight="Bold" Foreground="#065F46" VerticalAlignment="Center"/>
                        </StackPanel>
                      </Border>
                    </StackPanel>
                  </Grid>
                </Border>

                <!-- Right Instructions & Live Sync Status -->
                <StackPanel Grid.Column="2" VerticalAlignment="Center">
                  <DockPanel Margin="0,0,0,10">
                    <Border x:Name="ZaloQrTimerPill" DockPanel.Dock="Right" Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1" CornerRadius="6" Padding="10,4" VerticalAlignment="Center">
                      <TextBlock x:Name="ZaloQrTimerText" Text="Đang chuẩn bị..." FontSize="12" FontWeight="Bold" Foreground="#1D4ED8"/>
                    </Border>
                    <TextBlock x:Name="ZaloQrMainHeading" Text="Quét mã QR đăng nhập Zalo" FontSize="17" FontWeight="Bold" Foreground="#0F172A" VerticalAlignment="Center"/>
                  </DockPanel>

                  <TextBlock x:Name="ZaloQrStatusText" Text="Đang khởi tạo phiên đăng nhập Zalo cá nhân..." FontSize="13.5" FontWeight="SemiBold" Foreground="#334155" TextWrapping="Wrap" Margin="0,0,0,10"/>

                  <!-- Telegram Delivery Confirmation Banner -->
                  <Border x:Name="ZaloQrTgBanner" Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="8" Padding="12,9" Margin="0,0,0,14">
                    <TextBlock x:Name="ZaloQrTgText" Text="Chuẩn bị gửi đồng thời mã QR tới Telegram Chủ sở hữu..." FontSize="12.5" Foreground="#475569" TextWrapping="Wrap"/>
                  </Border>

                  <!-- 3-Step Guide -->
                  <Border x:Name="ZaloQrGuideBox" Background="#F8FAFC" CornerRadius="8" Padding="12,10" Margin="0,0,0,16">
                    <StackPanel>
                      <TextBlock Text="1. Mở ứng dụng Zalo trên điện thoại (hoặc xem ảnh gửi trong Telegram)." FontSize="12.5" Foreground="#334155" TextWrapping="Wrap" Margin="0,0,0,5"/>
                      <TextBlock Text="2. Bấm biểu tượng Quét mã QR ở góc trên bên phải ứng dụng Zalo." FontSize="12.5" Foreground="#334155" TextWrapping="Wrap" Margin="0,0,0,5"/>
                      <TextBlock Text="3. Quét mã bên trái và bấm Đăng nhập — phần mềm sẽ tự báo hoàn tất ngay!" FontSize="12.5" FontWeight="SemiBold" Foreground="#0F172A" TextWrapping="Wrap"/>
                    </StackPanel>
                  </Border>

                  <StackPanel Orientation="Horizontal">
                    <Button x:Name="ZaloQrRefreshBtn" Style="{StaticResource PrimaryBtn}" Content="Tạo mã QR mới" Margin="0,0,10,0"/>
                    <Button x:Name="ZaloQrBackBtn" Style="{StaticResource SecondaryBtn}" Content="Về Tổng quan"/>
                  </StackPanel>
                </StackPanel>
              </Grid>
            </Border>
          </StackPanel>
        </ScrollViewer>

      </Grid>
    </DockPanel>

    <!-- FULL-WINDOW CUSTOMER LICENSE ACTIVATION GATE -->
    <Border x:Name="LicenseGateOverlay" Grid.Column="0" Grid.ColumnSpan="2" Panel.ZIndex="999" Background="#F4F7FB" Visibility="Visible">
      <Grid>
        <Border Width="510" VerticalAlignment="Center" HorizontalAlignment="Center" Background="#FFFFFF" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="16" Padding="32,28">
          <StackPanel>
            <!-- Brand Logo -->
            <Border Width="220" Background="#FFFFFF" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="12" Padding="14,10" HorizontalAlignment="Center" Margin="0,0,0,16">
              <Image x:Name="LicenseLogoImage" Height="48" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
            </Border>

            <!-- Shield Lock Badge -->
            <Border Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1" CornerRadius="14" Padding="12,4" HorizontalAlignment="Center" Margin="0,0,0,10">
              <StackPanel Orientation="Horizontal">
                <Border Width="16" Height="16" CornerRadius="8" Background="#2563EB" VerticalAlignment="Center" Margin="0,0,6,0">
                  <Path Data="M 3.5,8.2 L 6.6,11.2 L 12.6,5" Stroke="#FFFFFF" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                </Border>
                <TextBlock Text="BẢO MẬT KHÁCH HÀNG CHÍNH THỨC" FontSize="11" FontWeight="Bold" Foreground="#1D4ED8" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>

            <TextBlock Text="Kích hoạt Em Trợ Lý" FontSize="21" FontWeight="Bold" Foreground="#0F172A" HorizontalAlignment="Center"/>
            <TextBlock Text="Nhập Khóa kích hoạt (Provider API Key trên codex.anhlaptrinh.vn) — chỉ cần kích hoạt 1 lần duy nhất trên máy này, các lần sau mở thẳng phần mềm" FontSize="12.5" Foreground="#64748B" TextAlignment="Center" TextWrapping="Wrap" Margin="0,5,0,18"/>

            <!-- Auto-Checking Saved Key View -->
            <StackPanel x:Name="LicenseCheckingBox" Visibility="Collapsed" Margin="0,6,0,12">
              <ProgressBar Height="8" IsIndeterminate="True" Foreground="#2563EB" Background="#DBEAFE" BorderThickness="0" Margin="0,0,0,10"/>
              <TextBlock Text="Đang xác thực bản quyền với máy chủ codex.anhlaptrinh.vn..." FontSize="13" FontWeight="SemiBold" Foreground="#1D4ED8" HorizontalAlignment="Center"/>
            </StackPanel>

            <!-- Interactive Key Entry View -->
            <StackPanel x:Name="LicenseInputBox" Visibility="Visible">
              <DockPanel Margin="0,0,0,6">
                <CheckBox x:Name="LicenseShowCheck" DockPanel.Dock="Right" Content="Hiện mã" FontSize="12" Foreground="#475569" VerticalAlignment="Center"/>
                <TextBlock Style="{StaticResource FieldLabel}" Text="Khóa kích hoạt / Provider API Key" Margin="0"/>
              </DockPanel>
              <Grid Margin="0,0,0,12">
                <PasswordBox x:Name="LicensePwdBox" Style="{StaticResource ModernPassword}" Height="40"/>
                <TextBox x:Name="LicensePlainBox" Style="{StaticResource ModernInput}" Height="40" Visibility="Collapsed"/>
              </Grid>

              <Border x:Name="LicenseMsgBanner" Background="#FEF2F2" BorderBrush="#FECACA" BorderThickness="1" CornerRadius="8" Padding="12,9" Margin="0,0,0,14" Visibility="Collapsed">
                <TextBlock x:Name="LicenseMsgText" Text="" FontSize="12.5" Foreground="#B91C1C" TextWrapping="Wrap"/>
              </Border>

              <Grid Margin="0,2,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="10"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="LicenseExitBtn" Grid.Column="0" Style="{StaticResource SecondaryBtn}" Content="Thoát" Height="40" MinWidth="96"/>
                <Button x:Name="LicenseActivateBtn" Grid.Column="2" Style="{StaticResource PrimaryBtn}" Content="Kích hoạt &amp; Mở khóa phần mềm" Height="40"/>
              </Grid>
              <Button x:Name="LicenseSignOutBtn" Style="{StaticResource SoftDangerBtn}" Content="Thoát bản quyền hiện tại (bắt buộc nhập lại Token)" Height="34" Margin="0,10,0,0" Visibility="Collapsed"/>
            </StackPanel>

            <TextBlock Text="Chỉ khóa API hợp lệ do Anh Lập Trình cấp trên codex.anhlaptrinh.vn mới sử dụng được ứng dụng." FontSize="11.5" Foreground="#94A3B8" TextAlignment="Center" TextWrapping="Wrap" Margin="0,16,0,0"/>
          </StackPanel>
        </Border>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$xmlDoc = [xml]$xamlText
$reader = New-Object System.Xml.XmlNodeReader($xmlDoc)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

function Get-Ui([string]$Name) {
  return $window.FindName($Name)
}

# WPF Adapters keeping 100% clean compatibility with installer contracts
function Enable-WpfCheckBoxAdapter($cb) {
  $cb | Add-Member -MemberType ScriptProperty -Name Checked -Value { [bool]$this.IsChecked } -SecondValue { param($v) $this.IsChecked = [bool]$v } -Force
  $cb | Add-Member -MemberType ScriptProperty -Name Enabled -Value { [bool]$this.IsEnabled } -SecondValue { param($v) $this.IsEnabled = [bool]$v } -Force
}

function New-WpfSecretBoxAdapter($pwdBox, $plainBox) {
  $state = [pscustomobject]@{
    PwdBox = $pwdBox
    PlainBox = $plainBox
    Masked = $true
  }
  $state | Add-Member -MemberType ScriptProperty -Name Text -Value {
    if ($this.Masked) { return [string]$this.PwdBox.Password }
    return [string]$this.PlainBox.Text
  } -SecondValue {
    param($v)
    $s = if ($null -eq $v) { '' } else { [string]$v }
    $this.PwdBox.Password = $s
    $this.PlainBox.Text = $s
  } -Force
  $state | Add-Member -MemberType ScriptProperty -Name UseSystemPasswordChar -Value {
    return [bool]$this.Masked
  } -SecondValue {
    param($v)
    $wantMask = [bool]$v
    if ($wantMask -and -not $this.Masked) {
      $this.PwdBox.Password = $this.PlainBox.Text
      $this.PlainBox.Visibility = [System.Windows.Visibility]::Collapsed
      $this.PwdBox.Visibility = [System.Windows.Visibility]::Visible
      $this.Masked = $true
    } elseif (-not $wantMask -and $this.Masked) {
      $this.PlainBox.Text = $this.PwdBox.Password
      $this.PwdBox.Visibility = [System.Windows.Visibility]::Collapsed
      $this.PlainBox.Visibility = [System.Windows.Visibility]::Visible
      $this.Masked = $false
    }
  } -Force
  $state | Add-Member -MemberType ScriptMethod -Name Clear -Value {
    $this.PwdBox.Clear()
    $this.PlainBox.Clear()
  } -Force
  return $state
}

# Bind Named Controls
$logoImage          = Get-Ui 'LogoImage'
$licenseLogoImage   = Get-Ui 'LicenseLogoImage'
$licenseGateOverlay = Get-Ui 'LicenseGateOverlay'
$licenseCheckingBox = Get-Ui 'LicenseCheckingBox'
$licenseInputBox    = Get-Ui 'LicenseInputBox'
$licenseShowCheck   = Get-Ui 'LicenseShowCheck'
$licensePwdBox      = Get-Ui 'LicensePwdBox'
$licensePlainBox    = Get-Ui 'LicensePlainBox'
$licenseKeyBox      = New-WpfSecretBoxAdapter $licensePwdBox $licensePlainBox
$licenseMsgBanner   = Get-Ui 'LicenseMsgBanner'
$licenseMsgText     = Get-Ui 'LicenseMsgText'
$licenseActivateBtn = Get-Ui 'LicenseActivateBtn'
$licenseExitBtn     = Get-Ui 'LicenseExitBtn'
$licenseSignOutBtn  = Get-Ui 'LicenseSignOutBtn'
$sidebarLicensePill = Get-Ui 'SidebarLicensePill'
$sidebarSignOutLicenseBtn = Get-Ui 'SidebarSignOutLicenseBtn'
$sidebarZaloPill    = Get-Ui 'SidebarZaloPill'
$sidebarZaloIconCircle = Get-Ui 'SidebarZaloIconCircle'
$sidebarZaloCheckIcon = Get-Ui 'SidebarZaloCheckIcon'
$sidebarZaloPendingDot = Get-Ui 'SidebarZaloPendingDot'
$sidebarZaloText    = Get-Ui 'SidebarZaloText'
$sidebarStatusPill  = Get-Ui 'SidebarStatusPill'
$sidebarStatusDot   = Get-Ui 'SidebarStatusDot'
$sidebarStatusText  = Get-Ui 'SidebarStatusText'
$versionText        = Get-Ui 'VersionText'
$navHomeBtn         = Get-Ui 'NavHomeBtn'
$navModularBtn      = Get-Ui 'NavModularBtn'
$navConfigBtn       = Get-Ui 'NavConfigBtn'
$navCodexBtn        = Get-Ui 'NavCodexBtn'
$navDiagBtn         = Get-Ui 'NavDiagBtn'
$headerZaloBadge    = Get-Ui 'HeaderZaloBadge'
$headerQuickBtn     = Get-Ui 'HeaderQuickBtn'
$headerTitle        = Get-Ui 'HeaderTitle'
$headerSubtitle     = Get-Ui 'HeaderSubtitle'
$stopTaskButton     = Get-Ui 'StopTaskBtn'
$cancelButton       = Get-Ui 'CancelBtn'
$primaryActionBtn   = Get-Ui 'PrimaryActionBtn'
$footerHintText     = Get-Ui 'FooterHintText'

$viewDashboard      = Get-Ui 'ViewDashboard'
$viewSetupForm      = Get-Ui 'ViewSetupForm'
$viewModular        = Get-Ui 'ViewModular'
$viewProgress       = Get-Ui 'ViewProgress'
$viewCodex          = Get-Ui 'ViewCodex'
$viewDiagnostics    = Get-Ui 'ViewDiagnostics'
$viewZaloQr         = Get-Ui 'ViewZaloQr'

$dashHeroTitle      = Get-Ui 'DashHeroTitle'
$dashHeroSub        = Get-Ui 'DashHeroSub'
$dashOpenWebBtn     = Get-Ui 'DashOpenWebBtn'
$dashRefreshBtn     = Get-Ui 'DashRefreshBtn'
$cardGwBadge        = Get-Ui 'CardGwBadge'
$cardGwBadgeText    = Get-Ui 'CardGwBadgeText'
$cardGwDot          = Get-Ui 'CardGwDot'
$cardGwStatus       = Get-Ui 'CardGwStatus'
$cardTgBadge        = Get-Ui 'CardTgBadge'
$cardTgBadgeText    = Get-Ui 'CardTgBadgeText'
$cardTgDot          = Get-Ui 'CardTgDot'
$cardTgStatus       = Get-Ui 'CardTgStatus'
$cardZaloBorder     = Get-Ui 'CardZaloBorder'
$cardZaloBadge      = Get-Ui 'CardZaloBadge'
$cardZaloBadgeIcon  = Get-Ui 'CardZaloBadgeIcon'
$cardZaloBadgeText  = Get-Ui 'CardZaloBadgeText'
$cardZaloDot        = Get-Ui 'CardZaloDot'
$cardZaloStatus     = Get-Ui 'CardZaloStatus'
$cardCodexBadge     = Get-Ui 'CardCodexBadge'
$cardCodexBadgeText = Get-Ui 'CardCodexBadgeText'
$cardCodexDot       = Get-Ui 'CardCodexDot'
$cardCodexStatus    = Get-Ui 'CardCodexStatus'
$dashRestartBtn     = Get-Ui 'DashRestartBtn'
$dashEditConfigBtn  = Get-Ui 'DashEditConfigBtn'
$dashZaloQrBtn      = Get-Ui 'DashZaloQrBtn'
$dashZaloBtn        = Get-Ui 'DashZaloBtn'
$dashCodexRepairBtn = Get-Ui 'DashCodexRepairBtn'
$dashOpenCodexBtn   = Get-Ui 'DashOpenCodexBtn'
$dashAutoHealBtn    = Get-Ui 'DashAutoHealBtn'
$dashExportBtn      = Get-Ui 'DashExportBtn'

$manageEditBanner   = Get-Ui 'ManageEditBanner'
$savedDraftBanner   = Get-Ui 'SavedDraftBanner'
$savedDraftBannerText = Get-Ui 'SavedDraftBannerText'
$clearSavedDraftBtn = Get-Ui 'ClearSavedDraftBtn'
$showSecretCheck    = Get-Ui 'ShowSecretCheck'
$tokenFieldLabel    = Get-Ui 'TokenFieldLabel'
$apiKeyFieldLabel   = Get-Ui 'ApiKeyFieldLabel'
$tokenPwdBox        = Get-Ui 'TokenPwdBox'
$tokenPlainBox      = Get-Ui 'TokenPlainBox'
$apiKeyPwdBox       = Get-Ui 'ApiKeyPwdBox'
$apiKeyPlainBox     = Get-Ui 'ApiKeyPlainBox'
$tokenBox           = New-WpfSecretBoxAdapter $tokenPwdBox $tokenPlainBox
$apiKeyBox          = New-WpfSecretBoxAdapter $apiKeyPwdBox $apiKeyPlainBox
$autoFetchIdBtn     = Get-Ui 'AutoFetchIdBtn'
$testConnBtn        = Get-Ui 'TestConnBtn'
$liveCheckBanner    = Get-Ui 'LiveCheckBanner'
$liveCheckText      = Get-Ui 'LiveCheckText'
$ownersBox          = Get-Ui 'OwnersBox'
$groupBox           = Get-Ui 'GroupBox'
$modelBox           = Get-Ui 'ModelBox'
$assistantBox       = Get-Ui 'AssistantBox'
$installOptionsCard = Get-Ui 'InstallOptionsCard'
$zaloCheck          = Get-Ui 'ZaloCheck'
$existingEditorCheck = Get-Ui 'ExistingEditorCheck'
$fullAccessCheck    = Get-Ui 'FullAccessCheck'
$advancedExpander   = Get-Ui 'AdvancedExpander'
$baseUrlBox         = Get-Ui 'BaseUrlBox'
$portBox            = Get-Ui 'PortBox'
$qrOwnerBox         = Get-Ui 'QrOwnerBox'
$audienceBox        = Get-Ui 'AudienceBox'
$addressingBox      = Get-Ui 'AddressingBox'
$styleBox           = Get-Ui 'StyleBox'

$coreReadyText      = Get-Ui 'CoreReadyText'
$progressCard       = Get-Ui 'ProgressCard'
$statusText         = Get-Ui 'StatusText'
$progressPercentText = Get-Ui 'ProgressPercentText'
$installProgressBar = Get-Ui 'InstallProgressBar'
$installChecklistCard = Get-Ui 'InstallChecklistCard'
$autoHealNoteBorder = Get-Ui 'AutoHealNoteBorder'
$autoHealProgressNote = Get-Ui 'AutoHealProgressNote'
$retryEditorPanel   = Get-Ui 'RetryEditorPanel'
$retryKeyPwdBox     = Get-Ui 'RetryKeyPwdBox'
$installFailureActions = Get-Ui 'InstallFailureActions'
$errorStepPill      = Get-Ui 'ErrorStepPill'
$errorStepText      = Get-Ui 'ErrorStepText'
$errorSummaryHeading = Get-Ui 'ErrorSummaryHeading'
$errorDetailBox     = Get-Ui 'ErrorDetailBox'
$btnCopyErrorDetail = Get-Ui 'BtnCopyErrorDetail'
$btnOpenCodexFromError = Get-Ui 'BtnOpenCodexFromError'
$btnBackToSetup     = Get-Ui 'BtnBackToSetup'
$btnInstallAutoHeal = Get-Ui 'BtnInstallAutoHeal'
$btnProgressExport  = Get-Ui 'BtnProgressExport'

$codexStateText     = Get-Ui 'CodexStateText'
$codexDirBox        = Get-Ui 'CodexDirBox'
$codexBrowseBtn     = Get-Ui 'CodexBrowseBtn'
$codexOpenDirBtn    = Get-Ui 'CodexOpenDirBtn'
$codexTerminalBtn   = Get-Ui 'CodexTerminalBtn'
$presetConfigBtn    = Get-Ui 'PresetConfigBtn'
$presetSkillBtn     = Get-Ui 'PresetSkillBtn'
$presetFixBtn       = Get-Ui 'PresetFixBtn'
$codexPromptBox     = Get-Ui 'CodexPromptBox'
$codexWriteCheck    = Get-Ui 'CodexWriteCheck'
$codexRunBtn        = Get-Ui 'CodexRunBtn'
$codexStopBtn       = Get-Ui 'CodexStopBtn'
$codexClearBtn      = Get-Ui 'CodexClearBtn'
$codexRefreshBtn    = Get-Ui 'CodexRefreshBtn'
$codexOutputBox     = Get-Ui 'CodexOutputBox'

$runPreflightBtn    = Get-Ui 'RunPreflightBtn'
$preflightListPanel = Get-Ui 'PreflightListPanel'
$diagAutoHealBtn    = Get-Ui 'DiagAutoHealBtn'
$diagRestartBtn     = Get-Ui 'DiagRestartBtn'
$diagZaloQrBtn      = Get-Ui 'DiagZaloQrBtn'
$diagZaloBtn        = Get-Ui 'DiagZaloBtn'
$diagCodexBtn       = Get-Ui 'DiagCodexBtn'
$diagUninstallBtn   = Get-Ui 'DiagUninstallBtn'
$diagExportBtn      = Get-Ui 'DiagExportBtn'
$diagShortcutBtn    = Get-Ui 'DiagShortcutBtn'
$diagChangeLicenseBtn = Get-Ui 'DiagChangeLicenseBtn'
$diagSignOutLicenseBtn = Get-Ui 'DiagSignOutLicenseBtn'

$modModelBox        = Get-Ui 'ModModelBox'
$modSelectAllBtn    = Get-Ui 'ModSelectAllBtn'
$modRefreshBtn      = Get-Ui 'ModRefreshBtn'
$modCheck1          = Get-Ui 'ModCheck1'
$modBadge1          = Get-Ui 'ModBadge1'
$modBadgeText1      = Get-Ui 'ModBadgeText1'
$modDetail1         = Get-Ui 'ModDetail1'
$modInstall1Btn     = Get-Ui 'ModInstall1Btn'
$modCheck2          = Get-Ui 'ModCheck2'
$modBadge2          = Get-Ui 'ModBadge2'
$modBadgeText2      = Get-Ui 'ModBadgeText2'
$modDetail2         = Get-Ui 'ModDetail2'
$modInstall2Btn     = Get-Ui 'ModInstall2Btn'
$modCheck3          = Get-Ui 'ModCheck3'
$modBadge3          = Get-Ui 'ModBadge3'
$modBadgeText3      = Get-Ui 'ModBadgeText3'
$modDetail3         = Get-Ui 'ModDetail3'
$modInstall3Btn     = Get-Ui 'ModInstall3Btn'
$modCheck4          = Get-Ui 'ModCheck4'
$modBadge4          = Get-Ui 'ModBadge4'
$modBadgeText4      = Get-Ui 'ModBadgeText4'
$modDetail4         = Get-Ui 'ModDetail4'
$modInstall4Btn     = Get-Ui 'ModInstall4Btn'
$modOpenClawInputsBox = Get-Ui 'ModOpenClawInputsBox'
$modZaloCheck       = Get-Ui 'ModZaloCheck'
$modTokenPwdBox     = Get-Ui 'ModTokenPwdBox'
$modAutoFetchBtn    = Get-Ui 'ModAutoFetchBtn'
$modOwnersBox       = Get-Ui 'ModOwnersBox'
$modGroupBox        = Get-Ui 'ModGroupBox'
$modTgStatusNote    = Get-Ui 'ModTgStatusNote'

$zaloQrFrame        = Get-Ui 'ZaloQrFrame'
$zaloQrImage        = Get-Ui 'ZaloQrImage'
$zaloQrLoadingBox   = Get-Ui 'ZaloQrLoadingBox'
$zaloQrSuccessBox   = Get-Ui 'ZaloQrSuccessBox'
$zaloQrMainHeading  = Get-Ui 'ZaloQrMainHeading'
$zaloQrTimerPill    = Get-Ui 'ZaloQrTimerPill'
$zaloQrTimerText    = Get-Ui 'ZaloQrTimerText'
$zaloQrStatusText   = Get-Ui 'ZaloQrStatusText'
$zaloQrTgBanner     = Get-Ui 'ZaloQrTgBanner'
$zaloQrTgText       = Get-Ui 'ZaloQrTgText'
$zaloQrGuideBox     = Get-Ui 'ZaloQrGuideBox'
$zaloQrRefreshBtn   = Get-Ui 'ZaloQrRefreshBtn'
$zaloQrBackBtn      = Get-Ui 'ZaloQrBackBtn'

Enable-WpfCheckBoxAdapter $zaloCheck
Enable-WpfCheckBoxAdapter $existingEditorCheck
Enable-WpfCheckBoxAdapter $fullAccessCheck

# Defaults matching installer contracts
$fullAccessCheck.Checked = $false
$zaloCheck.Checked = $true
$zaloCheck.Enabled = $true
$existingEditorCheck.Checked = $false
$versionText.Text = "v$($appVersionObj.InstallerVersion) · Anh Lập Trình"

foreach ($m in @('gpt-6.2-sol', 'GPT-6.1-terra', 'gpt-6.2-astra')) {
  [void]$modelBox.Items.Add($m)
  if ($modModelBox) { [void]$modModelBox.Items.Add($m) }
}
$modelBox.SelectedIndex = 0
if ($modModelBox) { $modModelBox.SelectedIndex = 0 }

# Load Brand Logo (alt.png) & Window Icon (alt.ico) without locking files on disk
$logoPath = Join-Path $PayloadRoot 'alt.png'
if (-not (Test-Path -LiteralPath $logoPath -PathType Leaf) -and $PSScriptRoot) {
  $cand = Join-Path (Split-Path -Parent $PSScriptRoot) 'alt.png'
  if (Test-Path -LiteralPath $cand -PathType Leaf) { $logoPath = $cand }
}
if (Test-Path -LiteralPath $logoPath -PathType Leaf) {
  try {
    $imgBytes = [IO.File]::ReadAllBytes($logoPath)
    $ms = New-Object System.IO.MemoryStream(,$imgBytes)
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.StreamSource = $ms
    $bmp.EndInit()
    $bmp.Freeze()
    $ms.Dispose()
    $logoImage.Source = $bmp
    if ($licenseLogoImage) { $licenseLogoImage.Source = $bmp }
  } catch { }
}

$iconPath = Join-Path $PayloadRoot 'windows-installer\alt.ico'
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf) -and $PSScriptRoot) {
  $candIco = Join-Path $PSScriptRoot 'alt.ico'
  if (Test-Path -LiteralPath $candIco -PathType Leaf) { $iconPath = $candIco }
}
if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
  try {
    $icoBytes = [IO.File]::ReadAllBytes($iconPath)
    $ims = New-Object System.IO.MemoryStream(,$icoBytes)
    $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($ims, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    $ims.Dispose()
  } catch { }
}

# State variables
$pending = Join-Path $env:USERPROFILE 'openclaw\installer-codex-pending.json'
$script:currentView = 'home'
$script:isManageMode = $false
$script:installRunning = $false
$script:installCompleted = $false
$script:retryEditor = $false
$script:currentManageAction = ''
$script:resultCode = 1
$script:runnerProcess = $null
$script:runnerDeadline = [datetime]::MinValue
$script:privateDir = $null
$script:secretFile = $null
$script:safeLog = $null
$script:sessionApiKeyFallback = ''
$script:lastInstallErrorDetail = ''
$script:lastFullErrorReport = ''
$script:lastActiveStepIndex = 1
$script:gatewayDashboardUrl = ''

$script:codexProcess = $null
$script:codexPrivateDir = $null
$script:codexLogFile = $null
$script:codexLogOffset = 0
$script:codexRunning = $false

$script:zaloQrProcess = $null
$script:zaloQrDir = $null
$script:zaloQrStateFile = $null
$script:zaloQrPngFile = $null
$script:zaloQrLoadedTicks = 0
$script:zaloQrRunning = $false
$script:openZaloQrAfterManage = $false
$script:zaloConnectedState = $false
$script:zaloInstalledState = $false
$script:zaloSyncProc = $null
$script:lastZaloSyncAt = [datetime]::MinValue
$script:licenseVerified = $false
$script:licenseCheckRunning = $false
$script:licenseCanDismiss = $false
$script:draftHydrating = $false
$script:draftDirty = $false

$codexGuideText = "Hướng dẫn nhanh:`r`n1. Chọn thư mục cần chỉnh sửa (mặc định là thư mục trợ lý OpenClaw).`r`n2. Nhập yêu cầu bằng tiếng Việt vào ô phía trên (hoặc bấm 1 mẫu gợi ý).`r`n3. Bấm `"Thực hiện bằng Codex`" để Codex CLI tự đọc và sửa tệp giúp bạn."
$codexDirBox.Text = Get-CodexDefaultWorkspace
$codexOutputBox.Text = $codexGuideText

function New-Brush([string]$Hex) {
  return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex)
}

function Show-Error([string]$Message) {
  [void][System.Windows.MessageBox]::Show($window, $Message, 'Không thể tiếp tục', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
}

function Show-Info([string]$Message, [string]$Title = 'Thông báo') {
  [void][System.Windows.MessageBox]::Show($window, $Message, $Title, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
}

function Cleanup-Secret {
  if ($script:privateDir -and (Test-Path -LiteralPath $script:privateDir)) {
    Remove-Item -LiteralPath $script:privateDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Cleanup-CodexRun {
  if ($script:codexPrivateDir -and (Test-Path -LiteralPath $script:codexPrivateDir)) {
    Remove-Item -LiteralPath $script:codexPrivateDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  $script:codexPrivateDir = $null
  $script:codexLogFile = $null
  $script:codexLogOffset = 0
}

function Stop-ProcessTreeById([int]$ProcessId) {
  if ($ProcessId -le 0 -or $ProcessId -eq $PID) { return }
  try {
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
      if ($child.ProcessId) { Stop-ProcessTreeById ([int]$child.ProcessId) }
    }
  } catch { }
  try {
    $tkPath = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    if (Test-Path -LiteralPath $tkPath -PathType Leaf) {
      $tkPsi = New-Object System.Diagnostics.ProcessStartInfo
      $tkPsi.FileName = $tkPath
      $tkPsi.Arguments = "/PID $ProcessId /T /F"
      $tkPsi.UseShellExecute = $false
      $tkPsi.CreateNoWindow = $true
      $tkPsi.RedirectStandardOutput = $true
      $tkPsi.RedirectStandardError = $true
      $tkProc = [Diagnostics.Process]::Start($tkPsi)
      [void]$tkProc.WaitForExit(3000)
      $tkProc.Dispose()
    }
  } catch { }
  try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { }
}

function Stop-CodexRun {
  if (-not $script:codexRunning) { return }
  if ($script:codexLogFile) {
    $pidPath = "$($script:codexLogFile).pid"
    if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
      try {
        $childPid = ([IO.File]::ReadAllText($pidPath, [Text.Encoding]::ASCII)).Trim()
        if ($childPid -match '^[0-9]+$') { Stop-ProcessTreeById ([int]$childPid) }
      } catch { }
    }
  }
  if ($script:codexProcess) {
    try {
      if (-not $script:codexProcess.HasExited) {
        Stop-ProcessTreeById $script:codexProcess.Id
        try { $script:codexProcess.Kill() } catch { }
      }
    } catch { }
  }
}

# Async UI background task helper (keeps WPF silky-smooth during network checks)
$script:asyncTasks = New-Object System.Collections.ArrayList
$asyncTimer = New-Object System.Windows.Threading.DispatcherTimer
$asyncTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$asyncTimer.Add_Tick({
  for ($i = $script:asyncTasks.Count - 1; $i -ge 0; $i--) {
    $item = $script:asyncTasks[$i]
    if ($item.Handle.IsCompleted) {
      $script:asyncTasks.RemoveAt($i)
      $res = $null
      $err = $null
      try {
        $out = $item.Ps.EndInvoke($item.Handle)
        if ($out -and $out.Count -gt 0) { $res = $out[$out.Count - 1] }
      } catch {
        $err = $_
      } finally {
        try { $item.Ps.Dispose() } catch { }
      }
      try { & $item.OnComplete $res $err } catch { }
    }
  }
  if ($script:asyncTasks.Count -eq 0) { $asyncTimer.Stop() }
})

function Start-AsyncUiTask {
  param(
    [Parameter(Mandatory=$true)][scriptblock]$Work,
    [hashtable]$Params = @{},
    [Parameter(Mandatory=$true)][scriptblock]$OnComplete
  )
  $ps = [PowerShell]::Create()
  [void]$ps.AddScript($Work.ToString())
  foreach ($k in $Params.Keys) {
    [void]$ps.AddParameter($k, $Params[$k])
  }
  $handle = $ps.BeginInvoke()
  [void]$script:asyncTasks.Add([pscustomobject]@{ Ps = $ps; Handle = $handle; OnComplete = $OnComplete })
  if (-not $asyncTimer.IsEnabled) { $asyncTimer.Start() }
}

# 5-Step Progress Checklist Updater
function Set-ChecklistStep([int]$Index, [string]$State, [string]$Badge = '') {
  $iconCtrl = Get-Ui "Step${Index}Icon"
  $textCtrl = Get-Ui "Step${Index}Text"
  $badgeCtrl = Get-Ui "Step${Index}Badge"
  if (-not $iconCtrl) { return }
  switch ($State) {
    'done' {
      $iconCtrl.Text = '✓'
      $iconCtrl.Foreground = New-Brush '#059669'
      $textCtrl.Foreground = New-Brush '#0F172A'
      $textCtrl.FontWeight = [System.Windows.FontWeights]::SemiBold
      $badgeCtrl.Text = if ($Badge) { $Badge } else { 'Hoàn tất' }
      $badgeCtrl.Foreground = New-Brush '#059669'
    }
    'active' {
      $iconCtrl.Text = '●'
      $iconCtrl.Foreground = New-Brush '#2563EB'
      $textCtrl.Foreground = New-Brush '#1D4ED8'
      $textCtrl.FontWeight = [System.Windows.FontWeights]::Bold
      $badgeCtrl.Text = if ($Badge) { $Badge } else { 'Đang chạy...' }
      $badgeCtrl.Foreground = New-Brush '#2563EB'
    }
    'heal' {
      $iconCtrl.Text = '↻'
      $iconCtrl.Foreground = New-Brush '#D97706'
      $textCtrl.Foreground = New-Brush '#B45309'
      $textCtrl.FontWeight = [System.Windows.FontWeights]::Bold
      $badgeCtrl.Text = if ($Badge) { $Badge } else { 'Codex đang tự sửa...' }
      $badgeCtrl.Foreground = New-Brush '#D97706'
    }
    'skipped' {
      $iconCtrl.Text = '—'
      $iconCtrl.Foreground = New-Brush '#94A3B8'
      $textCtrl.Foreground = New-Brush '#94A3B8'
      $textCtrl.FontWeight = [System.Windows.FontWeights]::Normal
      $badgeCtrl.Text = 'Bỏ qua'
      $badgeCtrl.Foreground = New-Brush '#94A3B8'
    }
    'error' {
      $iconCtrl.Text = '✕'
      $iconCtrl.Foreground = New-Brush '#DC2626'
      $textCtrl.Foreground = New-Brush '#DC2626'
      $textCtrl.FontWeight = [System.Windows.FontWeights]::Bold
      $badgeCtrl.Text = if ($Badge) { $Badge } else { 'Gặp lỗi' }
      $badgeCtrl.Foreground = New-Brush '#DC2626'
    }
    default {
      $iconCtrl.Text = '○'
      $iconCtrl.Foreground = New-Brush '#94A3B8'
      $textCtrl.Foreground = New-Brush '#475569'
      $textCtrl.FontWeight = [System.Windows.FontWeights]::Normal
      $badgeCtrl.Text = 'Chờ thực hiện'
      $badgeCtrl.Foreground = New-Brush '#94A3B8'
    }
  }
}

function Update-ProgressFromStatus([string]$Message) {
  $zaloOn = $zaloCheck.Checked
  $editorOn = (-not $existingEditorCheck.Checked)
  $pct = 8
  $activeStep = 1
  $isHealing = ($Message -match 'Codex CLI đang tự động|Codex CLI đã xử lý|Phát hiện sự cố|tự sửa lỗi')

  if ($Message.StartsWith('Hoàn tất:')) {
    $pct = 100
    for ($s = 1; $s -le 5; $s++) {
      if ($s -eq 5 -and -not $zaloOn) { Set-ChecklistStep 5 'skipped' }
      elseif ($s -eq 2 -and -not $editorOn) { Set-ChecklistStep 2 'done' 'Đã cài Codex CLI' }
      else { Set-ChecklistStep $s 'done' }
    }
    $installProgressBar.IsIndeterminate = $false
    $installProgressBar.Value = 100
    $progressPercentText.Text = '100%'
    return
  }

  $activeBadge = ''
  $subPct = -1
  if ($Message -match '(?<!\d)(\d{1,3})%') {
    $subPct = [Math]::Max(0, [Math]::Min(100, [int]$Matches[1]))
  }

  if ($isHealing) {
    $activeStep = [Math]::Max(1, [Math]::Min(5, [int]$script:lastActiveStepIndex))
    $pct = [Math]::Max(20, [int]$installProgressBar.Value)
  } elseif ($Message -match 'Zalo|/zaloqr|menu Telegram') {
    $activeStep = 5
    $pct = 90
  } elseif ($Message -match 'OpenClaw|kỹ năng|Full Exec|Gateway|lệnh openclaw') {
    $activeStep = 4
    $pct = 74
  } elseif ($Message -match 'Node\.js|Python|FFmpeg|môi trường|gói môi trường|tải song song') {
    $activeStep = 3
    $pct = if ($subPct -ge 0) { 46 + [int][Math]::Round($subPct * 0.16) } else { 54 }
    if ($subPct -ge 0) { $activeBadge = "Đang tải $subPct%" }
  } elseif ($Message -match 'Antigravity|Codex Extension|gói Codex CLI|giải nén và kích hoạt Codex|khóa API cho Codex|cài Codex|kiểm tra Codex|Codex CLI|lối tắt|Thử lại bước Codex') {
    $activeStep = 2
    $pct = if ($subPct -ge 0) { 20 + [int][Math]::Round($subPct * 0.22) } else { 30 }
    if ($subPct -ge 0) { $activeBadge = "Đang tải $subPct%" }
  } else {
    $activeStep = 1
    $pct = 12
  }
  $script:lastActiveStepIndex = $activeStep

  if ($script:currentManageAction) {
    $installProgressBar.IsIndeterminate = $true
    $progressPercentText.Text = 'Đang xử lý...'
    return
  }

  $installProgressBar.IsIndeterminate = $false
  $installProgressBar.Value = $pct
  $progressPercentText.Text = "$pct%"

  for ($s = 1; $s -le 5; $s++) {
    if ($s -eq 5 -and -not $zaloOn) { Set-ChecklistStep 5 'skipped'; continue }
    if ($s -lt $activeStep) {
      if ($s -eq 2 -and -not $editorOn) { Set-ChecklistStep 2 'done' 'Đã cài Codex CLI' }
      else { Set-ChecklistStep $s 'done' }
    } elseif ($s -eq $activeStep) {
      if ($isHealing) { Set-ChecklistStep $s 'heal' }
      else { Set-ChecklistStep $s 'active' $activeBadge }
    } else {
      Set-ChecklistStep $s 'pending'
    }
  }
}

function Update-CodexAvailability {
  $info = Find-EmTroLyCodexCli
  $codexStateText.Text = $info.Label
  $codexStateText.Foreground = if ($info.Available) { New-Brush '#059669' } else { New-Brush '#D97706' }
  $codexRunBtn.IsEnabled = (-not $script:codexRunning -and $info.Available)
  $codexStopBtn.IsEnabled = $script:codexRunning
  $codexTerminalBtn.IsEnabled = (-not $script:codexRunning -and $info.Available)
  return $info
}

function Update-ZaloGlobalBadges {
  if ($script:isManageMode -and $script:zaloInstalledState) {
    $sidebarZaloPill.Visibility = [System.Windows.Visibility]::Visible
    if ($script:zaloConnectedState) {
      $sidebarZaloPill.Background = New-Brush '#ECFDF5'
      $sidebarZaloPill.BorderBrush = New-Brush '#6EE7B7'
      $sidebarZaloIconCircle.Background = New-Brush '#10B981'
      $sidebarZaloCheckIcon.Visibility = [System.Windows.Visibility]::Visible
      $sidebarZaloPendingDot.Visibility = [System.Windows.Visibility]::Collapsed
      $sidebarZaloText.Text = 'Zalo: Đã kết nối'
      $sidebarZaloText.Foreground = New-Brush '#065F46'
      $headerZaloBadge.Visibility = [System.Windows.Visibility]::Visible
    } else {
      $sidebarZaloPill.Background = New-Brush '#FFFBEB'
      $sidebarZaloPill.BorderBrush = New-Brush '#FDE68A'
      $sidebarZaloIconCircle.Background = New-Brush '#F59E0B'
      $sidebarZaloCheckIcon.Visibility = [System.Windows.Visibility]::Collapsed
      $sidebarZaloPendingDot.Visibility = [System.Windows.Visibility]::Visible
      $sidebarZaloText.Text = 'Zalo: Chưa kết nối'
      $sidebarZaloText.Foreground = New-Brush '#B45309'
      $headerZaloBadge.Visibility = [System.Windows.Visibility]::Collapsed
    }
  } else {
    $sidebarZaloPill.Visibility = [System.Windows.Visibility]::Collapsed
    $headerZaloBadge.Visibility = [System.Windows.Visibility]::Collapsed
  }
}

function Start-LiveZaloStatusSync([switch]$Force) {
  if ($SmokeTest -or -not $script:isManageMode) { return }
  if ($script:zaloSyncProc -and -not $script:zaloSyncProc.HasExited) { return }
  if (-not $Force -and $script:lastZaloSyncAt -gt (Get-Date).AddSeconds(-12)) { return }
  $st = Get-EmTroLyInstalledState
  if (-not $st.OpenClawInstalled -or -not $st.ZaloInstalled) { return }
  $bridgeScript = Resolve-HelperScript 'zalo-qr-session.mjs'
  $nodeExe = Resolve-EmTroLyNodeBinary -OpenClawRoot $st.Root
  if (-not (Test-Path -LiteralPath $bridgeScript -PathType Leaf) -or -not $nodeExe) { return }
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $nodeExe
    $psi.Arguments = '"' + $bridgeScript.Replace('"', '\"') + '" --sync-status --root "' + $st.Root.Replace('"', '\"') + '"'
    $psi.WorkingDirectory = $st.Root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:zaloSyncProc = [Diagnostics.Process]::Start($psi)
    $script:lastZaloSyncAt = Get-Date
    if (-not $liveSyncTimer.IsEnabled) { $liveSyncTimer.Start() }
  } catch { }
}

function Update-DashboardCards {
  if (-not $script:isManageMode) { return }
  $dash = if (Get-Command Get-EmTroLyLiveDashboardStatus -ErrorAction SilentlyContinue) {
    Get-EmTroLyLiveDashboardStatus
  } else { $null }
  if (-not $dash -or -not $dash.State) { return }
  $st = $dash.State
  $script:gatewayDashboardUrl = $dash.GatewayUrl
  $script:zaloInstalledState = [bool]$st.ZaloInstalled

  $dashHeroTitle.Text = "$($st.AssistantName) đã sẵn sàng trên máy"
  $dashHeroSub.Text = "Model: $($st.Model) · Owner IDs: $($st.OwnerIds) · Group: $($st.GroupId)"
  $dashOpenWebBtn.IsEnabled = (-not [string]::IsNullOrWhiteSpace($dash.GatewayUrl))

  if ($dash.GatewayOnline) {
    $cardGwDot.Fill = New-Brush '#059669'
    $cardGwBadge.Background = New-Brush '#ECFDF5'
    $cardGwBadge.BorderBrush = New-Brush '#A7F3D0'
    $cardGwBadgeText.Foreground = New-Brush '#065F46'
    $cardGwBadgeText.Text = '✓ Đang kết nối'
    $cardGwStatus.Text = "Đang hoạt động tốt tại cổng $($dash.GatewayPort) (127.0.0.1:$($dash.GatewayPort))"
  } else {
    $cardGwDot.Fill = New-Brush '#D97706'
    $cardGwBadge.Background = New-Brush '#FFFBEB'
    $cardGwBadge.BorderBrush = New-Brush '#FDE68A'
    $cardGwBadgeText.Foreground = New-Brush '#B45309'
    $cardGwBadgeText.Text = '● Chưa phản hồi'
    $cardGwStatus.Text = "Cổng $($st.GatewayPort) chưa phản hồi — bấm Khởi động lại hoặc Tự sửa lỗi bằng Codex."
  }

  if ($st.HasTelegramToken) {
    $cardTgDot.Fill = New-Brush '#059669'
    $cardTgBadge.Background = New-Brush '#ECFDF5'
    $cardTgBadge.BorderBrush = New-Brush '#A7F3D0'
    $cardTgBadgeText.Foreground = New-Brush '#065F46'
    $cardTgBadgeText.Text = '✓ Đã kết nối'
    $cardTgStatus.Text = "Đã lưu Bot Token an toàn · $($dash.OwnerCount) Owner được cấp quyền Full Exec."
  } else {
    $cardTgDot.Fill = New-Brush '#DC2626'
    $cardTgBadge.Background = New-Brush '#FEF2F2'
    $cardTgBadge.BorderBrush = New-Brush '#FECACA'
    $cardTgBadgeText.Foreground = New-Brush '#B91C1C'
    $cardTgBadgeText.Text = '✕ Thiếu Token'
    $cardTgStatus.Text = 'Chưa thấy tệp telegram.token — vào Cấu hình nhanh để cập nhật lại Token.'
  }

  $isZaloLinked = ($st.ZaloInstalled -and $dash.PSObject.Properties['ZaloLinked'] -and $dash.ZaloLinked)
  $script:zaloConnectedState = [bool]$isZaloLinked

  if ($st.ZaloInstalled) {
    if ($isZaloLinked) {
      $cardZaloDot.Fill = New-Brush '#059669'
      $cardZaloBorder.BorderBrush = New-Brush '#A7F3D0'
      $cardZaloBadge.Background = New-Brush '#ECFDF5'
      $cardZaloBadge.BorderBrush = New-Brush '#6EE7B7'
      $cardZaloBadgeIcon.Visibility = [System.Windows.Visibility]::Visible
      $cardZaloBadgeText.Foreground = New-Brush '#065F46'
      $cardZaloBadgeText.Text = 'Đã kết nối'
      $dashZaloQrBtn.Content = 'Xem kết nối / Đổi Zalo'
      $cardZaloStatus.Text = 'Tài khoản Zalo cá nhân đã kết nối trực tuyến và sẵn sàng nhận/gửi tin nhắn.'
    } else {
      $cardZaloDot.Fill = New-Brush '#D97706'
      $cardZaloBorder.BorderBrush = New-Brush '#E2E8F0'
      $cardZaloBadge.Background = New-Brush '#FFFBEB'
      $cardZaloBadge.BorderBrush = New-Brush '#FDE68A'
      $cardZaloBadgeIcon.Visibility = [System.Windows.Visibility]::Collapsed
      $cardZaloBadgeText.Foreground = New-Brush '#B45309'
      $cardZaloBadgeText.Text = '● Chưa đăng nhập'
      $dashZaloQrBtn.Content = 'Quét QR Zalo'
      $cardZaloStatus.Text = 'Đã cài plugin Zalo · Bấm "Quét QR Zalo" bên dưới để quét mã đăng nhập ngay.'
    }
  } else {
    $cardZaloDot.Fill = New-Brush '#94A3B8'
    $cardZaloBorder.BorderBrush = New-Brush '#E2E8F0'
    $cardZaloBadge.Background = New-Brush '#F1F5F9'
    $cardZaloBadge.BorderBrush = New-Brush '#E2E8F0'
    $cardZaloBadgeIcon.Visibility = [System.Windows.Visibility]::Collapsed
    $cardZaloBadgeText.Foreground = New-Brush '#64748B'
    $cardZaloBadgeText.Text = 'Chưa cài'
    $dashZaloQrBtn.Content = 'Quét QR Zalo'
    $cardZaloStatus.Text = 'Chưa cài đặt Zalo (bấm nút bên dưới để cài và hiện mã QR đăng nhập).'
  }

  $codexCliOk = if ($dash.PSObject.Properties['CodexCliInstalled']) { [bool]$dash.CodexCliInstalled } else { [bool]$st.CodexInstalled }
  $ideOk = if ($dash.PSObject.Properties['AntigravityInstalled']) { [bool]$dash.AntigravityInstalled } else { [bool]$dash.HasAntigravityShortcut }
  $extOk = if ($dash.PSObject.Properties['CodexExtensionInstalled']) { [bool]$dash.CodexExtensionInstalled } else { [bool]$dash.HasAntigravityShortcut }

  if ($codexCliOk -and $ideOk -and $extOk -and $dash.HasAntigravityShortcut) {
    $cardCodexDot.Fill = New-Brush '#059669'
    $cardCodexBadge.Background = New-Brush '#ECFDF5'
    $cardCodexBadge.BorderBrush = New-Brush '#A7F3D0'
    $cardCodexBadgeText.Foreground = New-Brush '#065F46'
    $cardCodexBadgeText.Text = '✓ Đã cài đặt'
    $cardCodexStatus.Text = 'Antigravity IDE, Codex Extension & Codex CLI đã sẵn sàng · Đã có lối tắt trên Desktop.'
  } elseif ($ideOk -and -not $extOk) {
    $cardCodexDot.Fill = New-Brush '#D97706'
    $cardCodexBadge.Background = New-Brush '#FFFBEB'
    $cardCodexBadge.BorderBrush = New-Brush '#FDE68A'
    $cardCodexBadgeText.Foreground = New-Brush '#B45309'
    $cardCodexBadgeText.Text = '● Thiếu Codex Extension'
    $cardCodexStatus.Text = 'Đã có Antigravity IDE nhưng chưa cài Codex Extension riêng (EmTroLy - Antigravity) — bấm "Cài / Sửa Antigravity" bên dưới.'
  } elseif ($codexCliOk) {
    $cardCodexDot.Fill = New-Brush '#D97706'
    $cardCodexBadge.Background = New-Brush '#FFFBEB'
    $cardCodexBadge.BorderBrush = New-Brush '#FDE68A'
    $cardCodexBadgeText.Foreground = New-Brush '#B45309'
    $cardCodexBadgeText.Text = '● Thiếu Antigravity IDE'
    $cardCodexStatus.Text = 'Đã có Codex CLI nhưng chưa cài đủ Antigravity IDE & Codex Extension riêng — bấm "Cài / Sửa Antigravity" bên dưới.'
  } else {
    $cardCodexDot.Fill = New-Brush '#D97706'
    $cardCodexBadge.Background = New-Brush '#FFFBEB'
    $cardCodexBadge.BorderBrush = New-Brush '#FDE68A'
    $cardCodexBadgeText.Foreground = New-Brush '#B45309'
    $cardCodexBadgeText.Text = '● Chưa cài'
    $cardCodexStatus.Text = 'Chưa cài Antigravity IDE & Codex CLI — bấm "Cài / Sửa Antigravity" để cài đặt tự động.'
  }

  Update-ZaloGlobalBadges
  $hasCache = ($dash.PSObject.Properties['HasZaloStatusCache'] -and $dash.HasZaloStatusCache)
  if ($st.ZaloInstalled -and (-not $hasCache -or $script:lastZaloSyncAt -lt (Get-Date).AddSeconds(-18))) {
    Start-LiveZaloStatusSync
  }
}

function Stop-ZaloQrSession {
  if ($zaloQrTimer) { $zaloQrTimer.Stop() }
  $script:zaloQrRunning = $false
  if ($script:zaloQrProcess) {
    try {
      if (-not $script:zaloQrProcess.HasExited) {
        Stop-ProcessTreeById $script:zaloQrProcess.Id
        try { $script:zaloQrProcess.Kill() } catch { }
      }
    } catch { }
    try { $script:zaloQrProcess.Dispose() } catch { }
    $script:zaloQrProcess = $null
  }
  if ($script:zaloQrDir -and (Test-Path -LiteralPath $script:zaloQrDir)) {
    Remove-Item -LiteralPath $script:zaloQrDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  $script:zaloQrDir = $null
  $script:zaloQrStateFile = $null
  $script:zaloQrPngFile = $null
  $script:zaloQrLoadedTicks = 0
}

function Set-NavActive([string]$Key) {
  if ($Key -ne 'zaloqr' -and $script:zaloQrRunning) {
    Stop-ZaloQrSession
  }
  $script:currentView = $Key
  $viewDashboard.Visibility   = [System.Windows.Visibility]::Collapsed
  $viewSetupForm.Visibility   = [System.Windows.Visibility]::Collapsed
  $viewModular.Visibility     = [System.Windows.Visibility]::Collapsed
  $viewProgress.Visibility    = [System.Windows.Visibility]::Collapsed
  $viewCodex.Visibility       = [System.Windows.Visibility]::Collapsed
  $viewDiagnostics.Visibility = [System.Windows.Visibility]::Collapsed
  $viewZaloQr.Visibility      = [System.Windows.Visibility]::Collapsed

  foreach ($b in @($navHomeBtn, $navModularBtn, $navConfigBtn, $navCodexBtn, $navDiagBtn)) {
    $b.Background = [System.Windows.Media.Brushes]::Transparent
    $b.Foreground = New-Brush '#334155'
    $b.FontWeight = [System.Windows.FontWeights]::Medium
  }

  $activeBtn = $navHomeBtn
  if ($script:installRunning -or $script:retryEditor) {
    $viewProgress.Visibility = [System.Windows.Visibility]::Visible
    $installChecklistCard.Visibility = if ($script:currentManageAction) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
    $activeBtn = if ($script:isManageMode) { $navHomeBtn } else { $navConfigBtn }
    $headerTitle.Text = if ($script:retryEditor) { 'Tiếp tục cài Antigravity & Codex CLI' } elseif ($script:currentManageAction) { 'Đang thực hiện tác vụ quản lý' } else { 'Đang cài đặt trọn gói từ A–Z' }
    $headerSubtitle.Text = 'Bạn có thể theo dõi từng bước trực quan bên dưới hoặc bấm Dừng lại / Dừng & Thoát bất cứ lúc nào'
  } elseif ($Key -eq 'home') {
    $activeBtn = $navHomeBtn
    if ($script:isManageMode) {
      $viewDashboard.Visibility = [System.Windows.Visibility]::Visible
      $headerTitle.Text = 'Bảng điều khiển tổng quan'
      $headerSubtitle.Text = 'Theo dõi trạng thái trực tiếp các thành phần và thao tác nhanh chỉ với 1 bấm'
      Update-DashboardCards
    } else {
      $viewSetupForm.Visibility = [System.Windows.Visibility]::Visible
      $headerTitle.Text = 'Cài đặt nhanh trọn gói A–Z'
      $headerSubtitle.Text = 'Chỉ cần điền 4 thông tin cơ bản — OpenClaw, Telegram, Zalo, Antigravity & Codex sẽ tự cài đầy đủ'
    }
  } elseif ($Key -eq 'modular') {
    $activeBtn = $navModularBtn
    $viewModular.Visibility = [System.Windows.Visibility]::Visible
    $headerTitle.Text = 'Cài đặt từng phần thủ công'
    $headerSubtitle.Text = 'Chọn cài riêng lẻ từng công cụ (Codex CLI · Antigravity IDE · Codex Extension · OpenClaw) hoặc tích nhiều phần'
    Update-ModularCards
  } elseif ($Key -eq 'config') {
    $activeBtn = $navConfigBtn
    if ($script:isManageMode) {
      $viewSetupForm.Visibility = [System.Windows.Visibility]::Visible
      $headerTitle.Text = 'Cấu hình & Chỉnh sửa nhanh'
      $headerSubtitle.Text = 'Đổi Owner ID, Group ID, Model hoặc Bot Token chỉ trong ~3 giây mà không cần cài lại'
    } else {
      $viewProgress.Visibility = [System.Windows.Visibility]::Visible
      $installChecklistCard.Visibility = [System.Windows.Visibility]::Visible
      $headerTitle.Text = 'Tiến trình cài đặt tự động A–Z'
      $headerSubtitle.Text = 'Danh sách 5 bước cài đặt tự động và cơ chế tự sửa lỗi bằng Codex CLI'
    }
  } elseif ($Key -eq 'codex') {
    $activeBtn = $navCodexBtn
    $viewCodex.Visibility = [System.Windows.Visibility]::Visible
    $headerTitle.Text = 'Chỉnh sửa nhanh bằng Codex CLI'
    $headerSubtitle.Text = 'Chọn thư mục và gõ yêu cầu tiếng Việt — Codex sẽ tự đọc, sửa tệp và kiểm tra giúp bạn'
    [void](Update-CodexAvailability)
  } elseif ($Key -eq 'diag') {
    $activeBtn = $navDiagBtn
    $viewDiagnostics.Visibility = [System.Windows.Visibility]::Visible
    $headerTitle.Text = 'Chẩn đoán hệ thống & Hỗ trợ'
    $headerSubtitle.Text = 'Kiểm tra kết nối mạng, cho Codex tự sửa lỗi hoặc xuất báo cáo hỗ trợ đã ẩn mã bí mật'
  } elseif ($Key -eq 'zaloqr') {
    $activeBtn = $navHomeBtn
    $viewZaloQr.Visibility = [System.Windows.Visibility]::Visible
    $headerTitle.Text = 'Đăng nhập Zalo cá nhân bằng mã QR'
    $headerSubtitle.Text = 'Mã QR được hiển thị trực tiếp tại đây và gửi đồng thời vào Telegram của Chủ sở hữu'
  }

  $activeBtn.Background = New-Brush '#EFF6FF'
  $activeBtn.Foreground = New-Brush '#2563EB'
  $activeBtn.FontWeight = [System.Windows.FontWeights]::Bold
  Set-Buttons
}

function Set-Buttons {
  $navHomeBtn.Content   = if ($script:isManageMode) { '  Tổng quan' } else { '  Cài đặt nhanh' }
  $navConfigBtn.Content = if ($script:isManageMode) { '  Cấu hình nhanh' } else { '  Tiến trình cài đặt' }

  foreach ($nb in @($navHomeBtn, $navModularBtn, $navConfigBtn, $navCodexBtn, $navDiagBtn)) {
    $nb.IsEnabled = (-not $script:installRunning -and -not $script:retryEditor)
  }

  $onCodex = ($script:currentView -eq 'codex')
  $headerQuickBtn.Content = if ($onCodex) {
    if ($script:isManageMode) { '← Về Tổng quan' } else { '← Về Cài đặt' }
  } else { 'Mở Codex CLI' }
  $headerQuickBtn.IsEnabled = (-not $script:installRunning -and -not $script:retryEditor)

  if ($script:isManageMode) {
    $sidebarStatusPill.Background = New-Brush '#ECFDF5'
    $sidebarStatusDot.Fill = New-Brush '#059669'
    $sidebarStatusText.Text = 'Đã cài đặt · Sẵn sàng'
    $sidebarStatusText.Foreground = New-Brush '#065F46'
  } else {
    $sidebarStatusPill.Background = New-Brush '#F1F5F9'
    $sidebarStatusDot.Fill = New-Brush '#94A3B8'
    $sidebarStatusText.Text = 'Chưa cài đặt'
    $sidebarStatusText.Foreground = New-Brush '#475569'
  }
  Update-ZaloGlobalBadges

  # ALWAYS allow stopping & exiting cleanly while running!
  if ($script:installRunning) {
    $footerHintText.Text = 'Đang chạy... Bạn có thể bấm "Dừng lại" hoặc "Dừng & Thoát" bất cứ lúc nào.'
    $stopTaskButton.Visibility = [System.Windows.Visibility]::Visible
    $stopTaskButton.IsEnabled = $true
    $primaryActionBtn.Visibility = [System.Windows.Visibility]::Collapsed
    $cancelButton.Content = 'Dừng & Thoát'
    $cancelButton.Style = $window.FindResource('DangerBtn')
    $cancelButton.MinWidth = 148
    $cancelButton.IsEnabled = $true
    return
  }

  $stopTaskButton.Visibility = [System.Windows.Visibility]::Collapsed

  if ($onCodex -and $script:codexRunning) {
    $cancelButton.Content = 'Dừng & Thoát'
    $cancelButton.Style = $window.FindResource('DangerBtn')
    $cancelButton.MinWidth = 148
  } else {
    $cancelButton.Content = 'Thoát'
    $cancelButton.Style = $window.FindResource('SecondaryBtn')
    $cancelButton.MinWidth = 98
  }
  $cancelButton.IsEnabled = $true

  if ($script:retryEditor) {
    $footerHintText.Text = 'OpenClaw đã chạy tốt. Nhập API Key rồi bấm Thử lại bước Codex.'
    $primaryActionBtn.Visibility = [System.Windows.Visibility]::Visible
    $primaryActionBtn.Content = 'Thử lại bước Codex'
    $primaryActionBtn.IsEnabled = $true
  } elseif ($onCodex -or $script:currentView -eq 'diag' -or $script:currentView -eq 'zaloqr') {
    $footerHintText.Text = if ($script:currentView -eq 'zaloqr') { 'Quét mã QR trên màn hình hoặc trong Telegram — tự báo hoàn tất ngay khi đăng nhập.' } else { 'Mẹo: Mọi mã bí mật đều được lưu cục bộ an toàn trên máy bạn.' }
    $primaryActionBtn.Visibility = [System.Windows.Visibility]::Collapsed
  } elseif ($script:currentView -eq 'modular') {
    $footerHintText.Text = 'Tích chọn các phần muốn cài (hoặc bấm "Cài phần này" trên từng dòng) rồi bấm nút bên phải.'
    $primaryActionBtn.Visibility = [System.Windows.Visibility]::Visible
    $primaryActionBtn.Content = 'Cài các phần đã chọn'
    $primaryActionBtn.IsEnabled = $true
  } elseif ($script:isManageMode) {
    $footerHintText.Text = 'Sửa ô nào lưu ô đó (~3 giây) · Giữ nguyên lịch sử & dữ liệu cũ.'
    $primaryActionBtn.Visibility = [System.Windows.Visibility]::Visible
    $primaryActionBtn.Content = if ($script:currentView -eq 'home') { 'Cấu hình nhanh' } else { 'Lưu thay đổi' }
    $primaryActionBtn.IsEnabled = $true
  } else {
    $footerHintText.Text = 'Mẹo: Dán Bot Token rồi bấm "Lấy ID tự động" để khỏi tìm thủ công.'
    $primaryActionBtn.Visibility = [System.Windows.Visibility]::Visible
    $primaryActionBtn.Content = 'Cài đặt trọn gói A–Z'
    $primaryActionBtn.IsEnabled = $true
  }
}

function Stop-ActiveRunner([string]$ReasonMessage = 'Đã dừng tiến trình theo yêu cầu của bạn.') {
  $installTimer.Stop()
  $proc = $script:runnerProcess
  $script:runnerProcess = $null
  $script:installRunning = $false
  $script:currentManageAction = ''
  if ($proc) {
    $procId = 0
    try { $procId = [int]$proc.Id } catch { }
    if ($procId -gt 0) { Stop-ProcessTreeById $procId }
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
    try { [void]$proc.WaitForExit(2000) } catch { }
    try { $proc.Dispose() } catch { }
  }
  Cleanup-Secret
  $installProgressBar.IsIndeterminate = $false
  if (-not [string]::IsNullOrWhiteSpace($ReasonMessage)) {
    $statusText.Text = $ReasonMessage
  }
  if (-not $script:retryEditor -and -not $script:installCompleted) {
    $script:resultCode = 2
  }
  Set-Buttons
}

function Save-CurrentFormDraft {
  param([switch]$PreserveExistingSecrets)
  if (-not (Get-Command Save-EmTroLySetupDraft -ErrorAction SilentlyContinue)) { return }
  $tokVal = $tokenBox.Text.Trim()
  $keyVal = $apiKeyBox.Text.Trim()
  if ($PreserveExistingSecrets) {
    $prevDraft = if (Get-Command Get-EmTroLySavedSetupDraft -ErrorAction SilentlyContinue) { Get-EmTroLySavedSetupDraft } else { $null }
    if ([string]::IsNullOrWhiteSpace($tokVal) -and $prevDraft -and $prevDraft.telegram_token) {
      $tokVal = ([string]$prevDraft.telegram_token).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($keyVal)) {
      if ($prevDraft -and $prevDraft.ai_api_key) {
        $keyVal = ([string]$prevDraft.ai_api_key).Trim()
      } elseif (-not [string]::IsNullOrWhiteSpace($script:sessionApiKeyFallback)) {
        $keyVal = $script:sessionApiKeyFallback.Trim()
      }
    }
  }
  $draftObj = [ordered]@{
    telegram_token     = $tokVal
    ai_api_key         = $keyVal
    owner_ids          = $ownersBox.Text.Trim()
    group_id           = $groupBox.Text.Trim()
    model              = ([string]$modelBox.SelectedItem).Trim()
    assistant_name     = $assistantBox.Text.Trim()
    base_url           = $baseUrlBox.Text.Trim().TrimEnd('/')
    gateway_port       = $portBox.Text.Trim()
    qr_owner_id        = $qrOwnerBox.Text.Trim()
    audience           = $audienceBox.Text.Trim()
    addressing         = $addressingBox.Text.Trim()
    style              = $styleBox.Text.Trim()
    configure_zalo     = [bool]$zaloCheck.Checked
    skip_editor        = [bool]$existingEditorCheck.Checked
    accept_full_access = [bool]$fullAccessCheck.Checked
  }
  [void](Save-EmTroLySetupDraft -Draft $draftObj)
  $script:draftDirty = $false
}

function Apply-SavedSetupDraft {
  if ($script:isManageMode -or $script:retryEditor) { return $false }
  if (-not (Get-Command Get-EmTroLySavedSetupDraft -ErrorAction SilentlyContinue)) { return $false }
  $draft = Get-EmTroLySavedSetupDraft
  if (-not $draft) { return $false }

  $script:draftHydrating = $true
  $restoredAny = $false
  try {
    if ($draft.telegram_token) { $tokenBox.Text = [string]$draft.telegram_token; $restoredAny = $true }
    if ($draft.ai_api_key) { $apiKeyBox.Text = [string]$draft.ai_api_key }
    if ($draft.owner_ids) { $ownersBox.Text = [string]$draft.owner_ids; $restoredAny = $true }
    if ($draft.group_id) { $groupBox.Text = [string]$draft.group_id; $restoredAny = $true }
    if ($draft.assistant_name) {
      $assistantBox.Text = [string]$draft.assistant_name
      if ([string]$draft.assistant_name -cne 'Trợ lý OpenClaw') { $restoredAny = $true }
    }
    if ($draft.model) {
      for ($i = 0; $i -lt $modelBox.Items.Count; $i++) {
        if ([string]$modelBox.Items[$i] -ieq [string]$draft.model) {
          $modelBox.SelectedIndex = $i
          if ($i -ne 0) { $restoredAny = $true }
          break
        }
      }
    }
    if ($draft.gateway_port) {
      $portBox.Text = [string]$draft.gateway_port
      if ([string]$draft.gateway_port -ne '0') { $restoredAny = $true }
    }
    if ($draft.qr_owner_id) { $qrOwnerBox.Text = [string]$draft.qr_owner_id; $restoredAny = $true }
    if ($draft.audience) { $audienceBox.Text = [string]$draft.audience; $restoredAny = $true }
    if ($draft.addressing) { $addressingBox.Text = [string]$draft.addressing; $restoredAny = $true }
    if ($draft.style) { $styleBox.Text = [string]$draft.style; $restoredAny = $true }
    if ($null -ne $draft.PSObject.Properties['configure_zalo']) {
      $zaloCheck.Checked = [bool]$draft.configure_zalo
    }
    if ($null -ne $draft.PSObject.Properties['skip_editor']) {
      $existingEditorCheck.Checked = [bool]$draft.skip_editor
    }
    if ($null -ne $draft.PSObject.Properties['accept_full_access']) {
      $fullAccessCheck.Checked = [bool]$draft.accept_full_access
    }
  } finally {
    $script:draftHydrating = $false
    $script:draftDirty = $false
  }

  if ($restoredAny) {
    $savedWhen = if ($draft.savedAt) { " ($($draft.savedAt))" } else { '' }
    $savedDraftBannerText.Text = "✓ Đã tự động điền lại các thông số bạn đã nhập ở lần trước$savedWhen — lưu mã hóa an toàn trên máy."
    $savedDraftBanner.Visibility = [System.Windows.Visibility]::Visible
  }
  return $restoredAny
}

function Clear-SavedDraftAction {
  if (Get-Command Clear-EmTroLySavedSetupDraft -ErrorAction SilentlyContinue) {
    Clear-EmTroLySavedSetupDraft
  }
  $script:draftHydrating = $true
  try {
    $tokenBox.Clear()
    $ownersBox.Text = ''
    $groupBox.Text = ''
    $assistantBox.Text = 'Trợ lý OpenClaw'
    $modelBox.SelectedIndex = 0
    $portBox.Text = '0'
    $qrOwnerBox.Text = ''
    $audienceBox.Text = ''
    $addressingBox.Text = ''
    $styleBox.Text = ''
    $zaloCheck.Checked = $true
    $existingEditorCheck.Checked = $false
    $fullAccessCheck.Checked = $false
    if (-not [string]::IsNullOrWhiteSpace($script:sessionApiKeyFallback)) {
      $apiKeyBox.Text = $script:sessionApiKeyFallback
    } else {
      $apiKeyBox.Clear()
    }
    $savedDraftBanner.Visibility = [System.Windows.Visibility]::Collapsed
  } finally {
    $script:draftHydrating = $false
    $script:draftDirty = $false
  }
}

function Apply-ManageModeUI {
  $st = Get-EmTroLyInstalledState
  if (-not $st.OpenClawInstalled) { return }
  $script:isManageMode = $true
  $script:installCompleted = $true
  $script:resultCode = 0
  $script:draftHydrating = $true
  try {
    $assistantBox.Text = $st.AssistantName
    $baseUrlBox.Text = $st.BaseUrl
    for ($i = 0; $i -lt $modelBox.Items.Count; $i++) {
      if ([string]$modelBox.Items[$i] -ieq [string]$st.Model) {
        $modelBox.SelectedIndex = $i
        break
      }
    }
    $ownersBox.Text = $st.OwnerIds
    $groupBox.Text = $st.GroupId
    $portBox.Text = $st.GatewayPort
    $audienceBox.Text = $st.Audience
    $addressingBox.Text = $st.Addressing
    $styleBox.Text = $st.Style
    $fullAccessCheck.Checked = $true
    $zaloCheck.Checked = $st.ZaloInstalled
    if ($st.OwnerIds) {
      $qrOwnerBox.Text = (($ownersBox.Text -split ',')[0]).Trim()
    }
  } finally {
    $script:draftHydrating = $false
    $script:draftDirty = $false
  }

  $manageEditBanner.Visibility = [System.Windows.Visibility]::Visible
  $savedDraftBanner.Visibility = [System.Windows.Visibility]::Collapsed
  $installOptionsCard.Visibility = [System.Windows.Visibility]::Collapsed
  $tokenFieldLabel.Text = 'Telegram Bot Token mới (để trống = giữ nguyên mã cũ)'
  $apiKeyFieldLabel.Text = 'Provider API Key mới (để trống = giữ nguyên mã cũ)'
  Update-DashboardCards
}

function Test-FormInputs([bool]$ForManageConfig = $false) {
  if (Get-Command Normalize-EmTroLyCustomerInputs -ErrorAction SilentlyContinue) {
    $normForm = Normalize-EmTroLyCustomerInputs -Inputs @{
      assistant_name = $assistantBox.Text
      base_url       = $baseUrlBox.Text
      model          = [string]$modelBox.SelectedItem
      owner_ids      = $ownersBox.Text
      group_id       = $groupBox.Text
      gateway_port   = $portBox.Text
      qr_owner_id    = $qrOwnerBox.Text
      telegram_token = $tokenBox.Text
      ai_api_key     = $apiKeyBox.Text
      audience       = $audienceBox.Text
      addressing     = $addressingBox.Text
      style          = $styleBox.Text
      configure_zalo = [bool]$zaloCheck.Checked
    }
    $prevHydrate = $script:draftHydrating
    $script:draftHydrating = $true
    try {
      $assistantBox.Text = $normForm.assistant_name
      $baseUrlBox.Text   = $normForm.base_url
      $ownersBox.Text    = $normForm.owner_ids
      $groupBox.Text     = $normForm.group_id
      $portBox.Text      = $normForm.gateway_port
      $qrOwnerBox.Text   = $normForm.qr_owner_id
      if (-not [string]::IsNullOrWhiteSpace($tokenBox.Text)) { $tokenBox.Text = $normForm.telegram_token }
      if (-not [string]::IsNullOrWhiteSpace($apiKeyBox.Text)) { $apiKeyBox.Text = $normForm.ai_api_key }
    } finally {
      $script:draftHydrating = $prevHydrate
    }
  }
  if ([string]::IsNullOrWhiteSpace($assistantBox.Text)) { Show-Error 'Hãy nhập tên trợ lý hiển thị.'; return $false }
  if ($baseUrlBox.Text.Trim().TrimEnd('/') -cne 'https://codex.anhlaptrinh.vn/v1') { Show-Error 'Chỉ hỗ trợ máy chủ chính thức https://codex.anhlaptrinh.vn/v1.'; return $false }
  if ([string]$modelBox.SelectedItem -notin @('gpt-6.2-sol', 'GPT-6.1-terra', 'gpt-6.2-astra')) { Show-Error 'Model phải là gpt-6.2-sol, GPT-6.1-terra hoặc gpt-6.2-astra.'; return $false }
  if ($ownersBox.Text.Trim() -notmatch '^[1-9][0-9]*(,[1-9][0-9]*)*$') { Show-Error 'Telegram Owner IDs không hợp lệ (nhập số dương, cách nhau bởi dấu phẩy).'; return $false }
  if ($groupBox.Text.Trim() -notmatch '^-[1-9][0-9]*$') { Show-Error 'Telegram Group ID phải là số âm (ví dụ: -1001234567890).'; return $false }
  $portVal = 0
  if (-not [int]::TryParse($portBox.Text.Trim(), [ref]$portVal) -or ($portVal -ne 0 -and ($portVal -lt 1024 -or $portVal -gt 65000))) {
    Show-Error 'Cổng Gateway phải là 0 hoặc từ 1024 đến 65000.'
    return $false
  }

  if ($ForManageConfig) {
    if (-not [string]::IsNullOrWhiteSpace($tokenBox.Text) -and $tokenBox.Text.Trim() -notmatch '^[0-9]{5,}:[A-Za-z0-9_-]{20,}$') {
      Show-Error 'Telegram Bot Token mới không đúng định dạng (hoặc xóa trống để giữ nguyên Token cũ).'
      return $false
    }
  } else {
    if ([string]::IsNullOrWhiteSpace($tokenBox.Text)) { Show-Error 'Hãy nhập Telegram Bot Token.'; return $false }
    if ([string]::IsNullOrWhiteSpace($apiKeyBox.Text)) { Show-Error 'Hãy nhập Provider API Key.'; return $false }
    if (-not $fullAccessCheck.Checked) { Show-Error 'Hãy tích xác nhận bạn hiểu và đồng ý cấp quyền Full Exec.'; return $false }
    if ($zaloCheck.Checked) {
      if ([string]::IsNullOrWhiteSpace($qrOwnerBox.Text)) {
        $qrOwnerBox.Text = (($ownersBox.Text -split ',')[0]).Trim()
      }
      if ($qrOwnerBox.Text.Trim() -notmatch '^[1-9][0-9]*$' -or ((',' + $ownersBox.Text.Trim() + ',') -notmatch (',' + [regex]::Escape($qrOwnerBox.Text.Trim()) + ','))) {
        Show-Error 'QR Owner ID phải nằm trong danh sách Telegram Owner IDs.'
        return $false
      }
    }
  }
  return $true
}

function Show-LicenseGate([string]$ErrorMessage = '', [switch]$AllowCancel) {
  $script:licenseCanDismiss = ([bool]$AllowCancel -and $script:licenseVerified)
  if (-not $script:licenseCanDismiss) {
    $script:licenseVerified = $false
    $sidebarLicensePill.Visibility = [System.Windows.Visibility]::Collapsed
    if ($sidebarSignOutLicenseBtn) { $sidebarSignOutLicenseBtn.Visibility = [System.Windows.Visibility]::Collapsed }
  }
  $licenseGateOverlay.Visibility = [System.Windows.Visibility]::Visible
  $licenseCheckingBox.Visibility = [System.Windows.Visibility]::Collapsed
  $licenseInputBox.Visibility = [System.Windows.Visibility]::Visible
  $licenseActivateBtn.IsEnabled = $true
  $licenseActivateBtn.Content = 'Kích hoạt & Mở khóa phần mềm'
  $licenseExitBtn.Content = if ($script:licenseCanDismiss) { 'Quay lại' } else { 'Thoát' }
  if ($licenseSignOutBtn) {
    $licenseSignOutBtn.Visibility = if ($script:licenseCanDismiss) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  }
  if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
    $licenseMsgBanner.Visibility = [System.Windows.Visibility]::Visible
    $licenseMsgText.Text = $ErrorMessage
  } else {
    $licenseMsgBanner.Visibility = [System.Windows.Visibility]::Collapsed
    $licenseMsgText.Text = ''
  }
}

function Unlock-LicenseGate([string]$VerifiedKey, [switch]$SkipSave) {
  $script:licenseVerified = $true
  $script:licenseCanDismiss = $false
  $cleanKey = if ($VerifiedKey) { $VerifiedKey.Trim() } else { '' }
  if ($cleanKey) {
    $script:sessionApiKeyFallback = $cleanKey
    if (-not $SkipSave -and (Get-Command Save-EmTroLyLicenseKey -ErrorAction SilentlyContinue)) {
      Save-EmTroLyLicenseKey -ApiKey $cleanKey
    }
    if (-not $script:isManageMode) {
      $prevHydr = $script:draftHydrating
      $script:draftHydrating = $true
      try {
        if (-not $SkipSave -or [string]::IsNullOrWhiteSpace($apiKeyBox.Text)) {
          $apiKeyBox.Text = $cleanKey
        }
        if ($apiKeyBox.Text.Trim() -ceq $cleanKey) {
          $apiKeyFieldLabel.Text = 'Provider API Key (✓ Đã tự động điền từ khóa kích hoạt trên máy)'
        }
      } finally {
        $script:draftHydrating = $prevHydr
      }
    }
    if ($script:retryEditor -and [string]::IsNullOrWhiteSpace($retryKeyPwdBox.Password)) {
      $retryKeyPwdBox.Password = $cleanKey
    }
  }
  $licenseKeyBox.Clear()
  if ($licenseSignOutBtn) { $licenseSignOutBtn.Visibility = [System.Windows.Visibility]::Collapsed }
  $licenseGateOverlay.Visibility = [System.Windows.Visibility]::Collapsed
  $sidebarLicensePill.Visibility = [System.Windows.Visibility]::Visible
  if ($sidebarSignOutLicenseBtn) { $sidebarSignOutLicenseBtn.Visibility = [System.Windows.Visibility]::Visible }
  if ($script:isManageMode) {
    Update-DashboardCards
  }
}

function Invoke-UiLicenseSignOut {
  if ($script:installRunning -or $script:codexRunning -or $script:licenseCheckRunning) {
    Show-Error 'Hãy đợi tiến trình đang chạy hoàn tất trước khi thoát bản quyền.'
    return
  }
  $ansOut = [System.Windows.MessageBox]::Show(
    $window,
    "Bạn có muốn thoát bản quyền trên giao diện ứng dụng không?`n`n• Các trợ lý OpenClaw và công cụ CLI đã cài trước đó vẫn tiếp tục hoạt động bình thường.`n• Giao diện ứng dụng sẽ khóa lại ngay lập tức và bắt buộc phải nhập lại Token API trên codex.anhlaptrinh.vn (kể cả khi tắt đi mở lại).",
    'Xác nhận thoát bản quyền ứng dụng',
    [System.Windows.MessageBoxButton]::YesNo,
    [System.Windows.MessageBoxImage]::Question
  )
  if ($ansOut -ne [System.Windows.MessageBoxResult]::Yes) { return }

  Stop-ZaloQrSession
  if (Get-Command Invoke-EmTroLyLicenseSignOut -ErrorAction SilentlyContinue) {
    Invoke-EmTroLyLicenseSignOut
  }
  $script:licenseVerified = $false
  $script:licenseCanDismiss = $false
  $script:sessionApiKeyFallback = ''
  $prevHyd = $script:draftHydrating
  $script:draftHydrating = $true
  try {
    $apiKeyBox.Clear()
    $retryKeyPwdBox.Clear()
    $licenseKeyBox.Clear()
    if (-not $script:isManageMode) {
      $apiKeyFieldLabel.Text = 'Provider API Key (dùng chung cho OpenClaw & Codex CLI)'
    }
  } finally {
    $script:draftHydrating = $prevHyd
    $script:draftDirty = $false
  }
  Show-LicenseGate 'Đã thoát bản quyền ứng dụng. Vui lòng nhập lại Khóa kích hoạt (Provider API Key trên codex.anhlaptrinh.vn) để mở khóa.'
  [void]$licensePwdBox.Focus()
}

function Set-ModularBadgeVisual($BadgeBorder, $BadgeTextCtrl, [bool]$Installed) {
  if ($Installed) {
    $BadgeBorder.Background = New-Brush '#ECFDF5'
    $BadgeBorder.BorderBrush = New-Brush '#A7F3D0'
    $BadgeTextCtrl.Foreground = New-Brush '#065F46'
    $BadgeTextCtrl.Text = '✓ Đã cài đặt'
  } else {
    $BadgeBorder.Background = New-Brush '#F1F5F9'
    $BadgeBorder.BorderBrush = New-Brush '#E2E8F0'
    $BadgeTextCtrl.Foreground = New-Brush '#475569'
    $BadgeTextCtrl.Text = '○ Chưa cài'
  }
}

function Update-ModularCards {
  if (-not (Get-Command Get-EmTroLyModularStatus -ErrorAction SilentlyContinue)) { return $null }
  $ms = Get-EmTroLyModularStatus
  if (-not $ms) { return $null }

  Set-ModularBadgeVisual $modBadge1 $modBadgeText1 ([bool]$ms.CodexCliInstalled)
  $modDetail1.Text = $ms.CodexCliDetail
  $modInstall1Btn.Content = if ($ms.CodexCliInstalled) { 'Cập nhật / Cài lại' } else { 'Cài phần này' }

  Set-ModularBadgeVisual $modBadge2 $modBadgeText2 ([bool]$ms.AntigravityInstalled)
  $modDetail2.Text = $ms.AntigravityDetail
  $modInstall2Btn.Content = if ($ms.AntigravityInstalled) { 'Kiểm tra / Sửa lại' } else { 'Cài phần này' }

  Set-ModularBadgeVisual $modBadge3 $modBadgeText3 ([bool]$ms.CodexExtensionInstalled)
  $modDetail3.Text = $ms.CodexExtensionDetail
  $modInstall3Btn.Content = if ($ms.CodexExtensionInstalled) { 'Đồng bộ / Cài lại' } else { 'Cài phần này' }

  if (-not $script:installRunning) {
    $modCheck1.IsChecked = (-not [bool]$ms.CodexCliInstalled)
    $modCheck2.IsChecked = (-not [bool]$ms.AntigravityInstalled)
    $modCheck3.IsChecked = (-not [bool]$ms.CodexExtensionInstalled)
  }

  Set-ModularBadgeVisual $modBadge4 $modBadgeText4 ([bool]$ms.OpenClawInstalled)
  $modDetail4.Text = $ms.OpenClawDetail
  if ($ms.OpenClawInstalled) {
    $modInstall4Btn.Content = 'Mở Cấu hình nhanh'
    $modCheck4.IsChecked = $false
    $modCheck4.IsEnabled = $false
    $modOpenClawInputsBox.Visibility = [System.Windows.Visibility]::Collapsed
  } else {
    $modInstall4Btn.Content = 'Cài phần này'
    $modCheck4.IsEnabled = $true
    $modOpenClawInputsBox.Visibility = [System.Windows.Visibility]::Visible
    if ([string]::IsNullOrWhiteSpace($modOwnersBox.Text) -and -not [string]::IsNullOrWhiteSpace($ownersBox.Text)) {
      $modOwnersBox.Text = $ownersBox.Text
    }
    if ([string]::IsNullOrWhiteSpace($modGroupBox.Text) -and -not [string]::IsNullOrWhiteSpace($groupBox.Text)) {
      $modGroupBox.Text = $groupBox.Text
    }
    if ([string]::IsNullOrWhiteSpace($modTokenPwdBox.Password) -and -not [string]::IsNullOrWhiteSpace($tokenBox.Text)) {
      $modTokenPwdBox.Password = $tokenBox.Text
    }
  }
  return $ms
}

function Start-ModularInstall([string[]]$SelectedList) {
  if (-not $script:licenseVerified -and -not $SmokeTest) {
    Show-LicenseGate 'Vui lòng kích hoạt bản quyền trước khi cài đặt thành phần.'
    return
  }
  if ($script:installRunning) { return }
  $cleanSelected = @($SelectedList | Where-Object { $_ })
  if ($cleanSelected.Count -eq 0) {
    Show-Error 'Hãy tích chọn ít nhất 1 thành phần (hoặc bấm "Cài phần này" trên dòng tương ứng).'
    return
  }

  $msNow = Update-ModularCards
  if ($cleanSelected.Count -eq 1 -and $cleanSelected[0] -eq 'openclaw' -and $msNow -and $msNow.OpenClawInstalled) {
    Set-NavActive 'config'
    return
  }

  if ('codex-extension' -in $cleanSelected -and 'antigravity-ide' -notin $cleanSelected -and $msNow -and (-not $msNow.AntigravityInstalled)) {
    $askIde = [System.Windows.MessageBox]::Show(
      $window,
      'Máy chưa có Antigravity IDE (Phần 2). Bạn có muốn tự động tải & cài Antigravity IDE trước rồi cài luôn Codex Extension không?',
      'Tự động cài kèm Antigravity IDE',
      [System.Windows.MessageBoxButton]::YesNo,
      [System.Windows.MessageBoxImage]::Question
    )
    if ($askIde -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $cleanSelected = @('antigravity-ide') + $cleanSelected
  }

  $effectiveKey = if (-not [string]::IsNullOrWhiteSpace($apiKeyBox.Text)) {
    $apiKeyBox.Text.Trim()
  } elseif (-not [string]::IsNullOrWhiteSpace($script:sessionApiKeyFallback)) {
    $script:sessionApiKeyFallback.Trim()
  } elseif (Get-Command Get-EmTroLySavedLicenseKey -ErrorAction SilentlyContinue) {
    (Get-EmTroLySavedLicenseKey).Trim()
  } else { '' }

  if ([string]::IsNullOrWhiteSpace($effectiveKey)) {
    Show-LicenseGate 'Vui lòng nhập lại Khóa kích hoạt (Provider API Key) trên codex.anhlaptrinh.vn.'
    return
  }

  $chosenModel = if ($modModelBox -and $modModelBox.SelectedItem) { ([string]$modModelBox.SelectedItem).Trim() } else { ([string]$modelBox.SelectedItem).Trim() }
  if ([string]::IsNullOrWhiteSpace($chosenModel)) { $chosenModel = 'gpt-6.2-sol' }

  $wantOc = ('openclaw' -in $cleanSelected)
  if ($wantOc) {
    if ($msNow -and $msNow.OpenClawInstalled) {
      Show-Error 'Trợ lý OpenClaw đã được cài trên máy. Nếu muốn cài lại từ đầu, hãy vào Chẩn đoán & Hỗ trợ → Gỡ trợ lý để cài lại.'
      return
    }
    if (-not [string]::IsNullOrWhiteSpace($modTokenPwdBox.Password)) { $tokenBox.Text = $modTokenPwdBox.Password.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($modOwnersBox.Text)) { $ownersBox.Text = $modOwnersBox.Text.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($modGroupBox.Text)) { $groupBox.Text = $modGroupBox.Text.Trim() }
    if ([string]::IsNullOrWhiteSpace($apiKeyBox.Text)) { $apiKeyBox.Text = $effectiveKey }
    $zaloCheck.Checked = [bool]$modZaloCheck.IsChecked
    $fullAccessCheck.Checked = $true
    if (-not (Test-FormInputs -ForManageConfig $false)) { return }
    $ansExecMod = [System.Windows.MessageBox]::Show(
      $window,
      'Cài đặt Phần 4 (OpenClaw) sẽ cấp quyền Full Exec cho các Owner IDs và nhóm Telegram đã chọn. Bạn xác nhận tin tưởng và tiếp tục?',
      'Xác nhận Full Exec cho OpenClaw',
      [System.Windows.MessageBoxButton]::YesNo,
      [System.Windows.MessageBoxImage]::Warning
    )
    if ($ansExecMod -ne [System.Windows.MessageBoxResult]::Yes) { return }
  }

  $script:installRunning = $true
  $script:currentManageAction = ''
  Reset-ProgressVisualState
  $retryEditorPanel.Visibility = [System.Windows.Visibility]::Collapsed
  $statusText.Text = 'Đang khởi động cài đặt thành phần đã chọn (' + ($cleanSelected -join ', ') + ')...'
  $installProgressBar.IsIndeterminate = $true
  $progressPercentText.Text = 'Đang xử lý...'
  Set-NavActive 'progress'

  try {
    $modSettings = [ordered]@{
      member             = 'emtroly'
      components         = $cleanSelected
      assistant_name     = if ([string]::IsNullOrWhiteSpace($assistantBox.Text)) { 'Trợ lý OpenClaw' } else { $assistantBox.Text.Trim() }
      base_url           = 'https://codex.anhlaptrinh.vn/v1'
      model              = $chosenModel
      owner_ids          = $ownersBox.Text.Trim()
      group_id           = $groupBox.Text.Trim()
      gateway_port       = if ([string]::IsNullOrWhiteSpace($portBox.Text)) { '0' } else { $portBox.Text.Trim() }
      audience           = $audienceBox.Text.Trim()
      addressing         = $addressingBox.Text.Trim()
      style              = $styleBox.Text.Trim()
      accept_full_access = $wantOc
      configure_zalo     = [bool]$modZaloCheck.IsChecked
      skip_editor        = ('antigravity-ide' -notin $cleanSelected -and 'codex-extension' -notin $cleanSelected)
      qr_owner_id        = $qrOwnerBox.Text.Trim()
      telegram_token     = if ($wantOc) { $tokenBox.Text.Trim() } else { '' }
      ai_api_key         = $effectiveKey
    }

    $script:privateDir = Join-Path $env:TEMP ('openclaw-modular-' + [guid]::NewGuid().ToString('N'))
    New-CodexPrivateDirectory $script:privateDir
    $script:secretFile = Join-Path $script:privateDir 'settings.json'
    $script:safeLog = Join-Path $script:privateDir 'status.txt'
    [IO.File]::WriteAllText($script:secretFile, ($modSettings | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

    $runner = Join-Path $PayloadRoot 'windows-installer\run-native-install.ps1'
    $shellPath = Join-Path $PSHOME 'powershell.exe'
    $compCsv = ($cleanSelected -join ',')
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $shellPath
    $startInfo.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
      $runner + '" -SettingsFile "' + $script:secretFile +
      '" -PayloadRoot "' + $PayloadRoot + '" -LogFile "' + $script:safeLog + '" -Components "' + $compCsv + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $script:runnerProcess = [Diagnostics.Process]::Start($startInfo)
    try { $script:runnerProcess.StandardInput.Close() } catch { }
    $script:runnerDeadline = (Get-Date).AddMinutes(90)
    $modTokenPwdBox.Clear()
    $installTimer.Start()
  } catch {
    Cleanup-Secret
    $script:installRunning = $false
    Set-Buttons
    Show-Error 'Không thể khởi động trình cài đặt từng phần. Hãy kiểm tra quyền thư mục tạm.'
  }
}

function Invoke-LicenseVerifyFlow([string]$CandidateKey, [bool]$IsStartupAuto = $false) {
  if ($script:licenseCheckRunning) { return }
  $keyToCheck = if ($null -ne $CandidateKey) { $CandidateKey.Trim() } else { '' }
  if ([string]::IsNullOrWhiteSpace($keyToCheck)) {
    $emptyMsg = if ($IsStartupAuto) { '' } else { 'Vui lòng nhập Khóa kích hoạt (Provider API Key) do Anh Lập Trình cấp.' }
    Show-LicenseGate $emptyMsg
    return
  }

  $script:licenseCheckRunning = $true
  $licenseGateOverlay.Visibility = [System.Windows.Visibility]::Visible
  $licenseCheckingBox.Visibility = [System.Windows.Visibility]::Collapsed
  $licenseInputBox.Visibility = [System.Windows.Visibility]::Visible
  $licenseActivateBtn.IsEnabled = $false
  $licenseActivateBtn.Content = 'Đang xác thực...'
  $licenseMsgBanner.Visibility = [System.Windows.Visibility]::Collapsed

  Start-AsyncUiTask -Params @{ HelperPath = $wizardHelperPath; Key = $keyToCheck } -Work {
    param($HelperPath, $Key)
    . ([ScriptBlock]::Create([IO.File]::ReadAllText($HelperPath, [System.Text.Encoding]::UTF8)))
    $chk = Test-EmTroLyLicenseKey -ApiKey $Key
    return [pscustomobject]@{ Result = $chk; Key = $Key }
  } -OnComplete {
    param($payload, $err)
    $script:licenseCheckRunning = $false
    if ($err -or -not $payload -or -not $payload.Result) {
      Show-LicenseGate 'Không thể kết nối máy chủ xác thực codex.anhlaptrinh.vn. Hãy kiểm tra mạng và thử lại.'
      return
    }
    $r = $payload.Result
    if ($r.Valid) {
      Unlock-LicenseGate $payload.Key
      return
    }
    Show-LicenseGate ([string]$r.Message)
  }
}

function Reset-ProgressVisualState {
  $progressCard.Background = New-Brush '#EFF6FF'
  $progressCard.BorderBrush = New-Brush '#BFDBFE'
  $progressPercentText.Foreground = New-Brush '#2563EB'
  $installProgressBar.Foreground = New-Brush '#2563EB'
  $installProgressBar.Background = New-Brush '#DBEAFE'
  if ($autoHealNoteBorder) { $autoHealNoteBorder.Visibility = [System.Windows.Visibility]::Visible }
  $installFailureActions.Visibility = [System.Windows.Visibility]::Collapsed
  $btnCopyErrorDetail.Content = 'Sao chép lỗi'
}

function Show-RichFailureDiagnostics([string]$SummaryMessage, [object]$DiagPayload = $null, [bool]$IsManageFailure = $false) {
  $progressCard.Background = New-Brush '#FEF2F2'
  $progressCard.BorderBrush = New-Brush '#FCA5A5'
  $installProgressBar.IsIndeterminate = $false
  $installProgressBar.Foreground = New-Brush '#DC2626'
  $installProgressBar.Background = New-Brush '#FEE2E2'
  if ([int]$installProgressBar.Value -lt 12) { $installProgressBar.Value = 25 }
  $progressPercentText.Text = 'Gặp sự cố'
  $progressPercentText.Foreground = New-Brush '#DC2626'

  $stepIdx = [Math]::Max(1, [Math]::Min(5, [int]$script:lastActiveStepIndex))
  if (-not $IsManageFailure) {
    Set-ChecklistStep $stepIdx 'error' 'Gặp lỗi'
  }

  $stageMap = @{
    'input' = 'Bước 1 · Kiểm tra thông tin đầu vào'
    'provider' = 'Bước 1 · Kết nối máy chủ AI (codex.anhlaptrinh.vn)'
    'telegram' = 'Bước 1 · Kiểm tra Telegram Bot Token'
    'codex-cli' = 'Bước 2 · Cài đặt ưu tiên Codex CLI'
    'editor' = 'Bước 2 · Cài Antigravity IDE & Codex Extension'
    'install' = 'Bước 4 · Cài đặt OpenClaw & Gateway'
    'command' = 'Bước 4 · Đăng ký lệnh openclaw vào PATH'
    'zalo-verify' = 'Bước 5 · Kích hoạt plugin Zalo & /zaloqr'
    'telegram-menu' = 'Bước 5 · Đồng bộ menu lệnh Telegram'
    'auto-heal' = 'Tự động chẩn đoán & sửa lỗi (Codex CLI)'
    'reinstall-codex' = 'Cài / Sửa Antigravity IDE & Codex CLI'
    'install-zalo' = 'Cài / Đồng bộ Zalo cá nhân'
    'health-restart' = 'Khởi động lại & kiểm tra Gateway'
    'update-config' = 'Cập nhật cấu hình nhanh'
  }

  $stageRaw = if ($DiagPayload -and $DiagPayload.stage) { [string]$DiagPayload.stage } elseif ($IsManageFailure) { 'auto-heal' } else { "Bước $stepIdx" }
  $stageFriendly = if ($stageMap.ContainsKey($stageRaw)) { $stageMap[$stageRaw] } else { $stageRaw }
  $codeRaw = if ($DiagPayload -and $DiagPayload.code) { [string]$DiagPayload.code } else { '' }
  $timeRaw = if ($DiagPayload -and $DiagPayload.timestamp) { [string]$DiagPayload.timestamp } else { (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
  $healSum = if ($DiagPayload -and $DiagPayload.autoHealSummary) { [string]$DiagPayload.autoHealSummary } else { '' }
  $techRaw = if ($DiagPayload -and $DiagPayload.technicalDetail) { [string]$DiagPayload.technicalDetail } else { '' }

  $errorStepText.Text = $stageFriendly

  $activeSecrets = @()
  foreach ($candSec in @($tokenBox.Text, $apiKeyBox.Text, $script:sessionApiKeyFallback)) {
    if (-not [string]::IsNullOrWhiteSpace($candSec)) { $activeSecrets += $candSec.Trim() }
  }
  if (Get-Command Get-EmTroLySavedLicenseKey -ErrorAction SilentlyContinue) {
    try { $savedK = Get-EmTroLySavedLicenseKey; if ($savedK) { $activeSecrets += $savedK } } catch { }
  }
  $scrubText = {
    param([string]$T)
    if (Get-Command Remove-SensitiveStrings -ErrorAction SilentlyContinue) {
      return (Remove-SensitiveStrings -Text $T -Secrets $activeSecrets)
    }
    return $T
  }

  $safeSummary = & $scrubText $SummaryMessage
  $safeHealSum = & $scrubText $healSum
  $safeTechRaw = & $scrubText $techRaw
  $errorSummaryHeading.Text = $safeSummary

  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add("Thời điểm ghi nhận : $timeRaw")
  [void]$lines.Add("Hạng mục thực hiện : $stageFriendly")
  if ($codeRaw) { [void]$lines.Add("Mã chẩn đoán       : $codeRaw") }
  [void]$lines.Add("Tóm tắt thông báo  : $safeSummary")
  if ($safeHealSum) {
    [void]$lines.Add('')
    [void]$lines.Add("--- Ghi chú từ Codex tự sửa lỗi ---")
    [void]$lines.Add($safeHealSum)
  }
  if ($safeTechRaw) {
    [void]$lines.Add('')
    [void]$lines.Add("--- Nhật ký kỹ thuật chi tiết (đã ẩn mã bí mật) ---")
    [void]$lines.Add($safeTechRaw)
  }

  $fullReport = & $scrubText ($lines -join "`r`n")
  $script:lastInstallErrorDetail = "$safeSummary`n$safeTechRaw".Trim()
  $script:lastFullErrorReport = $fullReport
  $errorDetailBox.Text = $fullReport
  if ($autoHealNoteBorder) { $autoHealNoteBorder.Visibility = [System.Windows.Visibility]::Collapsed }
  $installFailureActions.Visibility = [System.Windows.Visibility]::Visible
  $btnBackToSetup.Visibility = if ($script:isManageMode) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }

  # Mirror full diagnostic log & ready-to-run prompt into Công cụ Codex CLI view so user also sees it immediately if they open Codex CLI!
  $codexOutputBox.Text = "=== CHI TIẾT LỖI GẦN NHẤT TRÊN GIAO DIỆN ===`r`n`r`n$fullReport`r`n`r`n(Bấm nút `"Thực hiện bằng Codex`" phía trên nếu bạn muốn giao yêu cầu tùy chỉnh cho Codex CLI xử lý trực tiếp.)"
  if ([string]::IsNullOrWhiteSpace($codexPromptBox.Text)) {
    $codexPromptBox.Text = "Hãy kiểm tra và khắc phục sự cố sau trên máy giúp tôi ($stageFriendly - mã: $codeRaw): $safeSummary"
  }
}

function Start-ManageAction([string]$ActionName, [string]$ErrorDetail = '') {
  if (-not $script:licenseVerified -and -not $SmokeTest) {
    Show-LicenseGate 'Vui lòng kích hoạt bản quyền trước khi thực hiện thao tác.'
    return
  }
  if ($script:installRunning) { return }
  if ($ActionName -eq 'update-config') {
    if (-not (Test-FormInputs -ForManageConfig $true)) { return }
  }
  if ($ActionName -eq 'install-zalo') {
    if ([string]::IsNullOrWhiteSpace($qrOwnerBox.Text) -and $ownersBox.Text.Trim()) {
      $qrOwnerBox.Text = (($ownersBox.Text -split ',')[0]).Trim()
    }
  }

  $script:currentManageAction = $ActionName
  $script:installRunning = $true
  Reset-ProgressVisualState
  $retryEditorPanel.Visibility = [System.Windows.Visibility]::Collapsed
  $statusText.Text = 'Đang chuẩn bị thực hiện thao tác...'
  $installProgressBar.IsIndeterminate = $true
  $progressPercentText.Text = 'Đang xử lý...'
  Set-NavActive 'progress'

  try {
    $script:privateDir = Join-Path $env:TEMP ('openclaw-manage-' + [guid]::NewGuid().ToString('N'))
    New-CodexPrivateDirectory $script:privateDir
    $script:secretFile = Join-Path $script:privateDir 'manage-request.json'
    $script:safeLog = Join-Path $script:privateDir 'status.txt'
    $workerCopy = Join-Path $script:privateDir 'manage-worker.ps1'
    $workerSrc = [IO.File]::ReadAllText($manageHelperPath, [System.Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($workerCopy, $workerSrc, (New-Object System.Text.UTF8Encoding($true)))

    $effectiveApiKey = if (-not [string]::IsNullOrWhiteSpace($apiKeyBox.Text)) {
      $apiKeyBox.Text.Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($retryKeyPwdBox.Password)) {
      $retryKeyPwdBox.Password.Trim()
    } else {
      $script:sessionApiKeyFallback
    }

    $payloadObj = [ordered]@{
      action         = $ActionName
      assistant_name = $assistantBox.Text.Trim()
      base_url       = $baseUrlBox.Text.Trim().TrimEnd('/')
      model          = ([string]$modelBox.SelectedItem).Trim()
      owner_ids      = $ownersBox.Text.Trim()
      group_id       = $groupBox.Text.Trim()
      gateway_port   = $portBox.Text.Trim()
      audience       = $audienceBox.Text.Trim()
      addressing     = $addressingBox.Text.Trim()
      style          = $styleBox.Text.Trim()
      qr_owner_id    = $qrOwnerBox.Text.Trim()
      telegram_token = $tokenBox.Text.Trim()
      ai_api_key     = $effectiveApiKey
      error_detail   = $ErrorDetail
    }
    [IO.File]::WriteAllText($script:secretFile, ($payloadObj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

    $shellPath = Join-Path $PSHOME 'powershell.exe'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $shellPath
    $psi.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
      $workerCopy + '" -RunManageWorker -WorkerRequestFile "' + $script:secretFile +
      '" -WorkerPayloadRoot "' + $PayloadRoot + '" -WorkerLogFile "' + $script:safeLog + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $script:runnerProcess = [Diagnostics.Process]::Start($psi)
    try { $script:runnerProcess.StandardInput.Close() } catch { }
    $script:runnerDeadline = (Get-Date).AddMinutes(45)
    if (-not [string]::IsNullOrWhiteSpace($apiKeyBox.Text)) {
      $script:sessionApiKeyFallback = $apiKeyBox.Text.Trim()
    }
    if ($ActionName -eq 'update-config' -and -not $SmokeTest) {
      Save-CurrentFormDraft -PreserveExistingSecrets
    }
    $tokenBox.Clear()
    $apiKeyBox.Clear()
    $installTimer.Start()
  } catch {
    Cleanup-Secret
    $script:currentManageAction = ''
    $script:installRunning = $false
    Set-Buttons
    Show-Error 'Không thể khởi động tác vụ cập nhật. Hãy kiểm tra quyền thư mục tạm.'
  }
}

function Start-Install {
  if (-not $script:licenseVerified -and -not $SmokeTest) {
    Show-LicenseGate 'Vui lòng kích hoạt bản quyền trước khi bắt đầu cài đặt.'
    return
  }
  if ($script:currentView -eq 'modular' -and -not $script:retryEditor) {
    $picked = @()
    if ($modCheck1.IsChecked) { $picked += 'codex-cli' }
    if ($modCheck2.IsChecked) { $picked += 'antigravity-ide' }
    if ($modCheck3.IsChecked) { $picked += 'codex-extension' }
    if ($modCheck4.IsChecked -and $modCheck4.IsEnabled) { $picked += 'openclaw' }
    Start-ModularInstall $picked
    return
  }
  if ($script:isManageMode -and -not $script:retryEditor) {
    if ($script:currentView -eq 'home') {
      Set-NavActive 'config'
      return
    }
    Start-ManageAction 'update-config'
    return
  }

  if ($script:retryEditor) {
    if ([string]::IsNullOrWhiteSpace($retryKeyPwdBox.Password)) {
      Show-Error 'Hãy nhập Khóa API để tiếp tục cài đặt Antigravity & Codex.'
      return
    }
  } else {
    if (-not $SmokeTest) { Save-CurrentFormDraft }
    if (-not (Test-FormInputs -ForManageConfig $false)) { return }
    if (-not $SmokeTest) { Save-CurrentFormDraft }
    $ansExec = [System.Windows.MessageBox]::Show($window, 'Các Owner IDs và thành viên trong nhóm Telegram đã chọn có thể yêu cầu đọc, sửa tệp và chạy lệnh trên máy. Bạn có tin tưởng họ?', 'Xác nhận Full Exec', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($ansExec -ne [System.Windows.MessageBoxResult]::Yes) { return }
    if ($zaloCheck.Checked) {
      $ansZalo = [System.Windows.MessageBox]::Show($window, 'Zalo dùng danh sách cho phép. Sau khi cài xong, Owner nhắn /zaloqr trong Telegram riêng của bot để quét mã QR. Bạn đồng ý?', 'Xác nhận cài Zalo', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
      if ($ansZalo -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
  }

  $script:installRunning = $true
  Reset-ProgressVisualState
  $statusText.Text = 'Đang kiểm tra thông tin cài đặt...'
  Update-ProgressFromStatus $statusText.Text
  Set-NavActive 'progress'

  try {
    $settings = if ($script:retryEditor) {
      @{ ai_api_key = $retryKeyPwdBox.Password.Trim() }
    } else {
      [ordered]@{
        member = 'emtroly'
        assistant_name = $assistantBox.Text.Trim()
        base_url = $baseUrlBox.Text.Trim().TrimEnd('/')
        model = ([string]$modelBox.SelectedItem).Trim()
        owner_ids = $ownersBox.Text.Trim()
        group_id = $groupBox.Text.Trim()
        gateway_port = $portBox.Text.Trim()
        audience = $audienceBox.Text.Trim()
        addressing = $addressingBox.Text.Trim()
        style = $styleBox.Text.Trim()
        accept_full_access = [bool]$fullAccessCheck.Checked
        configure_zalo = [bool]$zaloCheck.Checked
        skip_editor = [bool]$existingEditorCheck.Checked
        qr_owner_id = $qrOwnerBox.Text.Trim()
        telegram_token = $tokenBox.Text
        ai_api_key = $apiKeyBox.Text
      }
    }

    $script:privateDir = Join-Path $env:TEMP ('openclaw-member-' + [guid]::NewGuid().ToString('N'))
    New-CodexPrivateDirectory $script:privateDir
    $script:secretFile = Join-Path $script:privateDir 'settings.json'
    $script:safeLog = Join-Path $script:privateDir 'status.txt'
    [IO.File]::WriteAllText($script:secretFile, ($settings | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

    $runner = Join-Path $PayloadRoot 'windows-installer\run-native-install.ps1'
    $shellPath = Join-Path $PSHOME 'powershell.exe'
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $shellPath
    $startInfo.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
      $runner + '" -SettingsFile "' + $script:secretFile +
      '" -PayloadRoot "' + $PayloadRoot + '" -LogFile "' + $script:safeLog + '"'
    if ($script:retryEditor) { $startInfo.Arguments += ' -EditorOnly' }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $script:runnerProcess = [Diagnostics.Process]::Start($startInfo)
    try { $script:runnerProcess.StandardInput.Close() } catch { }
    $script:runnerDeadline = (Get-Date).AddMinutes(90)

    if (-not [string]::IsNullOrWhiteSpace($apiKeyBox.Text)) {
      $script:sessionApiKeyFallback = $apiKeyBox.Text.Trim()
      if (-not $script:retryEditor -and -not $settings.skip_editor) {
        $retryKeyPwdBox.Password = $apiKeyBox.Text.Trim()
      }
    }
    $installTimer.Start()
  } catch {
    Cleanup-Secret
    $script:installRunning = $false
    Set-Buttons
    Show-Error 'Không thể khởi động bộ cài đặt. Hãy kiểm tra quyền ghi vào thư mục tạm.'
  }
}

$installTimer = New-Object System.Windows.Threading.DispatcherTimer
$installTimer.Interval = [TimeSpan]::FromMilliseconds(700)
$installTimer.Add_Tick({
  if (-not $script:installRunning) { return }
  if ([string]::IsNullOrWhiteSpace($coreReadyText.Text) -and (Test-Path -LiteralPath $pending -PathType Leaf)) {
    $coreReadyText.Visibility = [System.Windows.Visibility]::Visible
    $coreReadyText.Text = if ($zaloCheck.Checked) {
      '✓ Trợ lý OpenClaw & Zalo đã sẵn sàng. Đang tiếp tục cài Antigravity & Codex CLI...'
    } else {
      '✓ Trợ lý OpenClaw đã sẵn sàng. Đang tiếp tục cài Antigravity & Codex CLI...'
    }
  }
  if ($script:safeLog -and (Test-Path -LiteralPath $script:safeLog -PathType Leaf)) {
    try {
      $msg = [IO.File]::ReadAllText($script:safeLog, [System.Text.Encoding]::UTF8)
      if ($msg) {
        if ($msg -match '^Đang tải (Codex Extension|Antigravity IDE)' -and $msg -notmatch '\d+%') {
          try {
            $isVsix = ($Matches[1] -eq 'Codex Extension')
            $filePat = if ($isVsix) { 'codex.vsix' } else { 'antigravity-ide-setup.exe' }
            $estTotal = if ($isVsix) { 389000000L } else { 199000000L }
            $cand = @(Get-ChildItem -Path (Join-Path $env:TEMP 'emtroly-editor-*') -Filter $filePat -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
            if ($cand.Count -gt 0 -and $cand[0].Length -gt 0) {
              $mbNow = [Math]::Round($cand[0].Length / 1MB, 1)
              $mbTot = [Math]::Round($estTotal / 1MB, 0)
              $pNow = [Math]::Min(99, [int][Math]::Floor(($cand[0].Length * 100.0) / $estTotal))
              $labelName = if ($isVsix) { 'Codex Extension' } else { 'Antigravity IDE' }
              $msg = "Đang tải $labelName... $pNow% ($mbNow / ~$mbTot MB)"
            }
          } catch { }
        }
        $statusText.Text = $msg
        Update-ProgressFromStatus $msg
      }
    } catch { }
  }
  if ($script:runnerProcess -and -not $script:runnerProcess.HasExited -and (Get-Date) -ge $script:runnerDeadline) {
    Stop-ActiveRunner 'Hết thời gian chờ cài đặt. Dữ liệu đã tạo vẫn được giữ an toàn.'
    return
  }
  if ($script:runnerProcess -and $script:runnerProcess.HasExited) {
    $installTimer.Stop()
    $code = $script:runnerProcess.ExitCode
    $script:runnerProcess.Dispose()
    $script:runnerProcess = $null
    if ($script:safeLog -and (Test-Path -LiteralPath $script:safeLog -PathType Leaf)) {
      try { $statusText.Text = [IO.File]::ReadAllText($script:safeLog, [System.Text.Encoding]::UTF8) } catch { }
    }
    $diagPayload = $null
    if ($script:safeLog -and (Test-Path -LiteralPath "$($script:safeLog).diag.json" -PathType Leaf)) {
      try {
        $diagPayload = [IO.File]::ReadAllText("$($script:safeLog).diag.json", [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      } catch { }
    }
    $detail = $statusText.Text
    if ($code -eq 0 -and -not $detail.StartsWith('Hoàn tất:')) { $code = 1 }
    $wasManage = $script:currentManageAction
    $script:currentManageAction = ''
    Cleanup-Secret
    $script:installRunning = $false
    $installProgressBar.IsIndeterminate = $false

    if ($wasManage) {
      if ($code -eq 0) {
        $script:resultCode = 0
        Reset-ProgressVisualState
        $installProgressBar.Value = 100
        $progressPercentText.Text = '100%'
        if ($wasManage -eq 'uninstall-instance') {
          $script:isManageMode = $false
          $script:installCompleted = $false
          $script:zaloConnectedState = $false
          $script:zaloInstalledState = $false
          $manageEditBanner.Visibility = [System.Windows.Visibility]::Collapsed
          $installOptionsCard.Visibility = [System.Windows.Visibility]::Visible
          $tokenFieldLabel.Text = 'Telegram Bot Token'
          $apiKeyFieldLabel.Text = 'Provider API Key'
          if (-not [string]::IsNullOrWhiteSpace($script:sessionApiKeyFallback) -and [string]::IsNullOrWhiteSpace($apiKeyBox.Text)) {
            $apiKeyBox.Text = $script:sessionApiKeyFallback
          }
          [void](Update-CodexAvailability)
          Show-Info $detail 'Đã gỡ trợ lý thành công'
          Set-NavActive 'home'
          return
        }
        Apply-ManageModeUI
        [void](Update-CodexAvailability)
        if ($wasManage -eq 'install-zalo' -or $script:openZaloQrAfterManage) {
          $script:openZaloQrAfterManage = $false
          Start-ZaloQrLoginSession
          return
        }
        Show-Info $detail 'Thực hiện thành công'
        Set-NavActive 'home'
      } else {
        $script:openZaloQrAfterManage = $false
        $statusText.Text = "Chưa hoàn tất: $detail"
        Show-RichFailureDiagnostics -SummaryMessage $detail -DiagPayload $diagPayload -IsManageFailure $true
        $viewDashboard.Visibility   = [System.Windows.Visibility]::Collapsed
        $viewSetupForm.Visibility   = [System.Windows.Visibility]::Collapsed
        $viewModular.Visibility     = [System.Windows.Visibility]::Collapsed
        $viewCodex.Visibility       = [System.Windows.Visibility]::Collapsed
        $viewDiagnostics.Visibility = [System.Windows.Visibility]::Collapsed
        $viewZaloQr.Visibility      = [System.Windows.Visibility]::Collapsed
        $viewProgress.Visibility    = [System.Windows.Visibility]::Visible
        Set-Buttons
      }
      return
    }

    $script:resultCode = $code
    if ($code -eq 0) {
      $tokenBox.Clear()
      $apiKeyBox.Clear()
      $script:installCompleted = $true
      $script:retryEditor = $false
      Reset-ProgressVisualState
      $retryEditorPanel.Visibility = [System.Windows.Visibility]::Collapsed
      Update-ProgressFromStatus $detail
      $codexDirBox.Text = Get-CodexDefaultWorkspace
      Apply-ManageModeUI
      [void](Update-CodexAvailability)
      [void](Update-ModularCards)
      if ($detail -match '^Hoàn tất: Đã cài đặt thành công phần đã chọn') {
        Show-Info "$detail`n`nBạn có thể cài tiếp các thành phần khác hoặc mở tab Công cụ Codex CLI ngay!" 'Cài đặt thành phần hoàn tất'
        Set-NavActive 'modular'
      } elseif ($detail -match '/zaloqr') {
        Show-Info "$detail`n`nTiếp theo: Màn hình sẽ hiển thị ngay mã QR Zalo (và gửi đồng thời vào Telegram Chủ sở hữu) để bạn quét kết nối luôn!" 'Cài đặt hoàn tất'
        Start-ZaloQrLoginSession
      } else {
        Show-Info "$detail`n`nLối tắt Em Trợ Lý đã sẵn sàng trên Desktop để bạn quản lý & dùng Codex bất cứ lúc nào." 'Cài đặt hoàn tất'
        Set-NavActive 'home'
      }
    } elseif ($code -eq 3 -or (Test-Path -LiteralPath $pending -PathType Leaf)) {
      $script:resultCode = 3
      $script:retryEditor = $true
      $coreReadyText.Visibility = [System.Windows.Visibility]::Visible
      $coreReadyText.Text = '✓ OpenClaw & Telegram đã hoạt động tốt.'
      $statusText.Text = if ($code -eq 3) { $detail } else { 'Bước cài Antigravity/Codex bị gián đoạn. Nhập khóa API bên dưới rồi bấm Thử lại bước Codex.' }
      $retryEditorPanel.Visibility = [System.Windows.Visibility]::Visible
      $script:lastActiveStepIndex = 2
      Show-RichFailureDiagnostics -SummaryMessage $statusText.Text -DiagPayload $diagPayload -IsManageFailure $false
      Set-Buttons
    } else {
      $statusText.Text = "Cài đặt chưa hoàn tất — xem chi tiết nguyên nhân ngay bên dưới."
      Show-RichFailureDiagnostics -SummaryMessage $detail -DiagPayload $diagPayload -IsManageFailure $false
      Set-Buttons
    }
  }
})

# Live Zalo QR Login Controller (Displays QR in WPF + Sends to Telegram Owner + Auto-detects Scan)
function Resolve-EmTroLyNodeBinary([string]$OpenClawRoot) {
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
  $cmd = @(Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($cmd.Count -gt 0 -and $cmd[0].Source) { return $cmd[0].Source }
  if ($env:LOCALAPPDATA) {
    $depNodes = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'MemberInstaller\dependencies\node-*\node.exe') -ErrorAction SilentlyContinue)
    if ($depNodes.Count -gt 0) { return $depNodes[0].FullName }
  }
  return ''
}

$zaloQrTimer = New-Object System.Windows.Threading.DispatcherTimer
$zaloQrTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$zaloQrTimer.Add_Tick({
  if (-not $script:zaloQrRunning) { return }

  if ($script:zaloQrPngFile -and (Test-Path -LiteralPath $script:zaloQrPngFile -PathType Leaf)) {
    try {
      $itemInfo = Get-Item -LiteralPath $script:zaloQrPngFile -ErrorAction Stop
      if ($itemInfo.Length -gt 64 -and $itemInfo.LastWriteTimeUtc.Ticks -ne $script:zaloQrLoadedTicks) {
        $pngBytes = [IO.File]::ReadAllBytes($script:zaloQrPngFile)
        $pms = New-Object System.IO.MemoryStream(,$pngBytes)
        $qBmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $qBmp.BeginInit()
        $qBmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $qBmp.StreamSource = $pms
        $qBmp.EndInit()
        $qBmp.Freeze()
        $pms.Dispose()
        $zaloQrImage.Source = $qBmp
        $zaloQrImage.Visibility = [System.Windows.Visibility]::Visible
        $zaloQrLoadingBox.Visibility = [System.Windows.Visibility]::Collapsed
        $zaloQrSuccessBox.Visibility = [System.Windows.Visibility]::Collapsed
        $script:zaloQrLoadedTicks = $itemInfo.LastWriteTimeUtc.Ticks
      }
    } catch { }
  }

  if ($script:zaloQrStateFile -and (Test-Path -LiteralPath $script:zaloQrStateFile -PathType Leaf)) {
    try {
      $stObj = [IO.File]::ReadAllText($script:zaloQrStateFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      if ($stObj.message) { $zaloQrStatusText.Text = [string]$stObj.message }
      if ($stObj.telegramNote) {
        $zaloQrTgText.Text = [string]$stObj.telegramNote
        if ($stObj.telegramSent) {
          $zaloQrTgBanner.Background = New-Brush '#ECFDF5'
          $zaloQrTgBanner.BorderBrush = New-Brush '#A7F3D0'
          $zaloQrTgText.Foreground = New-Brush '#065F46'
        } else {
          $zaloQrTgBanner.Background = New-Brush '#F8FAFC'
          $zaloQrTgBanner.BorderBrush = New-Brush '#E2E8F0'
          $zaloQrTgText.Foreground = New-Brush '#475569'
        }
      }
      if ($stObj.phase -eq 'qr_ready' -and $stObj.expiresAt) {
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $remainSec = [Math]::Max(0, [int][Math]::Ceiling(([double]$stObj.expiresAt - $nowMs) / 1000.0))
        $mins = [int][Math]::Floor($remainSec / 60)
        $secs = $remainSec % 60
        $zaloQrTimerText.Text = ('Còn hiệu lực: {0:D2}:{1:D2}' -f $mins, $secs)
        if ($remainSec -le 30) {
          $zaloQrTimerPill.Background = New-Brush '#FFFBEB'
          $zaloQrTimerPill.BorderBrush = New-Brush '#FDE68A'
          $zaloQrTimerText.Foreground = New-Brush '#B45309'
        } else {
          $zaloQrTimerPill.Background = New-Brush '#EFF6FF'
          $zaloQrTimerPill.BorderBrush = New-Brush '#BFDBFE'
          $zaloQrTimerText.Foreground = New-Brush '#1D4ED8'
        }
      }
      if ($stObj.connected -eq $true -or $stObj.phase -eq 'connected') {
        $tgConfirmNote = if ($stObj.telegramNote) { [string]$stObj.telegramNote } else { '✓ Đã đồng bộ kết nối Zalo thành công.' }
        Stop-ZaloQrSession
        $script:zaloConnectedState = $true
        $script:zaloInstalledState = $true
        Update-DashboardCards
        Show-ZaloConnectedView -TelegramNote $tgConfirmNote
        Show-Info 'Chúc mừng! Bạn đã quét mã QR và đăng nhập Zalo cá nhân thành công. Trợ lý OpenClaw đã kết nối Zalo và sẵn sàng hoạt động!' 'Đăng nhập Zalo thành công'
        return
      }
    } catch { }
  }

  if ($script:zaloQrProcess -and $script:zaloQrProcess.HasExited) {
    $exitCode = $script:zaloQrProcess.ExitCode
    if ($script:zaloQrStateFile -and (Test-Path -LiteralPath $script:zaloQrStateFile -PathType Leaf)) {
      try {
        $finalObj = [IO.File]::ReadAllText($script:zaloQrStateFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($finalObj.connected -eq $true) { return }
        if ($finalObj.message) { $zaloQrStatusText.Text = [string]$finalObj.message }
      } catch { }
    }
    Stop-ZaloQrSession
    $zaloQrRefreshBtn.IsEnabled = $true
    $zaloQrImage.Visibility = [System.Windows.Visibility]::Collapsed
    $zaloQrLoadingBox.Visibility = [System.Windows.Visibility]::Visible
    if ($exitCode -eq 2) {
      $zaloQrTimerPill.Background = New-Brush '#FFFBEB'
      $zaloQrTimerPill.BorderBrush = New-Brush '#FDE68A'
      $zaloQrTimerText.Foreground = New-Brush '#B45309'
      $zaloQrTimerText.Text = 'Đã hết hạn'
    } else {
      $zaloQrTimerPill.Background = New-Brush '#FEF2F2'
      $zaloQrTimerPill.BorderBrush = New-Brush '#FECACA'
      $zaloQrTimerText.Foreground = New-Brush '#B91C1C'
      $zaloQrTimerText.Text = 'Chưa tạo được QR'
    }
  }
})

$liveSyncTimer = New-Object System.Windows.Threading.DispatcherTimer
$liveSyncTimer.Interval = [TimeSpan]::FromMilliseconds(650)
$liveSyncTimer.Add_Tick({
  if ($script:zaloSyncProc) {
    if ($script:zaloSyncProc.HasExited) {
      try { $script:zaloSyncProc.Dispose() } catch { }
      $script:zaloSyncProc = $null
      $liveSyncTimer.Stop()
      Update-DashboardCards
      Set-Buttons
    }
  } else {
    $liveSyncTimer.Stop()
  }
})

function Show-ZaloConnectedView([string]$TelegramNote = '') {
  Stop-ZaloQrSession
  $script:zaloConnectedState = $true
  $script:zaloInstalledState = $true
  Set-NavActive 'zaloqr'
  $headerTitle.Text = 'Trạng thái kết nối Zalo cá nhân'
  $headerSubtitle.Text = 'Tài khoản Zalo cá nhân đã kết nối trực tuyến với trợ lý OpenClaw'
  $zaloQrMainHeading.Text = 'Tài khoản Zalo đã kết nối'
  $zaloQrFrame.BorderBrush = New-Brush '#34D399'
  $zaloQrFrame.Background = New-Brush '#F0FDF4'
  $zaloQrImage.Visibility = [System.Windows.Visibility]::Collapsed
  $zaloQrLoadingBox.Visibility = [System.Windows.Visibility]::Collapsed
  $zaloQrSuccessBox.Visibility = [System.Windows.Visibility]::Visible
  $zaloQrTimerPill.Background = New-Brush '#ECFDF5'
  $zaloQrTimerPill.BorderBrush = New-Brush '#6EE7B7'
  $zaloQrTimerText.Foreground = New-Brush '#065F46'
  $zaloQrTimerText.Text = '✓ Đã kết nối trực tuyến'
  $zaloQrStatusText.Text = 'Trợ lý OpenClaw đang giữ phiên kết nối Zalo cá nhân ổn định và sẵn sàng nhận/trả lời tin nhắn.'
  $zaloQrTgBanner.Background = New-Brush '#ECFDF5'
  $zaloQrTgBanner.BorderBrush = New-Brush '#A7F3D0'
  $zaloQrTgText.Foreground = New-Brush '#065F46'
  $zaloQrTgText.Text = if ($TelegramNote) { $TelegramNote } else { '✓ Không cần quét lại mã QR. Chỉ bấm "Đổi tài khoản / Tạo QR mới" nếu bạn muốn đổi sang Zalo khác.' }
  $zaloQrGuideBox.Visibility = [System.Windows.Visibility]::Collapsed
  $zaloQrRefreshBtn.Content = 'Đổi tài khoản / Tạo QR mới'
  $zaloQrRefreshBtn.IsEnabled = $true
  Update-ZaloGlobalBadges
}

function Start-ZaloQrLoginSession([switch]$ForceNewQr) {
  if (-not $script:licenseVerified -and -not $SmokeTest) {
    Show-LicenseGate 'Vui lòng kích hoạt bản quyền trước khi kết nối Zalo.'
    return
  }
  $st = Get-EmTroLyInstalledState
  if (-not $st.OpenClawInstalled) {
    Show-Error 'Hãy cài đặt trợ lý OpenClaw trước khi kết nối mã QR Zalo.'
    return
  }
  if (-not $st.ZaloInstalled) {
    $script:openZaloQrAfterManage = $true
    Start-ManageAction 'install-zalo'
    return
  }

  if (-not $ForceNewQr) {
    $dashCheck = if (Get-Command Get-EmTroLyLiveDashboardStatus -ErrorAction SilentlyContinue) { Get-EmTroLyLiveDashboardStatus } else { $null }
    if (($dashCheck -and $dashCheck.ZaloLinked) -or $script:zaloConnectedState) {
      Show-ZaloConnectedView
      return
    }
  }

  $bridgeScript = Resolve-HelperScript 'zalo-qr-session.mjs'
  if (-not (Test-Path -LiteralPath $bridgeScript -PathType Leaf)) {
    Show-Error 'Không tìm thấy công cụ tạo mã QR Zalo (zalo-qr-session.mjs).'
    return
  }
  $nodeExe = Resolve-EmTroLyNodeBinary -OpenClawRoot $st.Root
  if (-not $nodeExe) {
    Show-Error 'Không tìm thấy Node.js để khởi tạo phiên mã QR Zalo.'
    return
  }

  Stop-ZaloQrSession
  Set-NavActive 'zaloqr'

  $zaloQrMainHeading.Text = 'Quét mã QR đăng nhập Zalo'
  $zaloQrFrame.Background = New-Brush '#FFFFFF'
  $zaloQrFrame.BorderBrush = New-Brush '#BFDBFE'
  $zaloQrImage.Source = $null
  $zaloQrImage.Visibility = [System.Windows.Visibility]::Collapsed
  $zaloQrSuccessBox.Visibility = [System.Windows.Visibility]::Collapsed
  $zaloQrLoadingBox.Visibility = [System.Windows.Visibility]::Visible
  $zaloQrTimerPill.Background = New-Brush '#EFF6FF'
  $zaloQrTimerPill.BorderBrush = New-Brush '#BFDBFE'
  $zaloQrTimerText.Foreground = New-Brush '#1D4ED8'
  $zaloQrTimerText.Text = 'Đang khởi tạo...'
  $zaloQrStatusText.Text = 'Đang tạo mã QR đăng nhập Zalo và gửi tới Telegram Chủ sở hữu...'
  $zaloQrTgBanner.Background = New-Brush '#F8FAFC'
  $zaloQrTgBanner.BorderBrush = New-Brush '#E2E8F0'
  $zaloQrTgText.Foreground = New-Brush '#475569'
  $zaloQrTgText.Text = 'Chuẩn bị gửi đồng thời mã QR qua Telegram...'
  $zaloQrGuideBox.Visibility = [System.Windows.Visibility]::Visible
  $zaloQrRefreshBtn.Content = 'Tạo mã QR mới'

  $targetOwner = $qrOwnerBox.Text.Trim()
  if ([string]::IsNullOrWhiteSpace($targetOwner) -and $st.OwnerIds) {
    $targetOwner = (($st.OwnerIds -split ',')[0]).Trim()
  }

  try {
    $script:zaloQrDir = Join-Path $env:TEMP ('emtroly-zaloqr-' + [guid]::NewGuid().ToString('N'))
    New-CodexPrivateDirectory $script:zaloQrDir
    $script:zaloQrStateFile = Join-Path $script:zaloQrDir 'state.json'
    $script:zaloQrPngFile = Join-Path $script:zaloQrDir 'qr.png'
    $script:zaloQrLoadedTicks = 0

    $argList = @(
      ('"' + $bridgeScript.Replace('"', '\"') + '"'),
      '--root', ('"' + $st.Root.Replace('"', '\"') + '"'),
      '--state-file', ('"' + $script:zaloQrStateFile.Replace('"', '\"') + '"'),
      '--qr-out', ('"' + $script:zaloQrPngFile.Replace('"', '\"') + '"'),
      '--timeout-seconds', '160'
    )
    if ($targetOwner -match '^[1-9][0-9]*$') {
      $argList += @('--owner-id', $targetOwner)
    }
    if ($ForceNewQr) {
      $argList += '--force'
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $nodeExe
    $psi.Arguments = ($argList -join ' ')
    $psi.WorkingDirectory = $st.Root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:zaloQrProcess = [Diagnostics.Process]::Start($psi)
    $script:zaloQrRunning = $true
    $zaloQrTimer.Start()
  } catch {
    Stop-ZaloQrSession
    Show-Error 'Không thể khởi tạo phiên đăng nhập mã QR Zalo.'
  }
}

# Codex CLI Interactive Tab Worker
function Start-CodexTask {
  if (-not $script:licenseVerified -and -not $SmokeTest) {
    Show-LicenseGate 'Vui lòng kích hoạt bản quyền trước khi sử dụng Codex CLI.'
    return
  }
  if ($script:codexRunning) { return }
  $info = Update-CodexAvailability
  if (-not $info.Available) {
    Show-Error 'Chưa tìm thấy Codex CLI trên máy. Hãy hoàn tất cài đặt hoặc bấm Sửa / Cài lại Codex.'
    return
  }
  $targetDir = $codexDirBox.Text.Trim()
  if ([string]::IsNullOrWhiteSpace($targetDir) -or -not (Test-Path -LiteralPath $targetDir -PathType Container)) {
    Show-Error 'Thư mục cần sửa không tồn tại. Hãy bấm "Chọn thư mục..." để chọn thư mục hợp lệ.'
    return
  }
  $promptText = $codexPromptBox.Text.Trim()
  if ([string]::IsNullOrWhiteSpace($promptText)) {
    Show-Error 'Hãy nhập yêu cầu tiếng Việt bạn muốn Codex thực hiện.'
    return
  }
  $fallbackKey = if (-not [string]::IsNullOrWhiteSpace($apiKeyBox.Text)) { $apiKeyBox.Text.Trim() } else { $script:sessionApiKeyFallback }
  if ([string]::IsNullOrWhiteSpace($info.CodexHome) -and [string]::IsNullOrWhiteSpace($fallbackKey)) {
    Show-Error 'Codex CLI chưa có khóa API. Hãy nhập API Key ở mục Cấu hình trước.'
    return
  }

  try {
    $script:codexPrivateDir = Join-Path $env:TEMP ('emtroly-codex-ui-' + [guid]::NewGuid().ToString('N'))
    New-CodexPrivateDirectory $script:codexPrivateDir
    $reqPath = Join-Path $script:codexPrivateDir 'request.json'
    $script:codexLogFile = Join-Path $script:codexPrivateDir 'output.txt'
    $script:codexLogOffset = 0
    [IO.File]::WriteAllText($script:codexLogFile, '', (New-Object System.Text.UTF8Encoding($false)))

    $reqData = [ordered]@{
      executable = $info.Executable
      workspace  = $targetDir
      prompt     = $promptText
      allow_edit = [bool]$codexWriteCheck.IsChecked
      codex_home = $info.CodexHome
      model      = ([string]$modelBox.SelectedItem).Trim()
      base_url   = $baseUrlBox.Text.Trim()
      api_key    = if ([string]::IsNullOrWhiteSpace($info.CodexHome)) { $fallbackKey } else { '' }
    }
    [IO.File]::WriteAllText($reqPath, ($reqData | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

    $workerPath = Join-Path $script:codexPrivateDir 'codex-worker.ps1'
    $workerSource = [IO.File]::ReadAllText($codexHelperPath, [System.Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($workerPath, $workerSource, (New-Object System.Text.UTF8Encoding($true)))

    $shellPath = Join-Path $PSHOME 'powershell.exe'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $shellPath
    $psi.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
      $workerPath + '" -RunWorker -RequestFile "' + $reqPath + '" -OutputFile "' + $script:codexLogFile + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $codexOutputBox.Clear()
    $script:codexProcess = [Diagnostics.Process]::Start($psi)
    $script:codexRunning = $true
    [void](Update-CodexAvailability)
    $codexStateText.Text = 'Đang thực hiện yêu cầu bằng Codex CLI...'
    $codexStateText.Foreground = New-Brush '#2563EB'
    Set-Buttons
    $codexTimer.Start()
  } catch {
    Cleanup-CodexRun
    $script:codexRunning = $false
    [void](Update-CodexAvailability)
    Set-Buttons
    Show-Error 'Không thể khởi động Codex CLI. Hãy kiểm tra quyền truy cập thư mục tạm.'
  }
}

$codexTimer = New-Object System.Windows.Threading.DispatcherTimer
$codexTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$codexTimer.Add_Tick({
  if (-not $script:codexRunning) { return }
  if ($script:codexLogFile -and (Test-Path -LiteralPath $script:codexLogFile -PathType Leaf)) {
    try {
      $fullText = [IO.File]::ReadAllText($script:codexLogFile, [System.Text.Encoding]::UTF8)
      if ($fullText.Length -gt $script:codexLogOffset) {
        $codexOutputBox.AppendText($fullText.Substring($script:codexLogOffset))
        $script:codexLogOffset = $fullText.Length
        $codexOutputBox.ScrollToEnd()
      }
    } catch { }
  }
  if ($script:codexProcess -and $script:codexProcess.HasExited) {
    $codexTimer.Stop()
    if ($script:codexLogFile -and (Test-Path -LiteralPath $script:codexLogFile -PathType Leaf)) {
      try {
        $fullText = [IO.File]::ReadAllText($script:codexLogFile, [System.Text.Encoding]::UTF8)
        if ($fullText.Length -gt $script:codexLogOffset) {
          $codexOutputBox.AppendText($fullText.Substring($script:codexLogOffset))
          $script:codexLogOffset = $fullText.Length
          $codexOutputBox.ScrollToEnd()
        }
      } catch { }
    }
    $script:codexProcess.Dispose()
    $script:codexProcess = $null
    $script:codexRunning = $false
    Cleanup-CodexRun
    [void](Update-CodexAvailability)
    Set-Buttons
  }
})

# Event Handlers
$showSecretCheck.Add_Click({
  $mask = -not [bool]$showSecretCheck.IsChecked
  $tokenBox.UseSystemPasswordChar = $mask
  $apiKeyBox.UseSystemPasswordChar = $mask
})

$autoFetchIdBtn.Add_Click({
  $tok = $tokenBox.Text.Trim()
  if ([string]::IsNullOrWhiteSpace($tok)) {
    $ocTok = Join-Path $env:USERPROFILE 'openclaw\telegram.token'
    if (Test-Path -LiteralPath $ocTok -PathType Leaf) {
      try { $tok = ([IO.File]::ReadAllText($ocTok, [System.Text.Encoding]::UTF8)).Trim() } catch { }
    }
  }
  if ([string]::IsNullOrWhiteSpace($tok)) {
    Show-Error 'Hãy dán Telegram Bot Token vào ô phía trên trước rồi bấm Lấy ID tự động.'
    return
  }
  $autoFetchIdBtn.IsEnabled = $false
  $autoFetchIdBtn.Content = 'Đang lấy ID...'
  $liveCheckBanner.Visibility = [System.Windows.Visibility]::Visible
  $liveCheckBanner.Background = New-Brush '#EFF6FF'
  $liveCheckBanner.BorderBrush = New-Brush '#BFDBFE'
  $liveCheckText.Foreground = New-Brush '#1D4ED8'
  $liveCheckText.Text = 'Đang đọc tin nhắn gần nhất từ Telegram Bot để lấy Owner ID & Group ID...'

  Start-AsyncUiTask -Params @{ HelperPath = $wizardHelperPath; Token = $tok } -Work {
    param($HelperPath, $Token)
    . ([ScriptBlock]::Create([IO.File]::ReadAllText($HelperPath, [System.Text.Encoding]::UTF8)))
    return (Get-TelegramIdsFromBotUpdates -TelegramToken $Token)
  } -OnComplete {
    param($res, $err)
    $autoFetchIdBtn.IsEnabled = $true
    $autoFetchIdBtn.Content = 'Lấy ID tự động'
    if ($err -or -not $res) {
      $liveCheckBanner.Background = New-Brush '#FEF2F2'
      $liveCheckBanner.BorderBrush = New-Brush '#FECACA'
      $liveCheckText.Foreground = New-Brush '#B91C1C'
      $liveCheckText.Text = 'Không thể lấy ID từ Telegram. Hãy kiểm tra lại kết nối mạng.'
      return
    }
    if ($res.SuggestedOwnerId) {
      $ownersBox.Text = $res.SuggestedOwnerId
      if ([string]::IsNullOrWhiteSpace($qrOwnerBox.Text)) {
        $qrOwnerBox.Text = (($ownersBox.Text -split ',')[0]).Trim()
      }
    }
    if ($res.SuggestedGroupId) { $groupBox.Text = $res.SuggestedGroupId }
    if ($res.Ok -and ($res.SuggestedOwnerId -or $res.SuggestedGroupId)) {
      if (-not $SmokeTest) { Save-CurrentFormDraft -PreserveExistingSecrets }
      $liveCheckBanner.Background = New-Brush '#ECFDF5'
      $liveCheckBanner.BorderBrush = New-Brush '#A7F3D0'
      $liveCheckText.Foreground = New-Brush '#065F46'
      $liveCheckText.Text = '✓ ' + $res.Message
    } elseif ($res.Ok) {
      $liveCheckBanner.Background = New-Brush '#FFFBEB'
      $liveCheckBanner.BorderBrush = New-Brush '#FDE68A'
      $liveCheckText.Foreground = New-Brush '#B45309'
      $liveCheckText.Text = $res.Message
    } else {
      $liveCheckBanner.Background = New-Brush '#FEF2F2'
      $liveCheckBanner.BorderBrush = New-Brush '#FECACA'
      $liveCheckText.Foreground = New-Brush '#B91C1C'
      $liveCheckText.Text = $res.Message
    }
  }
})

$testConnBtn.Add_Click({
  if (-not $script:isManageMode -and -not $SmokeTest) { Save-CurrentFormDraft }
  $testConnBtn.IsEnabled = $false
  $testConnBtn.Content = 'Đang kiểm tra...'
  $liveCheckBanner.Visibility = [System.Windows.Visibility]::Visible
  $liveCheckBanner.Background = New-Brush '#EFF6FF'
  $liveCheckBanner.BorderBrush = New-Brush '#BFDBFE'
  $liveCheckText.Foreground = New-Brush '#1D4ED8'
  $liveCheckText.Text = 'Đang kiểm tra Telegram Bot Token và Provider API Key...'

  $ocRoot = Join-Path $env:USERPROFILE 'openclaw'
  Start-AsyncUiTask -Params @{
    HelperPath = $wizardHelperPath
    Token      = $tokenBox.Text.Trim()
    BaseUrl    = $baseUrlBox.Text.Trim()
    ApiKey     = $apiKeyBox.Text.Trim()
    Model      = ([string]$modelBox.SelectedItem).Trim()
    Root       = $ocRoot
  } -Work {
    param($HelperPath, $Token, $BaseUrl, $ApiKey, $Model, $Root)
    . ([ScriptBlock]::Create([IO.File]::ReadAllText($HelperPath, [System.Text.Encoding]::UTF8)))
    return (Test-EmTroLyLiveCredentials -TelegramToken $Token -BaseUrl $BaseUrl -ApiKey $ApiKey -Model $Model -OpenClawRoot $Root)
  } -OnComplete {
    param($res, $err)
    $testConnBtn.IsEnabled = $true
    $testConnBtn.Content = 'Kiểm tra kết nối'
    if ($err -or -not $res) {
      $liveCheckBanner.Background = New-Brush '#FEF2F2'
      $liveCheckBanner.BorderBrush = New-Brush '#FECACA'
      $liveCheckText.Foreground = New-Brush '#B91C1C'
      $liveCheckText.Text = 'Không thể thực hiện kiểm tra kết nối.'
      return
    }
    if ($res.AllOk) {
      $liveCheckBanner.Background = New-Brush '#ECFDF5'
      $liveCheckBanner.BorderBrush = New-Brush '#A7F3D0'
      $liveCheckText.Foreground = New-Brush '#065F46'
      $liveCheckText.Text = '✓ ' + $res.Summary
    } else {
      $liveCheckBanner.Background = New-Brush '#FFFBEB'
      $liveCheckBanner.BorderBrush = New-Brush '#FDE68A'
      $liveCheckText.Foreground = New-Brush '#B45309'
      $liveCheckText.Text = '! ' + $res.Summary
    }
  }
})

function Invoke-ExportSupportReportAction {
  try {
    $reportPath = Export-EmTroLySupportReport -PayloadRoot $PayloadRoot
    Show-Info "Đã xuất báo cáo hỗ trợ an toàn (đã ẩn toàn bộ mã bí mật) tại:`n$reportPath" 'Xuất báo cáo thành công'
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $reportPath + '"') | Out-Null
  } catch {
    Show-Error 'Không thể xuất file báo cáo hỗ trợ.'
  }
}

$runPreflightBtn.Add_Click({
  $runPreflightBtn.IsEnabled = $false
  $runPreflightBtn.Content = 'Đang quét...'
  $preflightListPanel.Children.Clear()
  $tbWait = New-Object System.Windows.Controls.TextBlock
  $tbWait.Text = 'Đang kiểm tra hệ điều hành, ổ cứng trống và đường truyền mạng...'
  $tbWait.Foreground = New-Brush '#2563EB'
  $tbWait.FontFamily = New-Object System.Windows.Media.FontFamily($uiFontFamily)
  [void]$preflightListPanel.Children.Add($tbWait)

  Start-AsyncUiTask -Params @{ HelperPath = $wizardHelperPath } -Work {
    param($HelperPath)
    . ([ScriptBlock]::Create([IO.File]::ReadAllText($HelperPath, [System.Text.Encoding]::UTF8)))
    return ,(Test-EmTroLyPreflightChecks)
  } -OnComplete {
    param($items, $err)
    $runPreflightBtn.IsEnabled = $true
    $runPreflightBtn.Content = 'Kiểm tra hệ thống ngay'
    $preflightListPanel.Children.Clear()
    foreach ($it in @($items)) {
      $row = New-Object System.Windows.Controls.DockPanel
      $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
      $icon = New-Object System.Windows.Controls.TextBlock
      $icon.FontFamily = New-Object System.Windows.Media.FontFamily($uiFontFamily)
      $icon.FontWeight = [System.Windows.FontWeights]::Bold
      $icon.Width = 24
      $icon.Text = if ($it.Ok) { '✓' } else { '!' }
      $icon.Foreground = if ($it.Ok) { New-Brush '#059669' } else { New-Brush '#DC2626' }
      [System.Windows.Controls.DockPanel]::SetDock($icon, [System.Windows.Controls.Dock]::Left)

      $det = New-Object System.Windows.Controls.TextBlock
      $det.FontFamily = New-Object System.Windows.Media.FontFamily($uiFontFamily)
      $det.FontSize = 12.5
      $det.Text = $it.Detail
      $det.Foreground = if ($it.Ok) { New-Brush '#475569' } else { New-Brush '#B91C1C' }
      [System.Windows.Controls.DockPanel]::SetDock($det, [System.Windows.Controls.Dock]::Right)

      $lbl = New-Object System.Windows.Controls.TextBlock
      $lbl.FontFamily = New-Object System.Windows.Media.FontFamily($uiFontFamily)
      $lbl.FontSize = 13
      $lbl.FontWeight = [System.Windows.FontWeights]::SemiBold
      $lbl.Text = $it.Name
      $lbl.Foreground = New-Brush '#0F172A'

      [void]$row.Children.Add($icon)
      [void]$row.Children.Add($det)
      [void]$row.Children.Add($lbl)
      [void]$preflightListPanel.Children.Add($row)
    }
  }
})

# Navigation & Action Wiring
$navHomeBtn.Add_Click({ Set-NavActive 'home' })
$navModularBtn.Add_Click({ Set-NavActive 'modular' })
$navConfigBtn.Add_Click({ Set-NavActive 'config' })
$navCodexBtn.Add_Click({ Set-NavActive 'codex' })
$navDiagBtn.Add_Click({ Set-NavActive 'diag' })

$headerQuickBtn.Add_Click({
  if ($script:installRunning -or $script:retryEditor) { return }
  if ($script:currentView -eq 'codex') { Set-NavActive 'home' } else { Set-NavActive 'codex' }
})

$dashOpenWebBtn.Add_Click({
  if ($script:gatewayDashboardUrl) {
    Start-Process -FilePath $script:gatewayDashboardUrl | Out-Null
  }
})
$dashRefreshBtn.Add_Click({
  Start-LiveZaloStatusSync -Force
  Update-DashboardCards
})
$dashRestartBtn.Add_Click({ Start-ManageAction 'health-restart' })
$dashEditConfigBtn.Add_Click({ Set-NavActive 'config' })
$dashZaloQrBtn.Add_Click({ Start-ZaloQrLoginSession })
$dashZaloBtn.Add_Click({ Start-ManageAction 'install-zalo' })
$dashCodexRepairBtn.Add_Click({ Start-ManageAction 'reinstall-codex' })
$dashOpenCodexBtn.Add_Click({ Set-NavActive 'codex' })
$dashAutoHealBtn.Add_Click({ Start-ManageAction 'auto-heal' })
$dashExportBtn.Add_Click({ Invoke-ExportSupportReportAction })

$diagAutoHealBtn.Add_Click({ Start-ManageAction 'auto-heal' })
$diagRestartBtn.Add_Click({ Start-ManageAction 'health-restart' })
$diagZaloQrBtn.Add_Click({ Start-ZaloQrLoginSession })
$diagZaloBtn.Add_Click({ Start-ManageAction 'install-zalo' })

$sidebarZaloPill.Add_MouseLeftButtonUp({
  if (-not $script:installRunning -and -not $script:retryEditor) {
    Start-ZaloQrLoginSession
  }
})
$headerZaloBadge.Add_MouseLeftButtonUp({
  if (-not $script:installRunning -and -not $script:retryEditor) {
    Show-ZaloConnectedView
  }
})

$zaloQrRefreshBtn.Add_Click({ Start-ZaloQrLoginSession -ForceNewQr })
$zaloQrBackBtn.Add_Click({
  Stop-ZaloQrSession
  Set-NavActive 'home'
})
$diagCodexBtn.Add_Click({ Start-ManageAction 'reinstall-codex' })
$diagUninstallBtn.Add_Click({
  if ($script:installRunning -or $script:retryEditor) { return }
  $confirmUn = [System.Windows.MessageBox]::Show(
    $window,
    "Bạn có chắc chắn muốn dừng Gateway, sao lưu cấu hình (openclaw.json) và gỡ sạch thư mục trợ lý OpenClaw để cài lại từ đầu không?`n`n(Lưu ý: Antigravity IDE & Codex CLI vẫn được giữ nguyên để lần cài lại diễn ra siêu nhanh!)",
    'Xác nhận gỡ trợ lý để cài lại',
    [System.Windows.MessageBoxButton]::YesNo,
    [System.Windows.MessageBoxImage]::Warning
  )
  if ($confirmUn -eq [System.Windows.MessageBoxResult]::Yes) {
    Start-ManageAction 'uninstall-instance'
  }
})
$diagExportBtn.Add_Click({ Invoke-ExportSupportReportAction })
$diagShortcutBtn.Add_Click({
  $sc = Install-EmTroLyAppShortcut -PayloadRoot $PayloadRoot
  if ($sc.Created) {
    Show-Info "Đã tạo lối tắt Em Trợ Lý trên Desktop:`n$($sc.Path)" 'Tạo lối tắt thành công'
  } else {
    Show-Error 'Chưa tìm thấy tệp ứng dụng để tạo lối tắt trên Desktop.'
  }
})
$openChangeLicensePrompt = {
  if ($script:installRunning -or $script:retryEditor) { return }
  Show-LicenseGate '' -AllowCancel
  [void]$licensePwdBox.Focus()
}
$sidebarLicensePill.Add_MouseLeftButtonUp($openChangeLicensePrompt)
$diagChangeLicenseBtn.Add_Click($openChangeLicensePrompt)
$sidebarSignOutLicenseBtn.Add_Click({ Invoke-UiLicenseSignOut })
$diagSignOutLicenseBtn.Add_Click({ Invoke-UiLicenseSignOut })
$licenseSignOutBtn.Add_Click({ Invoke-UiLicenseSignOut })

$modRefreshBtn.Add_Click({ [void](Update-ModularCards) })
$modSelectAllBtn.Add_Click({
  $modCheck1.IsChecked = $true
  $modCheck2.IsChecked = $true
  $modCheck3.IsChecked = $true
})
$modInstall1Btn.Add_Click({ Start-ModularInstall @('codex-cli') })
$modInstall2Btn.Add_Click({ Start-ModularInstall @('antigravity-ide') })
$modInstall3Btn.Add_Click({ Start-ModularInstall @('codex-extension') })
$modInstall4Btn.Add_Click({ Start-ModularInstall @('openclaw') })
$modAutoFetchBtn.Add_Click({
  $tokMod = $modTokenPwdBox.Password.Trim()
  if ([string]::IsNullOrWhiteSpace($tokMod)) {
    Show-Error 'Hãy dán Telegram Bot Token vào ô phía trên trước rồi bấm Lấy ID tự động.'
    return
  }
  $modAutoFetchBtn.IsEnabled = $false
  $modAutoFetchBtn.Content = 'Đang lấy...'
  $modTgStatusNote.Visibility = [System.Windows.Visibility]::Visible
  $modTgStatusNote.Foreground = New-Brush '#1D4ED8'
  $modTgStatusNote.Text = 'Đang đọc tin nhắn gần nhất từ Telegram Bot...'
  Start-AsyncUiTask -Params @{ HelperPath = $wizardHelperPath; Token = $tokMod } -Work {
    param($HelperPath, $Token)
    . ([ScriptBlock]::Create([IO.File]::ReadAllText($HelperPath, [System.Text.Encoding]::UTF8)))
    return (Get-TelegramIdsFromBotUpdates -TelegramToken $Token)
  } -OnComplete {
    param($res, $err)
    $modAutoFetchBtn.IsEnabled = $true
    $modAutoFetchBtn.Content = 'Lấy ID tự động'
    if ($err -or -not $res) {
      $modTgStatusNote.Foreground = New-Brush '#B91C1C'
      $modTgStatusNote.Text = 'Không lấy được ID từ Telegram. Kiểm tra kết nối mạng và Token.'
      return
    }
    if ($res.SuggestedOwnerId) { $modOwnersBox.Text = $res.SuggestedOwnerId; $ownersBox.Text = $res.SuggestedOwnerId }
    if ($res.SuggestedGroupId) { $modGroupBox.Text = $res.SuggestedGroupId; $groupBox.Text = $res.SuggestedGroupId }
    $modTgStatusNote.Foreground = if ($res.Ok) { New-Brush '#065F46' } else { New-Brush '#B91C1C' }
    $modTgStatusNote.Text = $res.Message
  }
})

$btnCopyErrorDetail.Add_Click({
  if (-not [string]::IsNullOrWhiteSpace($script:lastFullErrorReport)) {
    try {
      [System.Windows.Clipboard]::SetText($script:lastFullErrorReport)
      $btnCopyErrorDetail.Content = '✓ Đã sao chép'
    } catch { }
  }
})
$btnOpenCodexFromError.Add_Click({ Set-NavActive 'codex' })
$btnBackToSetup.Add_Click({ Set-NavActive 'home' })
$btnInstallAutoHeal.Add_Click({ Start-ManageAction 'auto-heal' $script:lastInstallErrorDetail })
$btnProgressExport.Add_Click({ Invoke-ExportSupportReportAction })

$codexBrowseBtn.Add_Click({
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $dialog.Description = 'Chọn thư mục bạn muốn Codex CLI chỉnh sửa hoặc kiểm tra'
  if (Test-Path -LiteralPath $codexDirBox.Text.Trim() -PathType Container) {
    $dialog.SelectedPath = $codexDirBox.Text.Trim()
  }
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $dialog.SelectedPath) {
    $codexDirBox.Text = $dialog.SelectedPath
  }
  $dialog.Dispose()
})
$codexOpenDirBtn.Add_Click({
  $dir = $codexDirBox.Text.Trim()
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Show-Error 'Thư mục chưa tồn tại để mở.'; return }
  Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $dir + '"') | Out-Null
})
$codexTerminalBtn.Add_Click({
  try {
    Start-CodexInteractiveWindow -WorkspaceDir $codexDirBox.Text.Trim() -Model ([string]$modelBox.SelectedItem).Trim()
  } catch {
    Show-Error 'Không thể mở cửa sổ Codex CLI. Hãy kiểm tra thư mục đã chọn và trạng thái cài đặt Codex.'
  }
})
$presetConfigBtn.Add_Click({ $codexPromptBox.Text = 'Hãy kiểm tra cấu hình trong thư mục này và chỉnh sửa giúp tôi theo yêu cầu: '; [void]$codexPromptBox.Focus() })
$presetSkillBtn.Add_Click({ $codexPromptBox.Text = 'Hãy chỉnh sửa nội dung hướng dẫn / kỹ năng của trợ lý theo yêu cầu sau: '; [void]$codexPromptBox.Focus() })
$presetFixBtn.Add_Click({ $codexPromptBox.Text = 'Hãy kiểm tra các tệp trong thư mục này, nếu có lỗi cấu hình hoặc cú pháp thì sửa giúp tôi và tóm tắt ngắn gọn những gì đã sửa.'; [void]$codexPromptBox.Focus() })
$codexRefreshBtn.Add_Click({ [void](Update-CodexAvailability) })
$codexRunBtn.Add_Click({ Start-CodexTask })
$codexStopBtn.Add_Click({
  Stop-CodexRun
  $codexOutputBox.AppendText("`r`n[Đã gửi yêu cầu dừng lệnh Codex CLI]`r`n")
})
$codexClearBtn.Add_Click({ $codexOutputBox.Text = $codexGuideText })

$licenseShowCheck.Add_Checked({ $licenseKeyBox.UseSystemPasswordChar = $false })
$licenseShowCheck.Add_Unchecked({ $licenseKeyBox.UseSystemPasswordChar = $true })
$licenseActivateBtn.Add_Click({ Invoke-LicenseVerifyFlow -CandidateKey $licenseKeyBox.Text -IsStartupAuto $false })
$licenseExitBtn.Add_Click({
  if ($script:licenseCanDismiss -and $script:licenseVerified) {
    $script:licenseCanDismiss = $false
    $licenseKeyBox.Clear()
    $licenseGateOverlay.Visibility = [System.Windows.Visibility]::Collapsed
    return
  }
  $window.Close()
})
$licensePwdBox.Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq [System.Windows.Input.Key]::Return) {
    Invoke-LicenseVerifyFlow -CandidateKey $licenseKeyBox.Text -IsStartupAuto $false
  }
})
$licensePlainBox.Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq [System.Windows.Input.Key]::Return) {
    Invoke-LicenseVerifyFlow -CandidateKey $licenseKeyBox.Text -IsStartupAuto $false
  }
})

$markDraftDirty = {
  if (-not $script:draftHydrating -and -not $script:isManageMode) {
    $script:draftDirty = $true
  }
}
foreach ($tbCtrl in @($tokenPlainBox, $apiKeyPlainBox, $ownersBox, $groupBox, $assistantBox, $portBox, $qrOwnerBox, $audienceBox, $addressingBox, $styleBox)) {
  if ($tbCtrl) { $tbCtrl.Add_TextChanged($markDraftDirty) }
}
foreach ($pwCtrl in @($tokenPwdBox, $apiKeyPwdBox)) {
  if ($pwCtrl) { $pwCtrl.Add_PasswordChanged($markDraftDirty) }
}
$modelBox.Add_SelectionChanged($markDraftDirty)
foreach ($cbCtrl in @($zaloCheck, $existingEditorCheck, $fullAccessCheck)) {
  if ($cbCtrl) { $cbCtrl.Add_Click($markDraftDirty) }
}
$clearSavedDraftBtn.Add_Click({ Clear-SavedDraftAction })

$primaryActionBtn.Add_Click({ Start-Install })
$stopTaskButton.Add_Click({
  if (-not $script:installRunning) { return }
  $ans = [System.Windows.MessageBox]::Show($window, 'Bạn có muốn dừng tiến trình đang chạy không?', 'Xác nhận dừng tác vụ', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
  if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
  Stop-ActiveRunner 'Đã dừng tiến trình theo yêu cầu của bạn. Bạn có thể chỉnh sửa lại thông tin hoặc bấm Thoát.'
})
$cancelButton.Add_Click({ $window.Close() })

$window.Add_Closing({
  param($sender, $e)
  if ($script:installRunning) {
    $ans = [System.Windows.MessageBox]::Show($window, 'Tiến trình đang chạy. Bạn có muốn dừng ngay tiến trình này và thoát giao diện không?', 'Xác nhận dừng và thoát', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) {
      $e.Cancel = $true
      return
    }
    Stop-ActiveRunner ''
  }
  if ($script:codexRunning) {
    $ansC = [System.Windows.MessageBox]::Show($window, 'Codex CLI đang thực hiện yêu cầu của bạn. Bạn có muốn dừng lệnh và thoát giao diện không?', 'Xác nhận dừng và thoát', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($ansC -ne [System.Windows.MessageBoxResult]::Yes) {
      $e.Cancel = $true
      return
    }
    Stop-CodexRun
    Cleanup-CodexRun
  }
  if (-not $SmokeTest -and -not $script:isManageMode -and $script:draftDirty) {
    Save-CurrentFormDraft
  }
  Stop-ZaloQrSession
  if ($asyncTimer) { $asyncTimer.Stop() }
  foreach ($asyncItem in @($script:asyncTasks)) {
    try { $asyncItem.Ps.Stop() } catch { }
    try { $asyncItem.Ps.Dispose() } catch { }
  }
  $script:asyncTasks.Clear()
  if ($liveSyncTimer) { $liveSyncTimer.Stop() }
  if ($script:zaloSyncProc) {
    try { if (-not $script:zaloSyncProc.HasExited) { $script:zaloSyncProc.Kill() } } catch { }
    try { $script:zaloSyncProc.Dispose() } catch { }
    $script:zaloSyncProc = $null
  }
  Cleanup-Secret
  $script:sessionApiKeyFallback = ''
  if (-not $script:retryEditor -and -not $script:installCompleted) {
    $script:resultCode = 2
  }
})

# Initialize Mode (Pending Retry / Existing Installed / Fresh Install)
$installedSnapshot = Get-EmTroLyInstalledState
$hasExistingInstall = $installedSnapshot.OpenClawInstalled -or
  ($env:LOCALAPPDATA -and (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'EmTroLy\Codex\auth.json') -PathType Leaf))

if (Test-Path -LiteralPath $pending -PathType Leaf) {
  $script:retryEditor = $true
  $script:resultCode = 3
  $coreReadyText.Visibility = [System.Windows.Visibility]::Visible
  $coreReadyText.Text = '✓ OpenClaw và Zalo đã hoàn tất ở lần cài trước.'
  $statusText.Text = 'Nhập khóa API bên dưới và bấm Thử lại bước Codex để hoàn tất.'
  $retryEditorPanel.Visibility = [System.Windows.Visibility]::Visible
  Set-NavActive 'progress'
} elseif ($installedSnapshot.OpenClawInstalled) {
  Apply-ManageModeUI
  if ($CodexMode) { Set-NavActive 'codex' } else { Set-NavActive 'home' }
} elseif ($CodexMode -or $hasExistingInstall) {
  $script:resultCode = 0
  $script:installCompleted = $true
  [void](Apply-SavedSetupDraft)
  Set-NavActive 'codex'
} else {
  [void](Apply-SavedSetupDraft)
  Set-NavActive 'home'
}

[void](Update-CodexAvailability)
if ($SmokeTest) {
  $window.Close()
  $script:resultCode = 0
  exit 0
}

# One-time per-machine activation: if already activated on this PC, unlock immediately BEFORE rendering (zero prompt / zero delay)
$savedLicOnStartup = if (Get-Command Get-EmTroLySavedLicenseKey -ErrorAction SilentlyContinue) { Get-EmTroLySavedLicenseKey } else { '' }
if (-not [string]::IsNullOrWhiteSpace($savedLicOnStartup)) {
  Unlock-LicenseGate $savedLicOnStartup -SkipSave
} else {
  Show-LicenseGate ''
}

$window.Add_ContentRendered({
  $window.Activate()
  if (-not $SmokeTest -and -not $script:licenseVerified) {
    [void]$licensePwdBox.Focus()
  }
})
try {
  [void]$window.ShowDialog()
} finally {
  Stop-ZaloQrSession
  Stop-CodexRun
  Cleanup-CodexRun
  Cleanup-Secret
  if ($script:singleInstanceMutex) {
    try { $script:singleInstanceMutex.ReleaseMutex() } catch { }
    try { $script:singleInstanceMutex.Dispose() } catch { }
    $script:singleInstanceMutex = $null
  }
}
exit $script:resultCode
