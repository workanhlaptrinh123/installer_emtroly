#!/usr/bin/env python3
"""Stage the release skill for new members without changing the shared image."""

import argparse
import runpy
import shutil
from pathlib import Path


def stage(release: Path, state: Path) -> bool:
    manager = runpy.run_path(str(release / "docker/module-manager.py"))
    profile, requested = manager["read_selection"](
        state / "modules.json", release / "modules/enabled.txt"
    )
    catalog = manager["ModuleCatalog"](
        release / "modules", release / "profiles",
        release / "native/skills", release / "native/module-skills.json"
    )
    if "zalo-personal" not in catalog.resolve(profile, requested):
        return False
    staged = []
    for skill in (
        "telegram-zalo-owner-login",
        "openclaw-zalo-text-delivery-guard",
        "openclaw-zalo-context-rotation-70k",
        "openclaw-compaction-recovery",
    ):
        source = release / "native/skills" / skill
        if not (source / "SKILL.md").is_file():
            raise SystemExit(f"Zalo reliability skill payload is missing: {skill}")
        destination = state / "workspace/skills" / skill
        if destination.exists():
            raise SystemExit(f"Zalo skill already exists; staging is for new members only: {skill}")
        shutil.copytree(source, destination)
        staged.append(skill)
    print("zalo_reliability_skills=" + ",".join(staged))
    return True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    args = parser.parse_args()
    print("zalo_text_guard_skill=" + ("staged" if stage(args.release, args.state) else "not-selected"))


if __name__ == "__main__":
    main()
