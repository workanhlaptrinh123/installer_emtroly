#!/usr/bin/env bash
set -Eeuo pipefail
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
SYSTEM="$(uname -s)"
ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) ARCH=x64;; arm64|aarch64) ARCH=arm64;; *) echo 'Unsupported architecture' >&2; exit 1;; esac
case "$SYSTEM" in Darwin) PLATFORM=macos;; Linux) PLATFORM=ubuntu;; *) echo 'Unsupported build platform' >&2; exit 1;; esac
"$PYTHON" -c 'import tkinter, PyInstaller, sqlite3' || { echo 'Python tkinter, sqlite3 and PyInstaller are required on the build machine.' >&2; exit 1; }
OUTPUT="${OUTPUT:-$BASE/build/unix-preview-$PLATFORM-$ARCH}"
[[ "$OUTPUT" = /* && ! -e "$OUTPUT" ]] || { echo 'OUTPUT must be a new absolute directory.' >&2; exit 1; }
mkdir -p "$OUTPUT"
"$PYTHON" "$BASE/unix-installer/stage_payload.py" "$BASE" "$OUTPUT/payload"
NAME="caidattroly-$PLATFORM-$ARCH-PREVIEW"
"$PYTHON" -m PyInstaller --noconfirm --onefile --windowed --name "$NAME" \
  --distpath "$OUTPUT/dist" --workpath "$OUTPUT/work" --specpath "$OUTPUT" \
  --hidden-import sqlite3 --hidden-import runpy --hidden-import contextlib \
  --hidden-import shlex --hidden-import uuid --hidden-import argparse --hidden-import copy \
  --hidden-import datetime --hidden-import dataclasses --hidden-import stat --hidden-import typing \
  --add-data "$OUTPUT/payload/native:native" --add-data "$OUTPUT/payload/modules:modules" \
  --add-data "$OUTPUT/payload/profiles:profiles" --add-data "$OUTPUT/payload/zalo:zalo" \
  --add-data "$BASE/alt.png:." \
  "$BASE/unix-installer/gui.py"
if [[ "$SYSTEM" == Darwin ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$OUTPUT/dist/$NAME.app" "$OUTPUT/$NAME.zip"
  (cd "$OUTPUT" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
else
  (cd "$OUTPUT/dist" && tar -czf "$OUTPUT/$NAME.tar.gz" "$NAME")
  (cd "$OUTPUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
fi
echo "Preview build: $OUTPUT"
echo 'Not a production release. Validate installation and Zalo on the target system first.'
