#!/usr/bin/env python3
"""Cross-platform team Git workflow helper for installer_emtroly.

Subcommands:
  status                 Show current branch, dirty files, and all active team branches.
  start <slug> [--carry] Create a new <user>/<slug> branch from latest origin/main.
  check-merge            Normalize BOM/LF rules, verify stub SHA-256, and check conflicts vs origin/main.
  ship -m "<msg>"        Commit, push feature branch, verify zero conflicts, merge into main & clean up.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[4]
REPO_WEB_URL = "https://github.com/workanhlaptrinh123/installer_emtroly"
FORBIDDEN_PATTERNS = (".token", ".secret", ".env")


def run_git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=str(ROOT),
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=check,
    )


def get_current_branch() -> str:
    return run_git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()


def get_user_prefix() -> str:
    raw = run_git("config", "user.name", check=False).stdout.strip()
    slug = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")
    return slug or "dev"


def slugify(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:48] or f"work-{datetime.now().strftime('%Y%m%d-%H%M')}"


def is_dirty() -> bool:
    return bool(run_git("status", "--porcelain").stdout.strip())


def normalize_repo_encodings() -> list[str]:
    changed: list[str] = []
    bom_targets = (
        list((ROOT / "windows-installer").glob("*.ps1"))
        + list((ROOT / "native").glob("*.ps1"))
        + [ROOT / "install-native-windows.ps1"]
    )
    for p in bom_targets:
        if not p.is_file():
            continue
        raw = p.read_bytes()
        fixed = b"\xef\xbb\xbf" + raw.lstrip(b"\xef\xbb\xbf")
        if fixed != raw:
            p.write_bytes(fixed)
            changed.append(str(p.relative_to(ROOT)))

    lf_targets = (
        [ROOT / "MANIFEST.txt", ROOT / "install-windows.ps1", ROOT / ".gitattributes"]
        + list(ROOT.glob("*.sh"))
        + list((ROOT / "unix-installer").glob("*.py"))
    )
    for p in lf_targets:
        if not p.is_file():
            continue
        raw = p.read_bytes()
        fixed = raw.lstrip(b"\xef\xbb\xbf").replace(b"\r\n", b"\n")
        if fixed != raw:
            p.write_bytes(fixed)
            changed.append(str(p.relative_to(ROOT)))
    return changed


def verify_safety_invariants() -> list[str]:
    errors: list[str] = []
    # Check forbidden staged/untracked files
    status_lines = run_git("status", "--porcelain").stdout.splitlines()
    for line in status_lines:
        if len(line) < 4:
            continue
        fname = line[3:].strip().strip('"')
        lower = fname.lower()
        if any(lower.endswith(ext) or f"/{ext}" in lower for ext in FORBIDDEN_PATTERNS):
            errors.append(f"Forbidden secret/env file detected in working tree: {fname}")

    # Verify immutable EmTroLy-Setup.exe SHA-256
    stub_exe = ROOT / "windows-installer/bootstrap-stub/EmTroLy-Setup.exe"
    stub_sha = ROOT / "windows-installer/bootstrap-stub/EmTroLy-Setup.exe.sha256"
    if stub_exe.is_file() and stub_sha.is_file():
        m = re.search(r"\b([a-fA-F0-9]{64})\b", stub_sha.read_text(encoding="utf-8"))
        if m:
            expected = m.group(1).lower()
            actual = hashlib.sha256(stub_exe.read_bytes()).hexdigest().lower()
            if actual != expected:
                errors.append(
                    f"EmTroLy-Setup.exe SHA-256 changed ({actual} != {expected}); revert unless intentionally re-submitting to Microsoft WDSI."
                )
    return errors


def check_conflicts_against_origin_main() -> tuple[bool, list[str]]:
    run_git("fetch", "origin", "main")
    res = run_git("merge-tree", "--write-tree", "--name-only", "origin/main", "HEAD", check=False)
    if res.returncode == 0:
        return True, []
    conflicts = [
        line.strip()
        for line in (res.stdout + "\n" + res.stderr).splitlines()
        if line.strip() and not line.strip().startswith(("CONFLICT", "Auto-merging")) and len(line.strip()) != 40
    ]
    conflict_msgs = [line.strip() for line in res.stdout.splitlines() if "CONFLICT" in line]
    return False, conflict_msgs or conflicts or ["Unknown merge conflict with origin/main"]


def cmd_status(_args: argparse.Namespace) -> int:
    run_git("fetch", "origin", "--prune", check=False)
    branch = get_current_branch()
    counts = run_git("rev-list", "--left-right", "--count", "origin/main...HEAD", check=False).stdout.strip().split()
    behind, ahead = (counts[0], counts[1]) if len(counts) == 2 else ("?", "?")
    print(f"Current branch : {branch} (ahead {ahead}, behind {behind} vs origin/main)")
    print(f"Git user       : {run_git('config', 'user.name', check=False).stdout.strip() or '(not set)'}")

    dirty = run_git("status", "--short").stdout.strip()
    print("\nLocal changes:")
    print(dirty if dirty else "  (clean)")

    print("\nActive remote team branches:")
    fmt = "%(refname:short)|%(authorname)|%(committerdate:relative)|%(subject)"
    refs = run_git("for-each-ref", "--sort=-committerdate", f"--format={fmt}", "refs/remotes/origin").stdout.splitlines()
    found_any = False
    for line in refs:
        parts = line.split("|", 3)
        if len(parts) != 4:
            continue
        ref_name, author, rel_time, subject = parts
        if ref_name in ("origin", "origin/HEAD", "origin/main"):
            continue
        found_any = True
        print(f"  - {ref_name} | {author} | {rel_time} | {subject}")
    if not found_any:
        print("  (none - all branches merged into main)")
    return 0


def cmd_start(args: argparse.Namespace) -> int:
    if is_dirty() and not args.carry:
        print("ERROR: Working tree has uncommitted changes. Commit them first or pass --carry.", file=sys.stderr)
        return 1
    run_git("fetch", "origin", "main")
    branch_name = f"{get_user_prefix()}/{slugify(args.slug)}"
    if args.carry:
        run_git("checkout", "-b", branch_name)
    else:
        run_git("checkout", "-B", branch_name, "origin/main")
    print(f"Created and switched to branch: {branch_name}")
    return 0


def cmd_check_merge(_args: argparse.Namespace) -> int:
    normalized = normalize_repo_encodings()
    if normalized:
        print("Normalized BOM/LF on:", ", ".join(normalized))
    errors = verify_safety_invariants()
    if errors:
        for e in errors:
            print(f"SAFETY ERROR: {e}", file=sys.stderr)
        return 1

    ok, conflicts = check_conflicts_against_origin_main()
    if not ok:
        print("CONFLICT DETECTED against origin/main:", file=sys.stderr)
        for c in conflicts:
            print(f"  - {c}", file=sys.stderr)
        return 2
    print("CHECK_MERGE_OK: Zero conflicts with origin/main and all safety checks passed.")
    return 0


def cmd_ship(args: argparse.Namespace) -> int:
    normalized = normalize_repo_encodings()
    if normalized:
        print("Normalized BOM/LF on:", ", ".join(normalized))
    errors = verify_safety_invariants()
    if errors:
        for e in errors:
            print(f"SAFETY ERROR: {e}", file=sys.stderr)
        return 1

    branch = get_current_branch()
    if branch == "main":
        if not is_dirty():
            print("Already on main with no local changes to ship.")
            return 0
        branch = f"{get_user_prefix()}/work-{datetime.now().strftime('%Y%m%d-%H%M')}"
        run_git("checkout", "-b", branch)
        print(f"Auto-created feature branch: {branch}")

    if is_dirty():
        run_git("add", "-A")
        commit_res = run_git("commit", "-m", args.message, check=False)
        if commit_res.returncode != 0:
            print(commit_res.stdout + commit_res.stderr, file=sys.stderr)
            return 1
        print(f"Committed changes on {branch}.")

    ok, conflicts = check_conflicts_against_origin_main()
    if not ok:
        print("CONFLICT DETECTED against origin/main. Resolve before merging:", file=sys.stderr)
        for c in conflicts:
            print(f"  - {c}", file=sys.stderr)
        return 2

    push_branch = run_git("push", "-u", "origin", branch, check=False)
    if push_branch.returncode != 0:
        print(push_branch.stdout + push_branch.stderr, file=sys.stderr)
        return 1
    print(f"Pushed branch to origin/{branch}.")

    # Switch to main, fast-forward from origin/main, merge feature branch cleanly
    run_git("checkout", "main")
    run_git("pull", "--ff-only", "origin", "main")
    merge_res = run_git("merge", "--no-ff", branch, "-m", f"merge({branch}): {args.message}", check=False)
    if merge_res.returncode != 0:
        run_git("merge", "--abort", check=False)
        run_git("checkout", branch, check=False)
        print("Merge into main hit an unexpected conflict and was aborted safely.", file=sys.stderr)
        print(merge_res.stdout + merge_res.stderr, file=sys.stderr)
        return 2

    push_main = run_git("push", "origin", "main", check=False)
    if push_main.returncode != 0:
        # Branch protection active on main: reset local main back to origin/main and provide PR link
        run_git("reset", "--hard", "origin/main")
        run_git("checkout", branch)
        pr_url = f"{REPO_WEB_URL}/compare/main...{branch}?expand=1"
        print("Branch protection is active on main (direct push blocked by GitHub).")
        print(f"Your branch origin/{branch} is pushed and conflict-free!")
        print(f"Open 1-click Pull Request: {pr_url}")
        return 0

    # Clean up merged temporary branch locally & remotely
    run_git("branch", "-d", branch, check=False)
    run_git("push", "origin", "--delete", branch, check=False)
    print(f"SHIP_OK: Merged {branch} into main, pushed origin/main, and cleaned up temporary branch.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="installer_emtroly Team Git Flow helper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="Show current branch and active team branches")

    p_start = sub.add_parser("start", help="Create a new feature branch from origin/main")
    p_start.add_argument("slug", help="Short task slug (e.g. fix-zalo-qr)")
    p_start.add_argument("--carry", action="store_true", help="Carry current uncommitted edits onto new branch")

    sub.add_parser("check-merge", help="Check BOM/LF, safety invariants, and conflicts against origin/main")

    p_ship = sub.add_parser("ship", help="Commit, push branch, verify zero conflicts, and merge into main")
    p_ship.add_argument("-m", "--message", required=True, help="Commit & merge message")

    args = parser.parse_args()
    if args.cmd == "status":
        return cmd_status(args)
    if args.cmd == "start":
        return cmd_start(args)
    if args.cmd == "check-merge":
        return cmd_check_merge(args)
    if args.cmd == "ship":
        return cmd_ship(args)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
