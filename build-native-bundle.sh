#!/usr/bin/env bash
set -Eeuo pipefail
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
"$PYTHON_BIN" -B - "$BASE" <<'PY'
import json
import sys
from pathlib import Path

base = Path(sys.argv[1])
mapping = json.loads((base / 'native/module-skills.json').read_text())
missing = [f'{module}:{skill}' for module, skills in mapping.items() for skill in skills
           if not (base / 'native/skills' / skill / 'SKILL.md').is_file()]
if missing:
    raise SystemExit('Missing skill payloads: ' + ', '.join(missing))
PY
count=$(find "$BASE/native/skills" -mindepth 2 -name SKILL.md | wc -l)
if [[ "$count" -lt 100 ]]; then echo "Unexpected skill count: $count" >&2; exit 1; fi
find "$BASE/native/skills" -type f \( -name '*.env' -o -name '*credential*' -o -name '*cookie*' -o -name 'auth.json' \) -print -quit | grep -q . && { echo 'Possible sensitive file in bundle' >&2; exit 1; } || true
printf 'native_skills=%s\n' "$count" > "$BASE/native/MANIFEST.txt"
echo "Native bundle ready: $count skills"
archive="$BASE/.native-full-bundle.$$.tar.gz"
trap 'rm -f "$archive"' EXIT
(cd "$BASE" && tar --exclude='*.bak-*' --exclude='__pycache__' --exclude='*.pyc' -czf "$archive" install-native-windows.ps1 install-native-unix.sh bootstrap-native.ps1 bootstrap-native.sh configure.py modules profiles native zalo README.md)
mv -f "$archive" "$BASE/native-full-bundle.tar.gz"
(cd "$BASE" && sha256sum native-full-bundle.tar.gz > native-full-bundle.sha256)
echo "Native bundle archive=$BASE/native-full-bundle.tar.gz"
