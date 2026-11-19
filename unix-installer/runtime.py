"""Install the pinned OpenClaw runtime inside one fresh Unix instance."""

import json
import os
from pathlib import Path
import re
import subprocess

from python_exec import restore_library_path


OPENCLAW_VERSION = "2026.11.4"


def instance_environment(root, home, node):
    root, home, node = Path(root), Path(home), Path(node)
    prefix = ".openclaw-member-"
    if root.parent != home or not root.name.startswith(prefix):
        raise ValueError("Instance must use the canonical profile path in the user home")
    member = root.name[len(prefix):]
    if not re.fullmatch(r"[a-z][a-z0-9_-]{0,56}", member):
        raise ValueError("Invalid instance profile")
    env = restore_library_path(dict(os.environ))
    for name in ("OPENCLAW_HOME", "OPENCLAW_GATEWAY_PORT", "OPENCLAW_GATEWAY_TOKEN",
                 "OPENCLAW_GATEWAY_PASSWORD", "OPENCLAW_SYSTEMD_UNIT", "OPENCLAW_LAUNCHD_LABEL",
                 "OPENCLAW_WINDOWS_TASK_NAME", "OPENCLAW_TASK_SCRIPT", "OPENCLAW_WRAPPER",
                 "OPENCLAW_SERVICE_KIND", "OPENCLAW_SERVICE_MARKER", "PYTHONHOME", "PYTHONPATH"):
        env.pop(name, None)
    env.update({"HOME": str(home), "OPENCLAW_STATE_DIR": str(root),
                "OPENCLAW_CONFIG_PATH": str(root / "openclaw.json"),
                "OPENCLAW_WORKSPACE_DIR": str(root / "workspace"),
                "OPENCLAW_PROFILE": "member-" + member,
                "PATH": str(node.parent) + os.pathsep + env.get("PATH", "")})
    return env


def _run(command, env, timeout, step):
    try:
        return subprocess.run([str(item) for item in command], env=env, check=True, timeout=timeout,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
    except (subprocess.SubprocessError, OSError):
        raise RuntimeError(step + " failed; no credentials were printed") from None


def install(root, home, node, npm, extra_bins=()):
    root, home, node, npm = (Path(item) for item in (root, home, node, npm))
    if any(not item.is_absolute() or item.resolve() != item or not item.exists() for item in (root, home, node)):
        raise ValueError("Invalid instance or Node paths")
    if not npm.is_absolute() or not npm.is_file() or not (root / "openclaw.json").is_file():
        raise ValueError("Invalid instance configuration or npm executable")
    directory = root / "runtime" / OPENCLAW_VERSION
    if directory.exists() or directory.is_symlink():
        raise FileExistsError("Runtime already exists; it was not changed")
    directory.mkdir(parents=True, mode=0o700)
    package = {"name": "member-openclaw-runtime", "version": "1.0.0", "private": True,
               "allowScripts": {key: True for key in ("@google/genai", "esbuild", "koffi", "openclaw",
                                                        "protobufjs", "tree-sitter-bash")}}
    (directory / "package.json").write_text(json.dumps(package) + "\n", encoding="utf-8")
    env = instance_environment(root, home, node)
    if extra_bins:
        env["PATH"] = str(node.parent) + os.pathsep + os.pathsep.join(str(item) for item in extra_bins) + os.pathsep + os.environ.get("PATH", "")
    env["npm_config_cache"] = str(root / "npm-cache")
    _run([npm, "install", "--prefix", directory, "openclaw@" + OPENCLAW_VERSION,
          "--no-audit", "--no-fund"], env, 900, "OpenClaw installation")
    entry = directory / "node_modules" / "openclaw" / "openclaw.mjs"
    postinstall = directory / "node_modules" / "openclaw" / "scripts" / "postinstall-bundled-plugins.mjs"
    if not entry.is_file() or not postinstall.is_file():
        raise RuntimeError("OpenClaw runtime is incomplete")
    _run([node, postinstall], env, 900, "Bundled plugin installation")
    version = _run([node, entry, "--version"], env, 60, "OpenClaw version check")
    if not re.search(r"(?<![0-9.])" + re.escape(OPENCLAW_VERSION) + r"(?![0-9.])", version):
        raise RuntimeError("Unexpected OpenClaw runtime version")
    return entry, env
