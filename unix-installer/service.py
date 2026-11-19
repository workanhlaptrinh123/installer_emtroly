"""Install and verify the private gateway without replacing existing services."""

import json
import shutil
import subprocess
import time

from runtime import _run


def check_linux_user_service():
    systemctl = shutil.which("systemctl")
    if not systemctl:
        raise RuntimeError("linux-user-service-unavailable")
    try:
        result = subprocess.run([systemctl, "--user", "show-environment"], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError("linux-user-service-unavailable") from None
    if result.returncode != 0:
        raise RuntimeError("linux-user-service-unavailable")


def _json(node, entry, env, arguments):
    text = _run([node, entry, *arguments], env, 45, "Gateway verification")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        raise RuntimeError("Gateway returned invalid status") from None


def install_and_verify(node, entry, env, port, wait_seconds=90):
    _run([node, entry, "gateway", "install", "--port", str(port)], env, 120, "Gateway service installation")
    _run([node, entry, "gateway", "start"], env, 120, "Gateway start")
    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            health = _json(node, entry, env, ["gateway", "health", "--json"])
            loaded = set(health.get("plugins", {}).get("loaded") or [])
            if health.get("ok") is True and {"zalouser", "telegram-zalo-owner-login"}.issubset(loaded):
                break
        except RuntimeError:
            pass
        if time.monotonic() >= deadline:
            raise RuntimeError("Gateway or required plugins did not become healthy")
        time.sleep(2)
    inspection = _json(node, entry, env, ["plugins", "inspect", "telegram-zalo-owner-login", "--runtime", "--json"])
    plugin = inspection.get("plugin", {})
    tools = set(plugin.get("toolNames") or [])
    for tool in inspection.get("tools") or []:
        tools.update(tool.get("names") or [])
    if (plugin.get("status") != "loaded" or plugin.get("enabled") is not True or
            "telegram_zalo_login_qr" not in tools or
            not {"zaloqr", "zalostatus"}.issubset(set(inspection.get("commands") or []))):
        raise RuntimeError("Zalo commands were not registered")
    return health
