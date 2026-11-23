---
name: git-team-flow
description: >-
  Automated team Git workflow for workanhlaptrinh123/installer_emtroly. Use whenever
  the user or their boss asks to start a new task/branch, see who is working on what
  (team branch status), push their branch, check for merge conflicts against main,
  safely merge into main, or publish a new release version tag without affecting
  existing releases.
---

# Git Team Flow (`installer_emtroly`)

Shared workflow for the 2-person team (`giangcr7` and boss) so nobody needs to memorize Git commands or risk overwriting each other's work on `main`.

## Helper Script

Always use [team_git.py](./scripts/team_git.py) for deterministic, cross-platform (Windows PowerShell & macOS/Linux) Git operations:

```bash
python .agents/skills/git-team-flow/scripts/team_git.py <command> [args]
```

## Supported Workflows

### 1. Xem trạng thái team ("Xem ai đang làm gì", "Kiểm tra nhánh")
```bash
python .agents/skills/git-team-flow/scripts/team_git.py status
```
Shows the current branch, local dirty files, ahead/behind counts vs `origin/main`, and a table of all active remote branches with author, timestamp, and last commit summary.

### 2. Bắt đầu đầu việc mới ("Tạo nhánh mới để làm việc X")
```bash
python .agents/skills/git-team-flow/scripts/team_git.py start "<short-task-slug>"
```
- Fetches latest `origin/main`.
- Auto-prefixes the branch with the local Git username (e.g. `giangcr7/fix-zalo-qr` or `sep/update-ui`).
- Never loses uncommitted local work (refuses if uncommitted edits exist unless the user asks to carry them over to the new branch with `--carry`).

### 3. Đẩy nhánh, kiểm tra conflict rồi gộp vào `main` ("Push nhánh, check conflict rồi gộp vào main")
1. First run preflight & conflict check:
   ```bash
   python .agents/skills/git-team-flow/scripts/team_git.py check-merge
   ```
   - Normalizes repo encoding rules (single UTF-8 BOM on `windows-installer/*.ps1`, `native/*.ps1`, `install-native-windows.ps1`; strict LF on `MANIFEST.txt`, `*.sh`, `unix-installer/*.py`, `install-windows.ps1`).
   - Verifies `windows-installer/bootstrap-stub/EmTroLy-Setup.exe` SHA-256 has not drifted.
   - Simulates a merge with latest `origin/main` using `git merge-tree` (non-destructive) to detect any conflicting files **before** touching `main`.
2. **If conflicts are reported**:
   - Do **NOT** force-push or blindly overwrite the other person's code.
   - Pull `origin/main` into the feature branch, inspect the exact conflicting hunks, resolve them carefully (asking the user if intent is ambiguous), and re-run `check-merge`.
3. **If zero conflicts**:
   - Run the quick integrity test (`python -m unittest windows-installer/test_edge_cases.py -k StaticIntegrityTests` on Windows, or `unix-installer` tests on macOS/Linux).
   - Execute the safe push + merge:
     ```bash
     python .agents/skills/git-team-flow/scripts/team_git.py ship -m "<commit message>"
     ```
   - `ship`:
     - Ensures work is committed on a feature branch (auto-creating `<user>/work-<timestamp>` if currently on `main`).
     - Pushes the feature branch to `origin`.
     - Re-verifies zero conflicts with `origin/main`.
     - Attempts clean merge into `main`, pushes `origin main`, and deletes the merged temporary branch locally & remotely.
     - If `main` has GitHub Branch Protection enabled (direct push rejected), leaves the pushed branch intact and prints the exact 1-click GitHub Pull Request link so the user/boss can approve and merge on GitHub.

### 4. Quy tắc an toàn bắt buộc của dự án
- Never use `git push --force` on `main`.
- Never delete or overwrite existing release tags (`v2026.*`).
- Never modify `windows-installer/bootstrap-stub/EmTroLy-Setup.exe` unless explicitly asked (its fixed SHA-256 preserves Microsoft SmartScreen reputation).
- Never commit `*.token`, `*.secret`, `.env`, or customer data.
