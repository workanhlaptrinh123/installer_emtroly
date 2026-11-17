#!/usr/bin/env python3
"""Apply the reviewed mention patch to a fresh native Zalo plugin only."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid


EXPECTED = {
    "monitor-Cc1OOIE-.mjs": "131ba8d7c9f221671099e5a0a6f92ed0657b4f72d6af6b8a082b52ef4c79185e",
    "send-B24acSlE.mjs": "2bda0ddda77fcdbddb527666767facba2fa2e8edd0bf16ab1c02f3f5ee59f15f",
    "zalo-js-Bu9ojNUf.mjs": "81c74913e1707706f095323242e369be26b2004580b601c9f7a3167d21c6b98f",
    "channel-D90hoq2j.mjs": "15de7821068afbbb514766374b8c80b9a56f733aacf0cf10d4fa5b6e4e4b9aad",
}
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def apply_diff(sources, patch):
    lines = patch.splitlines(keepends=True)
    output = {}
    index = 0
    while index < len(lines):
        if not lines[index].startswith("--- a/"):
            raise ValueError("Unexpected patch header")
        name = lines[index][6:].strip()
        if name not in sources or name in output or lines[index + 1].strip() != f"+++ b/{name}":
            raise ValueError("Unexpected patch file")
        index += 2
        original = sources[name].splitlines(keepends=True)
        result = []
        cursor = 0
        while index < len(lines) and not lines[index].startswith("--- a/"):
            match = HUNK.match(lines[index])
            if not match:
                raise ValueError("Invalid patch hunk")
            start = int(match.group(1)) - 1
            expected_old = int(match.group(2) or 1)
            expected_new = int(match.group(4) or 1)
            if start < cursor or start > len(original):
                raise ValueError("Invalid patch position")
            result.extend(original[cursor:start])
            cursor = start
            old_count = new_count = 0
            index += 1
            while index < len(lines) and not lines[index].startswith(("@@ ", "--- a/")):
                line = lines[index]
                kind, content = line[:1], line[1:]
                if kind not in (" ", "+", "-"):
                    raise ValueError("Unsupported patch line")
                if kind in (" ", "-"):
                    if cursor >= len(original) or original[cursor] != content:
                        raise ValueError("Patch context differs from the reviewed package")
                    cursor += 1
                    old_count += 1
                if kind in (" ", "+"):
                    result.append(content)
                    new_count += 1
                index += 1
            if old_count != expected_old or new_count != expected_new:
                raise ValueError("Patch hunk length differs")
        result.extend(original[cursor:])
        output[name] = "".join(result)
    if set(output) != set(sources):
        raise ValueError("Patch file set differs")
    return output


def prepare(setup, patch):
    sources = {}
    for name, expected in EXPECTED.items():
        path = setup / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("Missing or redirected plugin file")
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected:
            raise ValueError("Plugin differs from the reviewed release; mention patch was not applied")
        sources[name] = raw.decode("utf-8")
    return apply_diff(sources, patch.read_text(encoding="utf-8"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin-source", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--node", type=Path, required=True)
    parser.add_argument("--cli-entry", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    source = args.plugin_source.resolve(strict=True)
    source.relative_to(root)
    candidates = (source,) + tuple(source.parents)
    package_root = next((parent for parent in candidates if (parent / "package.json").is_file()
                         and json.loads((parent / "package.json").read_text(encoding="utf-8"))
                         .get("name") == "@openclaw/zalouser"), None)
    if package_root is None or json.loads((package_root / "package.json").read_text(encoding="utf-8")).get("version") != "2026.11.4":
        raise ValueError("Only the reviewed Zalo plugin 2026.11.4 is supported")
    setup = package_root / "dist" / ".setup"
    setup.resolve(strict=True).relative_to(root)
    skill = root / "workspace" / "skills" / "openclaw-zalo-reply-mention"
    patch = skill / "references" / "zalouser-2026.11.4.patch"
    candidate = prepare(setup, patch)
    sdk = args.cli_entry.parent / "dist" / "plugin-sdk" / "text-chunking.js"
    test = skill / "scripts" / "test-mention.mjs"
    if not sdk.is_file() or not test.is_file():
        raise ValueError("Mention verification prerequisites are missing")
    with tempfile.TemporaryDirectory(prefix="mention-check-", dir=root) as temporary:
        staged = Path(temporary)
        for name, content in candidate.items():
            (staged / name).write_text(content, encoding="utf-8", newline="")
            subprocess.run([str(args.node), "--check", str(staged / name)], check=True, capture_output=True, timeout=30)
        subprocess.run([str(args.node), str(test), str(staged), str(sdk)], check=True, capture_output=True, timeout=90)
        backup = root / "backups" / ("zalo-mention-" + uuid.uuid4().hex)
        backup.mkdir(parents=True)
        for name in candidate:
            shutil.copy2(setup / name, backup / name)
        replaced = []
        try:
            for name in candidate:
                if hashlib.sha256((setup / name).read_bytes()).hexdigest() != EXPECTED[name]:
                    raise ValueError("Plugin changed during verification")
                os.replace(staged / name, setup / name)
                replaced.append(name)
        except Exception:
            for name in replaced:
                shutil.copy2(backup / name, setup / name)
            raise
    print("zalo_reply_mention=installed_offline_verified_live_test_required")


if __name__ == "__main__":
    main()
