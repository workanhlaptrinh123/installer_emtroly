"""Prepare an isolated launcher and user-login startup without Administrator rights."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import time

from local_install import atomic_write


def startup_payload(system, node, launcher, config):
    arguments = [str(node), str(launcher), "supervise", str(config)]
    if system == "Windows":
        command = subprocess.list2cmdline([str(node), str(launcher), "start", str(config)])
        return ('CreateObject("WScript.Shell").Run "' + command.replace('"', '""') + '", 0, False\r\n').encode("utf-16")
    if system == "Darwin":
        label = "online.emtroly.openclaw." + hashlib.sha256(str(config).encode()).hexdigest()[:12]
        return plistlib.dumps({"Label": label, "ProgramArguments": arguments, "RunAtLoad": True,
                               "KeepAlive": True, "ThrottleInterval": 10})
    if system == "Linux":
        quoted = " ".join(json.dumps(argument.replace("%", "%%")) for argument in arguments)
        return ("[Unit]\nDescription=OpenClaw selected user instance\n[Service]\nExecStart=" + quoted +
                "\nRestart=on-failure\nRestartSec=10\n[Install]\nWantedBy=default.target\n").encode()
    raise ValueError("Unsupported native OS")


def install(root, home, node, cli_entry, port, expected_os=None):
    system = platform.system()
    os_names = {"windows": "Windows", "macos": "Darwin", "linux": "Linux"}
    if expected_os is not None and os_names.get(expected_os) != system:
        raise ValueError("Installer OS does not match the customer form; no files changed")
    root, home, node, cli_entry = (Path(item) for item in (root, home, node, cli_entry))
    for item in (root, home, node, cli_entry):
        if not item.is_absolute() or item.resolve() != item or not item.exists() or any(character in str(item) for character in "\n\r\x00"):
            raise ValueError("Require absolute real paths without control characters")
    config_path = root / "openclaw.json"
    if not config_path.is_file() or config_path.is_symlink():
        raise ValueError("Existing selected-instance config required")
    if not 1024 <= port <= 65535:
        raise ValueError("Invalid gateway port")
    document = json.loads(config_path.read_text(encoding="utf-8-sig"))
    if document.get("gateway", {}).get("port") != port:
        raise ValueError("Launcher port must match the selected config")
    settings = {"root": str(root), "home": str(home), "node": str(node), "cli_entry": str(cli_entry),
                "port": port, "path": os.environ.get("PATH", "")}
    tools = root / "tools" / "native-launcher"
    if tools.resolve() != tools:
        raise ValueError("Refusing symlinked launcher directory")
    launcher, manifest = tools / "native_launcher.cjs", tools / "instance.json"
    old_launcher = tools / "instance.json"
    if old_launcher.exists():
        previous = json.loads(old_launcher.read_text())
        if any(previous.get(key) != settings[key] for key in ("root", "home", "node", "cli_entry", "port")):
            raise ValueError("Existing launcher identity differs; perform an explicit migration")
    payload = startup_payload(system, node, launcher, manifest)
    identifier = hashlib.sha256(str(root).encode()).hexdigest()[:12]
    if system == "Windows":
        appdata = Path(os.environ.get("APPDATA", ""))
        if not appdata.is_absolute() or not appdata.is_dir():
            raise ValueError("Current user's APPDATA is unavailable")
        target = appdata / "Microsoft/Windows/Start Menu/Programs/Startup" / ("OpenClaw-" + identifier + ".vbs")
    elif system == "Darwin":
        target = home / "Library/LaunchAgents" / ("online.emtroly.openclaw." + hashlib.sha256(str(manifest).encode()).hexdigest()[:12] + ".plist")
    else:
        target = home / ".config/systemd/user" / ("openclaw-" + identifier + ".service")
    if target.resolve() != target or target.is_symlink():
        raise ValueError("Refusing redirected startup entry")
    source = Path(__file__).with_name("native_launcher.cjs")
    for destination, body in ((launcher, source.read_bytes()), (manifest, json.dumps(settings, ensure_ascii=False, indent=2).encode()), (target, payload)):
        if destination.is_file() and destination.read_bytes() == body:
            continue
        if destination.exists():
            saved = root / "backups" / ("native-launcher-" + str(time.time_ns())) / destination.name
            atomic_write(saved, destination.read_bytes())
        atomic_write(destination, body)
    if system == "Darwin":
        domain = "gui/" + str(os.getuid())
        label = plistlib.loads(payload)["Label"]
        existing = subprocess.run(["launchctl", "print", domain + "/" + label], capture_output=True, timeout=30)
        if existing.returncode:
            subprocess.run(["launchctl", "bootstrap", domain, str(target)], check=True, capture_output=True, timeout=30)
    elif system == "Linux":
        subprocess.run(["systemctl", "--user", "daemon-reload"], check=True, capture_output=True, timeout=30)
        subprocess.run(["systemctl", "--user", "enable", "--now", target.name], check=True, capture_output=True, timeout=30)
    return {"launcher": str(launcher), "settings": str(manifest), "startup_registered": True,
            "scope": "current-user-login", "health": "pending_probe"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("root", "home", "node", "cli-entry"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--expected-os", choices=("windows", "macos", "linux"), required=True)
    args = parser.parse_args()
    print(json.dumps(install(args.root, args.home, args.node, args.cli_entry, args.port, args.expected_os)))


if __name__ == "__main__":
    main()
