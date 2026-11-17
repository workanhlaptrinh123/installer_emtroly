#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install -d -m 700 "$ROOT" "$ROOT/module-catalog" "$ROOT/module-catalog/skills"
install -m 700 "$BASE/native/module-manager.py" "$ROOT/module-manager.py"
install -m 700 "$BASE/native/module-manager.sh" "$ROOT/module-manager.sh"
rm -rf "$ROOT/module-catalog/modules" "$ROOT/module-catalog/profiles"
cp -a "$BASE/modules" "$ROOT/module-catalog/"
cp -a "$BASE/profiles" "$ROOT/module-catalog/"
cp -a "$BASE/native/module-skills.json" "$ROOT/module-catalog/"
cp -a "$BASE/native/skills/." "$ROOT/module-catalog/skills/"
if [[ -w /usr/local/bin ]]; then ln -sfn "$ROOT/module-manager.sh" /usr/local/bin/member-module-native; fi
echo "Native module manager installed at $ROOT"
