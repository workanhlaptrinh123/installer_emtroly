"""Install the bundled module catalog and skills into a fresh instance."""

import os
from pathlib import Path
import shutil
import subprocess
from python_exec import command as python_command


def install(root, source, enable_zalo=True):
    root, source = Path(root), Path(source)
    if (not root.is_absolute() or root.resolve() != root or not (root / "openclaw.json").is_file() or
            not source.is_absolute() or source.resolve() != source):
        raise ValueError("Invalid instance or installer payload")
    catalog = root / "module-catalog"
    if catalog.exists() or catalog.is_symlink():
        raise FileExistsError("Existing module catalog was not changed")
    required = (source / "modules", source / "profiles", source / "native" / "skills")
    for folder in required:
        if not folder.is_dir() or folder.is_symlink():
            raise ValueError("Module payload is incomplete")
        for current, directories, files in os.walk(folder, followlinks=False):
            if any((Path(current) / name).is_symlink() for name in directories + files):
                raise ValueError("Module payload contains a symbolic link")
    catalog.mkdir(mode=0o700)
    for name, folder in zip(("modules", "profiles", "skills"), required):
        shutil.copytree(folder, catalog / name)
    shutil.copy2(source / "native" / "module-skills.json", catalog / "module-skills.json")
    manager = source / "native" / "module-manager.py"
    shutil.copy2(manager, root / "module-manager.py")
    profile_name = "basic-assistant-full" if enable_zalo else "installer-core"
    command = python_command(root / "module-manager.py", "install", "--openclaw-root", root,
                             "--catalog-root", catalog, "--skills-source", catalog / "skills",
                             "--profile", profile_name)
    try:
        subprocess.run(command, check=True, capture_output=True, timeout=300)
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError("Module and skill installation failed") from None
    expected_skills = ["cap-full-quyen-telegram-openclaw"]
    if enable_zalo:
        expected_skills.extend([
            "telegram-zalo-owner-login",
            "openclaw-telegram-zalo-qr-delivery",
            "openclaw-zalo-reply-mention",
        ])
    for skill in expected_skills:
        if not (root / "workspace" / "skills" / skill / "SKILL.md").is_file():
            raise RuntimeError("Required skill was not installed: " + skill)
