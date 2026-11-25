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


def get_user_identity() -> tuple[str, str, str]:
    """Return (name, email, branch_prefix) auto-detected from Git email (Gmail) or user.name."""
    name = run_git("config", "user.name", check=False).stdout.strip()
    email = run_git("config", "user.email", check=False).stdout.strip()
    raw = ""
    if email and "@" in email:
        local_part = email.split("@", 1)[0]
        # Strip numeric GitHub noreply prefix like "123456+giangcr7"
        if "+" in local_part and email.lower().endswith("users.noreply.github.com"):
            local_part = local_part.split("+", 1)[1]
        raw = local_part
    if not raw:
        raw = name
    slug = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")
    return name or "(chưa cấu hình)", email or "(chưa cấu hình)", (slug or "dev")


def get_user_prefix() -> str:
    return get_user_identity()[2]


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


def cmd_sync(_args: argparse.Namespace) -> int:
    """Morning 1-click sync: fetch latest origin/main and safely fast-forward local main."""
    fetch_res = run_git("fetch", "origin", "--prune", check=False)
    if fetch_res.returncode != 0:
        print(fetch_res.stdout + fetch_res.stderr, file=sys.stderr)
        return 1

    branch = get_current_branch()
    if branch == "main":
        stashed = False
        if is_dirty():
            stash_res = run_git("stash", "push", "-u", "-m", "team-git-auto-sync", check=False)
            if stash_res.returncode != 0:
                print(stash_res.stdout + stash_res.stderr, file=sys.stderr)
                return 1
            stashed = True

        pull_res = run_git("pull", "--ff-only", "origin", "main", check=False)
        if stashed:
            pop_res = run_git("stash", "pop", check=False)
            if pop_res.returncode != 0:
                print("WARNING: Đã kéo code mới nhưng file đang sửa dở bị trùng dòng (conflict khi pop stash):", file=sys.stderr)
                print(pop_res.stdout + pop_res.stderr, file=sys.stderr)
                return 2

        if pull_res.returncode != 0:
            print("Không thể fast-forward main tự động (main local có commit chưa push). Hãy dùng nút Tạo nhánh / Đẩy PR.", file=sys.stderr)
            print(pull_res.stdout + pull_res.stderr, file=sys.stderr)
            return 1

        print("SYNC_OK: Đã lấy code mới nhất từ origin/main về máy an toàn.")
        return 0

    # On a feature branch: check if behind origin/main
    counts = run_git("rev-list", "--left-right", "--count", "origin/main...HEAD", check=False).stdout.strip().split()
    behind = int(counts[0]) if len(counts) == 2 and counts[0].isdigit() else 0
    if behind == 0:
        print(f"SYNC_OK: Nhánh {branch} đã đồng bộ mới nhất với origin/main.")
        return 0

    if is_dirty():
        print(f"Đã fetch xong. Nhánh {branch} đang chậm hơn origin/main {behind} commit (đang có file sửa dở nên chưa tự gộp).")
        return 0

    ok, conflicts = check_conflicts_against_origin_main()
    if not ok:
        print(f"CONFLICT_DETECTED: Nhánh {branch} chậm hơn origin/main {behind} commit và có xung đột ở các file sau:", file=sys.stderr)
        for c in conflicts:
            print(f"  - {c}", file=sys.stderr)
        return 2

    merge_res = run_git("merge", "--no-edit", "origin/main", check=False)
    if merge_res.returncode != 0:
        run_git("merge", "--abort", check=False)
        print("Không thể tự gộp origin/main vào nhánh hiện tại.", file=sys.stderr)
        return 2

    print(f"SYNC_OK: Đã tự động cập nhật {behind} commit mới từ origin/main vào nhánh {branch} (0 conflict).")
    return 0


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


def cmd_pr(args: argparse.Namespace) -> int:
    """Level-2 workflow: auto-branch by username, check safety/conflicts, push branch for Auto-PR + Approve + Auto-Merge."""
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
            print("Already on main with no local changes to submit as a PR.")
            return 0
        branch = f"{get_user_prefix()}/work-{datetime.now().strftime('%Y%m%d-%H%M')}"
        run_git("checkout", "-b", branch)
        print(f"Auto-created personal branch: {branch}")

    if is_dirty():
        run_git("add", "-A")
        commit_res = run_git("commit", "-m", args.message, check=False)
        if commit_res.returncode != 0:
            print(commit_res.stdout + commit_res.stderr, file=sys.stderr)
            return 1
        print(f"Committed changes on {branch}.")

    ok, conflicts = check_conflicts_against_origin_main()
    if not ok:
        print("CONFLICT DETECTED against origin/main. Resolve before pushing PR:", file=sys.stderr)
        for c in conflicts:
            print(f"  - {c}", file=sys.stderr)
        return 2

    push_branch = run_git("push", "-u", "origin", branch, check=False)
    if push_branch.returncode != 0:
        print(push_branch.stdout + push_branch.stderr, file=sys.stderr)
        return 1

    pr_url = f"{REPO_WEB_URL}/pulls"
    compare_url = f"{REPO_WEB_URL}/compare/main...{branch}?expand=1"
    print(f"PR_PUSH_OK: Pushed {branch} with zero conflicts.")
    print("GitHub Actions will automatically open the PR, run safety/CI checks, and auto-merge after 1 Approve.")
    print(f"Pull Requests : {pr_url}")
    print(f"Direct Compare: {compare_url}")
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


def cmd_install_shortcut(_args: argparse.Namespace) -> int:
    """Create a 1-click 'Team Git Studio' shortcut on the user's Desktop (Windows & macOS)."""
    desktop = Path.home() / "Desktop"
    if not desktop.is_dir():
        # Handle OneDrive Desktop on Windows
        od_desktop = Path.home() / "OneDrive" / "Desktop"
        if od_desktop.is_dir():
            desktop = od_desktop
        else:
            print(f"ERROR: Desktop folder not found at {desktop}", file=sys.stderr)
            return 1

    if sys.platform == "win32":
        lnk_path = desktop / "Team Git Studio.lnk"
        target_bat = ROOT / "Team-Git.bat"
        ps_script = (
            "$ws = New-Object -ComObject WScript.Shell; "
            f"$sc = $ws.CreateShortcut('{str(lnk_path).replace(chr(39), chr(39)*2)}'); "
            f"$sc.TargetPath = '{str(target_bat).replace(chr(39), chr(39)*2)}'; "
            f"$sc.WorkingDirectory = '{str(ROOT).replace(chr(39), chr(39)*2)}'; "
            "$sc.WindowStyle = 7; "
            "$sc.IconLocation = 'shell32.dll,14'; "
            "$sc.Description = 'Team Git Studio - installer_emtroly'; "
            "$sc.Save()"
        )
        res = subprocess.run(["powershell", "-NoProfile", "-Command", ps_script], capture_output=True, text=True)
        if res.returncode != 0:
            print(res.stdout + res.stderr, file=sys.stderr)
            return 1
        print(f"SHORTCUT_OK: Created Desktop shortcut at {lnk_path}")
        return 0

    # macOS / Linux
    target_cmd = ROOT / "Team-Git.command"
    link_path = desktop / "Team Git Studio.command"
    try:
        if link_path.exists() or link_path.is_symlink():
            link_path.unlink()
        link_path.symlink_to(target_cmd)
        target_cmd.chmod(0o755)
        print(f"SHORTCUT_OK: Created Desktop shortcut at {link_path}")
        return 0
    except OSError as exc:
        print(f"ERROR: Could not create shortcut: {exc}", file=sys.stderr)
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description="installer_emtroly Team Git Flow helper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("sync", help="Fetch & safely pull latest code from origin/main (Step 1 morning button)")
    sub.add_parser("status", help="Show current branch and active team branches")

    p_start = sub.add_parser("start", help="Create a new feature branch from origin/main")
    p_start.add_argument("slug", help="Short task slug (e.g. fix-zalo-qr)")
    p_start.add_argument("--carry", action="store_true", help="Carry current uncommitted edits onto new branch")

    sub.add_parser("check-merge", help="Check BOM/LF, safety invariants, and conflicts against origin/main")

    p_pr = sub.add_parser("pr", help="Commit & push personal branch to trigger Auto-PR, CI checks, and Auto-Merge on Approve")
    p_pr.add_argument("-m", "--message", required=True, help="Commit & PR title message")

    p_ship = sub.add_parser("ship", help="Commit, push branch, verify zero conflicts, and merge into main")
    p_ship.add_argument("-m", "--message", required=True, help="Commit & merge message")

    p_ui = sub.add_parser("ui", help="Launch the local visual Team Git Dashboard in the browser")
    p_ui.add_argument("--port", type=int, default=8765, help="Localhost port (default: 8765)")
    p_ui.add_argument("--no-open", action="store_true", help="Do not auto-open the browser")

    sub.add_parser("install-shortcut", help="Create a 'Team Git Studio' shortcut on the Desktop")

    args = parser.parse_args()
    if args.cmd == "sync":
        return cmd_sync(args)
    if args.cmd == "status":
        return cmd_status(args)
    if args.cmd == "start":
        return cmd_start(args)
    if args.cmd == "check-merge":
        return cmd_check_merge(args)
    if args.cmd == "pr":
        return cmd_pr(args)
    if args.cmd == "ship":
        return cmd_ship(args)
    if args.cmd == "install-shortcut":
        return cmd_install_shortcut(args)
    if args.cmd == "ui":
        ui_script = Path(__file__).resolve().with_name("team_git_ui.py")
        cmd = [sys.executable, str(ui_script), "--port", str(args.port)]
        if args.no_open:
            cmd.append("--no-open")
        return subprocess.call(cmd, cwd=str(ROOT))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
