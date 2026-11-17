#!/usr/bin/env bash
set -Eeuo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEMBER="${1:?Usage: activate-protection.sh MEMBER}"
[[ "$MEMBER" =~ ^[a-z][a-z0-9_-]{0,63}$ ]] || exit 2
CONTAINER="user-$MEMBER"
DATA="/root/Apps/member_vps/docker-users/data/$MEMBER/root"
SKILLS="$BASE/native/skills"
[[ -f "$DATA/.openclaw/openclaw.json" ]] || { echo 'Member config unavailable' >&2; exit 1; }
for skill in openclaw-zalo-context-rotation-70k openclaw-zalo-text-delivery-guard; do
  [[ -f "$SKILLS/$skill/scripts/install.py" ]] || { echo "Missing protection installer: $skill" >&2; exit 1; }
done
python3 "$SKILLS/openclaw-zalo-text-delivery-guard/scripts/install.py" \
  --container "$CONTAINER" --member-data-dir "$DATA" \
  --member-home /root --member-label "$MEMBER" --apply
python3 "$SKILLS/openclaw-zalo-context-rotation-70k/scripts/install.py" \
  --container "$CONTAINER" --member-data-dir "$DATA" \
  --member-home /root --member-label "$MEMBER" --apply
docker exec -e HOME=/root "$CONTAINER" openclaw config validate
docker exec -e HOME=/root "$CONTAINER" openclaw health
printf 'zalo_protection=verified\n'
