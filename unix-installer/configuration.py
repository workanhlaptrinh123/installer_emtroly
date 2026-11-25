"""Build an isolated OpenClaw configuration without embedding provider secrets."""

from pathlib import Path
import secrets


def create_config(settings, root, port):
    root = Path(root)
    if not root.is_absolute() or not 1024 <= port <= 65000:
        raise ValueError("Invalid instance root or port")
    owners = settings["owner_ids"]
    member = settings["member"]
    model = settings["model"]
    token_file = str(root / "telegram.token")
    secret_file = str(root / "member-provider.secret")
    execution = {"host": "gateway", "mode": "full", "strictInlineEval": False}
    groups_cfg = (
        {settings["group_id"]: {"groupPolicy": "allowlist", "requireMention": False}}
        if settings.get("group_id")
        else {}
    )
    return {
        "gateway": {"mode": "local", "bind": "loopback", "port": port,
                    "auth": {"mode": "token", "token": secrets.token_hex(32)}},
        "secrets": {"providers": {"customer": {"source": "file", "path": secret_file, "mode": "singleValue"}}},
        "models": {"providers": {
            "customer": {"baseUrl": settings["base_url"],
                         "apiKey": {"source": "file", "provider": "customer", "id": "value"},
                         "api": "openai-completions", "models": [{"id": model, "name": model}]},
            "openai": {"baseUrl": settings["base_url"],
                       "apiKey": {"source": "file", "provider": "customer", "id": "value"},
                       "auth": "api-key", "api": "openai-completions",
                       "models": [{"id": "cx/gpt-image-2", "name": "Member image API"}]}}},
        "agents": {"defaults": {"workspace": str(root / "workspace"), "model": {"primary": "customer/" + model},
                                "mediaModels": {"image": {"primary": "openai/cx/gpt-image-2", "timeoutMs": 240000}}},
                   "entries": {"main": {"name": settings["assistant_name"], "tools": {"exec": execution,
                       "toolsBySender": {"*": {"alsoAllow": ["exec", "process", "group:fs"]}}}}}},
        "channels": {"telegram": {"enabled": True, "groupPolicy": "allowlist", "defaultAccount": member,
            "commands": {"native": True, "nativeSkills": False}, "accounts": {member: {
                "enabled": True, "tokenFile": token_file, "dmPolicy": "allowlist", "allowFrom": owners,
                "groupPolicy": "allowlist", "groupAllowFrom": owners,
                "groups": groups_cfg}}}},
        "bindings": [{"agentId": "main", "match": {"channel": "telegram", "accountId": member}}],
        "commands": {"ownerAllowFrom": ["telegram:" + owner for owner in owners]},
        "tools": {"exec": execution},
    }
