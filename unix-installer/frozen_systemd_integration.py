"""Exercise a real user service only on a disposable GitHub-hosted runner."""

import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

import dependencies
import instance
import payload
import runner
import runtime
import service
import zalo_setup


def main():
    home = Path.home().resolve(strict=True)
    if (os.environ.get("GITHUB_ACTIONS") != "true" or platform.system() != "Linux" or
            home != Path("/home/runner") or not getattr(sys, "frozen", False)):
        raise RuntimeError("This service test is restricted to a disposable Linux GitHub runner")
    service.check_linux_user_service()
    member = "ci-" + uuid.uuid4().hex[:12]
    root = home / (".openclaw-member-" + member)
    settings = {"member": member, "assistant_name": "CI Assistant", "owner_ids": "12345",
                "qr_owner_id": "12345", "group_id": "-12345", "telegram_token": "123456:" + "x" * 30,
                "base_url": "https://example.com/v1", "ai_api_key": "fake-key", "model": "gpt-6.2-sol",
                "gateway_port": "0", "accept_full_access": True}
    source = Path(sys._MEIPASS).resolve(strict=True)
    created = False
    attempted_service = False
    temporary = tempfile.TemporaryDirectory(prefix="emtroly-systemd-ci-")
    try:
        dependencies_dir = Path(temporary.name).resolve()
        node, npm = dependencies.install_node(dependencies_dir)
        port = runner.choose_port(0)
        instance.initialize(settings, home, port)
        created = True
        entry, env = runtime.install(root, home, node, npm)
        payload.install(root, source)
        zalo_setup.configure(root, home, node, entry, env, member, ["12345"], source)
        config_path = root / "openclaw.json"
        config = json.loads(config_path.read_text())
        config["channels"]["telegram"]["enabled"] = False
        config_path.write_text(json.dumps(config), encoding="utf-8")
        original_run = service._run
        def diagnostic_run(command, environment, timeout, step):
            if step != "Gateway service installation":
                return original_run(command, environment, timeout, step)
            try:
                result = subprocess.run([str(item) for item in command], env=environment, timeout=timeout,
                                        capture_output=True, text=True, stdin=subprocess.DEVNULL)
            except subprocess.TimeoutExpired:
                print("ci_gateway_install=timeout", flush=True)
                raise RuntimeError("Gateway service installation timed out") from None
            if result.returncode:
                text = (result.stdout + "\n" + result.stderr)[-3000:]
                for secret in (config["gateway"]["auth"]["token"], settings["telegram_token"], settings["ai_api_key"]):
                    text = text.replace(secret, "[redacted]")
                text = re.sub(r"[A-Za-z0-9_./:=+\-]{20,}", "[redacted]", text)
                for line in text.splitlines():
                    if re.search(r"token|password|secret|authorization|api.?key", line, re.IGNORECASE):
                        print("ci_gateway_install: [sensitive line omitted]", flush=True)
                    elif line.strip():
                        print("ci_gateway_install:", line, flush=True)
                raise RuntimeError("Gateway service installation failed")
            return result.stdout
        service._run = diagnostic_run
        attempted_service = True
        service.install_and_verify(node, entry, env, port)
        print("systemd_user_gateway_and_plugins=ok; telegram_disabled", flush=True)
    finally:
        removed_service = not attempted_service
        if attempted_service:
            for arguments in (("gateway", "stop"), ("gateway", "uninstall")):
                result = subprocess.run([str(node), str(entry), *arguments], env=env, stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60, check=False)
                if arguments[-1] == "uninstall":
                    removed_service = result.returncode == 0
        if created and removed_service and root.parent == home and root.name == ".openclaw-member-" + member and not root.is_symlink():
            shutil.rmtree(root)
        if removed_service:
            temporary.cleanup()
        elif sys.exc_info()[0] is None:
            raise RuntimeError("Could not remove the temporary CI gateway service")
        else:
            print("ci_service_cleanup=failed", flush=True)


if __name__ == "__main__":
    main()
