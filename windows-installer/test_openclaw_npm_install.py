import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _ps_quote(value: str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


class OpenClawNpmInstallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.real_node = shutil.which("node")
        if not cls.real_node or not Path(cls.real_node).is_file():
            raise unittest.SkipTest("System node.exe not found for PE binary fixture")

    def _run_ps(self, script_body: str, env_overrides: dict | None = None, timeout: int = 90) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["EMTROLY_NPM_RETRY_DELAY_MS"] = "1"
        env["EMTROLY_IGNORE_SYSTEM_NODE"] = "1"
        if env_overrides:
            for k, v in env_overrides.items():
                if v is None:
                    env.pop(k, None)
                else:
                    env[k] = str(v)

        with tempfile.NamedTemporaryFile("w", suffix=".ps1", delete=False, encoding="utf-8-sig") as tf:
            tf.write(script_body)
            script_path = Path(tf.name)
        try:
            return subprocess.run(
                ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script_path)],
                cwd=str(ROOT),
                env=env,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
            )
        finally:
            script_path.unlink(missing_ok=True)

    def _create_mock_toolchain(
        self,
        dep_root: Path,
        folder_name: str,
        use_real_node: bool,
        behavior_py: str,
        state_file: Path,
    ) -> tuple[Path, Path, Path]:
        tc_dir = dep_root / folder_name
        tc_dir.mkdir(parents=True, exist_ok=True)
        node_exe = tc_dir / "node.exe"
        if use_real_node:
            shutil.copy2(self.real_node, node_exe)
        else:
            node_exe.write_text("mock-node-lts\n", encoding="utf-8")

        worker_py = tc_dir / "mock_npm.py"
        worker_py.write_text(textwrap.dedent(behavior_py), encoding="utf-8")

        npm_cmd = tc_dir / "npm.cmd"
        npm_cmd.write_text(
            f'@echo off\r\n"{sys.executable}" "{worker_py}" %*\r\nexit /b %ERRORLEVEL%\r\n',
            encoding="ascii",
        )
        return tc_dir, node_exe, npm_cmd

    def _mock_npm_script(self, state_file: Path, attempts_jsonl: Path, scenario: str) -> str:
        return f"""
import json, os, pathlib, sys, time

state_path = pathlib.Path(r"{state_file}")
log_path = pathlib.Path(r"{attempts_jsonl}")
args = sys.argv[1:]

count = 1
if state_path.exists():
    count = int(state_path.read_text(encoding="utf-8").strip()) + 1
state_path.write_text(str(count), encoding="utf-8")

prefix = ""
for i, a in enumerate(args):
    if a == "--prefix" and i + 1 < len(args):
        prefix = args[i + 1]
        break
prefix_dir = pathlib.Path(prefix) if prefix else pathlib.Path.cwd()

broken_sentinel = prefix_dir / "node_modules" / "openclaw" / "broken.tmp"
record = {{
    "attempt": count,
    "cwd": str(pathlib.Path.cwd()),
    "script_dir": str(pathlib.Path(__file__).resolve().parent),
    "args": args,
    "prefix": prefix,
    "registry": os.environ.get("NPM_CONFIG_REGISTRY", ""),
    "cache": os.environ.get("NPM_CONFIG_CACHE", ""),
    "userconfig": os.environ.get("NPM_CONFIG_USERCONFIG", ""),
    "maxsockets": os.environ.get("NPM_CONFIG_MAXSOCKETS", ""),
    "ia32cap": os.environ.get("OPENSSL_ia32cap", ""),
    "node_options": os.environ.get("NODE_OPTIONS", ""),
    "path_head": os.environ.get("PATH", "").split(";")[0],
    "broken_tmp_existed_before": broken_sentinel.exists(),
}}
with log_path.open("a", encoding="utf-8") as fh:
    fh.write(json.dumps(record) + "\\n")

userconfig_reg = ""
uc_path = os.environ.get("NPM_CONFIG_USERCONFIG", "")
if uc_path and pathlib.Path(uc_path).exists():
    for line in pathlib.Path(uc_path).read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("registry="):
            userconfig_reg = line.split("=", 1)[1].strip()
record["userconfig_registry"] = userconfig_reg
# Re-write with userconfig_registry appended
lines = log_path.read_text(encoding="utf-8").splitlines()
lines[-1] = json.dumps(record)
log_path.write_text("\\n".join(lines) + "\\n", encoding="utf-8")

def write_full_artifacts():
    oc_dir = prefix_dir / "node_modules" / "openclaw"
    bin_dir = prefix_dir / "node_modules" / ".bin"
    oc_dir.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)
    (oc_dir / "package.json").write_text('{{"name":"openclaw","version":"2026.11.4"}}', encoding="utf-8")
    (oc_dir / "openclaw.mjs").write_text('console.log("ok");\\n', encoding="utf-8")
    (bin_dir / "openclaw.cmd").write_text('@echo off\\r\\necho ok\\r\\n', encoding="ascii")

scenario = {scenario!r}

if scenario == "tls_fail_twice_then_succeed":
    if count == 1:
        broken_sentinel.parent.mkdir(parents=True, exist_ok=True)
        broken_sentinel.write_text("partial", encoding="utf-8")
        sys.stderr.write("npm error code ERR_SSL_CIPHER_OPERATION_FAILED\\n")
        sys.stderr.write("npm error ossl_gcm_stream_update: cipher operation failed\\n")
        sys.stderr.write("leaked-token=tok_secret_value_123456\\n")
        sys.exit(1)
    elif count == 2:
        sys.stderr.write("npm error ERR_SSL_DECRYPTION_FAILED_OR_BAD_RECORD_MAC ciphercommon_gcm\\n")
        sys.exit(1)
    else:
        write_full_artifacts()
        sys.stdout.write("added 42 packages in 1s\\n")
        sys.exit(0)

elif scenario == "lts_succeeds_after_v24_tls_fail":
    script_folder = pathlib.Path(__file__).resolve().parent.name
    if "node-v22." in script_folder:
        write_full_artifacts()
        sys.stdout.write("added 42 packages with Node 22 LTS\\n")
        sys.exit(0)
    sys.stderr.write("npm error ERR_SSL_CIPHER_OPERATION_FAILED\\n")
    sys.stderr.write("npm error ossl_gcm_stream_update: cipher operation failed\\n")
    sys.exit(1)

elif scenario == "always_fail_tls":
    broken_sentinel.parent.mkdir(parents=True, exist_ok=True)
    broken_sentinel.write_text("partial", encoding="utf-8")
    sys.stderr.write("npm error ERR_SSL_CIPHER_OPERATION_FAILED\\n")
    sys.stderr.write("npm error ERR_SSL_DECRYPTION_FAILED_OR_BAD_RECORD_MAC\\n")
    sys.stderr.write("npm error ossl_gcm_stream_update: cipher operation failed\\n")
    sys.exit(1)

elif scenario == "exit_zero_missing_package_json":
    bin_dir = prefix_dir / "node_modules" / ".bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    (bin_dir / "openclaw.cmd").write_text('@echo off\\r\\necho ok\\r\\n', encoding="ascii")
    sys.exit(0)

elif scenario == "exit_zero_missing_openclaw_cmd":
    oc_dir = prefix_dir / "node_modules" / "openclaw"
    oc_dir.mkdir(parents=True, exist_ok=True)
    (oc_dir / "package.json").write_text('{{"name":"openclaw","version":"2026.11.4"}}', encoding="utf-8")
    sys.exit(0)

sys.exit(99)
"""

    def test_all_powershell_scripts_parse_without_syntax_errors(self) -> None:
        ps_files = sorted(
            str(p) for p in ROOT.rglob("*.ps1") if ".git" not in p.parts
        )
        self.assertGreater(len(ps_files), 15)
        file_list_json = json.dumps(ps_files)
        ps = textwrap.dedent(
            f"""
            $ErrorActionPreference = 'Stop'
            $files = {self._ps_literal_json(file_list_json)} | ConvertFrom-Json
            $bad = @()
            foreach ($f in $files) {{
              $tokens = $null
              $errors = $null
              [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
              if ($errors -and $errors.Count -gt 0) {{
                $errs = ($errors | ForEach-Object {{ "$($_.Extent.StartLineNumber): $($_.Message)" }}) -join '; '
                $bad += "$f => $errs"
              }}
            }}
            if ($bad.Count -gt 0) {{
              Write-Error ($bad -join "`n")
              exit 1
            }}
            Write-Output ("PARSED_OK:" + $files.Count)
            """
        )
        res = self._run_ps(ps, timeout=120)
        self.assertEqual(res.returncode, 0, msg=res.stdout + "\n" + res.stderr)
        self.assertIn(f"PARSED_OK:{len(ps_files)}", res.stdout)

    def _ps_literal_json(self, json_str: str) -> str:
        return _ps_quote(json_str)

    def test_no_insecure_tls_bypass_or_unverified_download(self) -> None:
        targets = [
            ROOT / "native" / "openclaw-npm.ps1",
            ROOT / "install-native-windows.ps1",
            ROOT / "windows-installer" / "run-native-install.ps1",
            ROOT / "windows-installer" / "auto-heal-codex.ps1",
            ROOT / "windows-installer" / "manage-instance.ps1",
            ROOT / "native" / "upgrade-windows.ps1",
            ROOT / "zalo" / "onboard-zalouser-windows.ps1",
        ]
        for path in targets:
            text = path.read_text(encoding="utf-8-sig")
            active_lines = [
                ln for ln in text.splitlines() if not ln.lstrip().startswith("#")
            ]
            low = "\n".join(active_lines).lower()
            self.assertNotIn("strict-ssl=false", low, msg=f"Forbidden strict-ssl=false in {path}")
            self.assertNotIn("node_tls_reject_unauthorized=0", low, msg=f"Forbidden NODE_TLS_REJECT_UNAUTHORIZED=0 in {path}")
            self.assertNotIn("servercertificatevalidationcallback", low, msg=f"Forbidden cert callback bypass in {path}")

        npm_helper = (ROOT / "native" / "openclaw-npm.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("function Invoke-OpenClawNpmInstall", npm_helper)
        self.assertIn("node_modules\\openclaw\\package.json", npm_helper)
        self.assertIn("node_modules\\.bin\\openclaw.cmd", npm_helper)
        self.assertNotIn("--prefer-offline", npm_helper)

    def test_retry_fails_twice_with_tls_then_succeeds_attempt_3(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            local_app = base / "LocalAppData"
            dep_root = local_app / "MemberInstaller" / "dependencies"
            shared_cache_keep = local_app / "MemberInstaller" / "npm-cache" / "keep.txt"
            shared_cache_keep.parent.mkdir(parents=True, exist_ok=True)
            shared_cache_keep.write_text("do-not-delete-shared-cache", encoding="utf-8")

            oc_root = base / "UserProfile" / "openclaw"
            oc_root.mkdir(parents=True, exist_ok=True)
            user_cfg = oc_root / "openclaw.json"
            user_cfg.write_text('{"preserve":true}', encoding="utf-8")
            rt_dir = oc_root / "runtime" / "2026.11.4"
            logs_dir = oc_root / "logs"

            state_file = base / "npm_count.txt"
            attempts_jsonl = base / "attempts.jsonl"
            _, node24, npm24 = self._create_mock_toolchain(
                dep_root,
                "node-v24.21.0-win-x64",
                use_real_node=True,
                behavior_py=self._mock_npm_script(state_file, attempts_jsonl, "tls_fail_twice_then_succeed"),
                state_file=state_file,
            )

            ps = textwrap.dedent(
                f"""
                $ErrorActionPreference = 'Stop'
                . {_ps_quote(str(ROOT / 'native' / 'openclaw-npm.ps1'))}
                $statuses = New-Object System.Collections.Generic.List[string]
                $res = Invoke-OpenClawNpmInstall `
                  -RuntimeDir {_ps_quote(str(rt_dir))} `
                  -OpenClawRoot {_ps_quote(str(oc_root))} `
                  -OpenClawVersion '2026.11.4' `
                  -LogsDir {_ps_quote(str(logs_dir))} `
                  -SecretsToRedact @('tok_secret_value_123456') `
                  -StatusCallback {{ param($m) $statuses.Add($m) }}
                [pscustomobject]@{{
                  Success = $res.Success
                  AttemptCount = $res.Attempts.Count
                  UsedNodeExe = $res.UsedNodeExe
                  UsedNpmCmd = $res.UsedNpmCmd
                  Registry = $res.Registry
                  CacheDir = $res.CacheDir
                  LogFiles = $res.LogFiles
                  Statuses = @($statuses)
                }} | ConvertTo-Json -Depth 5
                """
            )
            env_ovr = {
                "LOCALAPPDATA": str(local_app),
                "PATH": os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32"),
                "EMTROLY_SKIP_PROCESS_SWEEP": "1",
            }
            proc = self._run_ps(ps, env_overrides=env_ovr)
            self.assertEqual(proc.returncode, 0, msg=proc.stdout + "\n" + proc.stderr)
            out = json.loads(proc.stdout)
            self.assertTrue(out["Success"])
            self.assertEqual(out["AttemptCount"], 3)
            self.assertEqual(Path(out["UsedNodeExe"]).resolve(), node24.resolve())
            self.assertEqual(Path(out["UsedNpmCmd"]).resolve(), npm24.resolve())

            records = [json.loads(line) for line in attempts_jsonl.read_text(encoding="utf-8").splitlines() if line.strip()]
            self.assertEqual(len(records), 3)

            r1, r2, r3 = records
            # Attempt 1: bundled Node, primary registry, maxsockets=2, attempt-1 cache
            self.assertEqual(Path(r1["script_dir"]).resolve(), (dep_root / "node-v24.21.0-win-x64").resolve())
            self.assertEqual(r1["userconfig_registry"], "https://registry.npmjs.org/")
            self.assertEqual(r1["maxsockets"], "2")
            self.assertEqual(r1["ia32cap"], "")
            self.assertEqual(r1["node_options"], "")
            self.assertTrue(r1["cache"].endswith(r"openclaw\npm-cache\attempt-1"))
            self.assertIn("--no-audit", r1["args"])
            self.assertIn("--no-fund", r1["args"])
            self.assertNotIn("--prefer-offline", r1["args"])

            # Attempt 2: broken.tmp from attempt 1 cleaned up; OPENSSL_ia32cap + maxsockets=1
            self.assertFalse(r2["broken_tmp_existed_before"])
            self.assertEqual(r2["userconfig_registry"], "https://registry.npmjs.org/")
            self.assertEqual(r2["maxsockets"], "1")
            self.assertEqual(r2["ia32cap"], "~0x200000200000000")
            self.assertEqual(r2["node_options"], "")
            self.assertTrue(r2["cache"].endswith(r"openclaw\npm-cache\attempt-2"))

            # Attempt 3: TLS 1.2 + OPENSSL_ia32cap + fresh attempt-3 cache -> succeeded
            self.assertEqual(r3["userconfig_registry"], "https://registry.npmjs.org/")
            self.assertEqual(r3["maxsockets"], "1")
            self.assertEqual(r3["ia32cap"], "~0x200000200000000")
            self.assertEqual(r3["node_options"], "--tls-max-v1.2")
            self.assertTrue(r3["cache"].endswith(r"openclaw\npm-cache\attempt-3"))

            # Separate per-attempt logs exist and secrets are scrubbed
            for idx in (1, 2, 3):
                lf = logs_dir / f"npm-install-attempt-{idx}.log"
                self.assertTrue(lf.is_file(), msg=f"Missing {lf}")
            log1_txt = (logs_dir / "npm-install-attempt-1.log").read_text(encoding="utf-8")
            self.assertIn("ERR_SSL_CIPHER_OPERATION_FAILED", log1_txt)
            self.assertNotIn("tok_secret_value_123456", log1_txt)
            self.assertIn("[REDACTED_SECRET]", log1_txt)

            # Failed caches cleaned up, winning cache intact, user data & shared cache untouched
            self.assertFalse((oc_root / "npm-cache" / "attempt-1").exists())
            self.assertFalse((oc_root / "npm-cache" / "attempt-2").exists())
            self.assertTrue((oc_root / "npm-cache" / "attempt-3").exists())
            self.assertEqual(shared_cache_keep.read_text(encoding="utf-8"), "do-not-delete-shared-cache")
            self.assertEqual(user_cfg.read_text(encoding="utf-8"), '{"preserve":true}')
            self.assertTrue((rt_dir / "node_modules" / "openclaw" / "package.json").is_file())
            self.assertTrue((rt_dir / "node_modules" / ".bin" / "openclaw.cmd").is_file())

    def test_node_lts_preferred_after_v24_tls_error_when_present(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            local_app = base / "LocalAppData"
            dep_root = local_app / "MemberInstaller" / "dependencies"
            oc_root = base / "UserProfile" / "openclaw"
            rt_dir = oc_root / "runtime" / "2026.11.4"
            logs_dir = oc_root / "logs"

            state_file = base / "npm_count.txt"
            attempts_jsonl = base / "attempts.jsonl"
            behavior = self._mock_npm_script(state_file, attempts_jsonl, "lts_succeeds_after_v24_tls_fail")
            _, node24, _ = self._create_mock_toolchain(dep_root, "node-v24.21.0-win-x64", True, behavior, state_file)
            _, node22, npm22 = self._create_mock_toolchain(dep_root, "node-v22.14.0-win-x64", False, behavior, state_file)

            ps = textwrap.dedent(
                f"""
                $ErrorActionPreference = 'Stop'
                . {_ps_quote(str(ROOT / 'native' / 'openclaw-npm.ps1'))}
                $res = Invoke-OpenClawNpmInstall -RuntimeDir {_ps_quote(str(rt_dir))} -OpenClawRoot {_ps_quote(str(oc_root))} -OpenClawVersion '2026.11.4' -LogsDir {_ps_quote(str(logs_dir))}
                [pscustomobject]@{{
                  Success = $res.Success
                  AttemptCount = $res.Attempts.Count
                  PrimaryNodeExe = $res.PrimaryNodeExe
                  UsedNodeExe = $res.UsedNodeExe
                  UsedNpmCmd = $res.UsedNpmCmd
                }} | ConvertTo-Json -Depth 4
                """
            )
            proc = self._run_ps(ps, env_overrides={"LOCALAPPDATA": str(local_app), "EMTROLY_SKIP_PROCESS_SWEEP": "1"})
            self.assertEqual(proc.returncode, 0, msg=proc.stdout + "\n" + proc.stderr)
            out = json.loads(proc.stdout)
            self.assertTrue(out["Success"])
            self.assertEqual(out["AttemptCount"], 2)
            self.assertEqual(Path(out["PrimaryNodeExe"]).resolve(), node24.resolve())
            self.assertEqual(Path(out["UsedNodeExe"]).resolve(), node22.resolve())
            self.assertEqual(Path(out["UsedNpmCmd"]).resolve(), npm22.resolve())

    def test_total_npm_failure_exhausts_ladder_with_chacha20_and_fallback_registry(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            local_app = base / "LocalAppData"
            dep_root = local_app / "MemberInstaller" / "dependencies"
            oc_root = base / "UserProfile" / "openclaw"
            rt_dir = oc_root / "runtime" / "2026.11.4"
            logs_dir = oc_root / "logs"

            state_file = base / "npm_count.txt"
            attempts_jsonl = base / "attempts.jsonl"
            self._create_mock_toolchain(
                dep_root,
                "node-v24.21.0-win-x64",
                True,
                self._mock_npm_script(state_file, attempts_jsonl, "always_fail_tls"),
                state_file,
            )

            ps = textwrap.dedent(
                f"""
                $ErrorActionPreference = 'Stop'
                . {_ps_quote(str(ROOT / 'native' / 'openclaw-npm.ps1'))}
                $errMsg = ''
                try {{
                  [void](Invoke-OpenClawNpmInstall -RuntimeDir {_ps_quote(str(rt_dir))} -OpenClawRoot {_ps_quote(str(oc_root))} -OpenClawVersion '2026.11.4' -LogsDir {_ps_quote(str(logs_dir))})
                }} catch {{
                  $errMsg = $_.Exception.Message
                }}
                [pscustomobject]@{{
                  Threw = $errMsg
                  LastIsTls = $script:LastOpenClawNpmResult.IsTlsError
                  Labels = @($script:LastOpenClawNpmResult.Attempts | ForEach-Object {{ $_.Label }})
                  Success = $script:LastOpenClawNpmResult.Success
                }} | ConvertTo-Json -Depth 4
                """
            )
            proc = self._run_ps(ps, env_overrides={"LOCALAPPDATA": str(local_app), "EMTROLY_SKIP_PROCESS_SWEEP": "1"})
            self.assertEqual(proc.returncode, 0, msg=proc.stdout + "\n" + proc.stderr)
            out = json.loads(proc.stdout)
            self.assertEqual(out["Threw"], "Private OpenClaw installation failed.")
            self.assertFalse(out["Success"])
            self.assertTrue(out["LastIsTls"])
            self.assertEqual(
                out["Labels"],
                [
                    "primary-default",
                    "ia32cap-maxsockets1",
                    "ia32cap-tls12",
                    "ia32cap-tls12-chacha20",
                    "fallback-registry-scalar-tls12-chacha20",
                ],
            )
            records = [json.loads(line) for line in attempts_jsonl.read_text(encoding="utf-8").splitlines() if line.strip()]
            self.assertEqual(len(records), 5)
            # ChaCha20 strict (no AESGCM) on attempt 4, fallback registry + 0:0 scalar on attempt 5
            self.assertIn("CHACHA20", records[3]["node_options"])
            self.assertIn("!AESGCM:!GCM", records[3]["node_options"])
            self.assertEqual(records[3]["userconfig_registry"], "https://registry.npmjs.org/")
            self.assertEqual(records[4]["userconfig_registry"], "https://registry.npmmirror.com/")
            self.assertEqual(records[4]["ia32cap"], "0:0")
            self.assertEqual(records[4]["maxsockets"], "1")
            self.assertFalse((rt_dir / "node_modules").exists())
            self.assertTrue((logs_dir / "npm-install-attempt-5.log").is_file())

    def test_npm_exit_zero_missing_package_json_or_openclaw_cmd_fails_verification(self) -> None:
        for scenario, expected_missing in (
            ("exit_zero_missing_package_json", "package.json"),
            ("exit_zero_missing_openclaw_cmd", "openclaw.cmd"),
        ):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp)
                local_app = base / "LocalAppData"
                dep_root = local_app / "MemberInstaller" / "dependencies"
                oc_root = base / "UserProfile" / "openclaw"
                rt_dir = oc_root / "runtime" / "2026.11.4"
                logs_dir = oc_root / "logs"

                state_file = base / "npm_count.txt"
                attempts_jsonl = base / "attempts.jsonl"
                self._create_mock_toolchain(
                    dep_root,
                    "node-v24.21.0-win-x64",
                    True,
                    self._mock_npm_script(state_file, attempts_jsonl, scenario),
                    state_file,
                )

                ps = textwrap.dedent(
                    f"""
                    $ErrorActionPreference = 'Stop'
                    . {_ps_quote(str(ROOT / 'native' / 'openclaw-npm.ps1'))}
                    $errMsg = ''
                    try {{
                      [void](Invoke-OpenClawNpmInstall -RuntimeDir {_ps_quote(str(rt_dir))} -OpenClawRoot {_ps_quote(str(oc_root))} -OpenClawVersion '2026.11.4' -LogsDir {_ps_quote(str(logs_dir))})
                    }} catch {{
                      $errMsg = $_.Exception.Message
                    }}
                    [pscustomobject]@{{
                      Threw = $errMsg
                      VerificationFailed = $script:LastOpenClawNpmResult.VerificationFailed
                      MissingArtifacts = @($script:LastOpenClawNpmResult.MissingArtifacts)
                      ErrorMessage = $script:LastOpenClawNpmResult.ErrorMessage
                    }} | ConvertTo-Json -Depth 4
                    """
                )
                proc = self._run_ps(ps, env_overrides={"LOCALAPPDATA": str(local_app), "EMTROLY_SKIP_PROCESS_SWEEP": "1"})
                self.assertEqual(proc.returncode, 0, msg=proc.stdout + "\n" + proc.stderr)
                out = json.loads(proc.stdout)
                self.assertEqual(out["Threw"], "openclaw-npm-verification-failed")
                self.assertTrue(out["VerificationFailed"])
                self.assertTrue(any(expected_missing in m for m in out["MissingArtifacts"]), msg=out)

    def test_wait_runtime_process_exit_waits_for_active_node_process(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            rt_dir = base / "openclaw" / "runtime" / "2026.11.4"
            rt_dir.mkdir(parents=True, exist_ok=True)
            marker_js = rt_dir / "hold.js"
            marker_js.write_text("setTimeout(() => {}, 700);", encoding="utf-8")

            ps = textwrap.dedent(
                f"""
                $ErrorActionPreference = 'Stop'
                . {_ps_quote(str(ROOT / 'native' / 'openclaw-npm.ps1'))}
                $child = Start-Process -FilePath {_ps_quote(self.real_node)} -ArgumentList @({_ps_quote(str(marker_js))}) -PassThru -WindowStyle Hidden
                $sw = [Diagnostics.Stopwatch]::StartNew()
                Wait-EmTroLyRuntimeProcessesExit -TargetDir {_ps_quote(str(rt_dir))} -WaitMs 5000
                $sw.Stop()
                $stillRunning = $false
                try {{
                  $pCheck = Get-Process -Id $child.Id -ErrorAction SilentlyContinue
                  if ($pCheck -and -not $pCheck.HasExited) {{ $stillRunning = $true }}
                }} catch {{}}
                [pscustomobject]@{{
                  ElapsedMs = [int]$sw.ElapsedMilliseconds
                  StillRunning = $stillRunning
                }} | ConvertTo-Json
                """
            )
            proc = self._run_ps(ps, env_overrides={"EMTROLY_SKIP_PROCESS_SWEEP": "0"})
            self.assertEqual(proc.returncode, 0, msg=proc.stdout + "\n" + proc.stderr)
            out = json.loads(proc.stdout)
            self.assertFalse(out["StillRunning"])
            self.assertGreaterEqual(out["ElapsedMs"], 350)

    def test_run_native_install_separates_primary_and_autoheal_errors(self) -> None:
        for case_name, autoheal_mode in (
            ("autoheal_returns_path_missing", "path_missing"),
            ("autoheal_returns_other_error", "other_error"),
        ):
            with self.subTest(case=case_name), tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp)
                user_home = base / "UserProfile"
                local_app = base / "LocalAppData"
                payload = base / "Payload"
                (user_home).mkdir(parents=True, exist_ok=True)
                (local_app / "OpenClaw" / "bin").mkdir(parents=True, exist_ok=True)
                (local_app / "MemberInstaller" / "dependencies").mkdir(parents=True, exist_ok=True)
                (payload / "windows-installer").mkdir(parents=True, exist_ok=True)
                (payload / "native").mkdir(parents=True, exist_ok=True)

                for src_dir_rel in ("native", "windows-installer"):
                    for src_file in (ROOT / src_dir_rel).glob("*.ps1"):
                        dst = payload / src_dir_rel / src_file.name
                        dst.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(src_file, dst)

                # Avoid real network downloads during codex-cli step in this runner error-separation test
                (payload / "windows-installer" / "codex-cli.ps1").write_text(
                    "function Install-EmTroLyCodexCliFirst { param([Parameter(ValueFromRemainingArguments=$true)]$ArgsList) return [pscustomobject]@{ Installed=$true; Skipped=$true } }\n",
                    encoding="utf-8-sig",
                )

                # Stub installer producing genuine OpenSSL/npm TLS failure (logged via EMTROLY_INSTALL_LOG_FILE as real installer does)
                (payload / "install-native-windows.ps1").write_text(
                    textwrap.dedent(
                        """
                        param([Parameter(ValueFromRemainingArguments=$true)]$Ignored)
                        $lines = @(
                          "npm error code ERR_SSL_CIPHER_OPERATION_FAILED",
                          "npm error ERR_SSL_DECRYPTION_FAILED_OR_BAD_RECORD_MAC",
                          "npm error ossl_gcm_stream_update: cipher operation failed"
                        )
                        if ($env:EMTROLY_INSTALL_LOG_FILE) {
                          [IO.File]::AppendAllLines($env:EMTROLY_INSTALL_LOG_FILE, [string[]]$lines, [Text.UTF8Encoding]::new($false))
                        }
                        $lines | ForEach-Object { Write-Output $_ }
                        throw "Private OpenClaw installation failed."
                        """
                    ),
                    encoding="utf-8-sig",
                )

                # Put mock codex.cmd on isolated PATH so Ensure-AutoHealCodexBinary uses it cleanly in <1s
                ah_bin = base / "AutoHealBin"
                ah_bin.mkdir(parents=True, exist_ok=True)
                ah_worker = ah_bin / "codex_mock.py"
                if autoheal_mode == "path_missing":
                    ah_worker.write_text(
                        "import sys\nif '--version' in sys.argv:\n  print('codex 0.1.0'); sys.exit(0)\nsys.stderr.write('The system cannot find the path specified.\\n')\nsys.exit(1)\n",
                        encoding="utf-8",
                    )
                else:
                    ah_worker.write_text(
                        "import sys\nif '--version' in sys.argv:\n  print('codex 0.1.0'); sys.exit(0)\nsys.stderr.write('simulated-codex-network-error\\n')\nsys.exit(1)\n",
                        encoding="utf-8",
                    )
                (ah_bin / "codex.cmd").write_text(
                    f'@echo off\r\n"{sys.executable}" "{ah_worker}" %*\r\nexit /b %ERRORLEVEL%\r\n',
                    encoding="ascii",
                )

                settings_path = base / "settings.json"
                settings_obj = {
                    "member": "emtrolytest",
                    "telegram_token": "123456:FAKE_TEST_TOKEN_DO_NOT_USE_99999",
                    "owner_ids": "99999",
                    "group_id": "-100123456",
                    "assistant_name": "EmTroLyTest",
                    "style": "friendly",
                    "addressing": "em",
                    "audience": "general",
                    "base_url": "https://codex.anhlaptrinh.vn/v1",
                    "model": "gpt-6.2-sol",
                    "ai_api_key": "sk-test-fake-key-value-12345",
                    "gateway_port": 0,
                    "accept_full_access": True,
                    "skip_editor": True,
                    "configure_zalo": False,
                    "force_reinstall": False,
                }
                settings_path.write_text(json.dumps(settings_obj), encoding="utf-8")
                log_file = base / "runner.log"

                wrapper_ps = textwrap.dedent(
                    f"""
                    $ErrorActionPreference = 'Stop'
                    function Invoke-RestMethod {{
                      param($Uri, $Method, $Body, $Headers, $TimeoutSec, $MaximumRedirection, [switch]$UseBasicParsing)
                      if ([string]$Uri -like '*/models*') {{
                        return [pscustomobject]@{{ data = @([pscustomobject]@{{ id = 'gpt-6.2-sol' }}) }}
                      }}
                      return [pscustomobject]@{{ ok = $true; result = [pscustomobject]@{{ id = 1; is_bot = $true; username = 'testbot' }} }}
                    }}
                    & {_ps_quote(str(payload / 'windows-installer' / 'run-native-install.ps1'))} `
                      -SettingsFile {_ps_quote(str(settings_path))} `
                      -PayloadRoot {_ps_quote(str(payload))} `
                      -LogFile {_ps_quote(str(log_file))}
                    exit $LASTEXITCODE
                    """
                )
                (user_home).mkdir(parents=True, exist_ok=True)
                app_data = base / "AppData"
                app_data.mkdir(parents=True, exist_ok=True)
                sys_root = os.environ.get("SystemRoot", r"C:\Windows")
                iso_path = f"{ah_bin};{sys_root}\\System32;{sys_root};{sys_root}\\System32\\WindowsPowerShell\\v1.0"
                proc = self._run_ps(
                    wrapper_ps,
                    env_overrides={
                        "USERPROFILE": str(user_home),
                        "LOCALAPPDATA": str(local_app),
                        "APPDATA": str(app_data),
                        "HOME": str(user_home),
                        "PATH": iso_path,
                    },
                    timeout=45,
                )
                self.assertNotEqual(proc.returncode, 0)
                diag_path = Path(str(log_file) + ".diag.json")
                self.assertTrue(diag_path.is_file(), msg=proc.stdout + "\n" + proc.stderr)
                diag = json.loads(diag_path.read_text(encoding="utf-8-sig"))

                self.assertEqual(diag["code"], "Private OpenClaw installation failed.", msg=diag)
                self.assertIn("npm/OpenSSL", diag["friendlyMessage"])
                self.assertIn("HTTPS", diag["friendlyMessage"])
                self.assertNotIn("antivirus", diag["friendlyMessage"].lower())
                self.assertNotIn("diệt virus", diag["friendlyMessage"].lower())
                self.assertIn("Private OpenClaw installation failed.", diag["primaryInstallerError"])
                self.assertIn("npm/OpenSSL failed to decrypt HTTPS data", diag["primaryInstallerError"])
                self.assertIn("Primary installer error", diag["technicalDetail"])
                self.assertIn("Auto-Heal diagnostic error", diag["technicalDetail"])

                if autoheal_mode == "path_missing":
                    self.assertIn("The system cannot find the path specified.", diag["autoHealError"])
                    self.assertNotIn("The system cannot find the path specified.", diag["primaryInstallerError"])
                else:
                    self.assertIn("simulated-codex-network-error", diag["autoHealError"])
                    all_text = "\n".join(
                        str(diag.get(k, ""))
                        for k in ("friendlyMessage", "primaryInstallerError", "autoHealSummary", "autoHealError", "technicalDetail")
                    )
                    self.assertNotIn("The system cannot find the path specified.", all_text)


if __name__ == "__main__":
    unittest.main()
