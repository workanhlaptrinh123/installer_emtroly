using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Anh Lap Trinh - Em Tro Ly Setup")]
[assembly: AssemblyDescription("Official SmartScreen-Safe Online Setup Launcher for Anh Lap Trinh - Em Tro Ly")]
[assembly: AssemblyConfiguration("")]
[assembly: AssemblyCompany("Anh Lap Trinh")]
[assembly: AssemblyProduct("Anh Lap Trinh - Em Tro Ly")]
[assembly: AssemblyCopyright("Copyright (c) Anh Lap Trinh")]
[assembly: AssemblyTrademark("")]
[assembly: AssemblyCulture("")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace AnhLapTrinh.EmTroLy.Setup
{
    internal sealed class BootstrapOptions
    {
        public bool DownloadOnly;
        public bool Quiet;
        public string OutFile = string.Empty;
        public string VersionTag = string.Empty;
        public int TestLoopbackPort;
    }

    internal static class Program
    {
        private const string OfficialReleaseRoot = "https://github.com/workanhlaptrinh123/installer_emtroly/releases";
        private const string UserAgentValue = "AnhLapTrinh-EmTroLy-Setup/1.0";

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
                        "Em Trợ Lý - Anh Lập Trình",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error);
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

            bool createdNew = false;
            using (Mutex singleMutex = new Mutex(true, @"Local\EmTroLy-Bootstrap-Setup-SingleInstance", out createdNew))
            {
                if (!createdNew)
                {
                    return 0;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using (SetupForm form = new SetupForm(options))
                {
                    Application.Run(form);
                    return form.ExitCode;
                }
            }
        }

        internal static void ConfigureTls()
        {
            try
            {
                // Enable TLS 1.2 (3072) + TLS 1.3 (12288) when supported by OS
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

        internal static string DownloadAndVerifyInstaller(
            BootstrapOptions options,
            Action<string, int> reportProgress,
            Func<bool> isCancelled)
        {
            string baseUrl = BuildDownloadBaseUrl(options);
            if (reportProgress != null)
            {
                reportProgress("Đang kiểm tra phiên bản bộ cài mới nhất trên GitHub...", 5);
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
                    if (reportProgress != null)
                    {
                        reportProgress("Đã xác minh bộ cài mới nhất sẵn sàng, đang khởi động...", 100);
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
                            if (reportProgress != null && (now - lastTick >= 120 || readTotal == totalBytes))
                            {
                                lastTick = now;
                                string verTag = !string.IsNullOrEmpty(versionLabel) ? (" v" + versionLabel) : string.Empty;
                                if (totalBytes > 0)
                                {
                                    int pct = (int)Math.Min(95L, Math.Max(8L, (readTotal * 95L) / totalBytes));
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
                    reportProgress("Đang đối chiếu mã toàn vẹn SHA-256...", 98);
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
                    reportProgress("Đã tải xong và xác minh an toàn! Đang mở giao diện cài đặt...", 100);
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
                foreach (string f in Directory.GetFiles(workDir, "emtroly-*.exe"))
                {
                    if (!string.Equals(Path.GetFullPath(f), Path.GetFullPath(keepExe), StringComparison.OrdinalIgnoreCase))
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

    internal sealed class SetupForm : Form
    {
        private readonly BootstrapOptions _options;
        private readonly Label _titleLabel;
        private readonly Label _statusLabel;
        private readonly ProgressBar _progressBar;
        private readonly Button _cancelButton;
        private volatile bool _cancelled;
        private volatile bool _finished;
        public int ExitCode = 1;

        public SetupForm(BootstrapOptions options)
        {
            _options = options;
            Text = "Em Trợ Lý - Anh Lập Trình";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            ClientSize = new Size(460, 165);
            BackColor = Color.FromArgb(248, 250, 252);
            Font = new Font("Segoe UI", 9.5F, FontStyle.Regular, GraphicsUnit.Point);

            try
            {
                Icon selfIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                if (selfIcon != null)
                {
                    Icon = selfIcon;
                }
            }
            catch
            {
            }

            _titleLabel = new Label
            {
                Text = "Em Trợ Lý — Anh Lập Trình",
                Font = new Font("Segoe UI", 12F, FontStyle.Bold, GraphicsUnit.Point),
                ForeColor = Color.FromArgb(15, 23, 42),
                Location = new Point(22, 18),
                Size = new Size(416, 26),
                AutoEllipsis = true
            };

            _statusLabel = new Label
            {
                Text = "Đang kết nối máy chủ phát hành chính thức...",
                ForeColor = Color.FromArgb(71, 85, 105),
                Location = new Point(22, 50),
                Size = new Size(416, 22),
                AutoEllipsis = true
            };

            _progressBar = new ProgressBar
            {
                Location = new Point(22, 80),
                Size = new Size(416, 22),
                Minimum = 0,
                Maximum = 100,
                Value = 4,
                Style = ProgressBarStyle.Continuous
            };

            _cancelButton = new Button
            {
                Text = "Hủy",
                Location = new Point(348, 118),
                Size = new Size(90, 30),
                FlatStyle = FlatStyle.System
            };
            _cancelButton.Click += delegate
            {
                _cancelled = true;
                _cancelButton.Enabled = false;
                _statusLabel.Text = "Đang hủy...";
            };

            Controls.Add(_titleLabel);
            Controls.Add(_statusLabel);
            Controls.Add(_progressBar);
            Controls.Add(_cancelButton);

            Shown += delegate { StartWorker(); };
            FormClosing += delegate(object sender, FormClosingEventArgs e)
            {
                if (!_finished && !_cancelled)
                {
                    _cancelled = true;
                }
            };
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

                    if (!_options.DownloadOnly)
                    {
                        Program.LaunchInstaller(targetExe);
                    }

                    ExitCode = 0;
                    _finished = true;
                    BeginInvoke((MethodInvoker)delegate { Close(); });
                    return;
                }
                catch (OperationCanceledException)
                {
                    ExitCode = 1;
                    _finished = true;
                    BeginInvoke((MethodInvoker)delegate { Close(); });
                    return;
                }
                catch (Exception ex)
                {
                    if (_cancelled)
                    {
                        ExitCode = 1;
                        _finished = true;
                        BeginInvoke((MethodInvoker)delegate { Close(); });
                        return;
                    }

                    DialogResult choice = DialogResult.Cancel;
                    Invoke((MethodInvoker)delegate
                    {
                        choice = MessageBox.Show(
                            this,
                            "Không tải được bộ cài mới nhất:\r\n" + ex.Message + "\r\n\r\nBạn hãy kiểm tra kết nối mạng rồi bấm Thử lại.",
                            "Em Trợ Lý - Anh Lập Trình",
                            MessageBoxButtons.RetryCancel,
                            MessageBoxIcon.Warning);
                        if (choice == DialogResult.Retry)
                        {
                            _statusLabel.Text = "Đang thử kết nối lại...";
                            _progressBar.Value = 5;
                        }
                    });

                    if (choice != DialogResult.Retry)
                    {
                        ExitCode = 1;
                        _finished = true;
                        BeginInvoke((MethodInvoker)delegate { Close(); });
                        return;
                    }
                }
            }
        }

        private void UpdateProgressSafe(string text, int percent)
        {
            if (IsDisposed || !IsHandleCreated)
            {
                return;
            }
            try
            {
                BeginInvoke((MethodInvoker)delegate
                {
                    if (!IsDisposed)
                    {
                        _statusLabel.Text = text;
                        int clamped = Math.Max(0, Math.Min(100, percent));
                        _progressBar.Value = clamped;
                    }
                });
            }
            catch
            {
            }
        }
    }
}
