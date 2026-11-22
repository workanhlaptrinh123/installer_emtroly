"""Install a pinned FFmpeg binary privately when the user has none."""

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import urllib.parse
import urllib.request
import zipfile

import net_utils
from python_exec import restore_library_path


WHEELS = {
    ("Darwin", "x64"): ("imageio_ffmpeg-0.6.0-py3-none-macosx_10_9_intel.macosx_10_9_x86_64.whl", "9d2baaf867088508d4a3458e61eeb30e945c4ad8016025545f66c4b5aaef0a61", "imageio_ffmpeg/binaries/ffmpeg-macos-x86_64-v7.1", "4a4a968b98859588e98500ae25973d80a5ca5eed0724222b9f76360dcb72a001"),
    ("Darwin", "arm64"): ("imageio_ffmpeg-0.6.0-py3-none-macosx_11_0_arm64.whl", "b1ae3173414b5fc5f538a726c4e48ea97edc0d2cdc11f103afee655c463fa742", "imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v7.1", "6d175a4743ca50256e89a8cdd731100f9cee33bd79aeea46894d209410dc6617"),
    ("Linux", "x64"): ("imageio_ffmpeg-0.6.0-py3-none-manylinux2014_x86_64.whl", "c7e46fcec401dd990405049d2e2f475e2b397779df2519b544b8aab515195282", "imageio_ffmpeg/binaries/ffmpeg-linux-x86_64-v7.0.2", "e7e7fb30477f717e6f55f9180a70386c62677ef8a4d4d1a5d948f4098aa3eb99"),
    ("Linux", "arm64"): ("imageio_ffmpeg-0.6.0-py3-none-manylinux2014_aarch64.whl", "1d47bebd83d2c5fc770720d211855f208af8a596c82d17730aa51e815cdee6dc", "imageio_ffmpeg/binaries/ffmpeg-linux-aarch64-v7.0.2", "6bb182d0d75d23028db82e9e4f723ca69b853d055698486e6984ddb2c06fb8ce"),
}


def _verify(path, expected=None):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError("FFmpeg executable is missing or unsafe")
    if expected:
        with path.open("rb") as source:
            digest = hashlib.sha256()
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
            if digest.hexdigest() != expected:
                raise ValueError("FFmpeg checksum verification failed")
    try:
        result = subprocess.run([str(path), "-version"], capture_output=True, text=True, timeout=30, check=True,
                                env=restore_library_path(dict(os.environ)), stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        raise ValueError("FFmpeg executable could not be verified") from None
    if not result.stdout.startswith("ffmpeg version"):
        raise ValueError("Invalid FFmpeg executable")
    return path


def install(dependencies):
    existing = shutil.which("ffmpeg")
    if existing:
        try:
            return _verify(Path(existing).resolve())
        except ValueError:
            pass
    architecture = {"x86_64": "x64", "amd64": "x64", "arm64": "arm64", "aarch64": "arm64"}.get(platform.machine().lower())
    spec = WHEELS.get((platform.system(), architecture))
    if not spec:
        raise ValueError("FFmpeg is unavailable for this platform")
    filename, wheel_hash, member, binary_hash = spec
    dependencies = Path(dependencies)
    if not dependencies.is_absolute() or dependencies.resolve() != dependencies:
        raise ValueError("Invalid private dependency directory")
    dependencies.mkdir(parents=True, exist_ok=True, mode=0o700)
    destination = dependencies / ("ffmpeg-imageio-0.6.0-" + platform.system().lower() + "-" + architecture)
    executable = destination / "ffmpeg"
    if destination.exists() or destination.is_symlink():
        if destination.is_symlink() or not destination.is_dir():
            raise ValueError("Existing FFmpeg directory is unsafe")
        return _verify(executable, binary_hash)
    try:
        with net_utils.urlopen_with_retry("https://pypi.org/pypi/imageio-ffmpeg/0.6.0/json", timeout=60) as response:
            url = urllib.parse.urlsplit(response.geturl())
            if url.scheme != "https" or url.hostname != "pypi.org":
                raise ValueError("Unexpected FFmpeg metadata source")
            metadata = json.loads(response.read(4 * 1024 * 1024))
        matches = [item for item in metadata["urls"] if item.get("filename") == filename and item.get("digests", {}).get("sha256") == wheel_hash]
        if len(matches) != 1:
            raise ValueError("Pinned FFmpeg package was not found")
        url = urllib.parse.urlsplit(matches[0]["url"])
        if url.scheme != "https" or url.hostname != "files.pythonhosted.org":
            raise ValueError("Unexpected FFmpeg package source")
        with tempfile.TemporaryDirectory(prefix=".ffmpeg-download-", dir=dependencies) as temporary:
            temporary = Path(temporary)
            wheel = temporary / filename
            digest = hashlib.sha256()
            with net_utils.urlopen_with_retry(matches[0]["url"], timeout=300) as response, wheel.open("wb") as output:
                final = urllib.parse.urlsplit(response.geturl())
                if final.scheme != "https" or final.hostname != "files.pythonhosted.org":
                    raise ValueError("Unexpected FFmpeg package redirect")
                size = 0
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > 100 * 1024 * 1024:
                        raise ValueError("FFmpeg download is too large")
                    digest.update(chunk)
                    output.write(chunk)
            if digest.hexdigest() != wheel_hash:
                raise ValueError("FFmpeg package checksum mismatch")
            candidate_dir = temporary / "ready"
            candidate_dir.mkdir(mode=0o700)
            candidate = candidate_dir / "ffmpeg"
            with zipfile.ZipFile(wheel) as archive:
                info = archive.getinfo(member)
                if info.file_size > 200 * 1024 * 1024:
                    raise ValueError("FFmpeg binary is too large")
                with archive.open(info) as source, candidate.open("xb") as output:
                    shutil.copyfileobj(source, output)
            candidate.chmod(0o700)
            net_utils.clear_macos_quarantine(candidate)
            _verify(candidate, binary_hash)
            if destination.exists() or destination.is_symlink():
                raise ValueError("FFmpeg directory appeared during installation")
            candidate_dir.rename(destination)
    except (OSError, KeyError, json.JSONDecodeError, zipfile.BadZipFile):
        raise RuntimeError("FFmpeg download or verification failed") from None
    return _verify(executable, binary_hash)
