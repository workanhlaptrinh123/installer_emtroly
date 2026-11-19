"""Create an isolated, per-user command for an existing Unix runtime."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid


PATH_START = "# >>> installer_emtroly PATH >>>"
PATH_END = "# <<< installer_emtroly PATH <<<"


def configure_shell_path(root, home, shell):
    shell_name = Path(shell).name
    if shell_name not in ("bash", "zsh"):
        return {"updated": False, "reason": "unsupported-shell"}
    target = home / (".bashrc" if shell_name == "bash" else ".zshrc")
    if target.is_symlink() or (target.exists() and not target.is_file()):
        return {"updated": False, "reason": "unsafe-shell-config"}
    existed = target.exists()
    original = target.read_bytes() if existed else b""
    text = original.decode("utf-8")
    if PATH_START in text or PATH_END in text:
        if text.count(PATH_START) == text.count(PATH_END) == 1 and text.index(PATH_START) < text.index(PATH_END):
            return {"updated": False, "reason": "already-configured"}
        return {"updated": False, "reason": "invalid-existing-markers"}
    backup = root / "backups" / "shell"
    if backup.resolve() != backup:
        return {"updated": False, "reason": "unsafe-backup-directory"}
    backup.mkdir(parents=True, exist_ok=True, mode=0o700)
    if existed:
        backup_path = backup / (target.name + "." + uuid.uuid4().hex)
        descriptor = os.open(backup_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(original)
    snippet = ("\n" + PATH_START + '\ncase ":$PATH:" in *":$HOME/.local/bin:"*) ;; '
               '*) export PATH="$PATH:$HOME/.local/bin" ;; esac\n' + PATH_END + "\n").encode()
    descriptor, name = tempfile.mkstemp(prefix=".installer-path-", dir=home)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(original + snippet)
        if existed:
            temporary.chmod(target.stat().st_mode & 0o777)
        if target.is_symlink() or target.exists() != existed or (existed and target.read_bytes() != original):
            return {"updated": False, "reason": "shell-config-changed"}
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)
    return {"updated": True, "reason": "restart-terminal"}


def install(root, home, node, cli_entry, profile, expected_version, extra_bins=()):
    root, home, node, cli_entry = (Path(value) for value in (root, home, node, cli_entry))
    for path in (root, home, node, cli_entry):
        if not path.is_absolute() or path.resolve() != path or not path.exists():
            raise ValueError("Paths must be existing, absolute, and resolved")
    if home != Path.home().resolve() or root == home or home not in root.parents:
        raise ValueError("Instance must belong to the current user home")
    if not root.is_dir() or not node.is_file() or not cli_entry.is_file() or root not in cli_entry.parents:
        raise ValueError("Invalid private instance or runtime")
    bin_paths = [node.parent]
    for directory in extra_bins:
        path = Path(directory)
        if not path.is_absolute() or path.resolve() != path or not path.is_dir() or ":" in str(path):
            raise ValueError("Invalid private dependency directory")
        if path not in bin_paths:
            bin_paths.append(path)
    if ":" in str(node.parent):
        raise ValueError("Invalid private Node directory")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", profile):
        raise ValueError("Invalid instance profile")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", expected_version):
        raise ValueError("Invalid OpenClaw version")
    config = root / "openclaw.json"
    if config.is_symlink() or not config.is_file():
        raise ValueError("Instance configuration is missing")
    json.loads(config.read_text(encoding="utf-8"))
    result = subprocess.run([str(node), str(cli_entry), "--version"], capture_output=True,
                            text=True, timeout=30, check=True)
    if not re.search(r"(?<![0-9.])" + re.escape(expected_version) + r"(?![0-9.])", result.stdout):
        raise ValueError("Runtime version mismatch")

    user_bin = home / ".local" / "bin"
    if user_bin.resolve() != user_bin:
        raise ValueError("Refusing a symlinked command directory")
    user_bin.mkdir(mode=0o700, parents=True, exist_ok=True)
    if user_bin.resolve() != user_bin or not user_bin.is_dir():
        raise ValueError("Refusing a symlinked command directory")
    identifier = hashlib.sha256(str(root).encode()).hexdigest()[:12]
    alias = "openclaw-member-" + identifier
    environment = {
        "HOME": str(home), "OPENCLAW_STATE_DIR": str(root),
        "OPENCLAW_CONFIG_PATH": str(config), "OPENCLAW_WORKSPACE_DIR": str(root / "workspace"),
        "OPENCLAW_PROFILE": profile,
    }
    lines = ["#!/bin/sh", "unset OPENCLAW_HOME OPENCLAW_GATEWAY_PORT OPENCLAW_GATEWAY_TOKEN OPENCLAW_GATEWAY_PASSWORD",
             "unset OPENCLAW_SYSTEMD_UNIT OPENCLAW_LAUNCHD_LABEL OPENCLAW_WINDOWS_TASK_NAME OPENCLAW_TASK_SCRIPT",
             "unset OPENCLAW_WRAPPER OPENCLAW_SERVICE_KIND OPENCLAW_SERVICE_MARKER"]
    lines.extend("export " + key + "=" + shlex.quote(value) for key, value in environment.items())
    lines.append("export PATH=" + shlex.quote(":".join(str(path) for path in bin_paths)) + ':"$PATH"')
    lines.append("exec " + shlex.quote(str(node)) + " " + shlex.quote(str(cli_entry)) + ' "$@"')
    payload = ("\n".join(lines) + "\n").encode()

    def create(name):
        path = user_bin / name
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700)
        except FileExistsError:
            if not path.is_symlink() and path.is_file() and path.read_bytes() == payload:
                return path
            raise ValueError("Existing command was not modified: " + name) from None
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
        return path

    selected = create(alias)
    existing = shutil.which("openclaw")
    normal = user_bin / "openclaw"
    if existing == str(normal) or (not existing and not normal.exists() and not normal.is_symlink()):
        selected = create("openclaw")
    shell_path = configure_shell_path(root, home, os.environ.get("SHELL", ""))
    return {"command": selected.name, "alias": alias, "directory": str(user_bin),
            "path_present": str(user_bin) in os.environ.get("PATH", "").split(os.pathsep),
            "shell_path": shell_path}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ("root", "home", "node", "cli-entry", "profile", "expected-version"):
        parser.add_argument("--" + argument, required=True)
    parser.add_argument("--extra-bin", action="append", default=[])
    args = parser.parse_args()
    print(json.dumps(install(args.root, args.home, args.node, args.cli_entry, args.profile, args.expected_version,
                             args.extra_bin)))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print("Unable to install Unix CLI: " + str(error), file=sys.stderr)
        raise SystemExit(1)
