#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
python3 "$ROOT/module-manager.py" --openclaw-root "$ROOT" --catalog-root "$ROOT/module-catalog" --skills-source "$ROOT/module-catalog/skills" "$@"
status=$?
if [[ "$status" == 0 && "${1:-}" == "install" ]] && command -v openclaw >/dev/null 2>&1; then
  openclaw gateway restart >/dev/null 2>&1 || true
fi
exit "$status"
