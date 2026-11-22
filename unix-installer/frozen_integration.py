"""Opt-in packaged integration; fake credentials, no gateway and no Telegram API."""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

import dependencies
import instance
import payload
import runtime
import zalo_setup


def main():
    source = Path(sys._MEIPASS).resolve(strict=True)
    settings = {"member": "member01", "assistant_name": "Assistant", "owner_ids": "12345,67890",
                "qr_owner_id": "12345", "group_id": "-12345", "telegram_token": "123456:" + "x" * 30,
                "base_url": "https://example.com/v1", "ai_api_key": "fake-key", "model": "gpt-6.2-sol",
                "gateway_port": "0", "accept_full_access": True}
    with tempfile.TemporaryDirectory(prefix="installer-frozen-live-") as temporary:
        home = Path(temporary).resolve()
        os.environ["HOME"] = str(home)
        for _ in range(20):
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            if port <= 65000:
                break
        else:
            raise RuntimeError("Could not select a supported test port")
        root = instance.initialize(settings, home, port)
        node, npm = dependencies.install_node(home / "dependencies")
        entry, env = runtime.install(root, home, node, npm)
        print("frozen_runtime=ok", flush=True)
        payload.install(root, source)
        print("frozen_skills=ok", flush=True)
        zalo_setup.configure(root, home, node, entry, env, "member01", ["12345", "67890"], source)
        config = json.loads((root / "openclaw.json").read_text())
        assert config["plugins"]["entries"]["telegram-zalo-owner-login"]["enabled"] is True
        assert "*" not in config["channels"]["telegram"]["accounts"]["member01"]["groupAllowFrom"]
        print("frozen_zalo_commands=ok", flush=True)
        config["channels"]["telegram"]["enabled"] = False
        (root / "openclaw.json").write_text(json.dumps(config), encoding="utf-8")
        with (root / "gateway-test.log").open("w+") as log:
            gateway = subprocess.Popen([str(node), str(entry), "gateway", "run", "--port", str(port)],
                                       env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 90
                while time.monotonic() < deadline:
                    if gateway.poll() is not None:
                        raise RuntimeError("Temporary gateway exited before health verification")
                    result = subprocess.run([str(node), str(entry), "gateway", "health", "--json"], env=env,
                                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=25)
                    try:
                        health = json.loads(result.stdout)
                    except json.JSONDecodeError:
                        health = {}
                    if result.returncode == 0 and health.get("ok") is True:
                        assert {"zalouser", "telegram-zalo-owner-login"}.issubset(set(health.get("plugins", {}).get("loaded") or []))
                        print("temporary_gateway_and_plugins=ok; telegram_disabled", flush=True)
                        break
                    time.sleep(2)
                else:
                    raise RuntimeError("Temporary gateway did not become healthy")
            except Exception:
                log.flush()
                log.seek(0)
                print("temporary_gateway_log:", log.read()[-2000:], flush=True)
                raise
            finally:
                if gateway.poll() is None:
                    gateway.terminate()
                    try:
                        gateway.wait(timeout=20)
                    except subprocess.TimeoutExpired:
                        gateway.kill()
                        gateway.wait(timeout=10)


if __name__ == "__main__":
    main()
