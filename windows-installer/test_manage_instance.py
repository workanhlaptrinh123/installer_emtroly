import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MANAGE = ROOT / "windows-installer/manage-instance.ps1"
WIN_POWERSHELL = (
    Path(os.environ.get("SystemRoot", r"C:\Windows"))
    / "System32/WindowsPowerShell/v1.0/powershell.exe"
)
SHELL = str(WIN_POWERSHELL) if WIN_POWERSHELL.is_file() else (os.environ.get("PWSH") or shutil.which("pwsh"))


@unittest.skipUnless(SHELL and os.name == "nt", "Requires Windows PowerShell")
class ManageInstanceTests(unittest.TestCase):
    def _create_fixture_instance(self, home: Path, local_app: Path):
        oc = home / "openclaw"
        (oc / "workspace").mkdir(parents=True)
        runtime = oc / "runtime/2026.11.4/node_modules/openclaw"
        runtime.mkdir(parents=True)

        cli_mjs = runtime / "openclaw.mjs"
        cli_mjs.write_text(
            "const args = process.argv.slice(2);\n"
            "if (args[0] === 'approvals' && args[1] === 'set') process.exit(0);\n"
            "if (args[0] === 'approvals' && args[1] === 'get') {\n"
            "  console.log(JSON.stringify({file:{agents:{main:{security:'full',ask:'off',askFallback:'full'}}}}));\n"
            "  process.exit(0);\n"
            "}\n"
            "if (args[0] === 'config' && args[1] === 'validate') { console.log('{}'); process.exit(0); }\n"
            "process.exit(0);\n",
            encoding="utf-8",
        )

        (oc / "installer-instance.json").write_text(
            json.dumps({"root": str(oc), "profile": "member-emtroly", "cli_entry": str(cli_mjs)}),
            encoding="utf-8",
        )
        (oc / "openclaw-instance.ps1").write_text(
            "if ($args[0] -eq 'gateway' -and $args[1] -eq 'restart') { "
            "[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'restarted.marker'), 'yes'); exit 0 }\n"
            "if ($args[0] -eq 'gateway' -and $args[1] -eq 'status') { "
            "Write-Output '{\"ok\":true,\"plugins\":{\"loaded\":[\"zalouser\"]}}'; exit 0 }\n"
            "exit 0\n",
            encoding="utf-8-sig",
        )
        (oc / "telegram.token").write_text("111111:OLD_SECRET_TELEGRAM_TOKEN_123456789\n", encoding="utf-8")
        (oc / "member-provider.secret").write_text("sk-old-provider-key-999\n", encoding="utf-8")
        (oc / "workspace/CUSTOMER_PROFILE.md").write_text(
            "# Ho so tro ly\n\nTen tro ly: Tro Ly Cu\n\nDoi tuong phuc vu: Khach hang\n\nCach xung ho: anh - em\n\nPhong cach tra loi: Ngan gon\n",
            encoding="utf-8",
        )
        initial_cfg = {
            "gateway": {"mode": "local", "bind": "loopback", "port": 19789},
            "models": {
                "providers": {
                    "customer": {
                        "baseUrl": "https://codex.anhlaptrinh.vn/v1",
                        "models": [{"id": "gpt-6.2-sol", "name": "gpt-6.2-sol"}],
                    },
                    "openai": {"baseUrl": "https://codex.anhlaptrinh.vn/v1"},
                }
            },
            "agents": {
                "defaults": {"model": {"primary": "customer/gpt-6.2-sol"}},
                "entries": {
                    "main": {
                        "name": "Tro Ly Cu",
                        "tools": {"exec": {"host": "gateway", "mode": "full", "strictInlineEval": False}},
                    }
                },
            },
            "channels": {
                "telegram": {
                    "enabled": True,
                    "defaultAccount": "emtroly",
                    "allowFrom": ["111111111"],
                    "execApprovals": {"approvers": ["111111111"]},
                    "accounts": {
                        "emtroly": {
                            "enabled": True,
                            "allowFrom": ["111111111"],
                            "execApprovals": {"approvers": ["111111111"]},
                            "groups": {"-100111111": {"groupPolicy": "allowlist"}},
                        }
                    },
                }
            },
            "approvals": {
                "exec": {
                    "enabled": True,
                    "mode": "targets",
                    "agentFilter": ["main"],
                    "targets": [{"channel": "telegram", "accountId": "emtroly", "to": "111111111"}],
                },
                "plugin": {
                    "enabled": True,
                    "mode": "targets",
                    "agentFilter": ["main"],
                    "targets": [{"channel": "telegram", "accountId": "emtroly", "to": "111111111"}],
                },
            },
            "commands": {"ownerAllowFrom": ["telegram:111111111"]},
            "tools": {"exec": {"host": "gateway", "mode": "full", "strictInlineEval": False}},
            "bindings": [{"agentId": "main", "match": {"channel": "telegram", "accountId": "emtroly"}}],
        }
        (oc / "openclaw.json").write_text(json.dumps(initial_cfg, indent=2), encoding="utf-8")

        em_codex = local_app / "EmTroLy/Codex"
        em_codex.mkdir(parents=True)
        (em_codex / "config.toml").write_text('model = "gpt-6.2-sol"\n', encoding="utf-8")
        (em_codex / "auth.json").write_text('{"OPENAI_API_KEY":"sk-old-provider-key-999"}', encoding="utf-8")
        return oc, em_codex

    def test_reads_existing_state_and_updates_owners_without_requiring_secrets(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-manage-") as temporary:
            temp = Path(temporary)
            home = temp / "home"
            local_app = temp / "local"
            oc, em_codex = self._create_fixture_instance(home, local_app)

            staged_manage = temp / "manage-instance.ps1"
            staged_manage.write_text(MANAGE.read_text(encoding="utf-8-sig"), encoding="utf-8-sig")

            # 1. Verify Get-EmTroLyInstalledState reads pre-filled fields accurately
            probe_ps = temp / "probe.ps1"
            probe_ps.write_text(
                f'. "{staged_manage}"\n'
                "$st = Get-EmTroLyInstalledState\n"
                "Write-Output ($st | ConvertTo-Json -Compress)\n",
                encoding="utf-8-sig",
            )
            env = {**os.environ, "USERPROFILE": str(home), "LOCALAPPDATA": str(local_app)}
            probe_res = subprocess.run(
                [SHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(probe_ps)],
                env=env,
                capture_output=True,
                text=True,
                timeout=20,
            )
            self.assertEqual(probe_res.returncode, 0, probe_res.stdout + probe_res.stderr)
            state = json.loads(probe_res.stdout.strip())
            self.assertTrue(state["OpenClawInstalled"])
            self.assertEqual(state["AssistantName"], "Tro Ly Cu")
            self.assertEqual(state["OwnerIds"], "111111111")
            self.assertEqual(state["GroupId"], "-100111111")
            self.assertEqual(state["Addressing"], "anh - em")
            self.assertTrue(state["HasTelegramToken"])

            # 2. Update Owner ID (replacing 111111111 -> 222222222,333333333) & Model while leaving secrets BLANK
            req_file = temp / "req.json"
            status_file = temp / "status.txt"
            req_file.write_text(
                json.dumps(
                    {
                        "action": "update-config",
                        "assistant_name": "Trợ Lý Mới",
                        "base_url": "https://codex.anhlaptrinh.vn/v1",
                        "model": "GPT-6.1-terra",
                        "owner_ids": "222222222,333333333",
                        "group_id": "-100999999",
                        "gateway_port": "19789",
                        "audience": "Học viên",
                        "addressing": "thầy - bạn",
                        "style": "Thân thiện",
                        "telegram_token": "",
                        "ai_api_key": "",
                    }
                ),
                encoding="utf-8",
            )
            run_res = subprocess.run(
                [
                    SHELL,
                    "-NoLogo",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(staged_manage),
                    "-RunManageWorker",
                    "-WorkerRequestFile",
                    str(req_file),
                    "-WorkerPayloadRoot",
                    str(ROOT),
                    "-WorkerLogFile",
                    str(status_file),
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
            )
            status_text = status_file.read_text(encoding="utf-8") if status_file.exists() else ""
            self.assertEqual(run_res.returncode, 0, status_text + run_res.stdout + run_res.stderr)
            self.assertFalse(req_file.exists())
            self.assertIn("Hoàn tất:", status_text)

            updated_cfg = json.loads((oc / "openclaw.json").read_text(encoding="utf-8"))
            self.assertEqual(updated_cfg["agents"]["entries"]["main"]["name"], "Trợ Lý Mới")
            self.assertEqual(updated_cfg["agents"]["defaults"]["model"]["primary"], "customer/GPT-6.1-terra")
            self.assertEqual(
                updated_cfg["commands"]["ownerAllowFrom"],
                ["telegram:222222222", "telegram:333333333"],
            )
            self.assertNotIn("111111111", updated_cfg["channels"]["telegram"]["allowFrom"])
            self.assertIn("-100999999", updated_cfg["channels"]["telegram"]["accounts"]["emtroly"]["groups"])
            # Old secrets kept untouched because fields were left blank
            self.assertEqual(
                (oc / "telegram.token").read_text(encoding="utf-8").strip(),
                "111111:OLD_SECRET_TELEGRAM_TOKEN_123456789",
            )
            self.assertEqual(
                (oc / "member-provider.secret").read_text(encoding="utf-8").strip(),
                "sk-old-provider-key-999",
            )
            self.assertIn('model = "GPT-6.1-terra"', (em_codex / "config.toml").read_text(encoding="utf-8"))
            self.assertTrue((oc / "restarted.marker").is_file())
            self.assertEqual(len(list((oc / "backups").glob("quick-edit-*"))), 1)

            # 3. Clearing group_id to "" is allowed (Telegram Group ID is optional) and leaves groups={} with no "" key
            req_file.write_text(
                json.dumps(
                    {
                        "action": "update-config",
                        "assistant_name": "Trợ Lý Mới",
                        "base_url": "https://codex.anhlaptrinh.vn/v1",
                        "model": "GPT-6.1-terra",
                        "owner_ids": "222222222",
                        "group_id": "",
                        "gateway_port": "19789",
                        "audience": "Học viên",
                        "addressing": "thầy - bạn",
                        "style": "Thân thiện",
                        "telegram_token": "",
                        "ai_api_key": "",
                    }
                ),
                encoding="utf-8",
            )
            run_empty_grp = subprocess.run(
                [
                    SHELL,
                    "-NoLogo",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(staged_manage),
                    "-RunManageWorker",
                    "-WorkerRequestFile",
                    str(req_file),
                    "-WorkerPayloadRoot",
                    str(ROOT),
                    "-WorkerLogFile",
                    str(status_file),
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(run_empty_grp.returncode, 0, run_empty_grp.stdout + run_empty_grp.stderr)
            cleared_cfg = json.loads((oc / "openclaw.json").read_text(encoding="utf-8"))
            self.assertEqual(cleared_cfg["channels"]["telegram"]["accounts"]["emtroly"]["groups"], {})
            self.assertNotIn("", cleared_cfg["channels"]["telegram"]["accounts"]["emtroly"]["groups"])
            probe_res2 = subprocess.run(
                [SHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(probe_ps)],
                env=env,
                capture_output=True,
                text=True,
                timeout=20,
            )
            self.assertEqual(probe_res2.returncode, 0, probe_res2.stdout + probe_res2.stderr)
            self.assertEqual(json.loads(probe_res2.stdout.strip())["GroupId"], "")

    def test_updates_token_and_api_key_when_provided_and_syncs_codex_auth(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-manage-secrets-") as temporary:
            temp = Path(temporary)
            home = temp / "home"
            local_app = temp / "local"
            oc, em_codex = self._create_fixture_instance(home, local_app)

            staged_manage = temp / "manage-instance.ps1"
            staged_manage.write_text(MANAGE.read_text(encoding="utf-8-sig"), encoding="utf-8-sig")

            driver = temp / "driver.ps1"
            driver.write_text(
                r"""
param($ManageScript, $ReqFile, $PayloadDir, $LogFile)
function global:Invoke-RestMethod {
  param([switch]$UseBasicParsing, $Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection)
  if ($Uri -match '/getMe$') { return @{ ok = $true; result = @{ is_bot = $true; username = 'new_bot' } } }
  if ($Uri -match '/models$') { return @{ data = @(@{ id = 'gpt-6.2-astra' }) } }
  throw "unexpected-uri: $Uri"
}
& $ManageScript -RunManageWorker -WorkerRequestFile $ReqFile -WorkerPayloadRoot $PayloadDir -WorkerLogFile $LogFile
exit $LASTEXITCODE
""",
                encoding="utf-8-sig",
            )
            req_file = temp / "req.json"
            status_file = temp / "status.txt"
            new_token = "999999:NEW_TELEGRAM_BOT_TOKEN_ABCDEFGHIJKLMNOP"
            new_key = "sk-new-synced-api-key-777"
            req_file.write_text(
                json.dumps(
                    {
                        "action": "update-config",
                        "assistant_name": "Bot Mới",
                        "base_url": "https://codex.anhlaptrinh.vn/v1",
                        "model": "gpt-6.2-astra",
                        "owner_ids": "555555555",
                        "group_id": "-100555555",
                        "gateway_port": "19789",
                        "audience": "",
                        "addressing": "",
                        "style": "",
                        "telegram_token": new_token,
                        "ai_api_key": new_key,
                    }
                ),
                encoding="utf-8",
            )
            env = {**os.environ, "USERPROFILE": str(home), "LOCALAPPDATA": str(local_app)}
            res = subprocess.run(
                [
                    SHELL,
                    "-NoLogo",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(driver),
                    "-ManageScript",
                    str(staged_manage),
                    "-ReqFile",
                    str(req_file),
                    "-PayloadDir",
                    str(ROOT),
                    "-LogFile",
                    str(status_file),
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertEqual((oc / "telegram.token").read_text(encoding="utf-8").strip(), new_token)
            self.assertEqual((oc / "member-provider.secret").read_text(encoding="utf-8").strip(), new_key)
            codex_auth = json.loads((em_codex / "auth.json").read_text(encoding="utf-8"))
            self.assertEqual(codex_auth["OPENAI_API_KEY"], new_key)

    def test_gateway_restart_does_not_deadlock_on_detached_background_daemon(self):
        with tempfile.TemporaryDirectory(prefix="emtroly-manage-daemon-") as temporary:
            temp = Path(temporary)
            home = temp / "home"
            local_app = temp / "local"
            oc, _ = self._create_fixture_instance(home, local_app)
            pid_file = oc / "dummy-daemon.pid"

            # Simulate real user-gateway.cjs spawning a long-lived background daemon on gateway restart
            (oc / "openclaw-instance.ps1").write_text(
                "if ($args[0] -eq 'gateway' -and $args[1] -eq 'restart') {\n"
                "  $p = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') "
                "-ArgumentList '-NoLogo -NoProfile -Command Start-Sleep -Seconds 60' -WindowStyle Hidden -PassThru\n"
                f"  [IO.File]::WriteAllText('{pid_file}', [string]$p.Id)\n"
                "  exit 0\n"
                "}\n"
                "if ($args[0] -eq 'gateway' -and $args[1] -eq 'status') {\n"
                "  Write-Output '{\"ok\":true,\"plugins\":{\"loaded\":[\"zalouser\"]}}'; exit 0\n"
                "}\n"
                "exit 0\n",
                encoding="utf-8-sig",
            )
            staged_manage = temp / "manage-instance.ps1"
            staged_manage.write_text(MANAGE.read_text(encoding="utf-8-sig"), encoding="utf-8-sig")
            req_file = temp / "req.json"
            status_file = temp / "status.txt"
            req_file.write_text(json.dumps({"action": "health-restart"}), encoding="utf-8")
            env = {**os.environ, "USERPROFILE": str(home), "LOCALAPPDATA": str(local_app)}
            try:
                res = subprocess.run(
                    [
                        SHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
                        "-File", str(staged_manage),
                        "-RunManageWorker",
                        "-WorkerRequestFile", str(req_file),
                        "-WorkerPayloadRoot", str(ROOT),
                        "-WorkerLogFile", str(status_file),
                    ],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=18,
                )
                status_text = status_file.read_text(encoding="utf-8") if status_file.exists() else ""
                self.assertEqual(res.returncode, 0, status_text + res.stdout + res.stderr)
                self.assertIn("Hoàn tất:", status_text)
                self.assertTrue(pid_file.is_file())
            finally:
                if pid_file.is_file():
                    try:
                        pid = int(pid_file.read_text(encoding="utf-8").strip())
                        subprocess.run(
                            ["taskkill.exe", "/PID", str(pid), "/T", "/F"],
                            capture_output=True,
                            timeout=5,
                        )
                    except Exception:
                        pass


if __name__ == "__main__":
    unittest.main()
