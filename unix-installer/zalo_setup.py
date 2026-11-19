"""Prepare the Zalo and owner-QR plugins for one isolated instance."""

import json
import os
from pathlib import Path
import subprocess
from runtime import OPENCLAW_VERSION, _run
from python_exec import command as python_command


def _verify_permissions(config, member, owners):
    telegram = config.get("channels", {}).get("telegram", {})
    account = telegram.get("accounts", {}).get(member, {})
    bindings = [item for item in config.get("bindings", []) if item.get("agentId") == "main"
                and item.get("match", {}).get("channel") == "telegram"
                and item.get("match", {}).get("accountId") == member]
    if len(bindings) != 1:
        raise RuntimeError("Telegram owner binding verification failed")
    for owner in owners:
        lists = (config.get("commands", {}).get("ownerAllowFrom", []), telegram.get("allowFrom", []),
                 account.get("allowFrom", []), telegram.get("execApprovals", {}).get("approvers", []),
                 account.get("execApprovals", {}).get("approvers", []))
        if "telegram:" + owner not in lists[0] or any(owner not in values for values in lists[1:]):
            raise RuntimeError("Telegram owner permission verification failed")
        for kind in ("exec", "plugin"):
            policy = config.get("approvals", {}).get(kind, {})
            targets = [item for item in policy.get("targets", []) if item.get("channel") == "telegram"
                       and item.get("accountId") == member and str(item.get("to")) == owner]
            if policy.get("enabled") is not True or policy.get("mode") != "targets" or "main" not in policy.get("agentFilter", []) or not targets:
                raise RuntimeError("Telegram approval target verification failed")
    if "*" in account.get("groupAllowFrom", []):
        raise RuntimeError("Telegram group senders are not restricted to owners")
    for policy in (config.get("tools", {}).get("exec", {}),
                   config.get("agents", {}).get("entries", {}).get("main", {}).get("tools", {}).get("exec", {})):
        if policy.get("host") != "gateway" or policy.get("mode") != "full" or policy.get("strictInlineEval") is not False:
            raise RuntimeError("Full Exec policy verification failed")


def _cli_json(node, entry, env, arguments):
    output = _run([node, entry, *arguments], env, 120, "OpenClaw plugin inspection")
    try:
        return json.loads(output)
    except json.JSONDecodeError:
        raise RuntimeError("OpenClaw returned invalid plugin information") from None


def configure(root, home, node, entry, env, member, owners, source):
    root, home, node, entry, source = (Path(item) for item in (root, home, node, entry, source))
    if not (root / "openclaw.json").is_file() or root.resolve() != root or root not in entry.parents:
        raise ValueError("A private OpenClaw instance is required")
    environment = dict(env)
    environment["PATH"] = str(entry.parent.parent / ".bin") + os.pathsep + environment.get("PATH", "")
    command = [node, entry]
    owner_tool = source / "native/skills/tao-tro-ly-openclaw-windows-macos-linux/scripts/ensure_default_telegram_owner.py"
    training = source / "native/skills/sync-openclaw-owner-training/scripts/sync_owner_training_policy.py"
    backups = root / "backups" / "onboarding"
    owner_args = python_command(owner_tool, "--openclaw-root", root, "--account-id", member,
                                "--agent-id", "main", "--apply", "--backup-dir", backups / "owner")
    for owner in owners:
        owner_args.extend(["--owner-id", owner])
    _run(owner_args, environment, 120, "Telegram owner setup")
    _run(python_command(training, "--openclaw-root", root, "--workspace", root / "workspace",
                        "--apply", "--backup-dir", backups / "training"), environment, 120, "Owner training setup")
    _run(python_command(source / "native/finalize_permissions.py", "--config", root / "openclaw.json",
                        "--owners", ",".join(owners)), environment, 120, "Owner permissions setup")
    _verify_permissions(json.loads((root / "openclaw.json").read_text(encoding="utf-8")), member, owners)
    approvals = {"version": 1, "defaults": {"security": "allowlist", "ask": "on-miss",
                 "askFallback": "deny", "autoAllowSkills": False},
                 "agents": {"main": {"security": "full", "ask": "off", "askFallback": "full",
                                     "autoAllowSkills": True, "allowlist": []}}}
    try:
        subprocess.run([str(item) for item in [*command, "approvals", "set", "--stdin", "--json"]],
                       input=json.dumps(approvals), env=environment, check=True, timeout=120,
                       capture_output=True, text=True)
    except (subprocess.SubprocessError, OSError):
        raise RuntimeError("Full Exec approval setup failed") from None
    approval_state = _cli_json(node, entry, environment, ["approvals", "get", "--json"])
    actual = approval_state.get("file", {}).get("agents", {}).get("main", {})
    if actual.get("security") != "full" or actual.get("ask") != "off":
        raise RuntimeError("Full Exec approval verification failed")
    try:
        info = _cli_json(node, entry, environment, ["plugins", "info", "zalouser", "--json"])
    except RuntimeError:
        _run([*command, "plugins", "install", "--pin", "@openclaw/zalouser@" + OPENCLAW_VERSION],
             environment, 600, "Zalo plugin installation")
        info = _cli_json(node, entry, environment, ["plugins", "info", "zalouser", "--json"])
    plugin = info.get("plugin", {})
    if plugin.get("packageName") != "@openclaw/zalouser" or plugin.get("version") != OPENCLAW_VERSION:
        raise RuntimeError("Zalo plugin version does not match OpenClaw")
    if plugin.get("enabled") is not True:
        _run([*command, "plugins", "enable", "zalouser"], environment, 120, "Zalo plugin activation")
        plugin = _cli_json(node, entry, environment, ["plugins", "info", "zalouser", "--json"]).get("plugin", {})
    if plugin.get("enabled") is not True or plugin.get("status") != "loaded" or not plugin.get("source"):
        raise RuntimeError("Zalo plugin did not load")
    _run(python_command(source / "zalo/configure-zalo.py", "--root", root, "--private-access"),
         environment, 120, "Zalo configuration")
    qr = root / "workspace/skills/telegram-zalo-owner-login/scripts/deploy-native.py"
    _run(python_command(qr, "--root", root, "--home", home, "--node", node, "--cli-entry", entry,
                        "--telegram-account", member, "--zalo-account", "default", "--agent", "main", "--ensure"),
         environment, 300, "Zalo QR plugin installation")
    _run(python_command(source / "zalo/install-windows-reply-mention.py", "--plugin-source", plugin["source"],
                        "--root", root, "--node", node, "--cli-entry", entry), environment, 300, "Zalo mention setup")
    result = _cli_json(node, entry, environment, ["plugins", "inspect", "telegram-zalo-owner-login", "--runtime", "--json"])
    commands = set(result.get("commands") or [])
    if result.get("plugin", {}).get("status") != "loaded" or not {"zaloqr", "zalostatus"}.issubset(commands):
        raise RuntimeError("Zalo QR commands were not registered")
