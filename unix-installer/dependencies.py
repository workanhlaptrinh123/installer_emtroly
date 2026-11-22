"""Prepare an isolated Node.js runtime without changing the system installation."""

import hashlib
import os
from pathlib import Path, PurePosixPath
import platform
import re
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request

import net_utils

NODE_VERSION = "24.21.0"
MAX_ARCHIVE_BYTES = 150 * 1024 * 1024
NODE_DIGESTS = {
    "node-v24.21.0-darwin-arm64": "bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057",
    "node-v24.21.0-darwin-x64": "1462cb3b3046b815cf8ea436d3da450ec1a9f11dac7e5a46b0ada5305d7e8097",
    "node-v24.21.0-linux-arm64": "724282c3b43aec998aa9527380465b45d229e021b58035f5f4f63095eabfe5d5",
    "node-v24.21.0-linux-x64": "6e1db87ef58b8819e5d5402eff1536491b18edd8eb7bee5ef7897876e88dc5ff",
}


def _download(url, timeout):
    response = net_utils.urlopen_with_retry(url, timeout=timeout)
    parsed = urllib.parse.urlsplit(response.geturl())
    if parsed.scheme != "https" or parsed.hostname != "nodejs.org" or parsed.port not in (None, 443):
        response.close()
        raise ValueError("Node download redirected outside nodejs.org HTTPS")
    return response


def node_archive(system=None, machine=None):
    system = system or platform.system()
    machine = (machine or platform.machine()).lower()
    systems = {"Linux": "linux", "Darwin": "darwin"}
    architectures = {"x86_64": "x64", "amd64": "x64", "arm64": "arm64", "aarch64": "arm64"}
    if system not in systems or machine not in architectures:
        raise ValueError("Only macOS and Linux x64/arm64 are supported")
    return f"node-v{NODE_VERSION}-{systems[system]}-{architectures[machine]}"


def _safe_archive(archive, root_name):
    members = archive.getmembers()
    if not members or len(members) > 50000:
        raise ValueError("Unexpected Node archive contents")
    total = 0
    for member in members:
        name = PurePosixPath(member.name)
        if name.is_absolute() or not name.parts or name.parts[0] != root_name or ".." in name.parts:
            raise ValueError("Unsafe Node archive path")
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise ValueError("Unsupported Node archive entry")
        total += member.size
        if total > 500 * 1024 * 1024:
            raise ValueError("Node archive expands beyond the allowed size")
        if member.issym() or member.islnk():
            link = PurePosixPath(member.linkname)
            if link.is_absolute():
                raise ValueError("Unsafe Node archive link")
            parts = list(name.parent.parts if member.issym() else ())
            for component in link.parts:
                if component == "..":
                    if len(parts) <= 1:
                        raise ValueError("Node archive link escapes its directory")
                    parts.pop()
                elif component != ".":
                    parts.append(component)
            if not parts or parts[0] != root_name:
                raise ValueError("Node archive link escapes its directory")
    return members


def _verify_node(directory):
    node = directory / "bin" / "node"
    npm = directory / "bin" / "npm"
    if not node.is_file() or not npm.is_file() or not os.access(node, os.X_OK):
        raise ValueError("Node runtime or npm is incomplete")
    if directory.resolve() not in node.resolve().parents or directory.resolve() not in npm.resolve().parents:
        raise ValueError("Node runtime points outside its directory")
    result = subprocess.run([str(node), "--version"], capture_output=True, text=True, timeout=30, check=True)
    if result.stdout.strip() != "v" + NODE_VERSION:
        raise ValueError("Node runtime version mismatch")
    return node, npm


def install_node(dependencies):
    dependencies = Path(dependencies)
    if not dependencies.is_absolute() or dependencies.resolve() != dependencies:
        raise ValueError("Dependency directory must be an absolute non-symlink path")
    dependencies.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not dependencies.is_dir():
        raise ValueError("Dependency path is not a directory")
    root_name = node_archive()
    target = dependencies / root_name
    if target.exists() or target.is_symlink():
        if target.is_symlink() or not target.is_dir():
            raise ValueError("Existing Node runtime is not a safe directory")
        return _verify_node(target)

    filename = root_name + ".tar.gz"
    base = f"https://nodejs.org/dist/v{NODE_VERSION}/"
    with _download(base + "SHASUMS256.txt", timeout=60) as response:
        sums = response.read(1024 * 1024).decode("ascii")
    matches = re.findall(r"(?m)^([a-f0-9]{64})\s+" + re.escape(filename) + r"\s*$", sums)
    if len(matches) != 1 or matches[0] != NODE_DIGESTS.get(root_name):
        raise ValueError("Node checksum is missing or ambiguous")
    with tempfile.TemporaryDirectory(prefix=".node-download-", dir=dependencies) as temporary:
        temporary = Path(temporary)
        archive_path = temporary / filename
        digest = hashlib.sha256()
        size = 0
        with _download(base + filename, timeout=300) as response, archive_path.open("wb") as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_ARCHIVE_BYTES:
                    raise ValueError("Node download exceeds the allowed size")
                digest.update(chunk)
                output.write(chunk)
        if digest.hexdigest() != matches[0]:
            raise ValueError("Node checksum verification failed")
        with tarfile.open(archive_path, "r:gz") as archive:
            members = _safe_archive(archive, root_name)
            archive.extractall(temporary, members=members)
        net_utils.clear_macos_quarantine(temporary / root_name)
        _verify_node(temporary / root_name)
        if target.exists() or target.is_symlink():
            raise ValueError("Node runtime appeared during installation; retry")
        (temporary / root_name).rename(target)
    return _verify_node(target)
