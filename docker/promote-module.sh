#!/usr/bin/env bash
set -Eeuo pipefail
CONTAINER=""; ID=""; SOURCE=""; RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while (($#)); do
  case "$1" in
    --container) CONTAINER="${2:?missing container}"; shift 2;;
    --id) ID="${2:?missing module id}"; shift 2;;
    --source) SOURCE="${2:?missing source path}"; shift 2;;
    --release-dir) RELEASE_DIR="${2:?missing release dir}"; shift 2;;
    *) exit 2;;
  esac
done
[[ "$ID" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || exit 2
docker inspect "$CONTAINER" >/dev/null
DEST="$RELEASE_DIR/modules/$ID"
[[ ! -e "$DEST" ]] || { echo "Module exists: $DEST" >&2; exit 1; }
if docker exec "$CONTAINER" bash -lc "find -- '$SOURCE' -type f | grep -E '/(\.env|.*(token|secret|credential|session|cookie|identity|history|sqlite|db)(\.|$))' -m1 -q"; then
  echo 'Possible customer secret/session/runtime state; refusing promotion' >&2
  exit 1
fi
mkdir -p "$DEST"
docker cp "$CONTAINER:$SOURCE/." "$DEST/"
python3 - "$DEST/module.json" "$ID" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
if data.get('id') != sys.argv[2] or not data.get('version'):
    raise SystemExit('module metadata mismatch')
PY
grep -qxF "$ID" "$RELEASE_DIR/modules/enabled.txt" 2>/dev/null || printf '%s\n' "$ID" >> "$RELEASE_DIR/modules/enabled.txt"
echo "Promoted module=$ID into $RELEASE_DIR"
