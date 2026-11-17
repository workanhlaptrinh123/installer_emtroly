"""Prepare instance-local outbound files and persist delivery instructions; never send."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import zipfile


POLICY = Path(__file__).resolve().parents[1] / "references/installed-media-policy.md"
START = "<!-- member-media-delivery:v1:start -->"
END = "<!-- member-media-delivery:v1:end -->"
OFFICE_PARTS = {".docx": "word/document.xml", ".xlsx": "xl/workbook.xml", ".pptx": "ppt/presentation.xml"}


def persist_policy(workspace, state_dir):
    workspace = Path(workspace).resolve()
    state_dir = Path(state_dir).resolve()
    workspace.mkdir(parents=True, exist_ok=True)
    (state_dir / "media/outbound").mkdir(parents=True, exist_ok=True, mode=0o700)
    target = workspace / "AGENTS.md"
    if target.is_symlink():
        raise ValueError("Refusing symlinked workspace policy")
    original = target.read_text(encoding="utf-8") if target.exists() else ""
    if START in original or END in original:
        if original.count(START) != 1 or original.count(END) != 1 or original.index(START) > original.index(END):
            raise ValueError("Ambiguous media policy markers")
        start = original.index(START)
        end = original.index(END) + len(END)
        updated = original[:start] + POLICY.read_text(encoding="utf-8").rstrip() + original[end:]
    else:
        updated = original.rstrip() + "\n\n" + POLICY.read_text(encoding="utf-8")
    if updated != original:
        descriptor, temporary = tempfile.mkstemp(prefix=".media-policy-", dir=workspace)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(updated)
            os.replace(temporary, target)
        finally:
            Path(temporary).unlink(missing_ok=True)


def validate_office(file):
    required = OFFICE_PARTS.get(file.suffix.lower())
    if required:
        with zipfile.ZipFile(file) as archive:
            if required not in archive.namelist() or "[Content_Types].xml" not in archive.namelist():
                raise ValueError("Office artifact is incomplete")


def prepare_file(file, workspace, state_dir, max_bytes=20 * 1024 * 1024):
    workspace = Path(workspace).resolve(strict=True)
    state_dir = Path(state_dir).resolve(strict=True)
    outbound = state_dir / "media/outbound"
    outbound.mkdir(parents=True, exist_ok=True, mode=0o700)
    if outbound.is_symlink() or not outbound.resolve().is_relative_to(state_dir):
        raise ValueError("Outbound directory escapes instance state")
    source = Path(file).resolve(strict=True)
    if not any(source.is_relative_to(root) for root in (workspace, outbound.resolve())):
        raise ValueError("Artifact must belong to this workspace or outbound directory")
    if not source.is_file() or source.stat().st_size <= 0 or source.stat().st_size > max_bytes:
        raise ValueError("Artifact is empty, not a file or exceeds the configured byte limit")
    validate_office(source)
    descriptor, temporary = tempfile.mkstemp(prefix="attachment-", suffix=source.suffix, dir=outbound)
    staged = Path(temporary)
    digest = hashlib.sha256()
    size = 0
    try:
        with os.fdopen(descriptor, "wb") as output, source.open("rb") as input_stream:
            for chunk in iter(lambda: input_stream.read(1024 * 1024), b""):
                size += len(chunk)
                if size > max_bytes:
                    raise ValueError("Artifact grew beyond the configured byte limit")
                digest.update(chunk)
                output.write(chunk)
        if not size:
            raise ValueError("Artifact became empty")
        validate_office(staged)
        return {"status": "staged_not_sent", "media": str(staged), "filename": source.name,
                "bytes": size, "sha256": digest.hexdigest()}
    except Exception:
        staged.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install-policy", "prepare"))
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--file", type=Path)
    parser.add_argument("--max-bytes", type=int, default=20 * 1024 * 1024)
    args = parser.parse_args()
    if args.action == "install-policy":
        persist_policy(args.workspace, args.state_dir)
        print(json.dumps({"status": "policy_installed_not_delivery_test"}))
    else:
        if args.file is None or args.max_bytes <= 0:
            parser.error("prepare requires --file and positive --max-bytes")
        print(json.dumps(prepare_file(args.file, args.workspace, args.state_dir, args.max_bytes)))


if __name__ == "__main__":
    main()
