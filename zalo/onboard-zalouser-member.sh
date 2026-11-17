#!/usr/bin/env bash
set -Eeuo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER=""
MEMBER_LABEL=""
TELEGRAM_ACCOUNT=""
QR_TELEGRAM_ID=""
MODE="dry-run"
OPEN_GROUPS=0
DO_QR=0

usage() {
  cat <<'EOF'
Usage: onboard-zalouser-member.sh --container user-<member> --member-label <member>
  --telegram-account <account> [--dry-run|--apply] [--open-groups]
  [--qr --qr-telegram-id <verified-owner-id>]
EOF
}

while (($#)); do
  case "$1" in
    --container|--member-label|--telegram-account|--qr-telegram-id)
      (($# >= 2)) || { usage >&2; exit 2; }
      case "$1" in
        --container) CONTAINER="$2" ;;
        --member-label) MEMBER_LABEL="$2" ;;
        --telegram-account) TELEGRAM_ACCOUNT="$2" ;;
        --qr-telegram-id) QR_TELEGRAM_ID="$2" ;;
      esac
      shift 2 ;;
    --dry-run) MODE="dry-run"; shift ;;
    --apply) MODE="apply"; shift ;;
    --open-groups) OPEN_GROUPS=1; shift ;;
    --qr) DO_QR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ "$MEMBER_LABEL" =~ ^[a-z][a-z0-9_-]{0,63}$ ]] || exit 2
[[ "$CONTAINER" == "user-$MEMBER_LABEL" ]] || exit 2
[[ "$TELEGRAM_ACCOUNT" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 2
if ((DO_QR)); then
  [[ "$MODE" == apply && "$QR_TELEGRAM_ID" =~ ^[1-9][0-9]*$ ]] || exit 2
fi

runtime() {
  docker exec -e HOME=/root -e OPENCLAW_CONFIG_PATH=/root/.openclaw/openclaw.json "$CONTAINER" "$@"
}

runtime supervisorctl status openclaw-gateway | grep -q RUNNING
core_version="$(runtime openclaw --version | sed -n 's/^OpenClaw \([0-9][^ ]*\).*/\1/p')"
[[ "$core_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
runtime openclaw config validate >/dev/null
installed_version="$(runtime python3 -c 'import json; c=json.load(open("/root/.openclaw/openclaw.json")); print(c.get("plugins",{}).get("installs",{}).get("zalouser",{}).get("version", ""))')"
if [[ -z "$installed_version" ]]; then
  if plugin_info="$(runtime openclaw plugins info zalouser --json)"; then
    installed_version="$(printf '%s' "$plugin_info" | python3 -c 'import json,sys; p=json.load(sys.stdin).get("plugin",{}); print(p.get("version", "") if p.get("id")=="zalouser" and p.get("status")=="loaded" else "")')"
  elif ! printf '%s' "$plugin_info" | python3 -c 'import json,sys; p=json.load(sys.stdin); error=str(p.get("error", "")).lower(); sys.exit(0 if p.get("ok") is False and "not found" in error and "zalouser" in error else 1)'; then
    echo 'Could not inspect Zalo plugin; check the member runtime before retrying.' >&2
    exit 1
  fi
fi
if [[ -n "$installed_version" && "$installed_version" != "$core_version" ]]; then
  echo 'Plugin/core mismatch; use the controlled upgrade runbook first.' >&2
  exit 1
fi
runtime python3 -c 'import json,sys; c=json.load(open("/root/.openclaw/openclaw.json")); assert sys.argv[1] in c.get("channels",{}).get("telegram",{}).get("accounts",{})' "$TELEGRAM_ACCOUNT"
echo "mode=$MODE"
echo "container=$CONTAINER"
echo "core_version=$core_version"
echo "plugin_spec=@openclaw/zalouser@$core_version"
echo "group_policy=$([[ $OPEN_GROUPS == 1 ]] && echo open_no_mention || echo allowlist)"

if [[ "$MODE" == dry-run ]]; then
  echo 'dry_run=pass'
  exit 0
fi

umask 077
backup="$(mktemp -d "/root/_Backups/zalo-${MEMBER_LABEL}-XXXXXXXX")"
docker cp "$CONTAINER:/root/.openclaw/openclaw.json" "$backup/openclaw.json"
chmod 600 "$backup/openclaw.json"
if [[ -z "$installed_version" ]]; then
  runtime openclaw plugins install --pin "@openclaw/zalouser@$core_version"
fi
runtime openclaw plugins enable zalouser
runtime openclaw plugins doctor >/dev/null
runtime supervisorctl stop openclaw-gateway
restart_gateway() { runtime supervisorctl start openclaw-gateway; }
trap restart_gateway EXIT
docker exec -i -e HOME=/root -e OPENCLAW_CONFIG_PATH=/root/.openclaw/openclaw.json "$CONTAINER" \
  python3 - --root /root/.openclaw --open-groups "$OPEN_GROUPS" < "$BASE/configure-zalo.py"
runtime supervisorctl start openclaw-gateway
trap - EXIT
for attempt in {1..12}; do
  runtime openclaw health >/dev/null 2>&1 && break
  [[ "$attempt" -eq 12 ]] && { echo "Gateway health failed; backup=$backup" >&2; exit 1; }
  sleep 5
done
runtime openclaw config validate >/dev/null
runtime openclaw plugins doctor >/dev/null
runtime openclaw channels status --probe
bash "$BASE/activate-protection.sh" "$MEMBER_LABEL"
owner_login="$BASE/../native/skills/telegram-zalo-owner-login/scripts/deploy.py"
python3 "$owner_login" --member "$MEMBER_LABEL" --telegram-account "$TELEGRAM_ACCOUNT" --dry-run
python3 "$owner_login" --member "$MEMBER_LABEL" --telegram-account "$TELEGRAM_ACCOUNT" --apply
python3 "$owner_login" --member "$MEMBER_LABEL" --telegram-account "$TELEGRAM_ACCOUNT" --check
for attempt in {1..12}; do
  runtime openclaw health >/dev/null 2>&1 && break
  [[ "$attempt" -eq 12 ]] && { echo 'Owner QR plugin installed but gateway health failed' >&2; exit 1; }
  sleep 5
done
echo 'telegram_owner_qr=verified'
echo "apply=pass backup=$backup"

if ((DO_QR)); then
  qr_script=/root/.agents/skills/openclaw-zalo-qr-login/scripts/send_zalo_qr_to_telegram_owner.mjs
  runtime node "$qr_script" --target "$QR_TELEGRAM_ID" --account default --dry-run
  runtime node "$qr_script" --target "$QR_TELEGRAM_ID" --account default --apply
fi
