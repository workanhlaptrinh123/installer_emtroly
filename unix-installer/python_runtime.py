"""Provide a private Python runtime if a suitable system interpreter is missing."""

import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request

from dependencies import _safe_archive
from python_exec import restore_library_path


RELEASE = "20261110"
VERSION = "3.12.16"
ARCHIVES = {
    ("Darwin", "x64"): ("x86_64-apple-darwin", "b78a4c479f1964ec484880bee567568266f68da102269fb93a05fe8716b45f91"),
    ("Darwin", "arm64"): ("aarch64-apple-darwin", "2f11b8aa3726bdbd87dd9eb76568412faddf4f47e26913fa45d6a2e424972acd"),
    ("Linux", "x64"): ("x86_64-unknown-linux-gnu", "6a9e62dad033790aef722dbd370e0ce76ce17b73627ba3ae679f537049350b39"),
    ("Linux", "arm64"): ("aarch64-unknown-linux-gnu", "b6a41defec4975d94b4ff1950236e7383e5c02ba40ea48c9ec33c66087a35aab"),
}


def _verify(executable):
    executable = Path(executable)
    if not executable.is_file() or not os.access(executable, os.X_OK):
        return False
    env = restore_library_path(dict(os.environ))
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    try:
        subprocess.run([str(executable), "-c", "import sqlite3,ssl,sys; assert sys.version_info >= (3,11)"],
                       env=env, stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=30)
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def install(dependencies):
    system = platform.system()
    existing = shutil.which("python3")
    if existing and not (system == "Darwin" and existing == "/usr/bin/python3"):
        resolved = Path(existing).resolve()
        if _verify(resolved):
            return resolved
    architecture = {"x86_64": "x64", "amd64": "x64", "arm64": "arm64", "aarch64": "arm64"}.get(platform.machine().lower())
    spec = ARCHIVES.get((system, architecture))
    if not spec:
        raise ValueError("Python is unavailable for this platform")
    target_arch, expected = spec
    dependencies = Path(dependencies)
    if not dependencies.is_absolute() or dependencies.resolve() != dependencies:
        raise ValueError("Invalid private dependency directory")
    dependencies.mkdir(parents=True, exist_ok=True, mode=0o700)
    destination = dependencies / ("python-" + VERSION + "-" + RELEASE + "-" + system.lower() + "-" + architecture)
    executable = destination / "bin" / "python3"
    if destination.exists() or destination.is_symlink():
        if destination.is_symlink() or not destination.is_dir() or destination.resolve() not in executable.resolve().parents or not _verify(executable):
            raise ValueError("Existing Python runtime is invalid; it was not modified")
        return executable.resolve()
    filename = "cpython-" + VERSION + "+" + RELEASE + "-" + target_arch + "-install_only_stripped.tar.gz"
    url = "https://github.com/astral-sh/python-build-standalone/releases/download/" + RELEASE + "/" + urllib.parse.quote(filename)
    try:
        with tempfile.TemporaryDirectory(prefix=".python-download-", dir=dependencies) as temporary:
            temporary = Path(temporary)
            archive_path = temporary / filename
            digest = hashlib.sha256()
            with urllib.request.urlopen(url, timeout=300) as response, archive_path.open("wb") as output:
                final = urllib.parse.urlsplit(response.geturl())
                if final.scheme != "https" or final.hostname not in {"github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"}:
                    raise ValueError("Unexpected Python download source")
                size = 0
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > 150 * 1024 * 1024:
                        raise ValueError("Python download is too large")
                    digest.update(chunk)
                    output.write(chunk)
            if digest.hexdigest() != expected:
                raise ValueError("Python archive checksum mismatch")
            with tarfile.open(archive_path, "r:gz") as archive:
                archive.extractall(temporary, members=_safe_archive(archive, "python"))
            candidate = temporary / "python" / "bin" / "python3"
            if not _verify(candidate):
                raise ValueError("Downloaded Python is not usable")
            if destination.exists() or destination.is_symlink():
                raise ValueError("Python runtime appeared during installation")
            (temporary / "python").rename(destination)
    except (OSError, tarfile.TarError):
        raise RuntimeError("Python download or verification failed") from None
    if not _verify(executable):
        raise RuntimeError("Installed Python runtime failed verification")
    return executable.resolve()
