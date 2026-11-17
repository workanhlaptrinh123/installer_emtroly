#!/usr/bin/env python3
"""Install and validate clean V6 modules for one member runtime."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path


MODULE_ID = re.compile(r"^[a-z0-9][a-z0-9._-]*$")


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"Cannot read JSON: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit(f"JSON object required: {path}")
    return value


def validate_id(module_id: str) -> None:
    if not MODULE_ID.fullmatch(module_id):
        raise SystemExit(f"Invalid module id: {module_id}")


class ModuleCatalog:
    def __init__(self, module_root: Path, profile_root: Path, skill_root: Path, skill_map_path: Path):
        self.module_root = module_root
        self.profile_root = profile_root
        self.skill_root = skill_root
        self.skill_map = read_json(skill_map_path)
        self.manifests: dict[str, dict] = {}

    def manifest(self, module_id: str) -> dict:
        validate_id(module_id)
        if module_id in self.manifests:
            return self.manifests[module_id]
        module_dir = self.module_root / module_id
        manifest_path = module_dir / "module.json"
        if not manifest_path.is_file():
            raise SystemExit(f"Missing module metadata: {module_id}")
        data = read_json(manifest_path)
        if data.get("id") != module_id:
            raise SystemExit(f"Module id mismatch: {module_id}")
        if not data.get("version"):
            raise SystemExit(f"Module version missing: {module_id}")
        for field in ("requires", "conflicts"):
            if not isinstance(data.get(field, []), list):
                raise SystemExit(f"Module field must be a list: {module_id}.{field}")
        self.manifests[module_id] = data
        return data

    def profile_modules(self, profile_id: str, seen: set[str] | None = None) -> list[str]:
        validate_id(profile_id)
        seen = seen or set()
        if profile_id in seen:
            raise SystemExit(f"Profile inheritance cycle: {profile_id}")
        seen.add(profile_id)
        data = read_json(self.profile_root / f"{profile_id}.json")
        modules: list[str] = []
        parent = data.get("extends")
        if parent:
            modules.extend(self.profile_modules(parent, seen))
        modules.extend(data.get("modules", []))
        return modules

    def resolve(self, profile_id: str | None, requested: list[str]) -> list[str]:
        selected = self.profile_modules(profile_id or "basic-assistant-full")
        selected.extend(requested)
        resolved: list[str] = []
        visiting: set[str] = set()

        def add(module_id: str) -> None:
            validate_id(module_id)
            if module_id in resolved:
                return
            if module_id in visiting:
                raise SystemExit(f"Module dependency cycle: {module_id}")
            visiting.add(module_id)
            data = self.manifest(module_id)
            for dependency in data["requires"]:
                add(dependency)
            visiting.remove(module_id)
            resolved.append(module_id)

        for module_id in selected:
            add(module_id)
        for module_id in resolved:
            conflicts = set(self.manifest(module_id)["conflicts"])
            conflict = conflicts.intersection(resolved)
            if conflict:
                raise SystemExit(f"Module conflict: {module_id} with {sorted(conflict)}")
        return resolved


def read_selection(selection_path: Path, enabled_path: Path) -> tuple[str | None, list[str]]:
    if selection_path.is_file():
        data = read_json(selection_path)
        profile = data.get("profile")
        requested = data.get("modules") or []
        if not isinstance(profile, (str, type(None))) or not isinstance(requested, list):
            raise SystemExit("Member module selection requires profile:string and modules:list")
        return profile, requested
    if enabled_path.is_file():
        return None, [line.strip() for line in enabled_path.read_text().splitlines()
                      if line.strip() and not line.lstrip().startswith("#")]
    return "basic-assistant-full", []


def install(args: argparse.Namespace) -> None:
    module_root = Path(args.module_root)
    profile_root = Path(args.profile_root)
    state_root = Path(args.state_root)
    profile, requested = read_selection(Path(args.selection), module_root / "enabled.txt")
    catalog = ModuleCatalog(module_root, profile_root, Path(args.skill_root), Path(args.skill_map))
    modules = catalog.resolve(profile, requested)
    state_root.mkdir(parents=True, exist_ok=True)
    os.makedirs("/root/.openclaw/workspace/skills", mode=0o755, exist_ok=True)
    os.makedirs("/root/Apps", mode=0o755, exist_ok=True)
    os.makedirs("/etc/supervisor/conf.d", mode=0o755, exist_ok=True)

    for module_id in modules:
        module_dir = module_root / module_id
        data = catalog.manifest(module_id)
        state_path = state_root / f"{module_id}.json"
        previous = read_json(state_path) if state_path.is_file() else {}
        if previous.get("version") == data["version"] and previous.get("status") == "installed":
            continue
        for name, destination in (
            ("skills", Path("/root/.openclaw/workspace/skills")),
            ("apps", Path("/root/Apps")),
            ("supervisor", Path("/etc/supervisor/conf.d")),
            ("bin", Path("/usr/local/bin")),
        ):
            source = module_dir / name
            if source.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
                for item in source.iterdir():
                    target = destination / item.name
                    if item.is_dir():
                        shutil.copytree(item, target, dirs_exist_ok=True)
                    else:
                        shutil.copy2(item, target)
        for skill in catalog.skill_map.get(module_id, []):
            source = catalog.skill_root / skill
            if not (source / "SKILL.md").is_file():
                raise SystemExit(f"Missing skill payload: {module_id}:{skill}")
            target = Path("/root/.openclaw/workspace/skills") / skill
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(source, target)
        state_path.write_text(json.dumps({
            "id": module_id,
            "version": data["version"],
            "tier": data.get("tier", "optional"),
            "status": "installed",
            "release": "member-vps-v6-20261006",
            "skills": catalog.skill_map.get(module_id, []),
        }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("installed=" + ",".join(modules))


def validate(args: argparse.Namespace) -> None:
    profile, requested = read_selection(Path(args.selection), Path(args.module_root) / "enabled.txt")
    modules = ModuleCatalog(Path(args.module_root), Path(args.profile_root), Path(args.skill_root), Path(args.skill_map)).resolve(profile, requested)
    print("valid=" + ",".join(modules))


def list_state(args: argparse.Namespace) -> None:
    state_root = Path(args.state_root)
    for path in sorted(state_root.glob("*.json")):
        data = read_json(path)
        print(f"{data.get('id', path.stem)}\t{data.get('version', '?')}\t{data.get('status', '?')}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["install", "validate", "list"])
    parser.add_argument("--module-root", default="/opt/member-vps/modules")
    parser.add_argument("--profile-root", default="/opt/member-vps/profiles")
    parser.add_argument("--state-root", default="/root/.openclaw/module-state")
    parser.add_argument("--selection", default="/root/.openclaw/modules.json")
    parser.add_argument("--skill-root", default="/opt/member-vps/skills")
    parser.add_argument("--skill-map", default="/opt/member-vps/module-skills.json")
    args = parser.parse_args()
    if args.command == "install":
        install(args)
    elif args.command == "validate":
        validate(args)
    else:
        list_state(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
