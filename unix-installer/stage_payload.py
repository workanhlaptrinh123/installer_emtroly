"""Stage only tracked installer payload files, excluding local runtime data."""

import argparse
from pathlib import Path, PurePosixPath
import shutil
import subprocess


def stage(source, destination):
    source = Path(source).resolve(strict=True)
    destination = Path(destination)
    if not destination.is_absolute() or destination.resolve() != destination or destination.exists():
        raise ValueError("Destination must be a new, absolute, non-symlink path")
    output = subprocess.check_output(["git", "-C", str(source), "ls-files", "-z", "--",
                                      "native/skills", "native/module-manager.py", "native/module-skills.json",
                                      "native/finalize_permissions.py", "modules", "profiles",
                                      "zalo/configure-zalo.py", "zalo/install-windows-reply-mention.py"])
    names = [item.decode("utf-8") for item in output.split(b"\0") if item]
    if "native/install_unix_cli.py" not in names:
        names.append("native/install_unix_cli.py")
    if len(names) < 100:
        raise ValueError("Tracked installer payload is incomplete")
    for name in names:
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Invalid payload path")
        filename = relative.name.lower()
        if (filename in {".env", "auth.json"} or "cookie" in filename or "credential" in filename or
                filename.endswith((".token", ".secret", ".sqlite", ".sqlite3", ".db"))):
            raise ValueError("Sensitive-looking payload file is not allowed")
        src = source.joinpath(*relative.parts)
        if src.resolve() != src or not src.is_file():
            raise ValueError("Missing or symlinked payload file")
    destination.mkdir(parents=True, mode=0o700)
    for name in names:
        src = source.joinpath(*PurePosixPath(name).parts)
        target = destination.joinpath(*PurePosixPath(name).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, target)
    return len(names)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    print("staged_files=" + str(stage(args.source, args.destination)))
