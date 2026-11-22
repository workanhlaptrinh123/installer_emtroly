#!/usr/bin/env python3
"""Package an already-built Linux Em Tro Ly binary into an official Debian/Ubuntu .deb package."""

import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def build(executable, output, version, architecture, minimum_glibc, icon_path=None):
    executable = Path(executable).resolve(strict=True)
    output = Path(output).absolute()
    if not executable.is_file() or not output.parent.is_dir() or output.exists() or output.is_symlink():
        raise ValueError("A real executable and a new output file are required")
    if not re.fullmatch(r"[0-9][A-Za-z0-9.+~]*", version):
        raise ValueError("Invalid package version")
    if architecture not in {"amd64", "arm64"}:
        raise ValueError("Unsupported package architecture")
    if not re.fullmatch(r"2\.(?:3[5-9]|[4-9][0-9])", minimum_glibc):
        raise ValueError("Unsupported minimum glibc version")
    if output.suffix != ".deb":
        raise ValueError("Output must have a .deb extension")

    repo_icon = Path(icon_path) if icon_path else (Path(__file__).resolve().parent.parent / "alt.png")

    with tempfile.TemporaryDirectory(prefix="emtroly-deb-") as temporary:
        staging = Path(temporary) / "package"
        control = staging / "DEBIAN"
        binary_dir = staging / "usr/lib/emtroly"
        usr_bin = staging / "usr/bin"
        desktop_dir = staging / "usr/share/applications"
        pixmap_dir = staging / "usr/share/pixmaps"
        for directory in (control, binary_dir, usr_bin, desktop_dir, pixmap_dir):
            directory.mkdir(parents=True, mode=0o755)

        binary = binary_dir / "emtroly"
        shutil.copyfile(executable, binary)
        binary.chmod(0o755)
        (usr_bin / "emtroly").symlink_to("../lib/emtroly/emtroly")

        icon_name = "applications-system"
        if repo_icon.is_file():
            dst_icon = pixmap_dir / "emtroly.png"
            shutil.copyfile(repo_icon, dst_icon)
            dst_icon.chmod(0o644)
            icon_name = "emtroly"

        (control / "control").write_text(
            "Package: emtroly\n"
            f"Version: {version}\n"
            "Section: utils\n"
            "Priority: optional\n"
            f"Architecture: {architecture}\n"
            "Replaces: installer-emtroly-preview\n"
            "Conflicts: installer-emtroly-preview\n"
            "Maintainer: Anh Lap Trinh <support@anhlaptrinh.vn>\n"
            f"Depends: libc6 (>= {minimum_glibc}), libx11-6, libxext6, libxft2, libsqlite3-0, zlib1g, ca-certificates\n"
            "Description: Anh Lap Trinh - Em Tro Ly (OpenClaw, Zalo QR & Codex CLI)\n"
            " Bo cai dat va quan ly tro ly AI ca nhan tron goi cho Ubuntu / Debian Linux.\n",
            encoding="utf-8",
        )
        (desktop_dir / "emtroly.desktop").write_text(
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=Em Trợ Lý\n"
            "Comment=Cài đặt & Quản lý trợ lý AI OpenClaw, Zalo QR và Codex CLI\n"
            "Exec=/usr/bin/emtroly\n"
            f"Icon={icon_name}\n"
            "Terminal=false\n"
            "Categories=Utility;Development;\n",
            encoding="utf-8",
        )
        subprocess.run(["dpkg-deb", "--root-owner-group", "--build", str(staging), str(output)], check=True)

    checksum = hashlib.sha256()
    with output.open("rb") as package:
        for block in iter(lambda: package.read(1024 * 1024), b""):
            checksum.update(block)
    checksum_path = output.with_name(output.name + ".sha256")
    with checksum_path.open("x", encoding="ascii") as checksum_file:
        checksum_file.write(checksum.hexdigest() + "  " + output.name + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--version", default="2026.11.22")
    parser.add_argument("--architecture", choices=("amd64", "arm64"), required=True)
    parser.add_argument("--minimum-glibc", required=True)
    args = parser.parse_args()
    build(args.executable, args.output, args.version, args.architecture, args.minimum_glibc)
