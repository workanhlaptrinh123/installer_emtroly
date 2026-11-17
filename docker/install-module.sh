#!/usr/bin/env bash
set -Eeuo pipefail
CONTAINER=""; MODULE=""
while (($#)); do
  case "$1" in
    --container) CONTAINER="${2:?missing container}"; shift 2;;
    --module) MODULE="${2:?missing module path}"; shift 2;;
    *) echo "Usage: $0 --container user-NAME --module MODULE_DIR_OR_ARCHIVE" >&2; exit 2;;
  esac
done
[[ -n "$CONTAINER" && -e "$MODULE" ]] || exit 2
docker inspect "$CONTAINER" >/dev/null
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [[ -d "$MODULE" ]]; then cp -a "$MODULE/." "$TMP/"; else tar -xzf "$MODULE" -C "$TMP"; fi
[[ -f "$TMP/module.json" ]] || { echo 'module.json is missing' >&2; exit 1; }
python3 - "$TMP/module.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
if not data.get('id') or not data.get('version'):
    raise SystemExit('module.json requires id and version')
PY
docker cp "$TMP/." "$CONTAINER:/tmp/member-module"
docker exec "$CONTAINER" bash -lc '
  set -Eeuo pipefail
  mkdir -p /root/.openclaw/workspace/skills /root/Apps /etc/supervisor/conf.d
  [[ ! -d /tmp/member-module/skills ]] || cp -a /tmp/member-module/skills/. /root/.openclaw/workspace/skills/
  [[ ! -d /tmp/member-module/apps ]] || cp -a /tmp/member-module/apps/. /root/Apps/
  [[ ! -d /tmp/member-module/supervisor ]] || cp -a /tmp/member-module/supervisor/. /etc/supervisor/conf.d/
  supervisorctl reread >/dev/null || true
  supervisorctl update >/dev/null || true
  rm -rf /tmp/member-module
'
