import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class WindowsInstallerTests(unittest.TestCase):
    def test_release_requires_defender_scan_before_artifact_and_publication(self):
        workflow = (ROOT / ".github/workflows/release-windows.yml").read_text(encoding="utf-8")
        scanner = (ROOT / "windows-installer/scan-release.ps1").read_text(encoding="utf-8")
        scan = workflow.index("./windows-installer/scan-release.ps1")
        self.assertLess(workflow.index("./build-windows-installer.sh caidattroly.exe"), scan)
        self.assertLess(scan, workflow.index("- name: Upload workflow artifacts"))
        self.assertLess(scan, workflow.index("- name: Publish GitHub Release"))
        for required in ("Get-MpComputerStatus", "Update-MpSignature", "Get-MpPreference", "ExclusionPath", "ExclusionExtension", "ExclusionProcess", "-ScanType 3", "Get-MpThreatDetection", "Get-FileHash"):
            self.assertIn(required, scanner)

    def test_wizard_uses_fixed_internal_name_and_windows_user_openclaw_directory(self):
        wizard = (ROOT / "windows-installer/wizard.ps1").read_text(encoding="utf-8")
        runner = (ROOT / "windows-installer/run-native-install.ps1").read_text(encoding="utf-8")
        installer = (ROOT / "install-native-windows.ps1").read_text(encoding="utf-8")
        self.assertNotIn("$nameBox", wizard)
        self.assertIn("member = 'emtroly'", wizard)
        self.assertIn("Join-Path $env:USERPROFILE 'openclaw'", runner)
        self.assertIn("InstallRoot = $root", runner)
        self.assertIn("Invalid install root; no files were changed.", installer)
        self.assertIn("$fullAccessCheck.Checked = $false", wizard)

    def test_payload_contains_gui_and_safe_runner(self):
        nsi = (ROOT / "windows-installer/member-vps-installer.nsi").read_text(encoding="utf-8")
        wizard = (ROOT / "windows-installer/wizard.ps1").read_text(encoding="utf-8")
        runner = (ROOT / "windows-installer/run-native-install.ps1").read_text(encoding="utf-8")
        installer = (ROOT / "install-native-windows.ps1").read_text(encoding="utf-8")
        cli_helper = (ROOT / "native/skills/tao-tro-ly-openclaw-windows-macos-linux/scripts/install_windows_cli.py").read_text(encoding="utf-8")
        dependencies = (ROOT / "native/user-dependencies.ps1").read_text(encoding="utf-8")
        gateway = (ROOT / "native/user-gateway.ps1").read_text(encoding="utf-8")
        gateway_node = (ROOT / "native/user-gateway.cjs").read_text(encoding="utf-8")
        qr_plugin = (ROOT / "native/skills/telegram-zalo-owner-login/assets/index.mjs").read_text(encoding="utf-8")
        qr_helper = (ROOT / "native/skills/openclaw-zalo-qr-login/scripts/send_zalo_qr_to_telegram_owner.mjs").read_text(encoding="utf-8")
        self.assertIn("wizard.ps1", nsi)
        self.assertIn('Name "installer_emtroly"', nsi)
        self.assertIn("Em Trợ Lý - Cài đặt", wizard)
        self.assertIn("UseSystemPasswordChar", wizard)
        self.assertIn("accept_full_access", wizard)
        self.assertIn("$fullAccessCheck.Checked = $false", wizard)
        self.assertIn("$zaloCheck.Checked = $true", wizard)
        self.assertIn("$zaloCheck.Enabled = $false", wizard)
        self.assertIn("$qrOwnerBox.Text = (($ownersBox.Text -split ',')[0]).Trim()", wizard)
        self.assertIn("/models", runner)
        self.assertIn("api.telegram.org/bot", runner)
        self.assertIn("Remove-Item -LiteralPath $SettingsFile", runner)
        self.assertIn("2026.11.4", runner)
        self.assertIn("approvals get --json", runner)
        self.assertIn("unsupported-architecture", runner)
        self.assertIn("zalo-qr-plugin-not-loaded", runner)
        self.assertIn("'zalostatus'", runner)
        self.assertIn("setMyCommands", runner)
        self.assertIn("telegram-command-menu-not-registered", runner)
        self.assertIn("install_windows_cli.py", installer)
        self.assertIn("Install-UserOpenClawCli", installer)
        self.assertIn('"OpenClaw" / "bin"', cli_helper)
        self.assertIn("WindowStyle Hidden", wizard)
        self.assertIn("WindowStyle Hidden", nsi)
        self.assertNotIn("Start-Process -FilePath $shellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait", wizard)
        self.assertIn("-WindowStyle Hidden", gateway)
        self.assertIn("windowsHide: true", gateway_node)
        self.assertIn("windowsHide: true", qr_plugin)
        self.assertIn("windowsHide: true", qr_helper)
        self.assertIn("-WindowStyle Hidden", installer)
        self.assertIn("-WindowStyle Hidden", dependencies)

    def test_fresh_shell_probe_is_packaged_and_uses_windows_powershell(self):
        runner = (ROOT / "windows-installer/run-native-install.ps1").read_text(encoding="utf-8")
        probe = (ROOT / "windows-installer/verify-openclaw-command.ps1").read_text(encoding="utf-8")
        build = (ROOT / "build-windows-installer.sh").read_text(encoding="utf-8")
        self.assertIn("System32\\WindowsPowerShell\\v1.0\\powershell.exe", runner)
        self.assertIn("verify-openclaw-command.ps1", build)
        self.assertIn("GetEnvironmentVariable('Path', 'Machine')", probe)
        self.assertIn("GetEnvironmentVariable('Path', 'User')", probe)
        self.assertIn("OPENCLAW_STATE_DIR", probe)
        self.assertIn("$command.Source status", probe)

    def test_installer_assigns_all_entered_owner_ids_to_full_exec_policy(self):
        installer = (ROOT / "install-native-windows.ps1").read_text(encoding="utf-8")
        self.assertIn("foreach ($owner in $owners)", installer)
        self.assertIn("commands['ownerAllowFrom']", (ROOT / "native/finalize_permissions.py").read_text(encoding="utf-8"))
        self.assertIn("security='full'", installer)
        self.assertIn("ask='off'", installer)
        self.assertIn("gateway install --force", installer)
        self.assertIn("native=$true; nativeSkills=$false", installer)

    def test_installer_configures_owner_before_gateway_start(self):
        installer = (ROOT / "install-native-windows.ps1").read_text(encoding="utf-8")
        body = installer.split("$ErrorActionPreference = 'Stop'", 1)[1]
        self.assertNotRegex(body, r"(?i)\$Model\s*=(?!=)")
        self.assertLess(installer.index("ensure_default_telegram_owner.py"), installer.index("gateway restart"))
        self.assertLess(installer.index("approvals set --stdin"), installer.index("gateway restart"))
        self.assertLess(installer.index("skills check"), installer.index("gateway restart"))

    def test_requested_skills_are_in_windows_catalog(self):
        catalog = json.loads((ROOT / "native/module-skills.json").read_text(encoding="utf-8"))
        self.assertIn("openclaw-zalo-reply-mention", catalog["zalo-personal"])
        self.assertIn("openclaw-telegram-zalo-qr-delivery", catalog["zalo-personal"])
        self.assertIn("cap-full-quyen-telegram-openclaw", catalog["telegram-basic"])

    def test_zalo_onboarding_installs_verified_native_integrations(self):
        onboarding = (ROOT / "zalo/onboard-zalouser-windows.ps1").read_text(encoding="utf-8")
        mention = (ROOT / "zalo/install-windows-reply-mention.py").read_text(encoding="utf-8")
        self.assertIn("install-windows-reply-mention.py", onboarding)
        self.assertIn("deploy-native.py", onboarding)
        self.assertIn("2026.11.4", mention)
        self.assertIn("--private-access", onboarding)
        self.assertIn("function Stop-SelectedGateway", onboarding)
        self.assertIn("windows-plugin.ps1", onboarding)
        self.assertIn("$pluginInfo.plugin.enabled -ne $true", onboarding)
        self.assertIn("Invoke-ZaloPluginCli", onboarding)
        self.assertIn("Saved gateway PID does not belong to this OpenClaw instance.", onboarding)
        self.assertIn("owner can request /zaloqr", onboarding)
        self.assertNotIn("send_zalo_qr_to_telegram_owner.mjs --target", onboarding)
        self.assertIn("zalostatus", (ROOT / "native/skills/telegram-zalo-owner-login/assets/index.mjs").read_text(encoding="utf-8"))

    def test_no_placeholder_credentials_are_packaged(self):
        for path in [
            ROOT / "windows-installer/member-vps-installer.nsi",
            ROOT / "windows-installer/wizard.ps1",
            ROOT / "windows-installer/run-native-install.ps1",
            ROOT / "windows-installer/validation.ps1",
        ]:
            text = path.read_text(encoding="utf-8", errors="ignore")
            self.assertNotIn("ENTER_PRIVATELY", text)
            self.assertNotIn("sk-test-DO-NOT-LEAK", text)


if __name__ == "__main__":
    unittest.main()
