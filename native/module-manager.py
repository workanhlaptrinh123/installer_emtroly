#!/usr/bin/env python3
"""Cross-platform native V6 module manager."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def safe_id(value: str) -> bool:
    return bool(value) and all(ch.isalnum() or ch in "._-" for ch in value) and value[0].isalnum()


class Catalog:
    def __init__(self, root: Path):
        self.root = root
        self.modules = root / "modules"
        self.profiles = root / "profiles"
        self.skill_map = read_json(root / "module-skills.json")

    def metadata(self, module_id: str) -> dict:
        path = self.modules / module_id / "module.json"
        if not path.is_file():
            raise SystemExit(f"Unknown module: {module_id}")
        data = read_json(path)
        if data.get("id") != module_id or not data.get("version"):
            raise SystemExit(f"Invalid metadata: {path}")
        return data

    def profile_modules(self, profile: str, seen: set[str] | None = None) -> list[str]:
        seen = seen or set()
        if profile in seen:
            raise SystemExit(f"Profile cycle detected: {profile}")
        path = self.profiles / f"{profile}.json"
        if not path.is_file():
            raise SystemExit(f"Unknown profile: {profile}")
        data = read_json(path)
        resolved: list[str] = []
        parent = data.get("extends")
        if parent:
            resolved.extend(self.profile_modules(parent, seen | {profile}))
        resolved.extend(data.get("modules", []))
        return unique(resolved)

    def resolve(self, profile: str, requested: list[str]) -> list[str]:
        result: list[str] = []
        for module_id in self.profile_modules(profile) + requested:
            if module_id not in result:
                result.append(module_id)
        changed = True
        while changed:
            changed = False
            for module_id in list(result):
                for dependency in self.metadata(module_id).get("requires", []):
                    if dependency not in result:
                        result.insert(0, dependency)
                        changed = True
        for module_id in result:
            self.metadata(module_id)
        for module_id in result:
            conflicts = set(self.metadata(module_id).get("conflicts", []))
            if conflicts.intersection(result):
                raise SystemExit(f"Module conflict: {module_id}")
        return unique(result)

    def validate_skills(self, module_ids: list[str], source: Path) -> None:
        missing = []
        for module_id in module_ids:
            for skill in self.skill_map.get(module_id, []):
                if not (source / skill / "SKILL.md").is_file():
                    missing.append(f"{module_id}:{skill}")
        if missing:
            raise SystemExit("Missing native skill payloads: " + ", ".join(missing))


def unique(values: list[str]) -> list[str]:
    result: list[str] = []
    for value in values:
        if value not in result:
            result.append(value)
    return result


def paths(args: argparse.Namespace) -> tuple[Path, Path, Path, Path, Path]:
    root = Path(args.openclaw_root).expanduser()
    catalog_root = Path(args.catalog_root).expanduser()
    source = Path(args.skills_source).expanduser()
    state = root / "module-state"
    selection = root / "modules.json"
    return root, catalog_root, source, state, selection


def selection(selection_path: Path) -> tuple[str, list[str]]:
    if not selection_path.is_file():
        return "basic-assistant-full", []
    data = read_json(selection_path)
    return data.get("profile", "basic-assistant-full"), data.get("modules", [])


def install(args: argparse.Namespace) -> None:
    root, catalog_root, source, state_root, selection_path = paths(args)
    catalog = Catalog(catalog_root)
    profile, requested = selection(selection_path)
    if args.profile:
        profile = args.profile
    if args.module:
        requested.extend(args.module)
    modules = catalog.resolve(profile, requested)
    catalog.validate_skills(modules, source)
    if args.dry_run:
        print("valid=" + ",".join(modules))
        return
    workspace = root / "workspace" / "skills"
    installed_at = datetime.now(timezone.utc).isoformat()
    write_json(selection_path, {"profile": profile, "modules": unique(requested)})
    state_root.mkdir(parents=True, exist_ok=True)
    for module_id in modules:
        copied: list[str] = []
        module_root = catalog.modules / module_id
        for skill in catalog.skill_map.get(module_id, []):
            src = source / skill
            dest = workspace / skill
            dest.parent.mkdir(parents=True, exist_ok=True)
            if dest.exists():
                shutil.rmtree(dest)
            shutil.copytree(src, dest)
            copied.append(skill)
        for directory_name, destination in (("apps", root / "Apps"),):
            payload = module_root / directory_name
            if payload.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
                for item in payload.iterdir():
                    target = destination / item.name
                    if item.is_dir():
                        shutil.copytree(item, target, dirs_exist_ok=True)
                    else:
                        shutil.copy2(item, target)
        write_json(state_root / f"{module_id}.json", {
            "id": module_id,
            "version": catalog.metadata(module_id)["version"],
            "tier": catalog.metadata(module_id).get("tier", "optional"),
            "status": "installed",
            "installed_at": installed_at,
            "platform": sys.platform,
            "profile": profile,
            "skills": copied,
            "payload_root": str(module_root),
        })
    print("installed=" + ",".join(modules))


def validate(args: argparse.Namespace) -> None:
    root, catalog_root, source, _, selection_path = paths(args)
    catalog = Catalog(catalog_root)
    profile, requested = selection(selection_path)
    if args.profile:
        profile = args.profile
    if args.module:
        requested.extend(args.module)
    modules = catalog.resolve(profile, requested)
    catalog.validate_skills(modules, source)
    print("valid=" + ",".join(modules))


def list_state(args: argparse.Namespace) -> None:
    _, _, _, state_root, _ = paths(args)
    for path in sorted(state_root.glob("*.json")):
        data = read_json(path)
        print(f"{data.get('id', path.stem)}\t{data.get('version', '?')}\t{data.get('status', '?')}")


def remove(args: argparse.Namespace) -> None:
    root, _, _, state_root, selection_path = paths(args)
    if not args.module:
        raise SystemExit("remove requires --module MODULE_ID")
    target = state_root / f"{args.module[0]}.json"
    if not target.is_file():
        raise SystemExit(f"Module is not installed: {args.module[0]}")
    state = read_json(target)
    other_skills: set[str] = set()
    for path in state_root.glob("*.json"):
        if path != target:
            other_skills.update(read_json(path).get("skills", []))
    for skill in state.get("skills", []):
        if skill not in other_skills:
            shutil.rmtree(root / "workspace" / "skills" / skill, ignore_errors=True)
    target.unlink()
    profile, requested = selection(selection_path)
    if args.module[0] in requested:
        requested = [module_id for module_id in requested if module_id != args.module[0]]
        write_json(selection_path, {"profile": profile, "modules": requested})
    print("removed=" + args.module[0])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["install", "validate", "list", "remove"])
    parser.add_argument("--openclaw-root", default=os.environ.get("OPENCLAW_ROOT", "~/.openclaw"))
    parser.add_argument("--catalog-root", default=os.environ.get("OPENCLAW_MODULE_CATALOG", "~/.openclaw/module-catalog"))
    parser.add_argument("--skills-source", default=os.environ.get("OPENCLAW_MODULE_SKILLS", "~/.openclaw/module-catalog/skills"))
    parser.add_argument("--profile")
    parser.add_argument("--module", action="append", default=[])
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.command == "install":
        install(args)
    elif args.command == "validate":
        validate(args)
    elif args.command == "list":
        list_state(args)
    else:
        remove(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
