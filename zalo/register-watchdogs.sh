#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER=""
MEMBER_DATA_DIR=""
MEMBER_HOME=""
MEMBER_LABEL=""
CENTER_DIR="${CENTER_DIR:-/root/Automation/watchdog/shared_self_healing}"

usage() {
  cat <<'USAGE'
Usage: register-watchdogs.sh --container CONTAINER --member-data-dir DIR --member-home HOME --member-label LABEL
USAGE
}

while (($#)); do
  case "$1" in
    --container) CONTAINER=${2:-}; shift 2;;
    --member-data-dir) MEMBER_DATA_DIR=${2:-}; shift 2;;
    --member-home) MEMBER_HOME=${2:-}; shift 2;;
    --member-label) MEMBER_LABEL=${2:-}; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
done

[[ "$MEMBER_LABEL" =~ ^[a-z][a-z0-9_-]{0,63}$ ]] || { echo "Invalid member label" >&2; exit 2; }
[[ -f "$CENTER_DIR/project_config.json" && -x "$CENTER_DIR/run_project.sh" ]] || {
  echo "Shared Watchdog Center is unavailable: $CENTER_DIR" >&2
  exit 1
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="/root/_Backups/member-vps-v6-watchdogs/$MEMBER_LABEL/$stamp"
mkdir -p "$backup"
cp -a "$CENTER_DIR/project_config.json" "$backup/project_config.json.before"
crontab -l 2>/dev/null >"$backup/crontab.before" || true

python3 - "$CENTER_DIR/project_config.json" "$CONTAINER" "$MEMBER_HOME" "$MEMBER_LABEL" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
container, member_home, label = sys.argv[2:]
data = json.loads(config_path.read_text(encoding="utf-8"))
root = "/root/Automation/watchdog/shared_self_healing"

entries = {
    f"member_{label}_gateway_supervisor": {
        "project_root": root,
        "run_command": f"/usr/bin/python3 scripts/check_member_gateway_supervisor.py --container {container} --member-home {member_home} --member-label {label} --gateway-user root",
        "log_file": f"{root}/logs/member_{label}_gateway_supervisor.log",
        "lock_file": f"/tmp/member_{label}_gateway_supervisor.lock",
        "type": "openclaw_gateway",
        "ai_on_failure": False,
    },
    f"member_{label}_zalouser": {
        "project_root": root,
        "run_command": f"SKIP_NOT_CONFIGURED=1 CONTAINER={container} MEMBER_HOME={member_home} MEMBER_LABEL={label} PROJECT_KEY=member_{label}_zalouser bash scripts/check_member_zalouser.sh",
        "log_file": f"{root}/logs/member_{label}_zalouser.log",
        "lock_file": f"/tmp/member_{label}_zalouser.lock",
        "type": "openclaw_channel",
        "ai_on_failure": False,
    },
    f"member_{label}_resource_guard": {
        "project_root": root,
        "run_command": f"/usr/bin/python3 scripts/check_member_resource_guard.py --container {container} --member-home {member_home} --member-label {label} --account {label} --no-notify",
        "log_file": f"{root}/logs/member_{label}_resource_guard.log",
        "lock_file": f"/tmp/member_{label}_resource_guard.lock",
        "type": "host_resource",
        "ai_on_failure": False,
    },
}
data.update(entries)
tmp = config_path.with_suffix(".json.tmp")
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
tmp.replace(config_path)
print("registered=" + ",".join(entries))
PY

tmp="$(mktemp)"
crontab -l 2>/dev/null >"$tmp" || true
marker="member_${MEMBER_LABEL}_v6_watchdogs"
sed -i "/# BEGIN ${marker}/,/# END ${marker}/d" "$tmp"
{
  echo "# BEGIN ${marker}"
  echo "* * * * * $CENTER_DIR/run_project.sh member_${MEMBER_LABEL}_gateway_supervisor"
  echo "*/5 * * * * $CENTER_DIR/run_project.sh member_${MEMBER_LABEL}_zalouser"
  echo "*/5 * * * * $CENTER_DIR/run_project.sh member_${MEMBER_LABEL}_resource_guard"
  echo "# END ${marker}"
} >>"$tmp"
crontab "$tmp"
rm -f "$tmp"
echo "watchdogs=registered member=$MEMBER_LABEL backup=$backup"
