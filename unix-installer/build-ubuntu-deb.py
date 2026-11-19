#!/usr/bin/env python3
"""Package an already-built Ubuntu preview without touching user data."""

import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def build(executable, output, version, architecture, minimum_glibc):
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

    with tempfile.TemporaryDirectory(prefix="emtroly-deb-") as temporary:
        staging = Path(temporary) / "package"
        control = staging / "DEBIAN"
        binary_dir = staging / "usr/lib/installer-emtroly"
        desktop_dir = staging / "usr/share/applications"
        for directory in (control, binary_dir, desktop_dir):
            directory.mkdir(parents=True, mode=0o755)
        binary = binary_dir / "caidattroly"
        shutil.copyfile(executable, binary)
        binary.chmod(0o755)
        (control / "control").write_text(
            "Package: installer-emtroly-preview\n"
            f"Version: {version}\n"
            "Section: utils\nPriority: optional\n"
            f"Architecture: {architecture}\n"
            "Maintainer: installer_emtroly\n"
            f"Depends: libc6 (>= {minimum_glibc}), libx11-6, libxext6, libxft2, zlib1g\n"
            "Description: Em Tro Ly installer (testing preview)\n"
            " This preview is not an official customer release.\n", encoding="utf-8")
        (desktop_dir / "installer-emtroly-preview.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=Em Tro Ly (ban thu)\n"
            "Comment=Bo cai dat tro ly thu nghiem\n"
            "Exec=/usr/lib/installer-emtroly/caidattroly\n"
            "Icon=applications-system\nTerminal=false\nCategories=Utility;\n", encoding="utf-8")
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
    parser.add_argument("--version", default="0.20261119~preview1")
    parser.add_argument("--architecture", choices=("amd64", "arm64"), required=True)
    parser.add_argument("--minimum-glibc", required=True)
    args = parser.parse_args()
    build(args.executable, args.output, args.version, args.architecture, args.minimum_glibc)
