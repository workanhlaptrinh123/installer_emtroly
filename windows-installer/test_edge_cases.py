"""Comprehensive Unit Tests, Edge-Case Integration Tests, and Static Integrity Checks
for Anh Lap Trinh - Em Tro Ly (Windows & Unix installers).
"""

from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.error


ROOT = Path(__file__).resolve().parents[1]
WIN_POWERSHELL = (
    Path(os.environ.get("SystemRoot", r"C:\Windows"))
    / "System32/WindowsPowerShell/v1.0/powershell.exe"
)
SHELL = str(WIN_POWERSHELL) if WIN_POWERSHELL.is_file() else (os.environ.get("PWSH") or shutil.which("pwsh"))
NODE = shutil.which("node")
WSCRIPT = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/wscript.exe"

TEXT_KWARGS = {"text": True, "encoding": "utf-8", "errors": "replace"}


def stage_minimal_manage_payload(parent: Path) -> Path:
    payload = parent / "minimal_payload"
    wi = payload / "windows-installer"
    wi.mkdir(parents=True, exist_ok=True)
    for name in ("validation.ps1", "codex-cli.ps1", "auto-heal-codex.ps1", "wizard-helpers.ps1"):
        shutil.copy2(ROOT / "windows-installer" / name, wi / name)
    return payload


def run_ps(script_text: str, *, env: dict[str, str] | None = None, sta: bool = False, timeout: int = 35) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="emtroly-ps-unit-") as td:
        script_path = Path(td) / "run.ps1"
        script_path.write_text(script_text, encoding="utf-8-sig")
        cmd = [SHELL, "-NoLogo", "-NoProfile"]
        if sta:
            cmd.append("-STA")
        if os.name == "nt":
            cmd += ["-ExecutionPolicy", "Bypass"]
        cmd += ["-File", str(script_path)]
        return subprocess.run(cmd, env=env, capture_output=True, timeout=timeout, **TEXT_KWARGS)


# =============================================================================
# 1. PURE UNIT TESTS (Isolated single-function AAA tests, mocked externals)
# =============================================================================


class PureUnitTests(unittest.TestCase):
    def test_app_catalog_and_openclaw_version_comparison_windows_and_unix(self):
        # 1. Verify shared profiles/apps-catalog.json schema
        catalog_path = ROOT / "profiles/apps-catalog.json"
        self.assertTrue(catalog_path.is_file(), "Missing profiles/apps-catalog.json")
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(catalog.get("apps", [])), 3)
        self.assertGreaterEqual(len(catalog.get("combos", [])), 1)

        # 2. Verify Unix version comparison & upgrade detection
        sys.path.insert(0, str(ROOT / "unix-installer"))
        try:
            import runner as unix_runner

            self.assertEqual(unix_runner.compare_versions("2026.10.1", "2026.11.4"), -1)
            self.assertEqual(unix_runner.compare_versions("2026.11.4", "2026.11.4"), 0)
            self.assertEqual(unix_runner.compare_versions("2026.12.0", "2026.11.4"), 1)
            with tempfile.TemporaryDirectory(prefix="emtroly-ver-unix-") as td:
                oc_root = Path(td) / "openclaw"
                pkg = oc_root / "runtime/2026.10.1/node_modules/openclaw/package.json"
                pkg.parent.mkdir(parents=True)
                (oc_root / "openclaw.json").write_text("{}", encoding="utf-8")
                pkg.write_text(json.dumps({"version": "2026.10.1"}), encoding="utf-8")
                info_old = unix_runner.get_openclaw_version_info(oc_root, ROOT)
                self.assertTrue(info_old["installed"])
                self.assertTrue(info_old["needs_upgrade"])
                self.assertFalse(info_old["up_to_date"])
                pkg.write_text(json.dumps({"version": info_old["target_version"]}), encoding="utf-8")
                info_cur = unix_runner.get_openclaw_version_info(oc_root, ROOT)
                self.assertFalse(info_cur["needs_upgrade"])
                self.assertTrue(info_cur["up_to_date"])
        finally:
            sys.path.pop(0)

        # 3. Verify Windows PowerShell version comparison & catalog reader
        if SHELL and os.name == "nt":
            helpers = ROOT / "windows-installer/wizard-helpers.ps1"
            with tempfile.TemporaryDirectory(prefix="emtroly-ver-win-") as td:
                oc_root = Path(td) / "openclaw"
                pkg = oc_root / "runtime/2026.10.1/node_modules/openclaw/package.json"
                pkg.parent.mkdir(parents=True)
                (oc_root / "openclaw.json").write_text("{}", encoding="utf-8")
                pkg.write_text(json.dumps({"version": "2026.10.1"}), encoding="utf-8")
                res = run_ps(
                    f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{helpers}", [Text.Encoding]::UTF8)))\n'
                    "$ErrorActionPreference = 'Stop'\n"
                    "if ((Compare-EmTroLyVersion '2026.10.1' '2026.11.4') -ne -1) { throw 'cmp-lt-failed' }\n"
                    "if ((Compare-EmTroLyVersion '2026.11.4' '2026.11.4') -ne 0) { throw 'cmp-eq-failed' }\n"
                    "if ((Compare-EmTroLyVersion '2026.12.0' '2026.11.4') -ne 1) { throw 'cmp-gt-failed' }\n"
                    f"$v = Get-EmTroLyOpenClawVersionInfo -PayloadRoot '{ROOT}' -OpenClawRoot '{oc_root}'\n"
                    "if (-not $v.Installed -or -not $v.NeedsUpgrade -or $v.IsUpToDate) { throw 'old-ver-not-detected' }\n"
                    f"$cat = Get-EmTroLyAppCatalog -PayloadRoot '{ROOT}'\n"
                    "if (@($cat.Apps).Count -lt 3 -or @($cat.Combos).Count -lt 1) { throw 'catalog-load-failed' }\n"
                    "Write-Output 'CATALOG_AND_VERSION_UNIT_OK'\n"
                )
                self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
                self.assertIn("CATALOG_AND_VERSION_UNIT_OK", res.stdout)

    def test_unix_license_gate_pure_unit_tests(self):
        sys.path.insert(0, str(ROOT / "unix-installer"))
        try:
            import license_gate

            # Seal & unseal bound to machine ID
            sealed = license_gate.seal_machine_activation("sk-unix-key-abc123", machine_id="machine-A")
            self.assertNotIn("sk-unix-key-abc123", sealed)
            self.assertEqual(license_gate.unseal_machine_activation(sealed, machine_id="machine-A"), "sk-unix-key-abc123")
            self.assertEqual(license_gate.unseal_machine_activation(sealed, machine_id="machine-B"), "")
            self.assertEqual(license_gate.unseal_machine_activation("not-valid-base64!!!", machine_id="machine-A"), "")
            self.assertEqual(license_gate.unseal_machine_activation("", machine_id="machine-A"), "")
            with self.assertRaises(ValueError):
                license_gate.seal_machine_activation("   ", machine_id="machine-A")

            # Disk persistence isolated via XDG_CONFIG_HOME
            with tempfile.TemporaryDirectory(prefix="emtroly-unix-lic-") as td:
                prev_xdg = os.environ.get("XDG_CONFIG_HOME")
                prev_mid = os.environ.get("EMTROLY_TEST_MACHINE_ID")
                try:
                    os.environ["XDG_CONFIG_HOME"] = td
                    os.environ["EMTROLY_TEST_MACHINE_ID"] = "unix-box-1"
                    self.assertEqual(license_gate.get_saved_license_key(), "")
                    saved_path = license_gate.save_license_key("sk-unix-persisted-999")
                    self.assertTrue(saved_path.is_file())
                    self.assertEqual(license_gate.get_saved_license_key(), "sk-unix-persisted-999")
                    os.environ["EMTROLY_TEST_MACHINE_ID"] = "unix-box-2"
                    self.assertEqual(license_gate.get_saved_license_key(), "")
                    os.environ["EMTROLY_TEST_MACHINE_ID"] = "unix-box-1"
                    license_gate.clear_saved_license_key()
                    self.assertEqual(license_gate.get_saved_license_key(), "")
                finally:
                    if prev_xdg is None:
                        os.environ.pop("XDG_CONFIG_HOME", None)
                    else:
                        os.environ["XDG_CONFIG_HOME"] = prev_xdg
                    if prev_mid is None:
                        os.environ.pop("EMTROLY_TEST_MACHINE_ID", None)
                    else:
                        os.environ["EMTROLY_TEST_MACHINE_ID"] = prev_mid

            # Mocked verify_license_key across empty / wrong domain / 200 / empty models / 401 / 403 / 500 / network error
            self.assertFalse(license_gate.verify_license_key("")["valid"])
            bad_domain = license_gate.verify_license_key("sk-key", authority_base_url="https://api.openai.com/v1")
            self.assertFalse(bad_domain["valid"])
            self.assertTrue(bad_domain["revoked"])

            class FakeResp:
                def __init__(self, payload: dict):
                    self._raw = json.dumps(payload).encode("utf-8")

                def read(self):
                    return self._raw

                def __enter__(self):
                    return self

                def __exit__(self, *args):
                    return False

            ok = license_gate.verify_license_key(
                "sk-valid",
                opener=lambda req, timeout=15: FakeResp({"data": [{"id": "gpt-6.2-sol"}]}),
            )
            self.assertTrue(ok["valid"])
            self.assertEqual(ok["models"], ["gpt-6.2-sol"])

            no_models = license_gate.verify_license_key(
                "sk-empty-models",
                opener=lambda req, timeout=15: FakeResp({"data": []}),
            )
            self.assertFalse(no_models["valid"])
            self.assertTrue(no_models["revoked"])

            for code, expect_revoked, expect_net in ((401, True, False), (403, True, False), (500, False, True)):
                def _raise_http(req, timeout=15, status=code):
                    raise urllib.error.HTTPError(req.full_url, status, "err", {}, io.BytesIO(b""))

                res = license_gate.verify_license_key("sk-test", opener=_raise_http)
                self.assertFalse(res["valid"])
                self.assertEqual(res["revoked"], expect_revoked)
                self.assertEqual(res["network_error"], expect_net)

            net_err = license_gate.verify_license_key(
                "sk-test",
                opener=lambda req, timeout=15: (_ for _ in ()).throw(OSError("offline")),
            )
            self.assertFalse(net_err["valid"])
            self.assertTrue(net_err["network_error"])
        finally:
            sys.path.pop(0)

    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_validation_boundary_and_exception_inputs(self):
        val_path = ROOT / "windows-installer/validation.ps1"
        res = run_ps(
            f'. "{val_path}"\n'
            "$ErrorActionPreference = 'Stop'\n"
            "function New-ValidSettings([hashtable]$Over = @{}) {\n"
            "  $h = [ordered]@{\n"
            "    member = 'emtroly'; assistant_name = 'Em Tro Ly'; owner_ids = '123456789';\n"
            "    group_id = '-1001234567890'; telegram_token = '123456:ABCDEFGHIJKLMNOPQRSTUVWXYZ12345';\n"
            "    ai_api_key = 'sk-valid-key'; model = 'gpt-6.2-sol'; base_url = 'https://codex.anhlaptrinh.vn/v1';\n"
            "    gateway_port = '0'; accept_full_access = $true; configure_zalo = $true; qr_owner_id = '123456789'\n"
            "  }\n"
            "  foreach ($k in $Over.Keys) { $h[$k] = $Over[$k] }\n"
            "  return [pscustomobject]$h\n"
            "}\n"
            "# Valid boundary ports, all 3 models, and optional empty group_id\n"
            "foreach ($p in @('0', '1024', '65000')) { Test-MemberInstallerSettings (New-ValidSettings @{ gateway_port = $p }) }\n"
            "foreach ($m in @('gpt-6.2-sol', 'GPT-6.1-terra', 'gpt-6.2-astra')) { Test-MemberInstallerSettings (New-ValidSettings @{ model = $m }) }\n"
            "foreach ($g in @('', '   ', '-1001234567890')) { Test-MemberInstallerSettings (New-ValidSettings @{ group_id = $g }) }\n"
            "# Invalid cases must throw exact error codes\n"
            "$cases = @(\n"
            "  @{ Over = @{ member = 'BadUpper' }; Expect = 'invalid-member' },\n"
            "  @{ Over = @{ assistant_name = '   ' }; Expect = 'missing-assistant-name' },\n"
            "  @{ Over = @{ owner_ids = '0' }; Expect = 'invalid-owners' },\n"
            "  @{ Over = @{ owner_ids = '-12345' }; Expect = 'invalid-owners' },\n"
            "  @{ Over = @{ group_id = '10012345' }; Expect = 'invalid-group' },\n"
            "  @{ Over = @{ group_id = '*' }; Expect = 'invalid-group' },\n"
            "  @{ Over = @{ group_id = '-0' }; Expect = 'invalid-group' },\n"
            "  @{ Over = @{ telegram_token = 'bad-token' }; Expect = 'invalid-telegram-token' },\n"
            "  @{ Over = @{ ai_api_key = '' }; Expect = 'missing-api-key' },\n"
            "  @{ Over = @{ model = 'gpt-4o' }; Expect = 'invalid-model' },\n"
            "  @{ Over = @{ base_url = 'http://codex.anhlaptrinh.vn/v1' }; Expect = 'invalid-base-url' },\n"
            "  @{ Over = @{ base_url = 'https://user:pass@codex.anhlaptrinh.vn/v1' }; Expect = 'invalid-base-url' },\n"
            "  @{ Over = @{ base_url = 'https://codex.anhlaptrinh.vn/v1?x=1' }; Expect = 'invalid-base-url' },\n"
            "  @{ Over = @{ gateway_port = '80' }; Expect = 'invalid-port' },\n"
            "  @{ Over = @{ gateway_port = '1023' }; Expect = 'invalid-port' },\n"
            "  @{ Over = @{ gateway_port = '65001' }; Expect = 'invalid-port' },\n"
            "  @{ Over = @{ accept_full_access = $false }; Expect = 'full-access-consent-required' },\n"
            "  @{ Over = @{ qr_owner_id = '999999999' }; Expect = 'invalid-qr-owner' }\n"
            ")\n"
            "foreach ($c in $cases) {\n"
            "  $got = ''\n"
            "  try { Test-MemberInstallerSettings (New-ValidSettings $c.Over) } catch { $got = [string]$_.Exception.Message }\n"
            "  if ($got -cne $c.Expect) { throw \"Expected $($c.Expect) but got '$got'\" }\n"
            "}\n"
            "Write-Output 'VALIDATION_UNIT_OK'\n"
        )
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("VALIDATION_UNIT_OK", res.stdout)

    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_dpapi_seal_unseal_corrupt_cross_machine_and_no_plaintext_leftover(self):
        helpers = ROOT / "windows-installer/wizard-helpers.ps1"
        with tempfile.TemporaryDirectory(prefix="emtroly-dpapi-unit-") as td:
            home = Path(td) / "home"
            local = Path(td) / "local"
            home.mkdir()
            local.mkdir()
            env = {**os.environ, "USERPROFILE": str(home), "LOCALAPPDATA": str(local)}
            res = run_ps(
                f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{helpers}", [Text.Encoding]::UTF8)))\n'
                "$ErrorActionPreference = 'Stop'\n"
                "# Seed legacy plaintext license.key first\n"
                "$legacyDir = Join-Path $env:LOCALAPPDATA 'EmTroLyUI'\n"
                "[void][IO.Directory]::CreateDirectory($legacyDir)\n"
                "$legacyFile = Join-Path $legacyDir 'license.key'\n"
                "[IO.File]::WriteAllText($legacyFile, 'sk-legacy-plaintext-key-12345')\n"
                "# Save-EmTroLyLicenseKey seals into DPAPI activation.dat and removes plaintext license.key\n"
                "Save-EmTroLyLicenseKey -ApiKey 'sk-dpapi-secret-key-98765'\n"
                "if (Test-Path -LiteralPath $legacyFile) { throw 'plaintext-license-key-not-removed' }\n"
                "$actPath = Get-EmTroLyActivationFilePath\n"
                "if (-not (Test-Path -LiteralPath $actPath -PathType Leaf)) { throw 'activation-dat-missing' }\n"
                "$cipherRaw = [IO.File]::ReadAllText($actPath)\n"
                "if ($cipherRaw -match 'sk-dpapi-secret-key') { throw 'activation-dat-not-encrypted' }\n"
                "if ((Get-EmTroLySavedLicenseKey) -cne 'sk-dpapi-secret-key-98765') { throw 'dpapi-roundtrip-failed' }\n"
                "# Different machine binding ID must fail to decrypt\n"
                "$env:EMTROLY_TEST_MACHINE_ID = 'OTHER-MACHINE-GUID'\n"
                "if ((Get-EmTroLySavedLicenseKey) -ne '') { throw 'other-machine-decrypted-activation' }\n"
                "Remove-Item Env:EMTROLY_TEST_MACHINE_ID\n"
                "# Corrupted activation.dat returns empty string safely without throwing\n"
                "[IO.File]::WriteAllText($actPath, '!!!CORRUPT_BASE64!!!')\n"
                "if ((Get-EmTroLySavedLicenseKey) -ne '') { throw 'corrupt-activation-not-rejected' }\n"
                "Write-Output 'DPAPI_UNIT_OK'\n",
                env=env,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertIn("DPAPI_UNIT_OK", res.stdout)

    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_download_retry_transient_failure_and_checksum_fail_closed(self):
        editor_ps1 = ROOT / "windows-installer/install-antigravity-codex.ps1"
        deps_ps1 = ROOT / "native/user-dependencies.ps1"
        with tempfile.TemporaryDirectory(prefix="emtroly-dl-unit-") as td:
            src = Path(td) / "good.bin"
            src.write_bytes(b"verified-installer-bytes")
            good_hash = hashlib.sha256(b"verified-installer-bytes").hexdigest()
            out1 = Path(td) / "out-editor.bin"
            out2 = Path(td) / "out-dep.bin"
            res = run_ps(
                "$ErrorActionPreference = 'Stop'\n"
                f"$tokens = $null; $errs = $null\n"
                f"$ast = [Management.Automation.Language.Parser]::ParseFile('{editor_ps1}', [ref]$tokens, [ref]$errs)\n"
                "$fn = @($ast.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-VerifiedDownload' }, $true))[0]\n"
                "Invoke-Expression $fn.Extent.Text\n"
                f". '{deps_ps1}'\n"
                "$script:calls = 0\n"
                "function global:Invoke-WebRequest {\n"
                "  param([switch]$UseBasicParsing, $Uri, $OutFile, $TimeoutSec, $ErrorAction)\n"
                "  $script:calls++\n"
                "  if ($script:calls -lt 3) { throw 'transient-network-drop' }\n"
                f"  Copy-Item -LiteralPath '{src}' -Destination $OutFile -Force\n"
                "}\n"
                f"Get-VerifiedDownload -Url 'https://example.test/a.exe' -Path '{out1}' -Hash '{good_hash}'\n"
                f"if ($script:calls -ne 3 -or -not (Test-Path -LiteralPath '{out1}')) {{ throw 'editor-retry-failed' }}\n"
                "# Bad checksum must fail closed and delete corrupt file\n"
                "$script:calls = 3\n"
                "$errCode = ''\n"
                f"try {{ Get-VerifiedDownload -Url 'https://example.test/a.exe' -Path '{out1}' -Hash ('0'*64) }} catch {{ $errCode = [string]$_.Exception.Message }}\n"
                f"if ($errCode -cne 'editor-download-checksum' -or (Test-Path -LiteralPath '{out1}')) {{ throw 'bad-hash-not-cleaned' }}\n"
                "# FastDependencyDownload retries transient failures too\n"
                "$script:calls = 0\n"
                f"Invoke-FastDependencyDownload -Uri 'https://example.test/b.zip' -OutFile '{out2}' -MaxAttempts 3\n"
                f"if ($script:calls -ne 3 -or -not (Test-Path -LiteralPath '{out2}')) {{ throw 'dep-retry-failed' }}\n"
                "# Verify FFmpeg fast GitHub CDN primary mirror + gyan.dev fallback + status helper exist\n"
                f"$depSrc = [IO.File]::ReadAllText('{deps_ps1}', [Text.Encoding]::UTF8)\n"
                "if ($depSrc -notmatch 'github\\.com/GyanD/codexffmpeg' -or $depSrc -notmatch 'www\\.gyan\\.dev/ffmpeg') { throw 'ffmpeg-dual-mirror-missing' }\n"
                "$stTmp = Join-Path ([IO.Path]::GetTempPath()) ('dep-status-' + [guid]::NewGuid().ToString('N') + '.txt')\n"
                "$env:MEMBER_INSTALL_STATUS_FILE = $stTmp\n"
                "Write-DependencyInstallStatus 'Đang tải FFmpeg... 65% (71.2 / 109.5 MB)'\n"
                "if ([IO.File]::ReadAllText($stTmp, [Text.Encoding]::UTF8) -notmatch '65%') { throw 'dep-status-write-failed' }\n"
                "Remove-Item -LiteralPath $stTmp -Force -ErrorAction SilentlyContinue\n"
                "Remove-Item Env:MEMBER_INSTALL_STATUS_FILE -ErrorAction SilentlyContinue\n"
                "Write-Output 'DOWNLOAD_RETRY_UNIT_OK'\n"
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertIn("DOWNLOAD_RETRY_UNIT_OK", res.stdout)

    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_stale_gateway_pid_record_unit_logic_and_dotnet_port_probe(self):
        gw_ps1 = ROOT / "native/user-gateway.ps1"
        with tempfile.TemporaryDirectory(prefix="emtroly-pid-unit-") as td:
            recent_pid = Path(td) / "recent.pid.json"
            old_pid = Path(td) / "old.pid.json"
            recent_pid.write_text(json.dumps({"pid": None}), encoding="utf-8")
            old_pid.write_text(json.dumps({"pid": None, "startedAt": 1000}), encoding="utf-8")
            res = run_ps(
                f'. "{gw_ps1}"\n'
                "$ErrorActionPreference = 'Stop'\n"
                f"$rRecent = Get-Content -LiteralPath '{recent_pid}' -Raw | ConvertFrom-Json\n"
                f"$rOld = Get-Content -LiteralPath '{old_pid}' -Raw | ConvertFrom-Json\n"
                f"if (Test-StaleGatewayPidRecord -PidPath '{recent_pid}' -Record $rRecent -StaleSeconds 60) {{ throw 'recent-marked-stale' }}\n"
                f"if (-not (Test-StaleGatewayPidRecord -PidPath '{old_pid}' -Record $rOld -StaleSeconds 60)) {{ throw 'old-not-marked-stale' }}\n"
                "# Pure .NET IPGlobalProperties port probe fallback works without CIM/WMI\n"
                "$ports = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Select-Object -ExpandProperty Port)\n"
                "if ($null -eq $ports) { throw 'dotnet-port-probe-null' }\n"
                "Write-Output 'PID_AND_PORT_UNIT_OK'\n"
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertIn("PID_AND_PORT_UNIT_OK", res.stdout)

    def test_setup_draft_encrypted_roundtrip_windows_dpapi_and_unix(self):
        # 1. Unix machine-bound encrypted draft unit test
        sys.path.insert(0, str(ROOT / "unix-installer"))
        try:
            import license_gate

            with tempfile.TemporaryDirectory(prefix="emtroly-unix-draft-") as td:
                prev_xdg = os.environ.get("XDG_CONFIG_HOME")
                prev_mid = os.environ.get("EMTROLY_TEST_MACHINE_ID")
                try:
                    os.environ["XDG_CONFIG_HOME"] = td
                    os.environ["EMTROLY_TEST_MACHINE_ID"] = "unix-draft-box-1"
                    self.assertIsNone(license_gate.get_saved_setup_draft())
                    saved_path = license_gate.save_setup_draft(
                        {
                            "telegram_token": "777888:UNIX_DRAFT_SECRET_TOKEN_1234567890",
                            "ai_api_key": "sk-unix-draft-secret-key-99999",
                            "owner_ids": "111222333",
                            "group_id": "-100999888777",
                            "model": "gpt-6.2-astra",
                            "assistant_name": "Trợ Lý Của Anh",
                            "gateway_port": "19888",
                            "configure_zalo": False,
                            "accept_full_access": True,
                        }
                    )
                    raw_disk = saved_path.read_text(encoding="ascii")
                    self.assertNotIn("UNIX_DRAFT_SECRET_TOKEN", raw_disk)
                    self.assertNotIn("sk-unix-draft-secret-key", raw_disk)
                    loaded = license_gate.get_saved_setup_draft()
                    self.assertIsNotNone(loaded)
                    self.assertEqual(loaded["telegram_token"], "777888:UNIX_DRAFT_SECRET_TOKEN_1234567890")
                    self.assertEqual(loaded["assistant_name"], "Trợ Lý Của Anh")
                    self.assertEqual(loaded["configure_zalo"], False)
                    self.assertEqual(loaded["accept_full_access"], True)
                    # Different machine ID cannot decrypt
                    os.environ["EMTROLY_TEST_MACHINE_ID"] = "unix-draft-box-2"
                    self.assertIsNone(license_gate.get_saved_setup_draft())
                    os.environ["EMTROLY_TEST_MACHINE_ID"] = "unix-draft-box-1"
                    license_gate.clear_saved_setup_draft()
                    self.assertIsNone(license_gate.get_saved_setup_draft())
                finally:
                    if prev_xdg is None:
                        os.environ.pop("XDG_CONFIG_HOME", None)
                    else:
                        os.environ["XDG_CONFIG_HOME"] = prev_xdg
                    if prev_mid is None:
                        os.environ.pop("EMTROLY_TEST_MACHINE_ID", None)
                    else:
                        os.environ["EMTROLY_TEST_MACHINE_ID"] = prev_mid
        finally:
            sys.path.pop(0)

        # 2. Windows DPAPI encrypted draft unit test
        if SHELL and os.name == "nt":
            helpers = ROOT / "windows-installer/wizard-helpers.ps1"
            with tempfile.TemporaryDirectory(prefix="emtroly-win-draft-") as td:
                home = Path(td) / "home"
                local = Path(td) / "local"
                home.mkdir()
                local.mkdir()
                env = {**os.environ, "USERPROFILE": str(home), "LOCALAPPDATA": str(local)}
                res = run_ps(
                    f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{helpers}", [Text.Encoding]::UTF8)))\n'
                    "$ErrorActionPreference = 'Stop'\n"
                    "if ($null -ne (Get-EmTroLySavedSetupDraft)) { throw 'expected-null-before-save' }\n"
                    "$ok = Save-EmTroLySetupDraft -Draft @{\n"
                    "  telegram_token = '123456:DPAPI_DRAFT_TOKEN_SECRET_ABCDEFGHIJ'\n"
                    "  ai_api_key = 'sk-dpapi-draft-secret-key-55555'\n"
                    "  owner_ids = '698000111,698000222'\n"
                    "  group_id = '-1001234567890'\n"
                    "  model = 'gpt-6.2-astra'\n"
                    "  assistant_name = 'Trợ Lý Anh Lập Trình'\n"
                    "  base_url = 'https://codex.anhlaptrinh.vn/v1'\n"
                    "  gateway_port = '19888'\n"
                    "  qr_owner_id = '698000222'\n"
                    "  audience = 'Nhân sự kỹ thuật'\n"
                    "  addressing = 'anh / em'\n"
                    "  style = 'Ngắn gọn, dễ hiểu'\n"
                    "  configure_zalo = $false\n"
                    "  skip_editor = $true\n"
                    "  accept_full_access = $true\n"
                    "}\n"
                    "if (-not $ok) { throw 'save-draft-returned-false' }\n"
                    "$df = Get-EmTroLySetupDraftFilePath\n"
                    "$raw = [IO.File]::ReadAllText($df)\n"
                    "if ($raw -match 'DPAPI_DRAFT_TOKEN' -or $raw -match 'sk-dpapi-draft-secret') { throw 'draft-not-encrypted-on-disk' }\n"
                    "$d = Get-EmTroLySavedSetupDraft\n"
                    "if ($d.telegram_token -cne '123456:DPAPI_DRAFT_TOKEN_SECRET_ABCDEFGHIJ') { throw 'token-mismatch' }\n"
                    "if ($d.assistant_name -cne 'Trợ Lý Anh Lập Trình') { throw 'unicode-assistant-mismatch' }\n"
                    "if ($d.model -cne 'gpt-6.2-astra' -or $d.gateway_port -ne '19888' -or $d.configure_zalo -ne $false -or $d.skip_editor -ne $true -or $d.accept_full_access -ne $true) { throw 'fields-mismatch' }\n"
                    "# Cross-machine isolation\n"
                    "$env:EMTROLY_TEST_MACHINE_ID = 'ANOTHER-PC-GUID'\n"
                    "if ($null -ne (Get-EmTroLySavedSetupDraft)) { throw 'cross-machine-decrypted-draft' }\n"
                    "Remove-Item Env:EMTROLY_TEST_MACHINE_ID\n"
                    "# Corrupt draft file returns null cleanly\n"
                    "[IO.File]::WriteAllText($df, 'BROKEN_BASE64!!!')\n"
                    "if ($null -ne (Get-EmTroLySavedSetupDraft)) { throw 'corrupt-draft-not-null' }\n"
                    "Clear-EmTroLySavedSetupDraft\n"
                    "if (Test-Path -LiteralPath $df) { throw 'clear-draft-did-not-delete' }\n"
                    "Write-Output 'SETUP_DRAFT_UNIT_OK'\n",
                    env=env,
                )
                self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
                self.assertIn("SETUP_DRAFT_UNIT_OK", res.stdout)


# =============================================================================
# 2. EDGE-CASE INTEGRATION & COMPONENT TESTS (Real isolated temp environments)
# =============================================================================


@unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
class EdgeCaseIntegrationTests(unittest.TestCase):
    def test_vietnamese_unicode_paths_in_vbs_and_codex_cmd_shims(self):
        gw_ps1 = ROOT / "native/user-gateway.ps1"
        codex_ps1 = ROOT / "windows-installer/codex-cli.ps1"
        with tempfile.TemporaryDirectory(prefix="emtroly-vn-") as td:
            base = Path(td) / "Nguyễn Văn Ánh"
            home = base / "profile"
            local = base / "local"
            startup = base / "startup"
            oc_root = home / "openclaw"
            em_codex = local / "EmTroLy/Codex"
            em_ext = local / "EmTroLy/Antigravity/Extensions/openai.chatgpt-26.51111.21308/bin/windows-x86_64"
            for d in (home, local, startup, oc_root, em_codex, em_ext):
                d.mkdir(parents=True, exist_ok=True)
            (oc_root / "installer-instance.json").write_text(
                json.dumps({"root": str(oc_root), "profile": "member-emtroly", "cli_entry": str(oc_root / "cli.mjs"), "port": 19789}),
                encoding="utf-8",
            )
            (em_codex / "config.toml").write_text('model = "gpt-6.2-sol"\n', encoding="utf-8")
            (em_codex / "auth.json").write_text('{"OPENAI_API_KEY":"sk-vn"}', encoding="utf-8")
            # Tiny batch-compatible fake codex executable to verify chcp 65001 shim execution under Vietnamese folder!
            fake_exe = em_ext / "codex.exe"
            fake_exe.write_text("dummy", encoding="utf-8")

            env = {**os.environ, "USERPROFILE": str(home), "LOCALAPPDATA": str(local)}
            res = run_ps(
                f'. "{gw_ps1}"\n'
                f'. "{codex_ps1}"\n'
                "$ErrorActionPreference = 'Stop'\n"
                "Register-EmTroLyCodexCli -PayloadRoot '" + str(ROOT) + "' | Out-Null\n"
                "$shim = Join-Path $env:LOCALAPPDATA 'OpenClaw\\bin\\codex-emtroly.cmd'\n"
                "$uiShim = Join-Path $env:LOCALAPPDATA 'OpenClaw\\bin\\emtroly-ui.cmd'\n"
                "$shimTxt = [IO.File]::ReadAllText($shim, [Text.Encoding]::UTF8)\n"
                "$uiTxt = [IO.File]::ReadAllText($uiShim, [Text.Encoding]::UTF8)\n"
                "if ($shimTxt -notmatch 'chcp\\.com\" 65001') { throw 'codex-shim-missing-utf8-chcp' }\n"
                "if ($uiTxt -notmatch 'chcp\\.com\" 65001' -or $uiTxt -notmatch 'wscript\\.exe') { throw 'ui-shim-not-hidden-utf8' }\n"
                "# Verify Startup VBS encoding in user-gateway.ps1 is UTF-16 LE ([Text.Encoding]::Unicode)\n"
                f"$gwSrc = [IO.File]::ReadAllText('{gw_ps1}', [Text.Encoding]::UTF8)\n"
                "if ($gwSrc -notmatch 'WriteAllText\\(\\$startupFile,\\s*\\$body,\\s*\\[Text\\.Encoding\\]::Unicode\\)') { throw 'startup-vbs-not-unicode' }\n"
                "Write-Output 'UNICODE_PATHS_OK'\n",
                env=env,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertIn("UNICODE_PATHS_OK", res.stdout)

    def test_powershell51_native_stderr_warnings_do_not_abort_runner(self):
        runner = ROOT / "windows-installer/run-native-install.ps1"
        with tempfile.TemporaryDirectory(prefix="emtroly-stderr-") as td:
            root = Path(td)
            payload = root / "payload"
            (payload / "windows-installer").mkdir(parents=True)
            shutil.copy2(ROOT / "windows-installer/validation.ps1", payload / "windows-installer")
            (payload / "windows-installer/verify-openclaw-command.ps1").write_text("exit 0\n", encoding="utf-8-sig")
            # Fake installer that runs a REAL native process emitting warnings to stderr (exit 0)
            (payload / "install-native-windows.ps1").write_text(
                "param($Name,$OwnerIds,$GroupId,$AssistantName,$BaseUrl,$Model,$Profile,$Modules,$QrOwnerId,$OpenClawVersion,$InstallMode,$InstallRoot,$GatewayPort,$Audience,$Addressing,$Style,[switch]$UserInstall,$CredentialData)\n"
                "$ErrorActionPreference = 'Stop'\n"
                "& cmd.exe /d /c 'echo npm warn deprecated something 1>&2 & exit /b 0'\n"
                "if ($LASTEXITCODE -ne 0) { throw 'cmd-failed' }\n"
                "$r = Join-Path $env:USERPROFILE 'openclaw'\n"
                "foreach ($f in @('openclaw.json','installer-instance.json','openclaw-instance.ps1','windows-cli.json',"
                "'workspace\\skills\\core-openclaw-telegram\\SKILL.md','workspace\\skills\\cap-full-quyen-telegram-openclaw\\SKILL.md',"
                "'workspace\\skills\\reliable-media-delivery\\SKILL.md','workspace\\skills\\imagegen\\SKILL.md',"
                "'workspace\\skills\\core-openclaw-media\\SKILL.md','workspace\\skills\\openclaw-docx-reader\\SKILL.md',"
                "'workspace\\skills\\openclaw-python-docx-telegram\\SKILL.md')) {\n"
                "  $p = Join-Path $r $f; [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p)); [IO.File]::WriteAllText($p, 'ok')\n"
                "}\n"
                "$owners = @($OwnerIds -split ',')\n"
                "$exec = @{ host='gateway'; mode='full'; strictInlineEval=$false }\n"
                "$targets = @($owners | ForEach-Object { @{ channel='telegram'; accountId=$Name; to=$_ } })\n"
                "$cfg = @{ commands=@{ownerAllowFrom=@($owners | ForEach-Object { \"telegram:$_\" })}; channels=@{telegram=@{allowFrom=$owners;execApprovals=@{approvers=$owners};accounts=@{$Name=@{allowFrom=$owners;execApprovals=@{approvers=$owners}}}}}; approvals=@{exec=@{enabled=$true;mode='targets';agentFilter=@('main');targets=$targets};plugin=@{enabled=$true;mode='targets';agentFilter=@('main');targets=$targets}}; tools=@{exec=$exec}; agents=@{entries=@{main=@{tools=@{exec=$exec}}}}; bindings=@(@{agentId='main';match=@{channel='telegram';accountId=$Name}}) }\n"
                "[IO.File]::WriteAllText((Join-Path $r 'openclaw.json'), ($cfg | ConvertTo-Json -Depth 15))\n"
                "[IO.File]::WriteAllText((Join-Path $r 'installer-instance.json'), '{\"profile\":\"member-emtroly\"}')\n"
                "$rt = Join-Path $r 'runtime\\2026.11.4\\node_modules\\openclaw'; [void](New-Item -ItemType Directory -Force -Path $rt)\n"
                "[IO.File]::WriteAllText((Join-Path $rt 'openclaw.mjs'), \"const a=process.argv.slice(2);if(a[0]==='--version')console.log('OpenClaw 2026.11.4');else if(a[0]==='approvals')console.log(JSON.stringify({file:{agents:{main:{security:'full',ask:'off',askFallback:'full'}}}}));else if(a[0]==='gateway')console.log(JSON.stringify({ok:true,plugins:{loaded:[]}}));\")\n"
                "$global:LASTEXITCODE = 0\n",
                encoding="utf-8-sig",
            )
            home = root / "home"
            home.mkdir()
            settings_file = root / "settings.json"
            log_file = root / "status.txt"
            settings_file.write_text(
                json.dumps(
                    {
                        "member": "emtroly",
                        "assistant_name": "Em Tro Ly",
                        "base_url": "https://provider.example/v1",
                        "model": "gpt-6.2-sol",
                        "owner_ids": "123456789",
                        "group_id": "-1001234567890",
                        "gateway_port": "0",
                        "audience": "",
                        "addressing": "",
                        "style": "",
                        "accept_full_access": True,
                        "configure_zalo": False,
                        "skip_editor": True,
                        "qr_owner_id": "",
                        "telegram_token": "123456:STDERR_TEST_TOKEN_ABCDEFGHIJKLMNO",
                        "ai_api_key": "sk-stderr-test-key",
                    }
                ),
                encoding="utf-8",
            )
            clean_path = os.pathsep.join(
                p for p in os.environ.get("PATH", "").split(os.pathsep) if "openclaw" not in p.lower()
            )
            env = {**os.environ, "PATH": clean_path, "USERPROFILE": str(home), "LOCALAPPDATA": str(root / "local")}
            (root / "local").mkdir()
            res = run_ps(
                "function global:Invoke-RestMethod {\n"
                "  param([switch]$UseBasicParsing, $Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection)\n"
                "  if ($Uri -match '/models$') { return @{ data = @(@{ id = 'gpt-6.2-sol' }) } }\n"
                "  if ($Uri -match '/getMe$') { return @{ ok = $true; result = @{ is_bot = $true } } }\n"
                "  throw $Uri\n"
                "}\n"
                f'& "{runner}" -SettingsFile "{settings_file}" -PayloadRoot "{payload}" -LogFile "{log_file}"\n'
                "exit $LASTEXITCODE\n",
                env=env,
                timeout=45,
            )
            self.assertEqual(res.returncode, 0, f"status={log_file.read_text(encoding='utf-8') if log_file.exists() else ''}\n{res.stdout}\n{res.stderr}")
            self.assertTrue(log_file.read_text(encoding="utf-8").startswith("Hoàn tất:"))

    def test_diag_json_and_wpf_error_card_scrub_secrets_and_update_ui(self):
        manage_ps1 = ROOT / "windows-installer/manage-instance.ps1"
        wizard_ps1 = ROOT / "windows-installer/wizard.ps1"
        secret_tok = "987654:SUPER_SECRET_BOT_TOKEN_DO_NOT_LEAK_777"
        secret_key = "sk-super-secret-customer-key-do-not-leak-888"
        with tempfile.TemporaryDirectory(prefix="emtroly-errcard-") as td:
            temp = Path(td)
            home = temp / "home"
            local = temp / "local"
            home.mkdir()
            local.mkdir()

            # 1. Verify manage-instance.ps1 scrubs secrets from .diag.json on error
            req_file = temp / "req.json"
            status_file = temp / "status.txt"
            req_file.write_text(
                json.dumps(
                    {
                        "action": "auto-heal",
                        "ai_api_key": secret_key,
                        "telegram_token": secret_tok,
                        "error_detail": f"Crash with {secret_tok} and {secret_key}",
                    }
                ),
                encoding="utf-8",
            )
            env = {
                **os.environ,
                "USERPROFILE": str(home),
                "LOCALAPPDATA": str(local),
                "EMTROLY_ALLOW_MULTI_INSTANCE": "1",
            }
            # Force auto-heal to fail offline fast (minimal payload without native/user-dependencies.ps1)
            minimal_payload = stage_minimal_manage_payload(temp)
            res_m = run_ps(
                "$env:Path = ''\n"
                f'& "{manage_ps1}" -RunManageWorker -WorkerRequestFile "{req_file}" -WorkerPayloadRoot "{minimal_payload}" -WorkerLogFile "{status_file}"\n'
                "exit $LASTEXITCODE\n",
                env=env,
            )
            self.assertNotEqual(res_m.returncode, 0)
            diag_file = Path(str(status_file) + ".diag.json")
            self.assertTrue(diag_file.is_file(), "manage-instance must write .diag.json on failure")
            diag_text = diag_file.read_text(encoding="utf-8")
            self.assertNotIn(secret_tok, diag_text)
            self.assertNotIn(secret_key, diag_text)

            # 2. Verify WPF Show-RichFailureDiagnostics scrubs secrets, updates UI, and Change License dismissal works
            for h in ("codex-cli.ps1", "manage-instance.ps1", "auto-heal-codex.ps1", "wizard-helpers.ps1"):
                (temp / h).write_text((ROOT / "windows-installer" / h).read_text(encoding="utf-8-sig"), encoding="utf-8-sig")
            wiz_src = wizard_ps1.read_text(encoding="utf-8-sig")
            probe = f"""
Unlock-LicenseGate '{secret_key}'
$tokenBox.Text = '{secret_tok}'
$script:lastActiveStepIndex = 3
$diagObj = [pscustomobject]@{{
  timestamp = '2026-11-22 16:30:00'
  stage = 'install'
  code = 'gateway-health-failed'
  autoHealSummary = 'Failed with {secret_key}'
  technicalDetail = 'Leak attempt {secret_tok} and {secret_key}'
}}
Show-RichFailureDiagnostics -SummaryMessage 'Lỗi kết nối với {secret_tok}' -DiagPayload $diagObj -IsManageFailure $false
if ($installFailureActions.Visibility -ne [System.Windows.Visibility]::Visible) {{ throw 'error-card-hidden' }}
if ($autoHealNoteBorder.Visibility -ne [System.Windows.Visibility]::Collapsed) {{ throw 'note-not-collapsed' }}
if ($progressPercentText.Text -cne 'Gặp sự cố') {{ throw 'percent-text-wrong' }}
if ($errorDetailBox.Text -match [regex]::Escape('{secret_tok}') -or $errorDetailBox.Text -match [regex]::Escape('{secret_key}')) {{ throw 'secret-leaked-in-error-card' }}
if ($codexOutputBox.Text -match [regex]::Escape('{secret_tok}') -or $codexOutputBox.Text -match [regex]::Escape('{secret_key}')) {{ throw 'secret-leaked-in-codex-box' }}
if ($codexOutputBox.Text -notmatch 'gateway-health-failed') {{ throw 'error-not-mirrored-to-codex-tab' }}
# Verify Change License overlay allows dismissing back to unlocked app
Show-LicenseGate '' -AllowCancel
if ($licenseGateOverlay.Visibility -ne [System.Windows.Visibility]::Visible -or $licenseExitBtn.Content -cne 'Quay lại') {{ throw 'change-license-cancel-not-ready' }}
$window.Close()
Write-Output 'ERROR_CARD_UI_OK'
"""
            (temp / "wiz-err.ps1").write_text(wiz_src.replace("[void]$window.ShowDialog()", probe), encoding="utf-8-sig")
            res_w = run_ps(
                f'& "{temp / "wiz-err.ps1"}" -PayloadRoot "{ROOT}"\n',
                env=env,
                sta=True,
            )
            self.assertEqual(res_w.returncode, 0, res_w.stdout + res_w.stderr)
            self.assertIn("ERROR_CARD_UI_OK", res_w.stdout)

    def test_auto_heal_cleans_incomplete_root_only_never_complete_instance(self):
        manage_ps1 = ROOT / "windows-installer/manage-instance.ps1"
        with tempfile.TemporaryDirectory(prefix="emtroly-clean-half-") as td:
            temp = Path(td)
            home = temp / "home"
            local = temp / "local"
            oc = home / "openclaw"
            (oc / "runtime").mkdir(parents=True)
            (oc / "workspace").mkdir(parents=True)
            local.mkdir()

            # Case 1: Incomplete folder (NO openclaw.json) -> auto-heal cleans it cleanly and exits 0
            req1 = temp / "req1.json"
            st1 = temp / "st1.txt"
            req1.write_text(json.dumps({"action": "auto-heal"}), encoding="utf-8")
            env = {**os.environ, "USERPROFILE": str(home), "LOCALAPPDATA": str(local)}
            r1 = run_ps(
                f'& "{manage_ps1}" -RunManageWorker -WorkerRequestFile "{req1}" -WorkerPayloadRoot "{ROOT}" -WorkerLogFile "{st1}"\nexit $LASTEXITCODE\n',
                env=env,
            )
            self.assertEqual(r1.returncode, 0, r1.stdout + r1.stderr)
            self.assertFalse(oc.exists(), "Incomplete pre-config openclaw folder must be cleaned")
            self.assertTrue(st1.read_text(encoding="utf-8").startswith("Hoàn tất:"))

            # Case 2: Complete folder (HAS openclaw.json) -> auto-heal MUST NOT delete openclaw!
            minimal_payload = stage_minimal_manage_payload(temp)
            oc.mkdir(parents=True)
            (oc / "openclaw.json").write_text('{"gateway":{"port":19789}}', encoding="utf-8")
            req2 = temp / "req2.json"
            st2 = temp / "st2.txt"
            req2.write_text(json.dumps({"action": "auto-heal"}), encoding="utf-8")
            r2 = run_ps(
                "$env:Path = ''\n"
                f'& "{manage_ps1}" -RunManageWorker -WorkerRequestFile "{req2}" -WorkerPayloadRoot "{minimal_payload}" -WorkerLogFile "{st2}"\nexit $LASTEXITCODE\n',
                env=env,
            )
            self.assertNotEqual(r2.returncode, 0)
            self.assertTrue((oc / "openclaw.json").is_file(), "Complete instance openclaw.json must NEVER be deleted by auto-heal")

    def test_repair_shortcut_accepts_auto_updated_antigravity_version(self):
        repair_src = (ROOT / "windows-installer/repair-antigravity-shortcut.ps1").read_text(encoding="utf-8-sig")
        desktop_expr = "([Environment]::GetFolderPath('Desktop'))"
        with tempfile.TemporaryDirectory(prefix="emtroly-repair-upd-") as td:
            temp = Path(td)
            staged_repair = temp / "repair.ps1"
            staged_repair.write_text(repair_src.replace(desktop_expr, "$env:TEST_DESKTOP"), encoding="utf-8-sig")

            local = temp / "local"
            desktop = temp / "desktop"
            base = local / "EmTroLy"
            app = local / "Programs/EmTroLy-Antigravity-IDE-0123456789abcdef0123456789abcdef"
            for d in (
                desktop,
                base / "Codex",
                base / "Antigravity/UserData/User",
                base / "Antigravity/Extensions/openai.chatgpt-26.51111.21308/bin/windows-x86_64",
                app / "bin",
                app / "resources/app",
            ):
                d.mkdir(parents=True, exist_ok=True)
            (base / "installer-job.txt").write_text("0123456789abcdef0123456789abcdef", encoding="utf-8")
            (base / "Codex/config.toml").write_text('base_url = "https://codex.anhlaptrinh.vn/v1"\nrequires_openai_auth = true\n', encoding="utf-8")
            (base / "Codex/auth.json").write_text('{"OPENAI_API_KEY":"sk-fixture"}', encoding="utf-8")
            (base / "Antigravity/UserData/User/settings.json").write_text("{}", encoding="utf-8")
            (base / "Antigravity/Extensions/openai.chatgpt-26.51111.21308/package.json").write_text(
                '{"publisher":"openai","name":"chatgpt","version":"26.51111.21308"}', encoding="utf-8"
            )
            (base / "Antigravity/Extensions/openai.chatgpt-26.51111.21308/bin/windows-x86_64/codex.exe").write_text("bin", encoding="utf-8")
            (app / "Antigravity IDE.exe").write_text("ide", encoding="utf-8")
            (app / "bin/antigravity-ide.cmd").write_text("@echo off", encoding="utf-8")
            # Auto-updated Antigravity version (1.112.4 instead of pinned 1.107.0)
            (app / "resources/app/product.json").write_text('{"applicationName":"antigravity-ide","version":"1.112.4"}', encoding="utf-8")

            env = {**os.environ, "LOCALAPPDATA": str(local), "USERPROFILE": str(temp / "home"), "TEST_DESKTOP": str(desktop)}
            (temp / "home").mkdir()
            res = run_ps(f'& "{staged_repair}"\nexit $LASTEXITCODE\n', env=env)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertTrue((desktop / "EmTroLy - Antigravity.lnk").is_file())

    def test_wizard_single_instance_mutex_blocks_duplicate_and_startup_unlocks_offline(self):
        wizard_ps1 = ROOT / "windows-installer/wizard.ps1"
        with tempfile.TemporaryDirectory(prefix="emtroly-mutex-") as td:
            temp = Path(td)
            home = temp / "home"
            local = temp / "local"
            home.mkdir()
            local.mkdir()
            mutex_name = f"Local\\EmTroLy-Test-Mutex-{os.getpid()}"
            env = {
                **os.environ,
                "USERPROFILE": str(home),
                "LOCALAPPDATA": str(local),
                "EMTROLY_TEST_MUTEX_NAME": mutex_name,
                "EMTROLY_SUPPRESS_SINGLE_INSTANCE_MSGBOX": "1",
            }
            # Hold mutex in parent PS and launch wizard.ps1 as child: must exit 0 immediately without opening UI!
            res = run_ps(
                f"$created = $false\n"
                f"$m = New-Object System.Threading.Mutex($true, '{mutex_name}', [ref]$created)\n"
                "try {\n"
                f'  $p = Start-Process -FilePath "{SHELL}" -ArgumentList \'-STA -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{wizard_ps1}" -PayloadRoot "{ROOT}"\' -WindowStyle Hidden -PassThru\n'
                "  if (-not $p.WaitForExit(10000)) { try { $p.Kill() } catch {}; throw 'duplicate-wizard-did-not-exit' }\n"
                "  if ($p.ExitCode -ne 0) { throw ('unexpected-exit-' + $p.ExitCode) }\n"
                "  Write-Output 'SINGLE_INSTANCE_OK'\n"
                "} finally {\n"
                "  try { $m.ReleaseMutex() } catch {}\n"
                "  $m.Dispose()\n"
                "}\n",
                env=env,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertIn("SINGLE_INSTANCE_OK", res.stdout)

    @unittest.skipUnless(WSCRIPT.is_file(), "Requires Windows Script Host wscript.exe")
    def test_launch_wizard_vbs_propagates_exit_code_with_spaces_and_zero_windows(self):
        vbs = ROOT / "windows-installer/launch-wizard.vbs"
        with tempfile.TemporaryDirectory(prefix="emtroly vbs spaces ") as td:
            fake_wiz = Path(td) / "wizard.ps1"
            fake_wiz.write_text("param($PayloadRoot)\nif ($PayloadRoot -ne '" + td + "') { exit 9 }\nexit 17\n", encoding="utf-8-sig")
            proc = subprocess.run(
                [str(WSCRIPT), "//B", "//Nologo", str(vbs), SHELL, str(fake_wiz), td, "-WindowStyle Hidden"],
                capture_output=True,
                timeout=20,
                **TEXT_KWARGS,
            )
            self.assertEqual(proc.returncode, 17, proc.stdout + proc.stderr)

    @unittest.skipUnless(NODE, "Requires Node.js")
    def test_zalo_qr_bridge_timeout_and_corrupted_png_restore_running_channel(self):
        qr_bridge = ROOT / "windows-installer/zalo-qr-session.mjs"
        with tempfile.TemporaryDirectory(prefix="emtroly-zalo-edge-") as td:
            temp = Path(td)
            oc = temp / "openclaw"
            rt = oc / "runtime/2026.11.4/node_modules/openclaw"
            rt.mkdir(parents=True)
            calls_log = temp / "calls.log"
            bad_png = temp / "bad.png"
            bad_png.write_bytes(b"NOT_A_VALID_PNG_HEADER_AT_ALL_0123456789")

            fake_cli = rt / "openclaw.mjs"
            fake_cli.write_text(
                "import fs from 'node:fs';\n"
                f"const logFile = {json.dumps(str(calls_log))};\n"
                "const args = process.argv.slice(2);\n"
                "if (args[0] === 'gateway' && args[1] === 'call') {\n"
                "  const method = args[2];\n"
                "  fs.appendFileSync(logFile, method + '\\n');\n"
                "  if (method === 'channels.status') console.log(JSON.stringify({channels:{zalouser:{running:true}}}));\n"
                "  else console.log(JSON.stringify({ok:true}));\n"
                "  process.exit(0);\n"
                "}\n"
                "if (args[0] === 'channels' && args[1] === 'login') {\n"
                f"  console.log('Scan QR image: {str(bad_png).replace(chr(92), chr(92)*2)}');\n"
                "  setTimeout(() => process.exit(0), 60000);\n"
                "}\n",
                encoding="utf-8",
            )
            (oc / "installer-instance.json").write_text(json.dumps({"cli_entry": str(fake_cli)}), encoding="utf-8")
            (oc / "openclaw.json").write_text("{}", encoding="utf-8")
            state_file = temp / "state.json"
            qr_out = temp / "gui-qr.png"

            proc = subprocess.run(
                [NODE, str(qr_bridge), "--root", str(oc), "--state-file", str(state_file), "--qr-out", str(qr_out), "--timeout-seconds", "1"],
                capture_output=True,
                timeout=15,
                **TEXT_KWARGS,
            )
            self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
            self.assertFalse(qr_out.exists(), "Corrupted non-PNG file must not be copied to GUI QR output")
            state = json.loads(state_file.read_text(encoding="utf-8"))
            self.assertEqual(state["phase"], "expired")
            logged = calls_log.read_text(encoding="utf-8").splitlines()
            self.assertIn("channels.stop", logged)
            self.assertIn("channels.start", logged, "Previous running zalouser channel must be restored on timeout")

    def test_wizard_persists_and_restores_setup_inputs_across_restart(self):
        wizard_ps1 = ROOT / "windows-installer/wizard.ps1"
        with tempfile.TemporaryDirectory(prefix="emtroly-wiz-persist-") as td:
            temp = Path(td)
            home = temp / "home"
            local = temp / "local"
            home.mkdir()
            local.mkdir()
            for h in ("codex-cli.ps1", "manage-instance.ps1", "auto-heal-codex.ps1", "wizard-helpers.ps1"):
                (temp / h).write_text((ROOT / "windows-installer" / h).read_text(encoding="utf-8-sig"), encoding="utf-8-sig")
            wiz_src = wizard_ps1.read_text(encoding="utf-8-sig")
            env = {
                **os.environ,
                "USERPROFILE": str(home),
                "LOCALAPPDATA": str(local),
                "EMTROLY_ALLOW_MULTI_INSTANCE": "1",
            }

            # Session 1: User enters all form settings, saves draft (as on Start Install), and closes app
            probe1 = """
Unlock-LicenseGate 'sk-persist-license-key-111222'
$tokenBox.Text = '555666:PERSIST_TELEGRAM_TOKEN_XYZ123456789'
$ownersBox.Text = '112233445,998877665'
$groupBox.Text = '-1005566778899'
$modelBox.SelectedIndex = 2
$assistantBox.Text = 'Em Trợ Lý Riêng'
$portBox.Text = '19777'
$qrOwnerBox.Text = '998877665'
$audienceBox.Text = 'Khách hàng VIP'
$addressingBox.Text = 'anh / em'
$styleBox.Text = 'Tự nhiên, ngắn gọn'
$zaloCheck.Checked = $false
$existingEditorCheck.Checked = $true
$fullAccessCheck.Checked = $true
Save-CurrentFormDraft
$window.Close()
Write-Output 'SESSION1_SAVED'
"""
            (temp / "wiz1.ps1").write_text(wiz_src.replace("[void]$window.ShowDialog()", probe1), encoding="utf-8-sig")
            r1 = run_ps(f'& "{temp / "wiz1.ps1"}" -PayloadRoot "{ROOT}"\n', env=env, sta=True)
            self.assertEqual(r1.returncode, 0, r1.stdout + r1.stderr)
            self.assertIn("SESSION1_SAVED", r1.stdout)

            # Session 2: User reopens app -> all inputs + saved draft banner must be restored automatically; Clear resets cleanly
            probe2 = """
if ($tokenBox.Text -cne '555666:PERSIST_TELEGRAM_TOKEN_XYZ123456789') { throw ('token-not-restored:' + $tokenBox.Text) }
if ($apiKeyBox.Text -cne 'sk-persist-license-key-111222') { throw ('apikey-not-restored:' + $apiKeyBox.Text) }
if ($ownersBox.Text -cne '112233445,998877665') { throw 'owners-not-restored' }
if ($groupBox.Text -cne '-1005566778899') { throw 'group-not-restored' }
if ([string]$modelBox.SelectedItem -cne 'gpt-6.2-astra') { throw ('model-not-restored:' + [string]$modelBox.SelectedItem) }
if ($assistantBox.Text -cne 'Em Trợ Lý Riêng') { throw 'assistant-not-restored' }
if ($portBox.Text -cne '19777') { throw 'port-not-restored' }
if ($qrOwnerBox.Text -cne '998877665') { throw 'qrowner-not-restored' }
if ($audienceBox.Text -cne 'Khách hàng VIP' -or $addressingBox.Text -cne 'anh / em' -or $styleBox.Text -cne 'Tự nhiên, ngắn gọn') { throw 'profile-not-restored' }
if ($zaloCheck.Checked -ne $false -or $existingEditorCheck.Checked -ne $true -or $fullAccessCheck.Checked -ne $true) { throw 'checkboxes-not-restored' }
if ($savedDraftBanner.Visibility -ne [System.Windows.Visibility]::Visible) { throw 'saved-draft-banner-hidden' }
Clear-SavedDraftAction
if ($savedDraftBanner.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw 'banner-not-hidden-after-clear' }
if ($tokenBox.Text -ne '' -or $ownersBox.Text -ne '' -or $groupBox.Text -ne '') { throw 'fields-not-cleared' }
if ($apiKeyBox.Text -cne 'sk-persist-license-key-111222') { throw 'license-apikey-should-remain-after-draft-clear' }
$window.Close()
Write-Output 'SESSION2_RESTORED_AND_CLEARED'
"""
            (temp / "wiz2.ps1").write_text(wiz_src.replace("[void]$window.ShowDialog()", probe2), encoding="utf-8-sig")
            r2 = run_ps(f'& "{temp / "wiz2.ps1"}" -PayloadRoot "{ROOT}"\n', env=env, sta=True)
            self.assertEqual(r2.returncode, 0, r2.stdout + r2.stderr)
            self.assertIn("SESSION2_RESTORED_AND_CLEARED", r2.stdout)

    @unittest.skipUnless(NODE, "Requires Node.js")
    def test_zalo_qr_gateway_rpc_fast_path_and_telegram_plugin_auth(self):
        import base64
        from http.server import BaseHTTPRequestHandler, HTTPServer
        import threading

        # >= 32 bytes valid PNG
        valid_png = base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )
        qr_data_url = "data:image/png;base64," + base64.b64encode(valid_png).decode("ascii")
        tg_received = {"photos": 0, "messages": 0}

        class MockTg(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                _ = self.rfile.read(length)
                if self.path.endswith("/sendPhoto"):
                    tg_received["photos"] += 1
                    body = json.dumps({"ok": True, "result": {"message_id": 555}}).encode("utf-8")
                else:
                    tg_received["messages"] += 1
                    body = json.dumps({"ok": True, "result": {"message_id": 556}}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        srv = HTTPServer(("127.0.0.1", 0), MockTg)
        port = srv.server_address[1]
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory(prefix="emtroly-zalo-rpc-") as td:
                temp = Path(td)
                oc = temp / "openclaw"
                rt = oc / "runtime/2026.11.4/node_modules/openclaw"
                plugin_dir = oc / "tools/telegram-zalo-owner-login"
                rt.mkdir(parents=True)
                plugin_dir.mkdir(parents=True)

                fake_cli = rt / "openclaw.mjs"
                fake_cli.write_text(
                    "const a = process.argv.slice(2);\n"
                    "if (a[0] === 'gateway' && a[1] === 'call') {\n"
                    "  const m = a[2];\n"
                    f"  if (m === 'web.login.start') console.log(JSON.stringify({{qrDataUrl: {json.dumps(qr_data_url)}, message: 'Scan QR'}}));\n"
                    "  else if (m === 'web.login.wait') console.log(JSON.stringify({connected: true, message: 'Login successful.'}));\n"
                    "  else console.log(JSON.stringify({ok: true, channels: {zalouser: {running: false}}}));\n"
                    "  process.exit(0);\n"
                    "}\n"
                    "process.exit(1);\n",
                    encoding="utf-8",
                )
                (oc / "installer-instance.json").write_text(json.dumps({"cli_entry": str(fake_cli)}), encoding="utf-8")
                (oc / "telegram.token").write_text("123456:FAKE_TG_TOKEN_FOR_ZALO_RPC_TEST_999\n", encoding="utf-8")
                (oc / "openclaw.json").write_text(
                    json.dumps({"commands": {"ownerAllowFrom": ["telegram:6980864856"]}}),
                    encoding="utf-8",
                )

                # 1. Test GUI Bridge (`zalo-qr-session.mjs`) fast RPC path
                st_file = temp / "state.json"
                qr_out = temp / "gui.png"
                env = {**os.environ, "EMTROLY_TELEGRAM_API_BASE": f"http://127.0.0.1:{port}"}
                res1 = subprocess.run(
                    [NODE, str(ROOT / "windows-installer/zalo-qr-session.mjs"), "--root", str(oc), "--state-file", str(st_file), "--qr-out", str(qr_out), "--force", "--timeout-seconds", "15"],
                    env=env,
                    capture_output=True,
                    timeout=15,
                    **TEXT_KWARGS,
                )
                self.assertEqual(res1.returncode, 0, res1.stdout + res1.stderr)
                self.assertTrue(qr_out.is_file())
                self.assertEqual(qr_out.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")
                self.assertEqual(tg_received["photos"], 1)
                self.assertEqual(tg_received["messages"], 1)

                # 2. Test Telegram `/zaloqr` plugin (`assets/index.mjs`) context auth + RPC QR delivery
                shutil.copy2(ROOT / "native/skills/telegram-zalo-owner-login/assets/index.mjs", plugin_dir / "index.mjs")
                (plugin_dir / "settings.json").write_text(
                    json.dumps(
                        {
                            "pluginId": "telegram-zalo-owner-login",
                            "runtimeRoot": str(oc),
                            "runtimeHome": str(temp),
                            "agentId": "main",
                            "telegramAccount": "emtroly",
                            "zaloAccount": "default",
                            "cliCommand": NODE,
                            "cliPrefix": [str(fake_cli)],
                        }
                    ),
                    encoding="utf-8",
                )
                plugin_test_mjs = temp / "test-plugin.mjs"
                plugin_test_mjs.write_text(
                    f"import {{ authorizedCommandContext, authorizedToolContext, loginAndSendQr }} from {json.dumps((plugin_dir / 'index.mjs').as_uri())};\n"
                    "// OpenClaw 2026.11.4 DM command context (no agentId / assertOwnerCurrent, prefixed from/to)\n"
                    "const okDm = authorizedCommandContext({ isAuthorizedSender: true, senderIsOwner: true, senderId: '6980864856', from: 'telegram:6980864856', to: 'telegram:emtroly:6980864856', accountId: 'emtroly', sessionKey: 'agent:main:telegram:direct:6980864856' });\n"
                    "if (!okDm) throw new Error('valid-dm-command-rejected');\n"
                    "// Group chat MUST be rejected\n"
                    "const badGrp = authorizedCommandContext({ isAuthorizedSender: true, senderIsOwner: true, senderId: '6980864856', from: 'telegram:group:-5444081554', to: '-5444081554', accountId: 'emtroly', sessionKey: 'agent:main:telegram:group:-5444081554' });\n"
                    "if (badGrp) throw new Error('group-command-accepted');\n"
                    "// Non-owner MUST be rejected\n"
                    "const badUser = authorizedCommandContext({ isAuthorizedSender: true, senderIsOwner: false, senderId: '999999', from: 'telegram:999999', accountId: 'emtroly' });\n"
                    "if (badUser) throw new Error('non-owner-accepted');\n"
                    "// Tool context with prefixed requesterSenderId\n"
                    "const okTool = authorizedToolContext({ senderIsOwner: true, requesterSenderId: 'telegram:6980864856', messageChannel: 'telegram', agentAccountId: 'emtroly', sessionKey: 'agent:main:telegram:direct:6980864856', assertInvocationCurrent: () => {} });\n"
                    "if (!okTool) throw new Error('valid-tool-ctx-rejected');\n"
                    "// End-to-end loginAndSendQr via RPC + direct Telegram sendPhoto\n"
                    "const out = await loginAndSendQr('6980864856', () => {});\n"
                    "if (out.status !== 'login_completed' || out.telegramMessageId !== '555') throw new Error('unexpected-result:' + JSON.stringify(out));\n"
                    "console.log('PLUGIN_AUTH_AND_QR_OK');\n",
                    encoding="utf-8",
                )
                res2 = subprocess.run([NODE, str(plugin_test_mjs)], env=env, capture_output=True, timeout=15, **TEXT_KWARGS)
                self.assertEqual(res2.returncode, 0, res2.stdout + res2.stderr)
                self.assertIn("PLUGIN_AUTH_AND_QR_OK", res2.stdout)
                self.assertEqual(tg_received["photos"], 2)
        finally:
            srv.shutdown()
            srv.server_close()


# =============================================================================
# 3. STATIC INTEGRITY CHECKS (UTF-8 BOM + PowerShell AST across repository)
# =============================================================================


class StaticIntegrityTests(unittest.TestCase):
    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_all_windows_powershell_scripts_have_single_utf8_bom_and_clean_ast(self):
        targets = sorted(
            list((ROOT / "windows-installer").glob("*.ps1"))
            + list((ROOT / "native").glob("*.ps1"))
            + [ROOT / "install-native-windows.ps1"]
        )
        self.assertGreater(len(targets), 10)
        for ps_file in targets:
            raw = ps_file.read_bytes()
            self.assertTrue(raw.startswith(b"\xef\xbb\xbf"), f"{ps_file.name} is missing UTF-8 BOM (breaks Vietnamese in PS 5.1)")
            self.assertFalse(raw.startswith(b"\xef\xbb\xbf\xef\xbb\xbf"), f"{ps_file.name} has double UTF-8 BOM")

        quoted_paths = ",".join(f"'{str(p)}'" for p in targets)
        res = run_ps(
            f"$files = @({quoted_paths})\n"
            "foreach ($f in $files) {\n"
            "  $t = $null; $e = $null\n"
            "  [void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$t, [ref]$e)\n"
            "  if ($e.Count -gt 0) { throw \"AST parse error in ${f}: $($e[0].Message)\" }\n"
            "}\n"
            "Write-Output 'BOM_AND_AST_OK'\n"
        )
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("BOM_AND_AST_OK", res.stdout)

        # Root 1-line bootstrap (`irm .../install-windows.ps1 | iex`) MUST be pure ASCII without UTF-8 BOM
        # so Windows PowerShell 5.1 Invoke-RestMethod | Invoke-Expression never chokes on U+FEFF.
        bootstrap_ps = ROOT / "install-windows.ps1"
        boot_raw = bootstrap_ps.read_bytes()
        self.assertFalse(boot_raw.startswith(b"\xef\xbb\xbf"), "install-windows.ps1 must NOT start with UTF-8 BOM for irm | iex")
        iex_res = run_ps(
            f"$env:EMTROLY_BOOTSTRAP_NO_AUTORUN = '1'\n"
            f"$txt = [IO.File]::ReadAllText('{str(bootstrap_ps)}', [System.Text.Encoding]::UTF8)\n"
            "Invoke-Expression $txt\n"
            "if (-not (Get-Command Install-EmTroLyWindows -ErrorAction SilentlyContinue)) { throw 'missing-bootstrap-fn' }\n"
            "Write-Output 'IRM_IEX_PARSE_OK'\n"
        )
        self.assertEqual(iex_res.returncode, 0, iex_res.stdout + iex_res.stderr)
        self.assertIn("IRM_IEX_PARSE_OK", iex_res.stdout)

        # Windows 10 (.NET 4.8.0 build 19041) XamlReader.Load throws XamlParseException on TextBoxBase-inherited
        # attributes inside dynamic XAML strings (IsReadOnly, AcceptsReturn, VerticalScrollBarVisibility).
        wizard_txt = (ROOT / "windows-installer/wizard.ps1").read_text(encoding="utf-8-sig")
        xaml_match = re.search(r"\$xamlText\s*=\s*@'\r?\n(.*?)\r?\n'@", wizard_txt, re.S)
        self.assertIsNotNone(xaml_match, "Could not locate $xamlText in wizard.ps1")
        xaml_body = xaml_match.group(1)
        self.assertNotIn(
            'Property="IsReadOnly"',
            xaml_body,
            'wizard.ps1 XAML contains Property="IsReadOnly" which crashes WPF XamlReader on Windows 10 .NET 4.8.0',
        )
        for bad_tb in re.findall(r"<TextBox\b[^>]*>", xaml_body):
            for forbidden_attr in ('IsReadOnly="', 'AcceptsReturn="', 'VerticalScrollBarVisibility="'):
                self.assertNotIn(
                    forbidden_attr,
                    bad_tb,
                    f"wizard.ps1 TextBox XAML contains {forbidden_attr} which crashes WPF XamlReader on Windows 10 .NET 4.8.0",
                )

    @unittest.skipUnless(os.name == "nt", "Requires Windows x64")
    def test_immutable_bootstrap_stub_integrity_and_mock_download(self):
        from http.server import BaseHTTPRequestHandler, HTTPServer
        import threading

        stub_dir = ROOT / "windows-installer/bootstrap-stub"
        stub_exe = stub_dir / "EmTroLy-Setup.exe"
        stub_sha = stub_dir / "EmTroLy-Setup.exe.sha256"
        self.assertTrue(stub_exe.is_file(), "Missing immutable EmTroLy-Setup.exe")
        self.assertTrue(stub_sha.is_file(), "Missing EmTroLy-Setup.exe.sha256")

        expected_stub_hash = re.search(r"\b([a-fA-F0-9]{64})\b", stub_sha.read_text(encoding="utf-8")).group(1).lower()
        actual_stub_hash = hashlib.sha256(stub_exe.read_bytes()).hexdigest().lower()
        self.assertEqual(actual_stub_hash, expected_stub_hash, "EmTroLy-Setup.exe SHA-256 drifted; SmartScreen reputation depends on immutability!")

        fake_payload = b"MZ-FAKE-EMTROLY-INSTALLER-PAYLOAD-FOR-UNIT-TEST-2026" * 64
        good_hash = hashlib.sha256(fake_payload).hexdigest().lower()
        state = {"sha": good_hash}

        class MockReleaseHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/download/MANIFEST.txt":
                    data = b"installer_version=2026.11.23.4\n"
                elif self.path == "/download/emtroly.exe.sha256":
                    data = f"{state['sha']} *emtroly.exe\n".encode("ascii")
                elif self.path == "/download/emtroly.exe":
                    data = fake_payload
                else:
                    self.send_response(404)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        srv = HTTPServer(("127.0.0.1", 0), MockReleaseHandler)
        port = srv.server_address[1]
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory(prefix="emtroly-stub-test-") as td:
                out_ok = Path(td) / "downloaded-ok.exe"
                r_ok = subprocess.run(
                    [str(stub_exe), "--quiet", "--download-only", "--test-loopback-port", str(port), "--out", str(out_ok)],
                    capture_output=True,
                    timeout=20,
                    **TEXT_KWARGS,
                )
                self.assertEqual(r_ok.returncode, 0, r_ok.stdout + r_ok.stderr)
                self.assertTrue(out_ok.is_file())
                self.assertEqual(out_ok.read_bytes(), fake_payload)

                # Tampered SHA-256 must be rejected and never leave corrupted exe
                state["sha"] = "0" * 64
                out_bad = Path(td) / "downloaded-bad.exe"
                r_bad = subprocess.run(
                    [str(stub_exe), "--quiet", "--download-only", "--test-loopback-port", str(port), "--out", str(out_bad)],
                    capture_output=True,
                    timeout=20,
                    **TEXT_KWARGS,
                )
                self.assertNotEqual(r_bad.returncode, 0)
                self.assertFalse(out_bad.exists())
        finally:
            srv.shutdown()
            srv.server_close()

    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_github_self_update_helpers_sha256_and_wpf_banner_flow(self):
        from http.server import BaseHTTPRequestHandler, HTTPServer
        import threading

        fake_exe = b"MZ-EMTROLY-SELF-UPDATE-PAYLOAD-2099" * 128
        good_sha = hashlib.sha256(fake_exe).hexdigest().lower()
        srv_state = {
            "tag": "v2099.12.31.1",
            "sha": good_sha,
            "include_assets": True,
        }

        class MockGitHubUpdateServer(BaseHTTPRequestHandler):
            def do_GET(self):
                host_hdr = self.headers.get("Host", f"127.0.0.1:{self.server.server_port}")
                base_u = f"http://{host_hdr}"
                if self.path == "/releases/latest":
                    assets = []
                    if srv_state["include_assets"]:
                        assets = [
                            {
                                "name": "emtroly.exe",
                                "browser_download_url": f"{base_u}/download/emtroly.exe",
                                "size": len(fake_exe),
                            },
                            {
                                "name": "emtroly.exe.sha256",
                                "browser_download_url": f"{base_u}/download/emtroly.exe.sha256",
                                "size": 80,
                            },
                        ]
                    payload = json.dumps(
                        {
                            "tag_name": srv_state["tag"],
                            "html_url": "https://github.com/workanhlaptrinh123/installer_emtroly/releases/tag/" + srv_state["tag"],
                            "body": "Bổ sung thông báo và tự động cập nhật phiên bản mới.",
                            "assets": assets,
                        }
                    ).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json; charset=utf-8")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                elif self.path == "/download/emtroly.exe.sha256":
                    data = f"{srv_state['sha']}  emtroly.exe\n".encode("ascii")
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                elif self.path == "/download/emtroly.exe":
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(fake_exe)))
                    self.end_headers()
                    self.wfile.write(fake_exe)
                else:
                    self.send_response(404)
                    self.end_headers()

            def log_message(self, *args):
                pass

        srv = HTTPServer(("127.0.0.1", 0), MockGitHubUpdateServer)
        port = srv.server_address[1]
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            helpers = ROOT / "windows-installer/wizard-helpers.ps1"
            wizard_ps1 = ROOT / "windows-installer/wizard.ps1"
            with tempfile.TemporaryDirectory(prefix="emtroly-selfupd-win-") as td:
                temp = Path(td)
                home = temp / "home"
                local = temp / "local"
                home.mkdir()
                local.mkdir()
                env = {
                    **os.environ,
                    "USERPROFILE": str(home),
                    "LOCALAPPDATA": str(local),
                    "EMTROLY_UPDATE_API_BASE": f"http://127.0.0.1:{port}/releases",
                    "EMTROLY_TEST_SKIP_UPDATE_RELAUNCH": "1",
                    "EMTROLY_ALLOW_MULTI_INSTANCE": "1",
                    "EMTROLY_TEST_DESKTOP_DIR": str(temp / "desktop"),
                    "EMTROLY_TEST_PROGRAMS_DIR": str(temp / "programs"),
                }
                (temp / "desktop").mkdir()
                (temp / "programs").mkdir()

                # 1. Unit-test helper functions (trusted URLs, update check, SHA-256 download, bad hash rejection, UI sync)
                res_unit = run_ps(
                    f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{helpers}", [Text.Encoding]::UTF8)))\n'
                    "$ErrorActionPreference = 'Stop'\n"
                    "if (Test-EmTroLyTrustedGitHubUrl -Url 'https://evil.example.com/emtroly.exe') { throw 'evil-url-accepted' }\n"
                    "if (-not (Test-EmTroLyTrustedGitHubUrl -Url 'https://github.com/workanhlaptrinh123/installer_emtroly/releases/latest')) { throw 'github-url-rejected' }\n"
                    f"$uNew = Get-EmTroLyAppUpdateInfo -PayloadRoot '{ROOT}' -CurrentVersion '2026.11.24.3'\n"
                    "if (-not $uNew.Ok -or -not $uNew.HasUpdate -or $uNew.LatestVersion -cne '2099.12.31.1') { throw 'update-not-detected' }\n"
                    "$uSame = Get-EmTroLyAppUpdateInfo -CurrentVersion '2099.12.31.1'\n"
                    "if (-not $uSame.Ok -or $uSame.HasUpdate) { throw 'same-version-marked-update' }\n"
                    "$stFile = Join-Path $env:LOCALAPPDATA 'upd.status'\n"
                    "$dlOk = Install-EmTroLyAppUpdate -UpdateInfo $uNew -StatusFile $stFile\n"
                    "if (-not $dlOk.Ok -or -not (Test-Path -LiteralPath $dlOk.ExePath -PathType Leaf)) { throw 'download-update-failed' }\n"
                    "# Seed older installed EmTroLyUI and verify Sync-EmTroLyInstalledUiIfNewer refreshes it\n"
                    "$uiWin = Join-Path $env:LOCALAPPDATA 'EmTroLyUI\\windows-installer'\n"
                    "[void][IO.Directory]::CreateDirectory($uiWin)\n"
                    "[IO.File]::WriteAllText((Join-Path $uiWin 'wizard.ps1'), '# old')\n"
                    "[IO.File]::WriteAllText((Join-Path $env:LOCALAPPDATA 'EmTroLyUI\\MANIFEST.txt'), \"installer_version=2025.1.1`n\")\n"
                    f"if (-not (Sync-EmTroLyInstalledUiIfNewer -PayloadRoot '{ROOT}')) {{ throw 'ui-sync-did-not-run' }}\n"
                    "$syncedVer = (Get-EmTroLyAppVersion -PayloadRoot (Join-Path $env:LOCALAPPDATA 'EmTroLyUI')).InstallerVersion\n"
                    "if ($syncedVer -eq '2025.1.1') { throw 'ui-manifest-not-updated' }\n"
                    "Write-Output 'WIN_UPDATE_HELPER_OK'\n",
                    env=env,
                )
                self.assertEqual(res_unit.returncode, 0, res_unit.stdout + res_unit.stderr)
                self.assertIn("WIN_UPDATE_HELPER_OK", res_unit.stdout)

                # Tampered SHA-256 must fail closed and delete partial file
                srv_state["sha"] = "f" * 64
                srv_state["tag"] = "v2099.12.31.2"
                res_bad = run_ps(
                    f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{helpers}", [Text.Encoding]::UTF8)))\n'
                    "$ErrorActionPreference = 'Stop'\n"
                    "$uBad = Get-EmTroLyAppUpdateInfo -CurrentVersion '2026.11.24.3'\n"
                    "$failed = $false\n"
                    "try { [void](Install-EmTroLyAppUpdate -UpdateInfo $uBad -OutDir (Join-Path $env:LOCALAPPDATA 'bad-upd')) } catch { $failed = $true }\n"
                    "if (-not $failed) { throw 'tampered-sha-not-rejected' }\n"
                    "if (@(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'bad-upd') -Force -ErrorAction SilentlyContinue).Count -ne 0) { throw 'corrupt-part-left-behind' }\n"
                    "Write-Output 'TAMPERED_REJECTED_OK'\n",
                    env=env,
                )
                self.assertEqual(res_bad.returncode, 0, res_bad.stdout + res_bad.stderr)
                self.assertIn("TAMPERED_REJECTED_OK", res_bad.stdout)

                # 2. End-to-end WPF UI banner & self-update button probe
                srv_state["sha"] = good_sha
                srv_state["tag"] = "v2099.12.31.5"
                for h in ("codex-cli.ps1", "manage-instance.ps1", "auto-heal-codex.ps1", "wizard-helpers.ps1"):
                    (temp / h).write_text((ROOT / "windows-installer" / h).read_text(encoding="utf-8-sig"), encoding="utf-8-sig")
                wiz_src = wizard_ps1.read_text(encoding="utf-8-sig")
                probe_ui = r"""
Unlock-LicenseGate 'sk-upd-ui-test-key-123'
$script:probeStep = 0
$script:probePassed = $false
$script:probeError = ''
$probeTimer = New-Object System.Windows.Threading.DispatcherTimer
$probeTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$probeTimer.Add_Tick({
  try {
    if ($script:probeStep -eq 0 -and $null -ne $script:latestUpdateInfo -and -not $script:appUpdateChecking) {
      if ($appUpdateBanner.Visibility -ne [System.Windows.Visibility]::Visible) {
        throw 'update-banner-did-not-appear'
      }
      if ([string]$headerUpdateBtn.Content -notmatch '2099\.12\.31\.5') {
        throw ('unexpected-header-btn:' + [string]$headerUpdateBtn.Content)
      }
      $script:probeStep = 1
      Start-AppSelfUpdate
    } elseif ($script:probeStep -eq 1 -and -not $script:appUpdateDownloading -and $script:relaunchingForUpdate) {
      $probeTimer.Stop()
      $script:probePassed = $true
      $window.Close()
    }
  } catch {
    $probeTimer.Stop()
    $script:probeError = [string]$_.Exception.Message
    $window.Close()
  }
})
$window.Add_ContentRendered({ $probeTimer.Start() })
[void]$window.ShowDialog()
if (-not $script:probePassed) { throw ('wpf-update-probe-failed:' + $script:probeError) }
Write-Output 'WPF_UPDATE_BANNER_AND_DOWNLOAD_OK'
"""
                (temp / "wiz_upd.ps1").write_text(wiz_src.replace("[void]$window.ShowDialog()", probe_ui), encoding="utf-8-sig")
                res_ui = run_ps(f'& "{temp / "wiz_upd.ps1"}" -PayloadRoot "{ROOT}"\n', env=env, sta=True, timeout=40)
                self.assertEqual(res_ui.returncode, 0, res_ui.stdout + res_ui.stderr)
                self.assertIn("WPF_UPDATE_BANNER_AND_DOWNLOAD_OK", res_ui.stdout)
        finally:
            srv.shutdown()
            srv.server_close()

    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_windowsapps_python_shadow_orphaned_markers_and_existing_openclaw_recovery(self):
        # 1. Static guard: winget OpenJS.NodeJS.LTS must NEVER use --scope user (MSI is machine-scope only)
        native_win_txt = (ROOT / "install-native-windows.ps1").read_text(encoding="utf-8-sig")
        for line in native_win_txt.splitlines():
            if "OpenJS.NodeJS.LTS" in line:
                self.assertNotIn("--scope user", line)

        # 2. WindowsApps\python.exe shadowing User Python in PATH + orphaned Step 3/4 markers + existing openclaw dir
        with tempfile.TemporaryDirectory(prefix="emtroly-giangle-") as td:
            temp = Path(td)
            home = temp / "home"
            local = temp / "local"
            fake_winapps = temp / "Microsoft/WindowsApps"
            home.mkdir(parents=True)
            local.mkdir(parents=True)
            fake_winapps.mkdir(parents=True)

            # Create a dummy broken stub at ...\Microsoft\WindowsApps\python.exe (simulating MS Store alias)
            stub_py = fake_winapps / "python.exe"
            stub_py.write_bytes(b"")

            runner_txt = (ROOT / "windows-installer/run-native-install.ps1").read_text(encoding="utf-8-sig")
            fn_end = runner_txt.index("try {\n  try {") if "try {\n  try {" in runner_txt else runner_txt.index("try {\r\n  try {")
            fn_start = runner_txt.index("function Test-IsRecoverableIncompleteOpenClawDir")
            runner_fns = temp / "runner-fns.ps1"
            runner_fns.write_text(runner_txt[fn_start:fn_end], encoding="utf-8-sig")

            inst_lines = native_win_txt.splitlines()
            helper_start = next(i for i, l in enumerate(inst_lines) if l.startswith("function Optimize-NativeProcessPath"))
            helper_end = next(i for i, l in enumerate(inst_lines) if l.startswith("if (-not $UserInstall -and"))
            inst_fns = temp / "inst-fns.ps1"
            inst_fns.write_text("\n".join(inst_lines[helper_start:helper_end]), encoding="utf-8-sig")

            env = {
                **os.environ,
                "USERPROFILE": str(home),
                "LOCALAPPDATA": str(local),
                # Put Microsoft\WindowsApps FIRST in PATH to simulate Machine PATH shadowing User Python!
                "PATH": str(fake_winapps) + ";" + os.environ.get("PATH", ""),
            }
            res = run_ps(
                f'. "{ROOT / "native/user-dependencies.ps1"}"\n'
                f'. "{ROOT / "windows-installer/manage-instance.ps1"}"\n'
                f'. "{runner_fns}"\n'
                f'. "{inst_fns}"\n'
                "$ErrorActionPreference = 'Stop'\n"
                f"if (Test-PythonCandidate '{stub_py}') {{ throw 'windowsapps-stub-accepted' }}\n"
                "Optimize-UserDependencyPath\n"
                "$parts = @($env:Path -split ';' | Where-Object { $_ })\n"
                "if ($parts[0] -like '*\\WindowsApps*') { throw 'windowsapps-not-demoted-userdeps' }\n"
                "Optimize-NativeProcessPath\n"
                "$parts2 = @($env:Path -split ';' | Where-Object { $_ })\n"
                "if ($parts2[0] -like '*\\WindowsApps*') { throw 'windowsapps-not-demoted-native' }\n"
                "$realPy = Resolve-VerifiedPythonExe\n"
                "if (-not $realPy -or $realPy -like '*\\WindowsApps\\*') { throw ('bad-resolved-py:' + $realPy) }\n"
                "$managePy = Resolve-EmTroLyPythonExe\n"
                "if (-not $managePy -or $managePy -like '*\\WindowsApps\\*') { throw ('bad-manage-py:' + $managePy) }\n"
                "\n"
                "# Case A: Empty openclaw directory must be recoverable (not block Step 4!)\n"
                "$oc = Join-Path $env:USERPROFILE 'openclaw'\n"
                "[void][IO.Directory]::CreateDirectory($oc)\n"
                "if (-not (Test-IsRecoverableIncompleteOpenClawDir $oc)) { throw 'empty-openclaw-not-recoverable' }\n"
                "if (-not (Test-CanResetIncompleteRoot $oc)) { throw 'empty-openclaw-not-resettable' }\n"
                "\n"
                "# Case B: Half-installed openclaw (has openclaw.json + telegram.token, missing launchers, no marker)\n"
                "[IO.File]::WriteAllText((Join-Path $oc 'openclaw.json'), '{}')\n"
                "[IO.File]::WriteAllText((Join-Path $oc 'telegram.token'), 'tok')\n"
                "[void][IO.Directory]::CreateDirectory((Join-Path $oc 'workspace'))\n"
                "if (-not (Test-IsBrokenHalfInstalledOpenClawDir $oc)) { throw 'half-installed-not-detected' }\n"
                "if (-not (Test-CanResetIncompleteRoot $oc)) { throw 'half-installed-not-resettable' }\n"
                "\n"
                "# Case C: Orphaned Step 3/4 marker (.emtroly-installing.json with dead PID 999999) makes OpenClawInstalled=false\n"
                "[IO.File]::WriteAllText((Join-Path $oc '.emtroly-installing.json'), '{\"pid\":999999,\"name\":\"emtroly\"}')\n"
                "$stOrphan = Get-EmTroLyInstalledState\n"
                "if ($stOrphan.OpenClawInstalled) { throw 'orphaned-marker-treated-as-installed' }\n"
                "Remove-IncompleteOpenClawDirectory -DirPath $oc -AllowBrokenConfig\n"
                "if ((Test-Path -LiteralPath $oc) -and @(Get-ChildItem -LiteralPath $oc -Force).Count -gt 0) { throw 'incomplete-not-cleaned' }\n"
                "\n"
                "# Case D: Foreign user file inside openclaw is STILL strictly protected\n"
                "[void][IO.Directory]::CreateDirectory($oc)\n"
                "[IO.File]::WriteAllText((Join-Path $oc 'my-important-notes.docx'), 'keep')\n"
                "if (Test-IsRecoverableIncompleteOpenClawDir $oc) { throw 'foreign-file-not-protected-1' }\n"
                "if (Test-IsBrokenHalfInstalledOpenClawDir $oc) { throw 'foreign-file-not-protected-2' }\n"
                "if (Test-CanResetIncompleteRoot $oc) { throw 'foreign-file-not-protected-3' }\n"
                "Write-Output 'GIANGLE_4_BUGS_FIXED_OK'\n",
                env=env,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertIn("GIANGLE_4_BUGS_FIXED_OK", res.stdout)

    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_clean_pc_8point_hardening_8dot3_paths_portable_toolchains_and_blackbox_log(self):
        import ctypes
        from unittest.mock import MagicMock, patch

        # 1. Windows 8.3 short paths (~1) & mixed-case drive letters in install_windows_cli.py
        scripts_dir = ROOT / "native/skills/tao-tro-ly-openclaw-windows-macos-linux/scripts"
        sys.path.insert(0, str(scripts_dir))
        try:
            import install_windows_cli
        finally:
            sys.path.pop(0)

        def to_short_or_mixed_case(p: Path) -> str:
            buf = ctypes.create_unicode_buffer(1024)
            n = ctypes.windll.kernel32.GetShortPathNameW(str(p), buf, 1024)
            candidate = buf.value if n > 0 and buf.value else str(p)
            if len(candidate) >= 2 and candidate[1] == ":":
                candidate = candidate[0].swapcase() + candidate[1:]
            return candidate

        with tempfile.TemporaryDirectory(prefix="emtroly-8dot3-") as td:
            long_home = Path(td).resolve() / "Nguyễn Văn Ánh Công Ty TNHH"
            long_state = long_home / "openclaw"
            long_local = long_home / "AppData/Local"
            long_node_dir = long_local / "MemberInstaller/dependencies/node-v24.21.0-win-x64"
            for d in (long_state, long_local, long_node_dir):
                d.mkdir(parents=True, exist_ok=True)
            long_node = long_node_dir / "node.exe"
            long_node.write_text("fixture-node", encoding="utf-8")
            long_entry = long_state / "openclaw.mjs"
            long_entry.write_text("fixture-entry", encoding="utf-8")
            (long_state / "openclaw.json").write_text(json.dumps({"gateway": {"port": 19789}}), encoding="utf-8")

            short_home = to_short_or_mixed_case(long_home)
            short_state = to_short_or_mixed_case(long_state)
            short_local = to_short_or_mixed_case(long_local)
            short_node = to_short_or_mixed_case(long_node)
            short_entry = to_short_or_mixed_case(long_entry)

            mock_reg = MagicMock()
            mock_reg.REG_SZ, mock_reg.REG_EXPAND_SZ = 1, 2
            mock_reg.KEY_QUERY_VALUE, mock_reg.KEY_SET_VALUE = 1, 2
            mock_reg.QueryValueEx.return_value = (r"C:\Windows\System32", 2)
            with (
                patch.dict(os.environ, {"USERPROFILE": short_home, "LOCALAPPDATA": short_local, "PATH": r"C:\Windows\System32"}),
                patch.dict(sys.modules, {"winreg": mock_reg}),
                patch.object(install_windows_cli.shutil, "which", return_value=None),
                patch.object(install_windows_cli, "broadcast_environment", return_value=True),
                patch.object(
                    install_windows_cli.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess([], 0, "OpenClaw 2026.11.4\n", ""),
                ),
            ):
                cli_res = install_windows_cli.install(short_state, short_home, short_node, short_entry, 19789)
                self.assertTrue(cli_res["default_cli"])
                self.assertEqual(Path(cli_res["environment"]["OPENCLAW_STATE_DIR"]), long_state)
                self.assertTrue((long_local / "OpenClaw/bin/openclaw.cmd").is_file())

        # 2. Portable Python/Node resolution in module-manager.ps1 when System PATH only has WindowsApps\python.exe stub
        with tempfile.TemporaryDirectory(prefix="emtroly-modmgr-cleanpc-") as td2:
            temp2 = Path(td2)
            fake_winapps = temp2 / "Microsoft/WindowsApps"
            fake_winapps.mkdir(parents=True)
            (fake_winapps / "python.exe").write_bytes(b"")

            oc_dir = temp2 / "openclaw"
            oc_dir.mkdir()
            shutil.copy2(ROOT / "native/module-manager.ps1", oc_dir / "module-manager.ps1")
            shutil.copy2(ROOT / "native/windows-instance.ps1", oc_dir / "windows-instance.ps1")
            (oc_dir / "module-manager.py").write_text(
                "import sys; print('MODMGR_REAL_PY_OK:' + sys.argv[1])\n",
                encoding="utf-8",
            )
            real_node = NODE or str(Path(sys.executable))
            (oc_dir / "installer-instance.json").write_text(
                json.dumps(
                    {
                        "root": str(oc_dir),
                        "profile": "member-emtroly",
                        "cli_entry": str(oc_dir / "cli.mjs"),
                        "port": 19789,
                        "python": sys.executable,
                        "node": real_node,
                    }
                ),
                encoding="utf-8",
            )
            sys32 = str(Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32")
            stripped_env = {
                **os.environ,
                "USERPROFILE": str(temp2),
                "LOCALAPPDATA": str(temp2 / "local"),
                "PATH": str(fake_winapps) + ";" + sys32,
            }
            mm_res = run_ps(f'& "{oc_dir / "module-manager.ps1"}" -Command list\nexit $LASTEXITCODE\n', env=stripped_env)
            self.assertEqual(mm_res.returncode, 0, mm_res.stdout + mm_res.stderr)
            self.assertIn("MODMGR_REAL_PY_OK:list", mm_res.stdout)

        # 3. Unconfigured %APPDATA%\npm\openclaw.cmd auto-backup + persistent redacted install-latest.log + Support Report [6]
        runner = ROOT / "windows-installer/run-native-install.ps1"
        helpers = ROOT / "windows-installer/wizard-helpers.ps1"
        secret_tok = "888999:CLEANPC_SECRET_TOKEN_ABCDEFGHIJKLMNO"
        secret_key = "sk-cleanpc-secret-api-key-987654321"
        with tempfile.TemporaryDirectory(prefix="emtroly-npmshim-log-") as td3:
            root3 = Path(td3)
            home3 = root3 / "home"
            local3 = root3 / "local"
            roaming3 = root3 / "roaming"
            npm_global = roaming3 / "npm"
            for d in (home3, local3, npm_global):
                d.mkdir(parents=True)
            # Seed leftover manual `npm i -g openclaw` shims in %APPDATA%\npm (with NO ~/.openclaw/openclaw.json)
            (npm_global / "openclaw.cmd").write_text("@echo off\r\necho broken-global-openclaw\r\nexit /b 1\r\n", encoding="ascii")
            (npm_global / "openclaw.ps1").write_text("exit 1\n", encoding="utf-8")

            payload3 = root3 / "payload"
            (payload3 / "windows-installer").mkdir(parents=True)
            shutil.copy2(ROOT / "windows-installer/validation.ps1", payload3 / "windows-installer")
            shutil.copy2(ROOT / "windows-installer/wizard-helpers.ps1", payload3 / "windows-installer")
            (payload3 / "windows-installer/verify-openclaw-command.ps1").write_text("exit 0\n", encoding="utf-8-sig")
            (payload3 / "install-native-windows.ps1").write_text(
                "param($Name,$OwnerIds,$GroupId,$AssistantName,$BaseUrl,$Model,$Profile,$Modules,$QrOwnerId,$OpenClawVersion,$InstallMode,$InstallRoot,$GatewayPort,$Audience,$Addressing,$Style,[switch]$UserInstall,$CredentialData)\n"
                f"if ($env:EMTROLY_INSTALL_LOG_FILE) {{ [IO.File]::AppendAllText($env:EMTROLY_INSTALL_LOG_FILE, \"[step] token={secret_tok} key={secret_key}`r`n\") }}\n"
                "throw 'Private OpenClaw installation failed.'\n",
                encoding="utf-8-sig",
            )
            settings_path = root3 / "settings.json"
            status_path = root3 / "status.txt"
            settings_path.write_text(
                json.dumps(
                    {
                        "member": "emtroly",
                        "assistant_name": "Em Tro Ly",
                        "base_url": "https://provider.example/v1",
                        "model": "gpt-6.2-sol",
                        "owner_ids": "123456789",
                        "group_id": "",
                        "gateway_port": "0",
                        "audience": "",
                        "addressing": "",
                        "style": "",
                        "accept_full_access": True,
                        "configure_zalo": False,
                        "skip_editor": True,
                        "qr_owner_id": "",
                        "telegram_token": secret_tok,
                        "ai_api_key": secret_key,
                    }
                ),
                encoding="utf-8",
            )
            clean_sys_path = os.pathsep.join(
                p for p in os.environ.get("PATH", "").split(os.pathsep) if "openclaw" not in p.lower()
            )
            env3 = {
                **os.environ,
                "USERPROFILE": str(home3),
                "LOCALAPPDATA": str(local3),
                "APPDATA": str(roaming3),
                "PATH": str(npm_global) + os.pathsep + clean_sys_path,
                "TEST_MODE": "cleanpc-log-test",
            }
            r3 = run_ps(
                "function global:Invoke-RestMethod {\n"
                "  param([switch]$UseBasicParsing, $Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection)\n"
                "  if ($Uri -match '/models$') { return @{ data = @(@{ id = 'gpt-6.2-sol' }) } }\n"
                "  if ($Uri -match '/getMe$') { return @{ ok = $true; result = @{ is_bot = $true } } }\n"
                "  throw $Uri\n"
                "}\n"
                f'& "{runner}" -SettingsFile "{settings_path}" -PayloadRoot "{payload3}" -LogFile "{status_path}"\n'
                "exit $LASTEXITCODE\n",
                env=env3,
            )
            self.assertNotEqual(r3.returncode, 0)
            # Leftover %APPDATA%\npm\openclaw.cmd must have been quarantined instead of causing cli-probe-conflict!
            self.assertFalse((npm_global / "openclaw.cmd").exists(), "Stale npm global openclaw.cmd was not backed up")
            self.assertEqual(len(list(npm_global.glob("backup-openclaw-shims-*/openclaw.cmd"))), 1)
            self.assertNotIn("cli-probe-conflict", status_path.read_text(encoding="utf-8"))

            # Persistent black-box log must exist and scrub all secrets in .diag.json & Export-EmTroLySupportReport
            latest_log = local3 / "EmTroLyUI/logs/install-latest.log"
            self.assertTrue(latest_log.is_file(), "Missing persistent EmTroLyUI/logs/install-latest.log")
            diag_data = json.loads(Path(str(status_path) + ".diag.json").read_text(encoding="utf-8"))
            self.assertNotIn(secret_tok, diag_data["technicalDetail"])
            self.assertNotIn(secret_key, diag_data["technicalDetail"])
            self.assertIn("Private OpenClaw installation failed.", diag_data["technicalDetail"])

            report_out = root3 / "support-report.txt"
            rep_res = run_ps(
                f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{helpers}", [Text.Encoding]::UTF8)))\n'
                f'Export-EmTroLySupportReport -OutputPath "{report_out}" -PayloadRoot "{ROOT}" | Out-Null\n',
                env=env3,
            )
            self.assertEqual(rep_res.returncode, 0, rep_res.stdout + rep_res.stderr)
            rep_text = report_out.read_text(encoding="utf-8")
            self.assertIn("[6] NHAT KY CAI DAT GAN NHAT", rep_text)
            self.assertNotIn(secret_tok, rep_text)
            self.assertNotIn(secret_key, rep_text)

        # 4. Static & WSH fallback check in member-vps-installer.nsi & launch-wizard.vbs
        nsi_text = (ROOT / "windows-installer/member-vps-installer.nsi").read_text(encoding="utf-8")
        self.assertIn("fallback_ps:", nsi_text)
        self.assertIn("wsh.ok", nsi_text)

    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_status_file_lock_resilience_and_modular_installed_state_clean_errors(self):
        runner = ROOT / "windows-installer/run-native-install.ps1"
        helpers = ROOT / "windows-installer/wizard-helpers.ps1"
        with tempfile.TemporaryDirectory(prefix="emtroly-status-lock-") as td:
            root = Path(td)
            home = root / "home"
            local = root / "local"
            home.mkdir()
            local.mkdir()

            # Pre-seed installed Codex CLI, Antigravity IDE, and Codex Extension so modular run exercises rapid skip status writes
            codex_dir = local / "EmTroLy/Codex"
            ext_dir = local / "EmTroLy/Antigravity/Extensions/openai.chatgpt-26.51111.21308/bin/windows-x86_64"
            ide_dir = local / "Programs/EmTroLy-Antigravity-IDE-0123456789abcdef0123456789abcdef/resources/app"
            bin_dir = local / "OpenClaw/bin"
            desk_dir = root / "desktop"
            for d in (codex_dir, ext_dir, ide_dir, bin_dir, desk_dir):
                d.mkdir(parents=True, exist_ok=True)
            (codex_dir / "config.toml").write_text('model = "gpt-6.2-sol"\n', encoding="utf-8")
            (codex_dir / "auth.json").write_text('{"OPENAI_API_KEY":"sk-lock-test"}', encoding="utf-8")
            (bin_dir / "codex-emtroly.cmd").write_text("@echo off\r\n", encoding="ascii")
            (ext_dir / "codex.exe").write_text("bin", encoding="utf-8")
            (ext_dir.parents[1] / "package.json").write_text(
                json.dumps({"publisher": "openai", "name": "chatgpt", "version": "26.51111.21308"}),
                encoding="utf-8",
            )
            (ide_dir.parents[1] / "Antigravity IDE.exe").write_text("exe", encoding="utf-8")
            (ide_dir / "product.json").write_text(
                json.dumps({"applicationName": "antigravity-ide", "version": "2.7.0"}),
                encoding="utf-8",
            )

            payload = root / "payload"
            (payload / "windows-installer").mkdir(parents=True)
            for fname in ("validation.ps1", "codex-cli.ps1", "auto-heal-codex.ps1", "manage-instance.ps1", "wizard-helpers.ps1"):
                shutil.copy2(ROOT / "windows-installer" / fname, payload / "windows-installer" / fname)

            settings_path = root / "settings.json"
            status_path = root / "status.txt"
            status_path.write_text("initial", encoding="utf-8")
            settings_path.write_text(
                json.dumps(
                    {
                        "member": "emtroly",
                        "components": ["codex-cli", "antigravity-ide", "codex-extension"],
                        "force_reinstall": False,
                        "base_url": "https://codex.anhlaptrinh.vn/v1",
                        "model": "gpt-6.2-sol",
                        "ai_api_key": "sk-lock-test-key-123456789",
                    }
                ),
                encoding="utf-8",
            )
            env = {
                **os.environ,
                "USERPROFILE": str(home),
                "LOCALAPPDATA": str(local),
                "EMTROLY_TEST_DESKTOP_DIR": str(desk_dir),
            }

            # 1. Hold an EXCLUSIVE lock (FileShare.None) on status.txt during modular run -> must NEVER crash Write-SafeStatus!
            with open(status_path, "r+b") as raw_fh:
                import msvcrt

                msvcrt.locking(raw_fh.fileno(), msvcrt.LK_NBLCK, 1)
                try:
                    res_locked = run_ps(
                        "function global:Invoke-RestMethod {\n"
                        "  param([switch]$UseBasicParsing, $Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection)\n"
                        "  if ($Uri -match '/models$') { return @{ data = @(@{ id = 'gpt-6.2-sol' }) } }\n"
                        "  throw $Uri\n"
                        "}\n"
                        f'& "{runner}" -SettingsFile "{settings_path}" -PayloadRoot "{payload}" -LogFile "{status_path}" -Components "codex-cli,antigravity-ide"\n'
                        "exit $LASTEXITCODE\n",
                        env=env,
                        timeout=40,
                    )
                finally:
                    raw_fh.seek(0)
                    msvcrt.locking(raw_fh.fileno(), msvcrt.LK_UNLCK, 1)

            self.assertEqual(res_locked.returncode, 0, res_locked.stdout + res_locked.stderr)
            install_log = (local / "EmTroLyUI/logs/install-latest.log").read_text(encoding="utf-8")
            self.assertNotIn("Get-EmTroLyInstalledState", install_log)
            self.assertNotIn("FINAL_ERROR", install_log)
            self.assertIn("Hoàn tất:", install_log)

            # 2. Verify concurrent Read-EmTroLySharedUtf8File + Write-EmTroLySharedStatusFile never block each other
            res_shared = run_ps(
                f'. ([ScriptBlock]::Create([IO.File]::ReadAllText("{helpers}", [Text.Encoding]::UTF8)))\n'
                "$ErrorActionPreference = 'Stop'\n"
                "$global:Error.Clear()\n"
                "$st = Get-EmTroLyModularStatus\n"
                "if ($global:Error.Count -gt 0) { throw ('unexpected-global-error:' + $global:Error[0]) }\n"
                f"$share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete\n"
                f"$readerStream = New-Object System.IO.FileStream('{status_path}', [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)\n"
                "try {\n"
                f"  if (-not (Write-EmTroLySharedStatusFile -Path '{status_path}' -Text 'Hoàn tất: Không xung đột khóa file!')) {{ throw 'shared-write-failed' }}\n"
                f"  $readBack = Read-EmTroLySharedUtf8File -Path '{status_path}'\n"
                "  if ($readBack -cne 'Hoàn tất: Không xung đột khóa file!') { throw ('shared-read-mismatch:' + $readBack) }\n"
                "} finally {\n"
                "  $readerStream.Dispose()\n"
                "}\n"
                "Write-Output 'SHARED_LOCK_AND_CLEAN_ERRORS_OK'\n",
                env=env,
            )
            self.assertEqual(res_shared.returncode, 0, res_shared.stdout + res_shared.stderr)
            self.assertIn("SHARED_LOCK_AND_CLEAN_ERRORS_OK", res_shared.stdout)


class Step3CleanPcAndFailureUiTests(unittest.TestCase):
    def test_step3_parallel_downloader_uses_runspaces_never_threadpool_events(self):
        deps_src = (ROOT / "native" / "user-dependencies.ps1").read_text(encoding="utf-8-sig")
        wizard_src = (ROOT / "windows-installer" / "wizard.ps1").read_text(encoding="utf-8-sig")
        runner_src = (ROOT / "windows-installer" / "run-native-install.ps1").read_text(encoding="utf-8-sig")
        self.assertNotIn(
            "add_DownloadProgressChanged",
            deps_src,
            "WebClient.add_DownloadProgressChanged fires on ThreadPool without Runspace and crashes PS 5.1 silently",
        )
        self.assertIn("RunspaceFactory", deps_src)
        self.assertIn("Sanitize-WizardFailureSummary", wizard_src)
        self.assertIn("New-UnexpectedExitDiagnosticPayload", wizard_src)
        self.assertIn("OpenTelegramWebBtn", wizard_src)
        self.assertIn("https://web.telegram.org/", wizard_src)
        self.assertIn("'dependencies'", wizard_src)
        self.assertIn("ERR_SSL_CIPHER_OPERATION_FAILED", runner_src)
        native_src = (ROOT / "install-native-windows.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("--tls-max-v1.2", native_src)
        self.assertIn("OPENSSL_ia32cap", native_src)
        self.assertIn("registry.npmmirror.com", native_src)
        self.assertIn("if (Test-Path Env:NODE_OPTIONS)", native_src)
        self.assertNotIn("New-Object System.Diagnostics.ProcessStartInfo(", native_src)
        heal_src = (ROOT / "windows-installer" / "auto-heal-codex.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("$stdinPipeFailed", heal_src)
        self.assertIn("$stage = 'dependencies'", runner_src)

        if not sys.platform.startswith("win"):
            return

        import http.server
        import socketserver
        import threading

        class DualPayloadHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                payload = (b"NODE_" * 4096) if "node" in self.path else (b"FFMPEG_" * 4096)
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, format, *args):
                return

        class ReusableTcpServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True

        server = ReusableTcpServer(("127.0.0.1", 0), DualPayloadHandler)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                helpers_path = str(ROOT / "windows-installer" / "wizard-helpers.ps1")
                deps_path = str(ROOT / "native" / "user-dependencies.ps1")
                out1 = str(tmp_path / "node.part")
                out2 = str(tmp_path / "ffmpeg.part")
                test_ps1 = tmp_path / "verify_step3_and_sanitize.ps1"
                test_ps1.write_text(
                    "$ErrorActionPreference = 'Stop'\n"
                    "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8\n"
                    f". '{helpers_path}'\n"
                    "$sanitized = Sanitize-WizardFailureSummary -Summary 'Đang kiểm tra và cài Node.js, Python, FFmpeg nếu máy còn thiếu…' -ExitCode 2 -LastStepIndex 3\n"
                    "if ($sanitized -match '^(?i)Đang') { throw ('in-progress-leaked:' + $sanitized) }\n"
                    "if ($sanitized -notmatch 'Bước 3') { throw ('missing-step:' + $sanitized) }\n"
                    "$diag = New-UnexpectedExitDiagnosticPayload -Summary 'Đang tải...' -ExitCode 2 -LastStepIndex 3\n"
                    "if ($diag.stage -ne 'dependencies') { throw ('bad-stage:' + $diag.stage) }\n"
                    "if ($diag.friendlyMessage -match '^(?i)Đang') { throw ('diag-in-progress:' + $diag.friendlyMessage) }\n"
                    "$tokens = $null; $parseErrs = $null\n"
                    f"$ast = [System.Management.Automation.Language.Parser]::ParseFile('{deps_path}', [ref]$tokens, [ref]$parseErrs)\n"
                    "if ($parseErrs.Count -gt 0) { throw ('parse-err:' + $parseErrs[0].Message) }\n"
                    "$assign = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$workerScript' }, $true)\n"
                    "if (-not $assign) { throw 'workerScript-not-found' }\n"
                    "$sbText = $assign.Right.Expression.ScriptBlock.Extent.Text\n"
                    "$innerText = $sbText.Substring(1, $sbText.Length - 2)\n"
                    "$workerSb = [scriptblock]::Create($innerText)\n"
                    "$map = [hashtable]::Synchronized(@{\n"
                    "  node = [hashtable]::Synchronized(@{ Received = 0L; Total = 20480L; Error = '' })\n"
                    "  ffmpeg = [hashtable]::Synchronized(@{ Received = 0L; Total = 28672L; Error = '' })\n"
                    "})\n"
                    f"$items = @(@{{ Key='node'; Uri='http://127.0.0.1:{port}/node.zip'; Out='{out1}' }}, @{{ Key='ffmpeg'; Uri='http://127.0.0.1:{port}/ffmpeg.zip'; Out='{out2}' }})\n"
                    "$active = @()\n"
                    "foreach ($it in $items) {\n"
                    "  $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace(); $rs.Open()\n"
                    "  $ps = [System.Management.Automation.PowerShell]::Create(); $ps.Runspace = $rs\n"
                    "  [void]$ps.AddScript($workerSb).AddArgument([string]$it.Uri).AddArgument([string]$it.Out).AddArgument([string]$it.Key).AddArgument($map)\n"
                    "  $active += [pscustomobject]@{ Ps=$ps; Rs=$rs; Handle=$ps.BeginInvoke() }\n"
                    "}\n"
                    "foreach ($a in $active) {\n"
                    "  $r = $a.Ps.EndInvoke($a.Handle)\n"
                    "  if (-not $r -or ($r | Select-Object -Last 1) -ne $true) { throw 'parallel-worker-failed' }\n"
                    "  $a.Ps.Dispose(); $a.Rs.Close(); $a.Rs.Dispose()\n"
                    "}\n"
                    "if ($map['node'].Received -ne 20480 -or $map['ffmpeg'].Received -ne 28672) { throw ('bad-bytes:' + $map['node'].Received + '/' + $map['ffmpeg'].Received) }\n"
                    "Write-Output 'STEP3_RUNSPACE_AND_SANITIZE_OK'\n",
                    encoding="utf-8-sig",
                )
                res = subprocess.run(
                    ["powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(test_ps1)],
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                )
                self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
                self.assertIn("STEP3_RUNSPACE_AND_SANITIZE_OK", res.stdout)
        finally:
            server.shutdown()
            server.server_close()

    def test_openclaw_ssl_failure_stays_step4_and_autoheal_broken_pipe_never_masks_root_error(self):
        if not sys.platform.startswith("win"):
            return

        with tempfile.TemporaryDirectory(prefix="emtroly-ssl-pipe-") as td:
            root = Path(td)
            home = root / "home"
            local = root / "local"
            payload = root / "payload"
            heal_bin = local / "EmTroLy/AutoHealCli/node_modules/.bin"
            for d in (home, local, payload / "windows-installer", heal_bin):
                d.mkdir(parents=True, exist_ok=True)

            # Copy production runner & helpers
            for fname in ("run-native-install.ps1", "validation.ps1", "wizard-helpers.ps1", "auto-heal-codex.ps1"):
                shutil.copy2(ROOT / "windows-installer" / fname, payload / "windows-installer" / fname)
            (payload / "windows-installer/verify-openclaw-command.ps1").write_text("exit 0\n", encoding="utf-8-sig")

            # Broken codex.cmd that exits immediately without reading stdin (triggers WriteLine broken pipe if unguarded)
            (heal_bin / "codex.cmd").write_text("@echo off\r\necho immediate-exit\r\nexit /b 1\r\n", encoding="ascii")

            # Fake installer emitting historical Step 3 line + OpenClaw ERR_SSL_CIPHER_OPERATION_FAILED
            (payload / "install-native-windows.ps1").write_text(
                "param($Name,$OwnerIds,$GroupId,$AssistantName,$BaseUrl,$Model,$Profile,$Modules,$QrOwnerId,$OpenClawVersion,$InstallMode,$InstallRoot,$GatewayPort,$Audience,$Addressing,$Style,[switch]$UserInstall,$CredentialData)\n"
                "if ($env:EMTROLY_INSTALL_LOG_FILE) {\n"
                "  [IO.File]::AppendAllText($env:EMTROLY_INSTALL_LOG_FILE, \"[native] STATUS: Đang kiểm tra và cài Node.js, Python, FFmpeg nếu máy còn thiếu…`r`n\", [Text.UTF8Encoding]::new($false))\n"
                "  [IO.File]::AppendAllText($env:EMTROLY_INSTALL_LOG_FILE, \"[native] npm install attempt 3/3 failed (exit=1): npm error code ERR_SSL_CIPHER_OPERATION_FAILED`r`n\", [Text.UTF8Encoding]::new($false))\n"
                "}\n"
                "throw 'Private OpenClaw installation failed.'\n",
                encoding="utf-8-sig",
            )

            settings_path = root / "settings.json"
            status_path = root / "status.txt"
            settings_path.write_text(
                json.dumps(
                    {
                        "member": "emtroly",
                        "assistant_name": "Em Tro Ly",
                        "base_url": "https://provider.example/v1",
                        "model": "gpt-6.2-sol",
                        "owner_ids": "123456789",
                        "group_id": "",
                        "gateway_port": "0",
                        "audience": "",
                        "addressing": "",
                        "style": "",
                        "accept_full_access": True,
                        "configure_zalo": False,
                        "skip_editor": True,
                        "qr_owner_id": "",
                        "telegram_token": "123456:SSL_TEST_TOKEN_ABCDEFGHIJKLMNO",
                        "ai_api_key": "sk-ssl-test-key-123456",
                    }
                ),
                encoding="utf-8",
            )
            clean_ssl_path = os.pathsep.join(
                p for p in os.environ.get("PATH", "").split(os.pathsep) if "openclaw" not in p.lower()
            )
            env = {
                **os.environ,
                "USERPROFILE": str(home),
                "LOCALAPPDATA": str(local),
                "PATH": str(heal_bin) + os.pathsep + clean_ssl_path,
            }
            driver = root / "run_ssl_pipe.ps1"
            driver.write_text(
                "$ErrorActionPreference = 'Stop'\n"
                "function global:Invoke-RestMethod {\n"
                "  param([switch]$UseBasicParsing, $Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection)\n"
                "  if ($Uri -match '/models$') { return @{ data = @(@{ id = 'gpt-6.2-sol' }) } }\n"
                "  if ($Uri -match '/getMe$') { return @{ ok = $true; result = @{ is_bot = $true } } }\n"
                "  throw $Uri\n"
                "}\n"
                f"& '{payload / 'windows-installer/run-native-install.ps1'}' -SettingsFile '{settings_path}' -PayloadRoot '{payload}' -LogFile '{status_path}'\n"
                "exit $LASTEXITCODE\n",
                encoding="utf-8-sig",
            )
            res = subprocess.run(
                ["powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(driver)],
                env=env,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=45,
            )
            self.assertNotEqual(res.returncode, 0)
            diag_data = json.loads(Path(str(status_path) + ".diag.json").read_text(encoding="utf-8"))
            self.assertEqual(diag_data["stage"], "install", diag_data)
            self.assertEqual(diag_data["code"], "Private OpenClaw installation failed.", diag_data)
            self.assertNotIn("The pipe has been ended", diag_data["code"])
            self.assertIn("ERR_SSL_CIPHER_OPERATION_FAILED", diag_data["friendlyMessage"])

    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_autoheal_rejects_broken_npm_cli_without_win32_optional_and_recovers(self):
        import zipfile
        codex_ps1 = ROOT / "windows-installer/codex-cli.ps1"
        heal_ps1 = ROOT / "windows-installer/auto-heal-codex.ps1"
        with tempfile.TemporaryDirectory(prefix="emtroly-heal-win32-") as td:
            root = Path(td)
            local = root / "local"
            heal_root = local / "EmTroLy/AutoHealCli"
            heal_bin = heal_root / "node_modules/.bin"
            codex_pkg_bin = heal_root / "node_modules/@openai/codex/bin"
            for d in (heal_bin, codex_pkg_bin):
                d.mkdir(parents=True, exist_ok=True)
            (heal_bin / "codex.cmd").write_text("@echo off\r\necho fake-npm-wrapper\r\nexit /b 1\r\n", encoding="ascii")
            # Presence of @openai/codex/bin/codex.js without @openai/codex-win32-x64 means broken npm install
            (codex_pkg_bin / "codex.js").write_text("// missing @openai/codex-win32-x64", encoding="utf-8")

            # Also seed a cached VSIX with extension/bin/windows-x86_64/codex.exe so offline recovery succeeds immediately
            vsix_path = local / "EmTroLy/codex-26.51111.21308.vsix"
            with zipfile.ZipFile(vsix_path, "w") as zf:
                zf.writestr("extension/bin/windows-x86_64/codex.exe", "FAKE_CODEX_EXE_BYTES")

            sys32 = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32")
            clean_path = os.pathsep.join([sys32, os.path.join(sys32, "WindowsPowerShell", "v1.0")])
            res = subprocess.run(
                [
                    "powershell.exe",
                    "-NoLogo",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-Command",
                    "$ErrorActionPreference = 'Stop'\n"
                    f". '{codex_ps1}'\n"
                    f". '{heal_ps1}'\n"
                    "$info = Find-EmTroLyCodexCli\n"
                    "if ($info.Available) { throw 'broken-autoheal-marked-available' }\n"
                    "if (Test-EmTroLyCodexBinaryRunnable -Executable (Join-Path $env:LOCALAPPDATA 'EmTroLy\\AutoHealCli\\node_modules\\.bin\\codex.cmd')) { throw 'broken-autoheal-marked-runnable' }\n"
                    "$recovered = Ensure-AutoHealCodexBinary\n"
                    "if ($recovered -notmatch 'EmTroLy\\\\Codex\\\\bin\\\\codex\\.exe$' -or -not (Test-Path -LiteralPath $recovered)) { throw ('did-not-recover-from-vsix:' + $recovered) }\n"
                    "$srcHeal = [IO.File]::ReadAllText('" + str(heal_ps1).replace("'", "''") + "', [Text.Encoding]::UTF8)\n"
                    "if ($srcHeal -notmatch '--include=optional' -or $srcHeal -notmatch '@openai/codex-win32-x64') { throw 'optional-win32-install-flag-missing' }\n"
                    "Write-Output 'AUTOHEAL_WIN32_RECOVERY_OK'\n",
                ],
                env={**os.environ, "LOCALAPPDATA": str(local), "USERPROFILE": str(root), "PATH": clean_path},
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=30,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertIn("AUTOHEAL_WIN32_RECOVERY_OK", res.stdout)

    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_editor_download_resumes_range_across_truncated_streams(self):
        import http.server
        import threading

        editor_ps1 = ROOT / "windows-installer/install-antigravity-codex.ps1"
        part1 = b"A" * 65536
        part2 = b"B" * 65536
        part3 = b"C" * 32768
        payload_bytes = part1 + part2 + part3
        expected_hash = hashlib.sha256(payload_bytes).hexdigest()
        req_count = {"n": 0}

        class FlakyRangeHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                req_count["n"] += 1
                rng = self.headers.get("Range")
                if not rng:
                    # First request lies about Content-Length then truncates mid-stream after part1
                    self.send_response(200)
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header("Content-Length", str(len(payload_bytes)))
                    self.end_headers()
                    self.wfile.write(part1)
                    self.wfile.flush()
                    self.connection.close()
                    return
                start = int(rng.replace("bytes=", "").split("-")[0])
                rem = payload_bytes[start:]
                chunk = rem[:65536] if len(rem) > 65536 else rem
                end = start + len(rem) - 1
                self.send_response(206)
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(payload_bytes)}")
                self.send_header("Content-Length", str(len(rem)))
                self.end_headers()
                self.wfile.write(chunk)
                self.wfile.flush()
                if len(chunk) < len(rem):
                    self.connection.close()

            def log_message(self, format, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FlakyRangeHandler)
        port = server.server_address[1]
        t = threading.Thread(target=server.serve_forever, daemon=True)
        t.start()
        try:
            with tempfile.TemporaryDirectory(prefix="emtroly-range-dl-") as td:
                out_file = Path(td) / "Antigravity IDE.exe"
                status_file = Path(td) / "status.txt"
                res = run_ps(
                    "$ErrorActionPreference = 'Stop'\n"
                    f"$tokens = $null; $errs = $null\n"
                    f"$ast = [Management.Automation.Language.Parser]::ParseFile('{editor_ps1}', [ref]$tokens, [ref]$errs)\n"
                    "$fn = @($ast.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-VerifiedDownload' }, $true))[0]\n"
                    "Invoke-Expression $fn.Extent.Text\n"
                    f"$StatusFile = '{status_file}'\n"
                    "function Write-EditorStatus([string]$Text) { [IO.File]::WriteAllText($StatusFile, $Text, [Text.UTF8Encoding]::new($false)) }\n"
                    f"Get-VerifiedDownload -Url 'http://127.0.0.1:{port}/Antigravity%20IDE.exe' -Path '{out_file}' -Hash '{expected_hash}'\n"
                    f"$gotHash = (Get-FileHash -LiteralPath '{out_file}' -Algorithm SHA256).Hash\n"
                    f"if ($gotHash -ine '{expected_hash}') {{ throw 'hash-mismatch-after-range-resume' }}\n"
                    "Write-Output 'RANGE_RESUME_OK'\n"
                )
                self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
                self.assertIn("RANGE_RESUME_OK", res.stdout)
                self.assertGreaterEqual(req_count["n"], 2)
        finally:
            server.shutdown()
            server.server_close()

    def test_modular_install_keeps_inline_view_and_dotnet48_xaml_clean(self):
        wiz_text = (ROOT / "windows-installer/wizard.ps1").read_text(encoding="utf-8-sig")
        for control_name in (
            "ModProgressCard",
            "ModActiveCompPill",
            "ModActiveCompText",
            "ModProgressStatusText",
            "ModProgressPercentText",
            "ModProgressBar",
            "ModProgressSubText",
            "ModFailureActions",
            "ModErrorStepText",
            "ModErrorSummaryHeading",
            "ModErrorDetailBox",
            "ModCopyErrorBtn",
            "ModOpenCodexBtn",
            "ModRetryBtn",
            "ModAutoHealBtn",
            "ModExportBtn",
            "ModCheckAgyCli",
            "ModBadgeAgyCli",
            "ModBadgeTextAgyCli",
            "ModDetailAgyCli",
            "ModInstallAgyCliBtn",
            "ModConfig4Btn",
        ):
            self.assertIn(f'x:Name="{control_name}"', wiz_text)
        self.assertIn("antigravity-cli", (ROOT / "windows-installer/run-native-install.ps1").read_text(encoding="utf-8-sig"))
        self.assertIn("cli-runtime-only", (ROOT / "windows-installer/install-antigravity-codex.ps1").read_text(encoding="utf-8-sig"))
        # Ensure ModErrorDetailBox complies with .NET 4.8 XamlReader rules (no TextBoxBase attributes in XAML)
        m = re.search(r'<TextBox\s+x:Name="ModErrorDetailBox"[^/>]*/?>', wiz_text)
        self.assertIsNotNone(m)
        tag = m.group(0)
        for forbidden in ("IsReadOnly=", "AcceptsReturn=", "VerticalScrollBarVisibility="):
            self.assertNotIn(forbidden, tag)
        # Start-ModularInstall must stay on modular tab and never jump to ViewProgress
        start_mod_body = re.search(
            r"function Start-ModularInstall.*?^\}",
            wiz_text,
            re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(start_mod_body)
        self.assertIn("$script:activeInstallOrigin = 'modular'", start_mod_body.group(0))
        self.assertIn("Set-NavActive 'modular'", start_mod_body.group(0))
        self.assertNotIn("Set-NavActive 'progress'", start_mod_body.group(0))

    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_install_antigravity_cli_runtime_prestages_agy_exe_and_sidecar_via_range_resume(self):
        import http.server
        import threading

        editor_ps1 = ROOT / "windows-installer/install-antigravity-codex.ps1"
        cli_bytes = (b"MZ_ANTIGRAVITY_CLI_TEST_HEADER_" * 4096) + b"_TAIL"
        cli_sha512 = hashlib.sha512(cli_bytes).hexdigest()

        class CliMockHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.endswith("/windows_amd64.json"):
                    body = json.dumps(
                        {
                            "version": "1.5.18",
                            "url": f"http://127.0.0.1:{self.server.server_port}/antigravity-cli/1.5.18/windows-x64/cli_windows_x64.exe",
                            "sha512": cli_sha512,
                        }
                    ).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                rng = self.headers.get("Range")
                if not rng:
                    self.send_response(200)
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header("Content-Length", str(len(cli_bytes)))
                    self.end_headers()
                    self.wfile.write(cli_bytes[:40960])
                    self.wfile.flush()
                    self.connection.close()
                    return
                start = int(rng.replace("bytes=", "").split("-")[0])
                rem = cli_bytes[start:]
                self.send_response(206)
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Range", f"bytes {start}-{len(cli_bytes) - 1}/{len(cli_bytes)}")
                self.send_header("Content-Length", str(len(rem)))
                self.end_headers()
                self.wfile.write(rem)

            def log_message(self, format, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), CliMockHandler)
        port = server.server_address[1]
        t = threading.Thread(target=server.serve_forever, daemon=True)
        t.start()
        try:
            with tempfile.TemporaryDirectory(prefix="emtroly-agy-cli-") as td:
                root = Path(td)
                home = root / "home"
                stage = root / "stage"
                gemini_bin = home / ".gemini/bin"
                for d in (home, stage, gemini_bin):
                    d.mkdir(parents=True, exist_ok=True)
                # Leave abandoned artifacts that Antigravity's stalled 30s downloader created
                (gemini_bin / ".agy-install.lock").write_text("stale", encoding="utf-8")
                (gemini_bin / "agy.tmp.12345678-1234-1234-1234-1234567890ab").write_bytes(b"half")
                status_file = root / "status.txt"

                res = subprocess.run(
                    [
                        "powershell.exe",
                        "-NoLogo",
                        "-NoProfile",
                        "-ExecutionPolicy",
                        "Bypass",
                        "-Command",
                        "$ErrorActionPreference = 'Stop'\n"
                        f"$tokens = $null; $errs = $null\n"
                        f"$ast = [Management.Automation.Language.Parser]::ParseFile('{editor_ps1}', [ref]$tokens, [ref]$errs)\n"
                        "foreach ($fnName in @('Get-VerifiedDownload', 'Install-AntigravityCliRuntime')) {\n"
                        "  $fn = @($ast.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $fnName }, $true))[0]\n"
                        "  Invoke-Expression $fn.Extent.Text\n"
                        "}\n"
                        f"$StatusFile = '{status_file}'\n"
                        "function Write-EditorStatus([string]$Text) { [IO.File]::WriteAllText($StatusFile, $Text, [Text.UTF8Encoding]::new($false)) }\n"
                        f"Install-AntigravityCliRuntime -StagingDir '{stage}'\n"
                        "Write-Output 'AGY_CLI_PRESTAGE_OK'\n",
                    ],
                    env={
                        **os.environ,
                        "USERPROFILE": str(home),
                        "EMTROLY_AGY_CLI_MANIFEST_URL": f"http://127.0.0.1:{port}/manifests/windows_amd64.json",
                    },
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=30,
                )
                self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
                self.assertIn("AGY_CLI_PRESTAGE_OK", res.stdout)
                agy_exe = gemini_bin / "agy.exe"
                agy_sidecar = gemini_bin / "agy.version.json"
                self.assertTrue(agy_exe.is_file())
                self.assertEqual(agy_exe.read_bytes(), cli_bytes)
                self.assertFalse((gemini_bin / ".agy-install.lock").exists())
                self.assertFalse((gemini_bin / "agy.tmp.12345678-1234-1234-1234-1234567890ab").exists())
                sc = json.loads(agy_sidecar.read_text(encoding="utf-8"))
                self.assertEqual(sc["schemaVersion"], 1)
                self.assertEqual(sc["version"], "1.5.18")
                self.assertEqual(sc["size"], len(cli_bytes))
                self.assertEqual(sc["sha512"].lower(), cli_sha512.lower())
        finally:
            server.shutdown()
            server.server_close()

    @unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
    def test_codex_cli_and_extension_skip_download_when_latest_and_upgrade_when_older(self):
        import http.server
        import io
        import threading
        import zipfile

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("extension/package.json", '{"publisher":"openai","name":"chatgpt","version":"26.51120.50957"}')
            zf.writestr("extension/bin/windows-x86_64/codex.exe", b"MZ_FAKE_CODEX_2651120")
        vsix_bytes = buf.getvalue()
        vsix_sha256 = hashlib.sha256(vsix_bytes).hexdigest()
        counts = {"meta": 0, "vsix": 0, "sha": 0}

        class MockOpenVsxHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.endswith("/latest"):
                    counts["meta"] += 1
                    body = json.dumps(
                        {
                            "version": "26.51120.50957",
                            "files": {
                                "download": f"http://127.0.0.1:{self.server.server_port}/openai.chatgpt-26.51120.50957@win32-x64.vsix",
                                "sha256": f"http://127.0.0.1:{self.server.server_port}/openai.chatgpt-26.51120.50957@win32-x64.sha256",
                            },
                        }
                    ).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if self.path.endswith(".sha256"):
                    counts["sha"] += 1
                    body = (vsix_sha256 + "  openai.chatgpt-26.51120.50957@win32-x64.vsix\n").encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if self.path.endswith(".vsix"):
                    counts["vsix"] += 1
                    self.send_response(200)
                    self.send_header("Content-Type", "application/zip")
                    self.send_header("Content-Length", str(len(vsix_bytes)))
                    self.end_headers()
                    self.wfile.write(vsix_bytes)
                    return
                if self.path.endswith("/v1/models"):
                    body = json.dumps({"data": [{"id": "gpt-6.2-sol"}]}).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                self.send_response(404)
                self.end_headers()

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), MockOpenVsxHandler)
        port = server.server_address[1]
        t = threading.Thread(target=server.serve_forever, daemon=True)
        t.start()
        try:
            with tempfile.TemporaryDirectory(prefix="emtroly-latest-skip-", ignore_cleanup_errors=True) as td:
                root = Path(td)
                home = root / "home"
                local = root / "local"
                temp_dir = root / "tmp"
                desktop = home / "Desktop"
                for d in (home, local, temp_dir, desktop):
                    d.mkdir(parents=True, exist_ok=True)
                codex_ps1 = ROOT / "windows-installer/codex-cli.ps1"
                editor_ps1 = ROOT / "windows-installer/install-antigravity-codex.ps1"
                status_file = root / "status.txt"

                (home / ".codex").mkdir(parents=True, exist_ok=True)
                (home / ".codex/config.toml").write_text(
                    'model = "gpt-5"\n\n[projects.\'d:\\\\demo\']\ntrust_level = "trusted"\n\n[windows]\nsandbox = "elevated"\n',
                    encoding="utf-8",
                )
                env = {
                    **os.environ,
                    "USERPROFILE": str(home),
                    "LOCALAPPDATA": str(local),
                    "TEMP": str(temp_dir),
                    "EMTROLY_TEST_DESKTOP_DIR": str(desktop),
                    "EMTROLY_CODEX_OPENVSX_URL": f"http://127.0.0.1:{port}/api/openai/chatgpt/win32-x64/latest",
                    "EMTROLY_SKIP_AGY_CLI_PREFETCH": "1",
                }

                # 1. Fresh Install-EmTroLyCodexCliFirst downloads latest VSIX once & writes version sidecar + links ~/.codex
                res1 = run_ps(
                    "$ErrorActionPreference = 'Stop'\n"
                    f". ([ScriptBlock]::Create([IO.File]::ReadAllText('{codex_ps1}', [Text.Encoding]::UTF8)))\n"
                    "$s = [pscustomobject]@{ model='gpt-6.2-sol'; base_url='https://codex.anhlaptrinh.vn/v1'; ai_api_key='sk-test-latest'; skip_editor=$true }\n"
                    f"$r1 = Install-EmTroLyCodexCliFirst -Settings $s -PayloadRoot '{ROOT}' -StatusFile '{status_file}' -ForceConfigUpdate -CheckLatestVersion\n"
                    "if (-not $r1.Installed -or $r1.Skipped -or $r1.Version -ne '26.51120.50957') { throw ('unexpected-r1:' + ($r1 | ConvertTo-Json -Compress)) }\n"
                    f"$r2 = Install-EmTroLyCodexCliFirst -Settings $s -PayloadRoot '{ROOT}' -StatusFile '{status_file}' -ForceConfigUpdate -CheckLatestVersion\n"
                    "if (-not $r2.Installed -or -not $r2.Skipped -or -not $r2.UpToDate -or $r2.Version -ne '26.51120.50957') { throw ('unexpected-r2:' + ($r2 | ConvertTo-Json -Compress)) }\n"
                    "Write-Output 'CODEX_CLI_LATEST_SKIP_OK'\n",
                    env=env,
                )
                self.assertEqual(res1.returncode, 0, res1.stdout + res1.stderr)
                self.assertIn("CODEX_CLI_LATEST_SKIP_OK", res1.stdout)
                self.assertEqual(counts["vsix"], 1, f"Expected 1 VSIX download, got {counts}")
                self.assertIn("phiên bản mới nhất", status_file.read_text(encoding="utf-8"))
                user_codex_cfg = (home / ".codex/config.toml").read_text(encoding="utf-8")
                self.assertIn('base_url = "https://codex.anhlaptrinh.vn/v1"', user_codex_cfg)
                self.assertIn('model = "gpt-6.2-sol"', user_codex_cfg)
                self.assertIn("[projects.'d:\\\\demo']", user_codex_cfg)
                self.assertIn("[windows]", user_codex_cfg)
                user_codex_auth = json.loads((home / ".codex/auth.json").read_text(encoding="utf-8"))
                self.assertEqual(user_codex_auth["OPENAI_API_KEY"], "sk-test-latest")

                # 2. Extension already at latest (26.51120.50957): install-antigravity-codex.ps1 must skip download & --install-extension
                staged_ed = root / "install-antigravity-codex.ps1"
                ed_src = editor_ps1.read_text(encoding="utf-8-sig").replace("([Environment]::GetFolderPath('Desktop'))", "$env:TEST_DESKTOP")
                staged_ed.write_text(ed_src, encoding="utf-8-sig")
                shutil.copytree(ROOT / "windows-installer/activation-probe", root / "activation-probe")

                ide_dir = local / "Programs/EmTroLy-Antigravity-IDE-0123456789abcdef0123456789abcdef"
                for d in (ide_dir / "bin", ide_dir / "resources/app"):
                    d.mkdir(parents=True, exist_ok=True)
                (ide_dir / "Antigravity IDE.exe").write_text("ide-bin", encoding="utf-8")
                (ide_dir / "bin/antigravity-ide.cmd").write_text("@echo off", encoding="utf-8")
                (ide_dir / "resources/app/product.json").write_text('{"applicationName":"antigravity-ide","version":"1.107.0","ideVersion":"2.7.0"}', encoding="utf-8")

                em_base = local / "EmTroLy"
                (em_base / "installer-job.txt").write_text("0123456789abcdef0123456789abcdef", encoding="utf-8")
                (em_base / "editor-app-path.txt").write_text(str(ide_dir), encoding="utf-8")
                ext_latest = em_base / "Antigravity/Extensions/openai.chatgpt-26.51120.50957/bin/windows-x86_64"
                ext_latest.mkdir(parents=True, exist_ok=True)
                (ext_latest.parent.parent / "package.json").write_text('{"publisher":"openai","name":"chatgpt","version":"26.51120.50957"}', encoding="utf-8")
                (ext_latest / "codex.exe").write_text("codex-bin", encoding="utf-8")

                env_ed = {**env, "TEST_DESKTOP": str(desktop), "EMTROLY_TEST_DESKTOP_DIR": str(desktop)}
                res2 = run_ps(
                    "$ErrorActionPreference = 'Stop'\n"
                    "function global:Start-Process {\n"
                    "  param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)\n"
                    "  if ($FilePath -match 'antigravity-ide-setup\\.exe$') { throw 'should-not-download-ide' }\n"
                    "  if ($FilePath -match 'cmd\\.exe$' -and $ArgumentList -match '--install-extension') { throw 'should-not-reinstall-latest-extension' }\n"
                    "  if ($FilePath -match 'Antigravity IDE\\.exe$') { throw 'should-not-launch-activation-when-skipped' }\n"
                    "  $p = [pscustomobject]@{ ExitCode = 0 }; $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($m) return $true }; return $p\n"
                    "}\n"
                    "$s = [pscustomobject]@{ job_id='0123456789abcdef0123456789abcdef'; model='gpt-6.2-sol'; base_url='https://codex.anhlaptrinh.vn/v1'; ai_api_key='sk-test-latest' }\n"
                    f"& '{staged_ed}' -Settings $s -StatusFile '{status_file}' -AllowUpdateExisting\n"
                    "Write-Output 'EXT_SKIP_LATEST_OK'\n",
                    env=env_ed,
                )
                self.assertEqual(res2.returncode, 0, res2.stdout + res2.stderr)
                self.assertIn("EXT_SKIP_LATEST_OK", res2.stdout)
                self.assertEqual(counts["vsix"], 1, f"Extension already latest must NOT re-download VSIX: {counts}")
                self.assertTrue((desktop / "EmTroLy - Antigravity.lnk").is_file())

                # 3. Modular Update in run-native-install.ps1 skips all downloads when everything is already latest
                staged_runner = root / "run-native-install.ps1"
                runner_src = (ROOT / "windows-installer/run-native-install.ps1").read_text(encoding="utf-8-sig").replace(
                    'Uri "$baseUrl/models"',
                    f'Uri "http://127.0.0.1:{port}/v1/models"',
                )
                staged_runner.write_text(runner_src, encoding="utf-8-sig")
                agy_dir = home / ".gemini/bin"
                agy_dir.mkdir(parents=True, exist_ok=True)
                (agy_dir / "agy.exe").write_text("agy-ready", encoding="utf-8")
                (agy_dir / "agy.version.json").write_text('{"version":"1.5.19"}', encoding="utf-8")

                mod_settings = root / "mod-update.json"
                mod_settings.write_text(
                    json.dumps(
                        {
                            "base_url": "https://codex.anhlaptrinh.vn/v1",
                            "model": "gpt-6.2-sol",
                            "ai_api_key": "sk-test-latest",
                            "force_reinstall": True,
                        }
                    ),
                    encoding="utf-8",
                )
                runner_res = subprocess.run(
                    [
                        SHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
                        "-File", str(staged_runner),
                        "-SettingsFile", str(mod_settings),
                        "-PayloadRoot", str(ROOT),
                        "-LogFile", str(status_file),
                        "-Components", "codex-cli,antigravity-ide,codex-extension",
                    ],
                    env={**env_ed, "TEST_MODE": "modular-unit"},
                    capture_output=True,
                    text=True,
                    timeout=35,
                )
                status_text = status_file.read_text(encoding="utf-8") if status_file.exists() else ""
                self.assertEqual(runner_res.returncode, 0, status_text + runner_res.stdout + runner_res.stderr)
                self.assertIn("đã ở phiên bản mới nhất", status_text)
                self.assertEqual(counts["vsix"], 1, f"Runner update should download 0 times when latest: {counts}")
                self.assertTrue((home / ".antigravity-ide/extensions/openai.chatgpt-26.51120.50957-win32-x64/package.json").is_file())
                self.assertTrue((home / ".antigravity-ide/extensions/extensions.json").is_file())

                # 4. Downgrading installed extension to older 26.51111.21308 triggers VSIX download & cleanup of old dir
                shutil.rmtree(em_base / "Antigravity/Extensions/openai.chatgpt-26.51120.50957")
                ext_old = em_base / "Antigravity/Extensions/openai.chatgpt-26.51111.21308/bin/windows-x86_64"
                ext_old.mkdir(parents=True, exist_ok=True)
                (ext_old.parent.parent / "package.json").write_text('{"publisher":"openai","name":"chatgpt","version":"26.51111.21308"}', encoding="utf-8")
                (ext_old / "codex.exe").write_text("old-codex", encoding="utf-8")

                res4 = run_ps(
                    "$ErrorActionPreference = 'Stop'\n"
                    "function global:Start-Process {\n"
                    "  param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)\n"
                    "  if ($FilePath -match 'antigravity-ide-setup\\.exe$') { throw 'should-not-download-ide' }\n"
                    "  if ($FilePath -match 'cmd\\.exe$' -and $ArgumentList -match '--install-extension') {\n"
                    f"    $newExt = Join-Path $env:LOCALAPPDATA 'EmTroLy\\Antigravity\\Extensions\\openai.chatgpt-26.51120.50957'\n"
                    "    [void](New-Item -ItemType Directory -Force -Path (Join-Path $newExt 'bin\\windows-x86_64'))\n"
                    "    [IO.File]::WriteAllText((Join-Path $newExt 'package.json'), '{\"publisher\":\"openai\",\"name\":\"chatgpt\",\"version\":\"26.51120.50957\"}')\n"
                    "    [IO.File]::WriteAllText((Join-Path $newExt 'bin\\windows-x86_64\\codex.exe'), 'upgraded-codex')\n"
                    "  }\n"
                    "  if ($FilePath -match 'Antigravity IDE\\.exe$') { [IO.File]::WriteAllText($env:EMTROLY_CODEX_ACTIVATION_MARKER, 'ok') }\n"
                    "  $p = [pscustomobject]@{ ExitCode = 0 }; $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($m) return $true }; return $p\n"
                    "}\n"
                    "$s = [pscustomobject]@{ job_id='0123456789abcdef0123456789abcdef'; model='gpt-6.2-sol'; base_url='https://codex.anhlaptrinh.vn/v1'; ai_api_key='sk-test-latest' }\n"
                    f"& '{staged_ed}' -Settings $s -StatusFile '{status_file}' -AllowUpdateExisting\n"
                    "Write-Output 'EXT_UPGRADE_OK'\n",
                    env=env_ed,
                )
                self.assertEqual(res4.returncode, 0, res4.stdout + res4.stderr)
                self.assertIn("EXT_UPGRADE_OK", res4.stdout)
                self.assertEqual(counts["vsix"], 2)
                self.assertFalse((em_base / "Antigravity/Extensions/openai.chatgpt-26.51111.21308").exists())
                self.assertTrue((em_base / "Antigravity/Extensions/openai.chatgpt-26.51120.50957/package.json").is_file())
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
