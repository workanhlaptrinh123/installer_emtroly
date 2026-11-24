using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

[assembly: AssemblyTitle("Anh Lap Trinh - Em Tro Ly Setup")]
[assembly: AssemblyDescription("Official SmartScreen-Safe Online Setup Launcher for Anh Lap Trinh - Em Tro Ly")]
[assembly: AssemblyConfiguration("")]
[assembly: AssemblyCompany("Anh Lap Trinh")]
[assembly: AssemblyProduct("Anh Lap Trinh - Em Tro Ly")]
[assembly: AssemblyCopyright("Copyright (c) Anh Lap Trinh")]
[assembly: AssemblyTrademark("")]
[assembly: AssemblyCulture("")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

namespace AnhLapTrinh.EmTroLy.Setup
{
    internal sealed class BootstrapOptions
    {
        public bool DownloadOnly;
        public bool Quiet;
        public string OutFile = string.Empty;
        public string VersionTag = string.Empty;
        public int TestLoopbackPort;
        public string RenderPreviewFile = string.Empty;
    }

    internal static class Program
    {
        private const string OfficialReleaseRoot = "https://github.com/workanhlaptrinh123/installer_emtroly/releases";
        private const string UserAgentValue = "AnhLapTrinh-EmTroLy-Setup/1.1";

        [STAThread]
        private static int Main(string[] args)
        {
            BootstrapOptions options;
            try
            {
                options = ParseArgs(args);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.Message);
                return 2;
            }

            if (!Environment.Is64BitOperatingSystem)
            {
                if (!options.Quiet)
                {
                    MessageBox.Show(
                        "Bộ cài Em Trợ Lý yêu cầu Windows 10/11 64-bit (x64).",
                        "Em Trợ Lý — Anh Lập Trình",
                        MessageBoxButton.OK,
                        MessageBoxImage.Error);
                }
                return 1;
            }

            ConfigureTls();

            if (options.Quiet)
            {
                try
                {
                    string target = DownloadAndVerifyInstaller(options, null, null);
                    if (!options.DownloadOnly)
                    {
                        LaunchInstaller(target);
                    }
                    return 0;
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine(ex.Message);
                    return 1;
                }
            }

            if (!string.IsNullOrWhiteSpace(options.RenderPreviewFile))
            {
                Application previewApp = new Application();
                SetupWindow previewWin = new SetupWindow(options);
                previewApp.Run(previewWin);
                return previewWin.ExitCode;
            }

            bool createdNew = false;
            using (Mutex singleMutex = new Mutex(true, @"Local\EmTroLy-Bootstrap-Setup-SingleInstance", out createdNew))
            {
                if (!createdNew)
                {
                    return 0;
                }

                Application app = new Application();
                SetupWindow window = new SetupWindow(options);
                app.Run(window);
                return window.ExitCode;
            }
        }

        internal static void ConfigureTls()
        {
            try
            {
                ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072 | (SecurityProtocolType)12288;
            }
            catch
            {
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            }
        }

        internal static BootstrapOptions ParseArgs(string[] args)
        {
            BootstrapOptions opt = new BootstrapOptions();
            if (args == null)
            {
                return opt;
            }
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i] ?? string.Empty;
                if (string.Equals(a, "--download-only", StringComparison.OrdinalIgnoreCase))
                {
                    opt.DownloadOnly = true;
                }
                else if (string.Equals(a, "--quiet", StringComparison.OrdinalIgnoreCase))
                {
                    opt.Quiet = true;
                }
                else if (string.Equals(a, "--out", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    opt.OutFile = args[++i];
                }
                else if (string.Equals(a, "--render-preview", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    opt.RenderPreviewFile = args[++i];
                }
                else if (string.Equals(a, "--version", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    string v = (args[++i] ?? string.Empty).Trim();
                    if (!Regex.IsMatch(v, @"^v?[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$"))
                    {
                        throw new ArgumentException("Invalid version format.");
                    }
                    opt.VersionTag = v.StartsWith("v", StringComparison.OrdinalIgnoreCase) ? v : ("v" + v);
                }
                else if (string.Equals(a, "--test-loopback-port", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    int port;
                    if (!int.TryParse(args[++i], out port) || port < 1 || port > 65535)
                    {
                        throw new ArgumentException("Invalid loopback port.");
                    }
                    opt.TestLoopbackPort = port;
                }
            }
            return opt;
        }

        internal static string BuildDownloadBaseUrl(BootstrapOptions options)
        {
            if (options.TestLoopbackPort > 0)
            {
                return "http://127.0.0.1:" + options.TestLoopbackPort.ToString() + "/download";
            }
            if (!string.IsNullOrEmpty(options.VersionTag))
            {
                return OfficialReleaseRoot + "/download/" + options.VersionTag;
            }
            return OfficialReleaseRoot + "/latest/download";
        }

        internal static string FormatFriendlyErrorMessage(Exception ex)
        {
            string raw = ex != null ? (ex.Message ?? string.Empty) : string.Empty;
            WebException webEx = ex as WebException;
            if (webEx != null)
            {
                HttpWebResponse httpResp = webEx.Response as HttpWebResponse;
                if (httpResp != null)
                {
                    int code = (int)httpResp.StatusCode;
                    if (code == 404)
                    {
                        return "Phiên bản mới vừa được tạo trên GitHub và đang hoàn tất đóng gói (404). Bạn vui lòng đợi khoảng 1 phút rồi bấm \"Thử lại ngay\".";
                    }
                    if (code == 403 || code == 429)
                    {
                        return "Máy chủ GitHub đang tạm giới hạn lượt tải đồng thời (" + code.ToString() + "). Bạn hãy đợi vài giây rồi bấm \"Thử lại ngay\".";
                    }
                    if (code >= 500)
                    {
                        return "Máy chủ GitHub đang bận tạm thời (" + code.ToString() + "). Vui lòng bấm \"Thử lại ngay\" sau ít giây.";
                    }
                }
                if (webEx.Status == WebExceptionStatus.NameResolutionFailure ||
                    webEx.Status == WebExceptionStatus.ConnectFailure)
                {
                    return "Không kết nối được mạng tới GitHub. Bạn hãy kiểm tra Wi-Fi / Internet hoặc tường lửa rồi bấm \"Thử lại ngay\".";
                }
                if (webEx.Status == WebExceptionStatus.Timeout)
                {
                    return "Kết nối mạng bị quá thời gian chờ. Bạn hãy kiểm tra đường truyền rồi bấm \"Thử lại ngay\".";
                }
            }
            if (string.IsNullOrWhiteSpace(raw))
            {
                return "Không tải được bộ cài mới nhất. Bạn hãy kiểm tra kết nối mạng rồi bấm \"Thử lại ngay\".";
            }
            return "Không tải được bộ cài mới nhất: " + raw;
        }

        internal static string DownloadAndVerifyInstaller(
            BootstrapOptions options,
            Action<string, int> reportProgress,
            Func<bool> isCancelled)
        {
            string baseUrl = BuildDownloadBaseUrl(options);
            if (reportProgress != null)
            {
                reportProgress("Đang kiểm tra phiên bản bộ cài mới nhất trên GitHub...", 8);
            }

            string versionLabel = ReadLatestVersionLabel(baseUrl);
            string shaText = DownloadSmallText(baseUrl + "/emtroly.exe.sha256", 30000);
            Match shaMatch = Regex.Match(shaText ?? string.Empty, @"\b([a-fA-F0-9]{64})\b");
            if (!shaMatch.Success)
            {
                throw new InvalidDataException("Không đọc được mã kiểm tra an toàn SHA-256 từ máy chủ phát hành.");
            }
            string expectedHash = shaMatch.Groups[1].Value.ToLowerInvariant();

            string workDir;
            string targetExe;
            if (!string.IsNullOrWhiteSpace(options.OutFile))
            {
                targetExe = Path.GetFullPath(options.OutFile);
                workDir = Path.GetDirectoryName(targetExe);
            }
            else
            {
                string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                workDir = Path.Combine(localAppData, @"AnhLapTrinh\EmTroLy\bootstrap");
                string suffix = !string.IsNullOrEmpty(versionLabel)
                    ? Regex.Replace(versionLabel, @"[^0-9A-Za-z._-]", "")
                    : expectedHash.Substring(0, 12);
                targetExe = Path.Combine(workDir, "emtroly-" + suffix + ".exe");
            }

            if (!string.IsNullOrEmpty(workDir))
            {
                Directory.CreateDirectory(workDir);
            }

            if (File.Exists(targetExe))
            {
                string cachedHash = ComputeSha256Hex(targetExe);
                if (string.Equals(cachedHash, expectedHash, StringComparison.OrdinalIgnoreCase))
                {
                    string verDisplay = !string.IsNullOrEmpty(versionLabel) ? (" v" + versionLabel) : string.Empty;
                    if (reportProgress != null)
                    {
                        reportProgress("Đã xác minh an toàn bộ cài" + verDisplay + "! Đang mở giao diện Em Trợ Lý...", 100);
                    }
                    CleanupOldCachedInstallers(workDir, targetExe, options.OutFile);
                    return targetExe;
                }
            }

            string tmpExe = targetExe + ".part-" + Guid.NewGuid().ToString("N").Substring(0, 8);
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(baseUrl + "/emtroly.exe");
                req.Method = "GET";
                req.AllowAutoRedirect = true;
                req.UserAgent = UserAgentValue;
                req.Timeout = 600000;
                req.ReadWriteTimeout = 120000;

                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                {
                    ValidateRedirectHost(resp.ResponseUri, options.TestLoopbackPort > 0);
                    long totalBytes = resp.ContentLength;
                    using (Stream inStream = resp.GetResponseStream())
                    using (FileStream outStream = new FileStream(tmpExe, FileMode.Create, FileAccess.Write, FileShare.None, 262144))
                    {
                        byte[] buffer = new byte[65536];
                        long readTotal = 0;
                        int lastTick = Environment.TickCount - 500;
                        int n;
                        while ((n = inStream.Read(buffer, 0, buffer.Length)) > 0)
                        {
                            if (isCancelled != null && isCancelled())
                            {
                                throw new OperationCanceledException("Đã hủy tải bộ cài.");
                            }
                            outStream.Write(buffer, 0, n);
                            readTotal += n;

                            int now = Environment.TickCount;
                            if (reportProgress != null && (now - lastTick >= 100 || readTotal == totalBytes))
                            {
                                lastTick = now;
                                string verTag = !string.IsNullOrEmpty(versionLabel) ? (" v" + versionLabel) : string.Empty;
                                if (totalBytes > 0)
                                {
                                    int pct = (int)Math.Min(96L, Math.Max(10L, (readTotal * 96L) / totalBytes));
                                    double mbDone = readTotal / (1024.0 * 1024.0);
                                    double mbTotal = totalBytes / (1024.0 * 1024.0);
                                    reportProgress(
                                        string.Format("Đang tải bộ cài Em Trợ Lý{0} ({1:0.0} / {2:0.0} MB)...", verTag, mbDone, mbTotal),
                                        pct);
                                }
                                else
                                {
                                    double mbDone = readTotal / (1024.0 * 1024.0);
                                    reportProgress(
                                        string.Format("Đang tải bộ cài Em Trợ Lý{0} ({1:0.0} MB)...", verTag, mbDone),
                                        50);
                                }
                            }
                        }
                    }
                }

                if (reportProgress != null)
                {
                    reportProgress("Đang đối chiếu mã kiểm tra toàn vẹn SHA-256...", 98);
                }

                string actualHash = ComputeSha256Hex(tmpExe);
                if (!string.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException("Mã kiểm tra SHA-256 của bộ cài không khớp. Đã hủy để bảo vệ máy tính của bạn.");
                }

                if (File.Exists(targetExe))
                {
                    try { File.Delete(targetExe); } catch { }
                }
                File.Move(tmpExe, targetExe);
                CleanupOldCachedInstallers(workDir, targetExe, options.OutFile);

                if (reportProgress != null)
                {
                    reportProgress("Đã tải xong và xác minh an toàn! Đang mở giao diện Em Trợ Lý...", 100);
                }
                return targetExe;
            }
            finally
            {
                if (File.Exists(tmpExe))
                {
                    try { File.Delete(tmpExe); } catch { }
                }
            }
        }

        private static void ValidateRedirectHost(Uri finalUri, bool allowLoopback)
        {
            if (finalUri == null)
            {
                throw new WebException("URL phản hồi không hợp lệ.");
            }
            if (allowLoopback && string.Equals(finalUri.Host, "127.0.0.1", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
            if (!string.Equals(finalUri.Scheme, "https", StringComparison.OrdinalIgnoreCase))
            {
                throw new WebException("Chỉ chấp nhận kết nối HTTPS an toàn.");
            }
            string host = (finalUri.Host ?? string.Empty).ToLowerInvariant();
            if (host == "github.com" ||
                host.EndsWith(".github.com", StringComparison.Ordinal) ||
                host.EndsWith(".githubusercontent.com", StringComparison.Ordinal))
            {
                return;
            }
            throw new WebException("Máy chủ tải về không thuộc GitHub chính thức: " + host);
        }

        private static string ReadLatestVersionLabel(string baseUrl)
        {
            try
            {
                string manifest = DownloadSmallText(baseUrl + "/MANIFEST.txt", 12000);
                Match m = Regex.Match(manifest ?? string.Empty, @"(?m)^installer_version=([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$");
                if (m.Success)
                {
                    return m.Groups[1].Value.Trim();
                }
            }
            catch
            {
            }
            return string.Empty;
        }

        private static string DownloadSmallText(string url, int timeoutMs)
        {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = "GET";
            req.AllowAutoRedirect = true;
            req.UserAgent = UserAgentValue;
            req.Timeout = timeoutMs;
            req.ReadWriteTimeout = timeoutMs;
            using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
            using (Stream s = resp.GetResponseStream())
            using (StreamReader sr = new StreamReader(s, Encoding.UTF8))
            {
                return sr.ReadToEnd();
            }
        }

        private static string ComputeSha256Hex(string filePath)
        {
            using (SHA256 sha = SHA256.Create())
            using (FileStream fs = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read, 131072))
            {
                byte[] hash = sha.ComputeHash(fs);
                StringBuilder sb = new StringBuilder(hash.Length * 2);
                for (int i = 0; i < hash.Length; i++)
                {
                    sb.Append(hash[i].ToString("x2"));
                }
                return sb.ToString();
            }
        }

        private static void CleanupOldCachedInstallers(string workDir, string keepExe, string explicitOutFile)
        {
            if (!string.IsNullOrWhiteSpace(explicitOutFile) || string.IsNullOrEmpty(workDir) || !Directory.Exists(workDir))
            {
                return;
            }
            try
            {
                string keepName = Path.GetFileName(keepExe);
                foreach (string f in Directory.GetFiles(workDir, "emtroly-*.exe"))
                {
                    if (!string.Equals(Path.GetFileName(f), keepName, StringComparison.OrdinalIgnoreCase))
                    {
                        try { File.Delete(f); } catch { }
                    }
                }
            }
            catch
            {
            }
        }

        internal static void LaunchInstaller(string exePath)
        {
            ProcessStartInfo psi = new ProcessStartInfo
            {
                FileName = exePath,
                WorkingDirectory = Path.GetDirectoryName(exePath) ?? Environment.CurrentDirectory,
                UseShellExecute = false
            };
            using (Process.Start(psi))
            {
            }
        }
    }

    internal sealed class SetupWindow : Window
    {
        private const string WindowContentXaml = @"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Margin='16'
        Background='#FFFFFF'
        BorderBrush='#E2E8F0'
        BorderThickness='1'
        CornerRadius='14'
        Padding='24,20'>
  <Border.Resources>
    <Style x:Key='PrimaryActionBtn' TargetType='Button'>
      <Setter Property='Background' Value='#2563EB'/>
      <Setter Property='Foreground' Value='#FFFFFF'/>
      <Setter Property='FontFamily' Value='Segoe UI'/>
      <Setter Property='FontSize' Value='13'/>
      <Setter Property='FontWeight' Value='SemiBold'/>
      <Setter Property='Height' Value='36'/>
      <Setter Property='Padding' Value='18,0'/>
      <Setter Property='Cursor' Value='Hand'/>
      <Setter Property='BorderThickness' Value='0'/>
      <Setter Property='Template'>
        <Setter.Value>
          <ControlTemplate TargetType='Button'>
            <Border x:Name='bd' Background='{TemplateBinding Background}' CornerRadius='8' Padding='{TemplateBinding Padding}'>
              <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property='IsMouseOver' Value='True'>
                <Setter TargetName='bd' Property='Background' Value='#1D4ED8'/>
              </Trigger>
              <Trigger Property='IsEnabled' Value='False'>
                <Setter TargetName='bd' Property='Opacity' Value='0.5'/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key='SecondaryActionBtn' TargetType='Button'>
      <Setter Property='Background' Value='#FFFFFF'/>
      <Setter Property='Foreground' Value='#334155'/>
      <Setter Property='BorderBrush' Value='#CBD5E1'/>
      <Setter Property='BorderThickness' Value='1'/>
      <Setter Property='FontFamily' Value='Segoe UI'/>
      <Setter Property='FontSize' Value='13'/>
      <Setter Property='FontWeight' Value='SemiBold'/>
      <Setter Property='Height' Value='36'/>
      <Setter Property='MinWidth' Value='92'/>
      <Setter Property='Padding' Value='16,0'/>
      <Setter Property='Cursor' Value='Hand'/>
      <Setter Property='Template'>
        <Setter.Value>
          <ControlTemplate TargetType='Button'>
            <Border x:Name='bd' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='8' Padding='{TemplateBinding Padding}'>
              <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property='IsMouseOver' Value='True'>
                <Setter TargetName='bd' Property='Background' Value='#F8FAFC'/>
                <Setter TargetName='bd' Property='BorderBrush' Value='#94A3B8'/>
              </Trigger>
              <Trigger Property='IsEnabled' Value='False'>
                <Setter TargetName='bd' Property='Opacity' Value='0.45'/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Border.Resources>

  <StackPanel>
    <!-- Top Brand Logo & Official Security Pill -->
    <DockPanel Margin='0,0,0,14'>
      <Border DockPanel.Dock='Right'
              Background='#ECFDF5'
              BorderBrush='#A7F3D0'
              BorderThickness='1'
              CornerRadius='12'
              Padding='10,4'
              VerticalAlignment='Center'>
        <StackPanel Orientation='Horizontal' VerticalAlignment='Center'>
          <Ellipse Width='7' Height='7' Fill='#10B981' VerticalAlignment='Center' Margin='0,0,6,0'/>
          <TextBlock Text='Xác thực SHA-256' FontSize='11.5' FontWeight='Bold' Foreground='#065F46' VerticalAlignment='Center'/>
        </StackPanel>
      </Border>
      <Border x:Name='BrandLogoHost'
              Background='#F8FAFC'
              BorderBrush='#E2E8F0'
              BorderThickness='1'
              CornerRadius='8'
              Padding='10,5'
              HorizontalAlignment='Left'
              VerticalAlignment='Center'>
        <Image x:Name='BrandLogoImage' Height='28' Stretch='Uniform' RenderOptions.BitmapScalingMode='HighQuality'/>
      </Border>
    </DockPanel>

    <!-- Title & Clear Subtitle (Full Wrapping, Never Clips) -->
    <TextBlock Text='Em Trợ Lý — Bộ Cài Đặt Chính Thức'
               FontSize='17.5'
               FontWeight='Bold'
               Foreground='#0F172A'
               TextWrapping='Wrap'/>
    <TextBlock Text='Tự động kiểm tra, tải phiên bản mới nhất và mở giao diện quản lý trọn gói'
               FontSize='12.5'
               Foreground='#64748B'
               Margin='0,4,0,0'
               TextWrapping='Wrap'/>

    <Border Height='1' Background='#F1F5F9' Margin='0,14,0,14'/>

    <!-- Live Status Message + Percentage Pill -->
    <Grid Margin='0,0,0,10'>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width='*'/>
        <ColumnDefinition Width='Auto'/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name='StatusText'
                 Grid.Column='0'
                 Text='Đang kết nối máy chủ phát hành chính thức...'
                 FontSize='13'
                 FontWeight='SemiBold'
                 Foreground='#1E293B'
                 LineHeight='19'
                 TextWrapping='Wrap'
                 VerticalAlignment='Center'/>
      <Border x:Name='PercentPill'
              Grid.Column='1'
              Background='#EFF6FF'
              BorderBrush='#BFDBFE'
              BorderThickness='1'
              CornerRadius='8'
              Padding='10,3'
              Margin='12,0,0,0'
              VerticalAlignment='Top'>
        <TextBlock x:Name='PercentText'
                   Text='5%'
                   FontSize='12'
                   FontWeight='Bold'
                   Foreground='#1D4ED8'/>
      </Border>
    </Grid>

    <!-- Smooth Rounded Progress Track & Indicator -->
    <Border x:Name='ProgressTrack'
            Height='10'
            Background='#DBEAFE'
            CornerRadius='5'
            ClipToBounds='True'>
      <Border x:Name='ProgressFill'
              HorizontalAlignment='Left'
              Height='10'
              Width='24'
              Background='#2563EB'
              CornerRadius='5'/>
    </Border>

    <!-- Friendly Inline Error Banner (Replaces raw system popup) -->
    <Border x:Name='ErrorBanner'
            Background='#FEF2F2'
            BorderBrush='#FECACA'
            BorderThickness='1'
            CornerRadius='10'
            Padding='13,10'
            Margin='0,12,0,0'
            Visibility='Collapsed'>
      <TextBlock x:Name='ErrorText'
                 Text=''
                 FontSize='12.5'
                 Foreground='#B91C1C'
                 LineHeight='18'
                 TextWrapping='Wrap'/>
    </Border>

    <!-- Footer Hint & Action Buttons -->
    <DockPanel Margin='0,16,0,0'>
      <StackPanel DockPanel.Dock='Right' Orientation='Horizontal' VerticalAlignment='Center'>
        <Button x:Name='RetryButton'
                Style='{StaticResource PrimaryActionBtn}'
                Content='Thử lại ngay'
                Margin='0,0,8,0'
                Visibility='Collapsed'/>
        <Button x:Name='CancelButton'
                Style='{StaticResource SecondaryActionBtn}'
                Content='Hủy'/>
      </StackPanel>
      <TextBlock x:Name='FooterHint'
                 Text='An toàn tuyệt đối · Giữ nguyên dữ liệu trên máy'
                 FontSize='11.5'
                 Foreground='#94A3B8'
                 VerticalAlignment='Center'
                 Margin='0,0,12,0'
                 TextWrapping='Wrap'/>
    </DockPanel>
  </StackPanel>
</Border>";

        private readonly BootstrapOptions _options;
        private readonly TextBlock _statusText;
        private readonly Border _percentPill;
        private readonly TextBlock _percentText;
        private readonly Border _progressTrack;
        private readonly Border _progressFill;
        private readonly Border _errorBanner;
        private readonly TextBlock _errorText;
        private readonly Button _retryButton;
        private readonly Button _cancelButton;
        private readonly ManualResetEvent _retrySignal = new ManualResetEvent(false);
        private volatile bool _cancelled;
        private volatile bool _finished;
        private volatile bool _waitingForRetry;
        private int _currentPercent = 5;
        public int ExitCode = 1;

        public SetupWindow(BootstrapOptions options)
        {
            _options = options;
            Title = "Em Trợ Lý — Anh Lập Trình";
            Width = 520;
            SizeToContent = SizeToContent.Height;
            ResizeMode = ResizeMode.CanMinimize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background = BrushFromHex("#F1F5F9");
            FontFamily = new FontFamily("Segoe UI");
            UseLayoutRounding = true;
            SnapsToDevicePixels = true;
            TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
            TextOptions.SetTextRenderingMode(this, TextRenderingMode.ClearType);

            TryLoadWindowIcon();

            Border rootCard = (Border)XamlReader.Parse(WindowContentXaml);
            Content = rootCard;

            Border brandHost = (Border)rootCard.FindName("BrandLogoHost");
            Image brandImage = (Image)rootCard.FindName("BrandLogoImage");
            _statusText = (TextBlock)rootCard.FindName("StatusText");
            _percentPill = (Border)rootCard.FindName("PercentPill");
            _percentText = (TextBlock)rootCard.FindName("PercentText");
            _progressTrack = (Border)rootCard.FindName("ProgressTrack");
            _progressFill = (Border)rootCard.FindName("ProgressFill");
            _errorBanner = (Border)rootCard.FindName("ErrorBanner");
            _errorText = (TextBlock)rootCard.FindName("ErrorText");
            _retryButton = (Button)rootCard.FindName("RetryButton");
            _cancelButton = (Button)rootCard.FindName("CancelButton");

            if (!TryLoadEmbeddedBrandLogo(brandImage) && brandHost != null)
            {
                brandHost.Visibility = Visibility.Collapsed;
            }

            _progressTrack.SizeChanged += delegate { RefreshProgressBarWidth(); };

            _retryButton.Click += delegate
            {
                if (_waitingForRetry && !_cancelled)
                {
                    _waitingForRetry = false;
                    _errorBanner.Visibility = Visibility.Collapsed;
                    _retryButton.Visibility = Visibility.Collapsed;
                    _cancelButton.Content = "Hủy";
                    ApplyProgressVisual("Đang thử kết nối lại máy chủ GitHub...", 8, false);
                    _retrySignal.Set();
                }
            };

            _cancelButton.Click += delegate
            {
                _cancelled = true;
                _cancelButton.IsEnabled = false;
                _retryButton.IsEnabled = false;
                _statusText.Text = "Đang đóng...";
                _retrySignal.Set();
                if (_waitingForRetry)
                {
                    Close();
                }
            };

            ContentRendered += delegate
            {
                RefreshProgressBarWidth();
                if (!string.IsNullOrWhiteSpace(_options.RenderPreviewFile))
                {
                    RunPreviewCapture(_options.RenderPreviewFile);
                }
                else
                {
                    StartWorker();
                }
            };

            Closing += delegate
            {
                if (!_finished && !_cancelled)
                {
                    _cancelled = true;
                    _retrySignal.Set();
                }
            };
        }

        private void TryLoadWindowIcon()
        {
            try
            {
                string selfExe = Assembly.GetExecutingAssembly().Location;
                if (!string.IsNullOrEmpty(selfExe) && File.Exists(selfExe))
                {
                    Icon = ImagingCreateIconFromExe(selfExe);
                }
            }
            catch
            {
            }
        }

        private static ImageSource ImagingCreateIconFromExe(string exePath)
        {
            Uri uri = new Uri(exePath, UriKind.Absolute);
            IconBitmapDecoder decoder = new IconBitmapDecoder(
                uri,
                BitmapCreateOptions.PreservePixelFormat,
                BitmapCacheOption.OnLoad);
            if (decoder.Frames != null && decoder.Frames.Count > 0)
            {
                return decoder.Frames[0];
            }
            return null;
        }

        private static bool TryLoadEmbeddedBrandLogo(Image target)
        {
            if (target == null)
            {
                return false;
            }
            try
            {
                using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("EmTroLyLogo.png"))
                {
                    if (s == null)
                    {
                        return false;
                    }
                    MemoryStream ms = new MemoryStream();
                    s.CopyTo(ms);
                    ms.Position = 0;
                    BitmapImage bmp = new BitmapImage();
                    bmp.BeginInit();
                    bmp.CacheOption = BitmapCacheOption.OnLoad;
                    bmp.StreamSource = ms;
                    bmp.EndInit();
                    bmp.Freeze();
                    ms.Dispose();
                    target.Source = bmp;
                    return true;
                }
            }
            catch
            {
                return false;
            }
        }

        private static SolidColorBrush BrushFromHex(string hex)
        {
            SolidColorBrush b = (SolidColorBrush)new BrushConverter().ConvertFromString(hex);
            if (b != null && b.CanFreeze)
            {
                b.Freeze();
            }
            return b;
        }

        private void RefreshProgressBarWidth()
        {
            double trackW = _progressTrack.ActualWidth;
            if (trackW <= 0)
            {
                return;
            }
            int clamped = Math.Max(0, Math.Min(100, _currentPercent));
            if (clamped <= 0)
            {
                _progressFill.Width = 0;
            }
            else
            {
                _progressFill.Width = Math.Max(12.0, (trackW * clamped) / 100.0);
            }
        }

        private void ApplyProgressVisual(string message, int percent, bool isSuccess)
        {
            _currentPercent = Math.Max(0, Math.Min(100, percent));
            _statusText.Text = message;
            _percentText.Text = _currentPercent.ToString() + "%";

            if (isSuccess || _currentPercent >= 100)
            {
                _progressFill.Background = BrushFromHex("#10B981");
                _percentPill.Background = BrushFromHex("#ECFDF5");
                _percentPill.BorderBrush = BrushFromHex("#A7F3D0");
                _percentText.Foreground = BrushFromHex("#065F46");
            }
            else
            {
                _progressFill.Background = BrushFromHex("#2563EB");
                _percentPill.Background = BrushFromHex("#EFF6FF");
                _percentPill.BorderBrush = BrushFromHex("#BFDBFE");
                _percentText.Foreground = BrushFromHex("#1D4ED8");
            }
            RefreshProgressBarWidth();
        }

        private void RunPreviewCapture(string outputPath)
        {
            ApplyProgressVisual("Đang tải bộ cài Em Trợ Lý v2026.11.24.5 (1.5 / 2.2 MB)...", 68, false);
            DispatcherTimer timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(220) };
            timer.Tick += delegate
            {
                timer.Stop();
                try
                {
                    UpdateLayout();
                    FrameworkElement root = (FrameworkElement)Content;
                    DpiScale dpi = VisualTreeHelper.GetDpi(this);
                    int pxW = Math.Max(1, (int)Math.Round((root.ActualWidth + 32) * dpi.DpiScaleX));
                    int pxH = Math.Max(1, (int)Math.Round((root.ActualHeight + 32) * dpi.DpiScaleY));

                    DrawingVisual dv = new DrawingVisual();
                    using (DrawingContext dc = dv.RenderOpen())
                    {
                        dc.DrawRectangle(Background, null, new Rect(0, 0, root.ActualWidth + 32, root.ActualHeight + 32));
                        VisualBrush vb = new VisualBrush(root) { Stretch = Stretch.None };
                        dc.DrawRectangle(vb, null, new Rect(16, 16, root.ActualWidth, root.ActualHeight));
                    }
                    RenderTargetBitmap rtb = new RenderTargetBitmap(pxW, pxH, dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
                    rtb.Render(dv);

                    string fullOut = Path.GetFullPath(outputPath);
                    string dir = Path.GetDirectoryName(fullOut);
                    if (!string.IsNullOrEmpty(dir))
                    {
                        Directory.CreateDirectory(dir);
                    }
                    PngBitmapEncoder encoder = new PngBitmapEncoder();
                    encoder.Frames.Add(BitmapFrame.Create(rtb));
                    using (FileStream fs = new FileStream(fullOut, FileMode.Create, FileAccess.Write))
                    {
                        encoder.Save(fs);
                    }
                    ExitCode = 0;
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine(ex.Message);
                    ExitCode = 1;
                }
                _finished = true;
                Close();
            };
            timer.Start();
        }

        private void StartWorker()
        {
            Thread worker = new Thread(RunDownloadLoop)
            {
                IsBackground = true,
                Name = "EmTroLyBootstrapWorker"
            };
            worker.Start();
        }

        private void RunDownloadLoop()
        {
            while (!_cancelled)
            {
                try
                {
                    string targetExe = Program.DownloadAndVerifyInstaller(
                        _options,
                        UpdateProgressSafe,
                        delegate { return _cancelled; });

                    Thread.Sleep(280);

                    if (!_options.DownloadOnly)
                    {
                        Program.LaunchInstaller(targetExe);
                    }

                    ExitCode = 0;
                    _finished = true;
                    Dispatcher.BeginInvoke((Action)delegate { Close(); });
                    return;
                }
                catch (OperationCanceledException)
                {
                    ExitCode = 1;
                    _finished = true;
                    Dispatcher.BeginInvoke((Action)delegate { Close(); });
                    return;
                }
                catch (Exception ex)
                {
                    if (_cancelled)
                    {
                        ExitCode = 1;
                        _finished = true;
                        Dispatcher.BeginInvoke((Action)delegate { Close(); });
                        return;
                    }

                    string friendly = Program.FormatFriendlyErrorMessage(ex);
                    _retrySignal.Reset();
                    _waitingForRetry = true;

                    Dispatcher.Invoke((Action)delegate
                    {
                        _statusText.Text = "Chưa tải được bộ cài tự động";
                        _progressFill.Background = BrushFromHex("#EF4444");
                        _percentPill.Background = BrushFromHex("#FEF2F2");
                        _percentPill.BorderBrush = BrushFromHex("#FECACA");
                        _percentText.Foreground = BrushFromHex("#B91C1C");
                        _percentText.Text = "Tạm dừng";
                        _errorText.Text = friendly;
                        _errorBanner.Visibility = Visibility.Visible;
                        _retryButton.Visibility = Visibility.Visible;
                        _retryButton.IsEnabled = true;
                        _cancelButton.Content = "Đóng";
                        _cancelButton.IsEnabled = true;
                    });

                    _retrySignal.WaitOne();
                    _waitingForRetry = false;
                    if (_cancelled)
                    {
                        ExitCode = 1;
                        _finished = true;
                        Dispatcher.BeginInvoke((Action)delegate { Close(); });
                        return;
                    }
                }
            }
        }

        private void UpdateProgressSafe(string text, int percent)
        {
            try
            {
                Dispatcher.BeginInvoke((Action)delegate
                {
                    if (!_finished)
                    {
                        ApplyProgressVisual(text, percent, percent >= 100);
                    }
                });
            }
            catch
            {
            }
        }
    }
}
