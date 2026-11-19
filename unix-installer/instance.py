"""Create a fresh per-user installation without changing existing instances."""

import json
import os
from pathlib import Path

from configuration import create_config
from settings import validate


def _write_private(path, content):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(content)


def initialize(settings, home, port):
    values = validate(settings)
    home = Path(home)
    if not home.is_absolute() or home.resolve() != home or home != Path.home().resolve() or not home.is_dir():
        raise ValueError("Current user's resolved home directory is required")
    root = home / (".openclaw-member-" + values["member"])
    if root.exists() or root.is_symlink():
        raise FileExistsError("Instance already exists; it was not changed")
    document = create_config(values, root, port)
    root.mkdir(mode=0o700)
    (root / "workspace").mkdir(mode=0o700)
    _write_private(root / "telegram.token", values["telegram_token"] + "\n")
    _write_private(root / "member-provider.secret", values["ai_api_key"] + "\n")
    _write_private(root / "openclaw.json", json.dumps(document, ensure_ascii=False, indent=2) + "\n")
    return root
