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


PATH_START = "# >>> installer_emtroly PATH >>>"
PATH_END = "# <<< installer_emtroly PATH <<<"


def _remove_shell_path_block(rc_file: Path) -> bool:
    if rc_file.is_symlink() or not rc_file.is_file():
        return False
    try:
        raw = rc_file.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return False
    if PATH_START not in raw or PATH_END not in raw:
        return False
    pattern = re.compile(
        r"\n?" + re.escape(PATH_START) + r"\n.*?\n" + re.escape(PATH_END) + r"\n?",
        re.DOTALL,
    )
    updated, count = pattern.subn("\n", raw)
    if count == 0 or updated == raw:
        return False
    cleaned = re.sub(r"\n{3,}", "\n\n", updated)
    if cleaned == "\n":
        cleaned = ""
    try:
        mode = rc_file.stat().st_mode & 0o777
        tmp = rc_file.with_name(f".{rc_file.name}.emtroly-reset-{os.getpid()}")
        tmp.write_text(cleaned, encoding="utf-8")
        os.chmod(tmp, mode)
        os.replace(tmp, rc_file)
        return True
    except OSError:
        return False


def has_any_emtroly_footprint(home: Path | None = None, config_home: Path | None = None) -> bool:
    resolved_home = Path(home).resolve() if home is not None else Path.home().resolve()
    cfg_env = os.environ.get("XDG_CONFIG_HOME", "").strip()
    cfg_base = Path(config_home).resolve() if config_home is not None else (Path(cfg_env).resolve() if cfg_env else (resolved_home / ".config"))
    if any(resolved_home.glob(".openclaw-member-*")):
        return True
    if (resolved_home / ".local/share/installer_emtroly").exists():
        return True
    if (cfg_base / "anhlaptrinh/emtroly").exists():
        return True
    if (resolved_home / "Applications/EmTroLy - Antigravity.command").is_file():
        return True
    if (resolved_home / ".local/share/applications/emtroly-antigravity.desktop").is_file():
        return True
    bin_dir = resolved_home / ".local/bin"
    if bin_dir.is_dir():
        if any(bin_dir.glob("openclaw-member-*")) or (bin_dir / "codex-emtroly").is_file():
            return True
    return False


def factory_reset_emtroly(home: Path | None = None, config_home: Path | None = None) -> dict:
    """Reset the machine completely to a brand-new user state as if EmTroLy was never installed."""
    resolved_home = Path(home).resolve() if home is not None else Path.home().resolve()
    cfg_env = os.environ.get("XDG_CONFIG_HOME", "").strip()
    cfg_base = (
        Path(config_home).resolve()
        if config_home is not None
        else (Path(cfg_env).resolve() if cfg_env else (resolved_home / ".config"))
    )

    em_data_dir = resolved_home / ".local/share/installer_emtroly"
    em_cfg_dir = cfg_base / "anhlaptrinh/emtroly"
    em_cfg_parent = cfg_base / "anhlaptrinh"

    for check_target in (em_data_dir, em_cfg_dir):
        if check_target.is_symlink():
            raise ValueError("unsafe-symlink-instance")

    removed_instances: list[str] = []
    for inst_dir in sorted(resolved_home.glob(".openclaw-member-*")):
        if inst_dir.is_symlink():
            raise ValueError("unsafe-symlink-instance")
        member_suffix = inst_dir.name[len(".openclaw-member-") :].strip().lower()
        if re.fullmatch(r"[a-z][a-z0-9_-]{0,56}", member_suffix):
            _stop_and_remove_unix_service(member_suffix, resolved_home)
        if inst_dir.is_dir():
            shutil.rmtree(inst_dir)
            removed_instances.append(inst_dir.name)
        elif inst_dir.exists():
            inst_dir.unlink()

    bin_dir = resolved_home / ".local/bin"
    if bin_dir.is_dir() and not bin_dir.is_symlink():
        for alias_shim in list(bin_dir.glob("openclaw-member-*")):
            if alias_shim.is_file() and not alias_shim.is_symlink():
                try:
                    alias_shim.unlink()
                except OSError:
                    pass
        codex_alias = bin_dir / "codex-emtroly"
        if codex_alias.is_file() and not codex_alias.is_symlink():
            try:
                codex_alias.unlink()
            except OSError:
                pass
        for generic_name, markers in (
            ("openclaw", ("OPENCLAW_STATE_DIR", ".openclaw-member-", "installer_emtroly")),
            ("codex", ("installer_emtroly", "CODEX_HOME")),
        ):
            cand = bin_dir / generic_name
            if cand.is_file() and not cand.is_symlink():
                try:
                    txt = cand.read_text(encoding="utf-8", errors="ignore")
                    if any(m in txt for m in markers):
                        cand.unlink()
                except OSError:
                    pass

    for rc_name in (".bashrc", ".zshrc"):
        _remove_shell_path_block(resolved_home / rc_name)

    for launcher_file in (
        resolved_home / "Applications/EmTroLy - Antigravity.command",
        resolved_home / ".local/share/applications/emtroly-antigravity.desktop",
    ):
        if launcher_file.is_file() and not launcher_file.is_symlink():
            try:
                launcher_file.unlink()
            except OSError:
                pass

    if em_data_dir.is_dir():
        shutil.rmtree(em_data_dir)

    if em_cfg_dir.is_dir():
        shutil.rmtree(em_cfg_dir)
    if em_cfg_parent.is_dir() and not em_cfg_parent.is_symlink():
        try:
            if not any(em_cfg_parent.iterdir()):
                em_cfg_parent.rmdir()
        except OSError:
            pass

    return {
        "reset": True,
        "removed_instances": removed_instances,
        "home": str(resolved_home),
    }
