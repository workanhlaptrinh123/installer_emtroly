"""Expose a verified private OpenClaw runtime to the current Windows user."""

import argparse
import hashlib
import json
import ntpath
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import time

from local_install import atomic_write


VERSION = "2026.11.4"


def merge_path(current, additions):
    entries = current.split(";") if current else []
    normalized = {ntpath.normcase(ntpath.normpath(ntpath.expandvars(entry.strip().strip('"')))) for entry in entries}
    for addition in additions:
        identity = ntpath.normcase(ntpath.normpath(ntpath.expandvars(str(addition))))
        if identity not in normalized:
            entries.append(str(addition))
            normalized.add(identity)
    return ";".join(entries)


def update_user_path(directory, backup):
    import winreg

    with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, "Environment", 0,
                            winreg.KEY_QUERY_VALUE | winreg.KEY_SET_VALUE) as registry:
        try:
            previous, value_type = winreg.QueryValueEx(registry, "Path")
        except FileNotFoundError:
            previous, value_type = "", winreg.REG_EXPAND_SZ
        if not isinstance(previous, str) or value_type not in (winreg.REG_SZ, winreg.REG_EXPAND_SZ):
            raise ValueError("Unsupported User PATH registry value; left unchanged")
        updated = merge_path(previous, [directory])
        if updated == previous:
            return False
        atomic_write(backup / "user-path.json", json.dumps({"value": previous, "type": value_type}).encode())
        winreg.SetValueEx(registry, "Path", 0, value_type, updated)
    return True


def broadcast_environment():
    import ctypes

    try:
        result = ctypes.c_size_t()
        return bool(ctypes.windll.user32.SendMessageTimeoutW(
            0xFFFF, 0x1A, 0, ctypes.c_wchar_p("Environment"), 0x2, 5000, ctypes.byref(result)))
    except (AttributeError, OSError):
        return False


def instance_environment(root, home, identifier, profile=None):
    selected_profile = profile if profile is not None else "member-" + identifier
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", selected_profile):
        raise ValueError("Invalid selected service profile")
    return {"HOME": str(home), "OPENCLAW_STATE_DIR": str(root),
            "OPENCLAW_CONFIG_PATH": str(root / "openclaw.json"),
            "OPENCLAW_WORKSPACE_DIR": str(root / "workspace"),
            "OPENCLAW_PROFILE": selected_profile,
            "OPENCLAW_HOME": "", "OPENCLAW_GATEWAY_PORT": "",
            "OPENCLAW_GATEWAY_TOKEN": "", "OPENCLAW_GATEWAY_PASSWORD": "",
            "OPENCLAW_WINDOWS_TASK_NAME": "", "OPENCLAW_TASK_SCRIPT": "",
            "OPENCLAW_WRAPPER": "", "OPENCLAW_SYSTEMD_UNIT": "", "OPENCLAW_LAUNCHD_LABEL": ""}


def shim_payload(node, cli_entry, environment, identifier):
    def escaped(value):
        if any(character in str(value) for character in '\r\n\x00"'):
            raise ValueError("Invalid Windows command path")
        return str(value).replace("%", "%%")

    lines = ["@echo off", "@rem OpenClaw member CLI " + identifier,
             '"%SystemRoot%\\System32\\chcp.com" 65001 >nul', "setlocal DisableDelayedExpansion"]
    lines.extend('set "' + name + "=" + escaped(value) + '"' for name, value in environment.items())
    command = '"' + escaped(node) + '" "' + escaped(cli_entry) + '"'
    lines.extend([
        'set "PATH=' + escaped(node.parent) + ';%PATH%"',
        'if /I "%~1"=="status" goto openclaw_gateway_status',
        'goto openclaw_passthrough',
        ':openclaw_gateway_status',
        command + ' gateway status %2 %3 %4 %5 %6 %7 %8 %9',
        'exit /b %errorlevel%',
        ':openclaw_passthrough',
        command + ' %*',
        'exit /b %errorlevel%',
        "",
    ])
    return "\r\n".join(lines).encode("utf-8")


def install(root, home, node, cli_entry, port, profile=None):
    if platform.system() != "Windows":
        raise ValueError("Windows CLI helper must run on the customer Windows machine")
    root, home, node, cli_entry = (Path(item) for item in (root, home, node, cli_entry))
    for item in (root, home, node, cli_entry):
        if not item.is_absolute() or item.resolve() != item or not item.exists():
            raise ValueError("Require existing absolute real paths")
        if any(character in str(item) for character in '\r\n\x00"'):
            raise ValueError("Invalid Windows path")
    if not root.is_dir() or not home.is_dir() or not node.is_file() or not cli_entry.is_file():
        raise ValueError("Invalid selected instance or runtime")
    if not os.environ.get("USERPROFILE") or Path(os.environ["USERPROFILE"]).resolve() != home:
        raise ValueError("Refusing to configure a different Windows user's PATH")
    localappdata = Path(os.environ.get("LOCALAPPDATA", ""))
    if not localappdata.is_absolute() or not localappdata.is_dir():
        raise ValueError("Current user's LOCALAPPDATA is unavailable")
    config = root / "openclaw.json"
    if config.is_symlink() or not config.is_file():
        raise ValueError("Selected-instance config required")
    if not 1024 <= port <= 65535 or json.loads(config.read_text(encoding="utf-8-sig")).get("gateway", {}).get("port") != port:
        raise ValueError("Port must match the selected config")
    identifier = hashlib.sha256(str(root).casefold().encode()).hexdigest()[:12]
    environment = instance_environment(root, home, identifier, profile)
    invocation = {name: value for name, value in os.environ.items() if name not in environment}
    invocation.update({name: value for name, value in environment.items() if value})
    invocation["PATH"] = str(node.parent) + os.pathsep + os.environ.get("PATH", "")
    checked = subprocess.run([str(node), str(cli_entry), "--version"], env=invocation,
                             capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60, check=False)
    version_output = checked.stdout.strip()
    if checked.returncode or not re.fullmatch(r"(?:OpenClaw\s+)?" + re.escape(VERSION) + r"(?:\s+\([^\r\n]+\))?", version_output):
        raise ValueError("Private OpenClaw CLI version check failed; no PATH changed")
    directory = localappdata / "OpenClaw" / "bin"
    if directory.resolve() != directory:
        raise ValueError("Refusing redirected CLI directory")
    alias = directory / ("openclaw-member-" + identifier + ".cmd")
    default = directory / "openclaw.cmd"
    body = shim_payload(node, cli_entry, environment, identifier)
    marker = ("@rem OpenClaw member CLI " + identifier + "\r\n").encode()
    existing_command = shutil.which("openclaw")
    default_available = not existing_command or Path(existing_command).resolve() == default
    default_available = default_available and (not default.exists() or marker in default.read_bytes().splitlines(keepends=True)[:3])
    destinations = [alias, default] if default_available else [alias]
    for destination in destinations:
        if destination.is_symlink() or destination.exists() and marker not in destination.read_bytes().splitlines(keepends=True)[:3]:
            raise ValueError("Refusing to replace another instance's CLI")
    backup = root / "backups" / ("windows-cli-" + str(time.time_ns()))
    for destination in destinations:
        if destination.is_file() and destination.read_bytes() == body:
            continue
        if destination.exists():
            atomic_write(backup / destination.name, destination.read_bytes())
        atomic_write(destination, body)
    changed = update_user_path(directory, backup)
    os.environ["PATH"] = merge_path(os.environ.get("PATH", ""), [directory])
    notified = broadcast_environment()
    return {"cli_path": str(default if default_available else alias), "cli_alias": alias.stem,
            "default_cli": default_available, "user_bin": str(directory), "user_path_updated": changed,
            "environment_broadcast": notified, "parent_terminal_refresh_required": True,
            "environment": environment, "version": VERSION, "gateway_installed": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("root", "home", "node", "cli-entry"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--profile")
    args = parser.parse_args()
    print(json.dumps(install(args.root, args.home, args.node, args.cli_entry, args.port, args.profile)))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError):
        print(json.dumps({"status": "failed", "reason": "windows_cli_validation_or_io"}))
        raise SystemExit(1)
