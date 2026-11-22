"""Safe recovery of interrupted installs and clean 1-click uninstallation on macOS & Linux."""

from __future__ import annotations

from datetime import datetime
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess


INSTALLING_MARKER = ".emtroly-installing.json"
KNOWN_PARTIAL_ENTRIES = {"runtime", "workspace", "npm-cache", "logs"}


def write_installing_marker(root: Path, member: str) -> Path:
    marker = Path(root) / INSTALLING_MARKER
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(marker, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(f'{{"pid":{os.getpid()},"member":"{member}"}}\n')
    return marker


def clear_installing_marker(root: Path) -> None:
    marker = Path(root) / INSTALLING_MARKER
    try:
        if marker.is_file() and not marker.is_symlink():
            marker.unlink()
    except OSError:
        pass


def is_recoverable_incomplete_instance(root: Path) -> bool:
    root = Path(root)
    if root.is_symlink() or not root.exists() or not root.is_dir():
        return False
    marker = root / INSTALLING_MARKER
    if marker.exists() and not marker.is_symlink() and marker.is_file():
        return True
    if (root / "openclaw.json").exists() or (root / "openclaw.json").is_symlink():
        return False
    try:
        entries = list(root.iterdir())
    except OSError:
        return False
    if not entries:
        return False
    for entry in entries:
        if entry.is_symlink() or entry.name not in KNOWN_PARTIAL_ENTRIES:
            return False
    return True


def archive_incomplete_instance(root: Path, home: Path) -> Path:
    root = Path(root)
    home = Path(home)
    backups_root = home / ".local/share/installer_emtroly/backups"
    backups_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = backups_root / f"incomplete-{root.name.lstrip('.')}-{stamp}-{os.getpid()}"
    shutil.move(str(root), str(dest))
    return dest


def _stop_and_remove_unix_service(member: str, home: Path) -> None:
    profile = f"member-{member}"
    sys_name = platform.system()
    if sys_name == "Linux":
        systemctl = shutil.which("systemctl")
        unit_names = (
            f"openclaw-gateway-{profile}.service",
            f"openclaw-{profile}.service",
        )
        if systemctl:
            for unit in unit_names:
                try:
                    subprocess.run(
                        [systemctl, "--user", "disable", "--now", unit],
                        stdin=subprocess.DEVNULL,
                        capture_output=True,
                        timeout=20,
                        check=False,
                    )
                except (OSError, subprocess.SubprocessError):
                    pass
        systemd_user_dir = home / ".config/systemd/user"
        if systemd_user_dir.is_dir():
            for unit_file in systemd_user_dir.glob(f"*{profile}*.service"):
                if not unit_file.is_symlink():
                    try:
                        unit_file.unlink()
                    except OSError:
                        pass
            if systemctl:
                try:
                    subprocess.run(
                        [systemctl, "--user", "daemon-reload"],
                        stdin=subprocess.DEVNULL,
                        capture_output=True,
                        timeout=15,
                        check=False,
                    )
                except (OSError, subprocess.SubprocessError):
                    pass
    elif sys_name == "Darwin":
        launch_agents = home / "Library/LaunchAgents"
        launchctl = shutil.which("launchctl")
        uid = os.geteuid() if hasattr(os, "geteuid") else 501
        if launch_agents.is_dir():
            for plist in launch_agents.glob(f"*{profile}*.plist"):
                if plist.is_symlink():
                    continue
                if launchctl:
                    for cmd in (
                        [launchctl, "bootout", f"gui/{uid}", str(plist)],
                        [launchctl, "unload", str(plist)],
                    ):
                        try:
                            subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, timeout=15, check=False)
                        except (OSError, subprocess.SubprocessError):
                            pass
                try:
                    plist.unlink()
                except OSError:
                    pass


def uninstall_instance(member: str, home: Path | None = None) -> dict:
    member_clean = (member or "").strip().lower()
    if not re.fullmatch(r"[a-z][a-z0-9_-]{0,56}", member_clean):
        raise ValueError("invalid-member")
    resolved_home = Path(home).resolve() if home is not None else Path.home().resolve()
    root = resolved_home / f".openclaw-member-{member_clean}"
    if root.is_symlink():
        raise ValueError("unsafe-symlink-instance")
    if not root.exists():
        raise FileNotFoundError("instance-missing")

    _stop_and_remove_unix_service(member_clean, resolved_home)

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_dir = resolved_home / ".local/share/installer_emtroly/backups" / f"uninstall-{member_clean}-{stamp}"
    backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    for rel_src, dst_name in (
        ("openclaw.json", "openclaw.json"),
        ("workspace/CUSTOMER_PROFILE.md", "CUSTOMER_PROFILE.md"),
    ):
        src_file = root / rel_src
        if src_file.is_file() and not src_file.is_symlink():
            dst_file = backup_dir / dst_name
            shutil.copy2(src_file, dst_file)
            try:
                os.chmod(dst_file, 0o600)
            except OSError:
                pass

    bin_dir = resolved_home / ".local/bin"
    alias_shim = bin_dir / f"openclaw-member-{member_clean}"
    default_shim = bin_dir / "openclaw"
    for candidate in (alias_shim, default_shim):
        if candidate.is_file() and not candidate.is_symlink():
            try:
                text = candidate.read_text(encoding="utf-8", errors="ignore")
                if candidate == alias_shim or str(root) in text:
                    candidate.unlink()
            except OSError:
                pass

    shutil.rmtree(root)
    return {
        "uninstalled": True,
        "member": member_clean,
        "root": str(root),
        "backup": str(backup_dir),
    }
