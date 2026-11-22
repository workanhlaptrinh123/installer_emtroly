using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Anh Lập Trình - Em Trợ Lý")]
[assembly: AssemblyDescription("Anh Lập Trình - Em Trợ Lý")]
[assembly: AssemblyCompany("Anh Lập Trình")]
[assembly: AssemblyProduct("Anh Lập Trình - Em Trợ Lý")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

public static class Program {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDPIAware();

    private static void EnablePerMonitorHiDpi() {
        try {
            // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
            if (SetProcessDpiAwarenessContext(new IntPtr(-4))) {
                return;
            }
        } catch { }
        try { SetProcessDPIAware(); } catch { }
    }

    [STAThread]
    public static int Main(string[] args) {
        EnablePerMonitorHiDpi();
        try { SetCurrentProcessExplicitAppUserModelID("AnhLapTrinh.EmTroLy.App"); } catch { }
        Application.EnableVisualStyles();

        string baseDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\', '/');
        string root = baseDir;
        string wizard = Path.Combine(baseDir, "windows-installer", "wizard.ps1");
        if (!File.Exists(wizard)) {
            string localWizard = Path.Combine(baseDir, "wizard.ps1");
            DirectoryInfo parent = Directory.GetParent(baseDir);
            if (File.Exists(localWizard) && parent != null) {
                wizard = localWizard;
                root = parent.FullName;
            }
        }

        bool codexMode = false;
        bool smokeTest = false;
        for (int i = 0; i < args.Length; i++) {
            if (string.Equals(args[i], "-PayloadRoot", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length) {
                root = args[++i];
                wizard = Path.Combine(root, "windows-installer", "wizard.ps1");
            } else if (string.Equals(args[i], "-CodexMode", StringComparison.OrdinalIgnoreCase)) {
                codexMode = true;
            } else if (string.Equals(args[i], "-SmokeTest", StringComparison.OrdinalIgnoreCase)) {
                smokeTest = true;
            }
        }

        if (!File.Exists(wizard)) {
            MessageBox.Show("Không tìm thấy tệp giao diện:\n" + wizard, "Anh Lập Trình - Em Trợ Lý", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }

        try {
            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ApartmentState = System.Threading.ApartmentState.STA;
            iss.ThreadOptions = PSThreadOptions.UseCurrentThread;
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss)) {
                rs.ApartmentState = System.Threading.ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create()) {
                    ps.Runspace = rs;
                    string scriptText = File.ReadAllText(wizard, Encoding.UTF8);
                    if (scriptText.IndexOf("LicenseGateOverlay", StringComparison.Ordinal) < 0 ||
                        scriptText.IndexOf("Test-EmTroLyLicenseKey", StringComparison.Ordinal) < 0) {
                        MessageBox.Show("Tệp giao diện thiếu thành phần xác thực bản quyền chính thức của Anh Lập Trình.", "Anh Lập Trình - Em Trợ Lý", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return 1;
                    }
                    Environment.SetEnvironmentVariable("EMTROLY_HOST_VERIFIED", "1");
                    ps.AddScript(scriptText).AddParameter("PayloadRoot", root);
                    if (codexMode) {
                        ps.AddParameter("CodexMode", true);
                    }
                    if (smokeTest) {
                        ps.AddParameter("SmokeTest", true);
                    }
                    ps.Invoke();
                    if (ps.HadErrors && ps.Streams.Error.Count > 0) {
                        var sb = new StringBuilder();
                        foreach (var err in ps.Streams.Error) {
                            sb.AppendLine(err.ToString());
                        }
                        MessageBox.Show("Không thể mở giao diện:\n\n" + sb.ToString(), "Anh Lập Trình - Em Trợ Lý", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return 1;
                    }
                }
                object rcObj = rs.SessionStateProxy.PSVariable.GetValue("resultCode");
                int rc;
                if (rcObj != null && int.TryParse(rcObj.ToString(), out rc)) {
                    return rc;
                }
            }
            return 0;
        } catch (Exception ex) {
            MessageBox.Show("Lỗi khởi động giao diện:\n\n" + ex.Message, "Anh Lập Trình - Em Trợ Lý", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
