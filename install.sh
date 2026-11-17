#!/usr/bin/env bash
set -Eeuo pipefail
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${1:?Usage: bash install.sh /private/customer.json [dry-run]}"
NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["member"])' "$SETTINGS")"
[[ "$NAME" =~ ^[a-z][a-z0-9_-]{0,63}$ ]] || exit 2
CHECK_DIR="/tmp/member-vps-settings-check-$$"
python3 "$BASE/configure.py" --settings "$SETTINGS" --root "$CHECK_DIR"
find "$CHECK_DIR" -type f -delete
rmdir "$CHECK_DIR/workspace" "$CHECK_DIR" 2>/dev/null || true
DATA="/root/Apps/member_vps/docker-users/data/$NAME"
[[ ! -e "$DATA" ]] || { echo 'Customer directory already exists'; exit 1; }
if docker container inspect "user-$NAME" >/dev/null 2>&1; then
  echo 'Container already exists'; exit 1
fi
ROOT_TEMPLATE="$BASE/v2-derived-root-template.tar.gz"
HOME_TEMPLATE="$BASE/v2-derived-home-template.tar.gz"
[[ -f "$ROOT_TEMPLATE" && -f "$HOME_TEMPLATE" ]] || { echo 'V2-derived baseline archives are missing'; exit 1; }
[[ "${2:-}" != dry-run ]] || { echo "Would create user-$NAME with independent persistent data; no changes made"; exit 0; }
IMAGE='member-vps-golden:20261116'
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker load -i "$BASE/golden-image.tar.gz"
fi
umask 077
mkdir -p "$DATA/root/.openclaw" "$DATA/home"
tar -xzf "$ROOT_TEMPLATE" -C "$DATA/root"
tar -xzf "$HOME_TEMPLATE" -C "$DATA/home"
chmod 700 "$DATA/root" "$DATA/home"
python3 "$BASE/configure.py" --settings "$SETTINGS" --root "$DATA/root/.openclaw" --runtime-root /root --workspace-dir "$DATA/root/.openclaw/workspace"
python3 "$BASE/docker/stage-zalo-text-guard.py" --release "$BASE" --state "$DATA/root/.openclaw"
docker run --rm --entrypoint openclaw -v "$DATA/root:/root" "$IMAGE" config validate
docker run -d --name "user-$NAME" --restart unless-stopped --memory 4g --cpus 2 \
  --mount "type=bind,source=$DATA/root,target=/root" \
  --mount "type=bind,source=$DATA/home,target=/home/$NAME" "$IMAGE"
docker exec "user-$NAME" openclaw config validate
gateway_ready=false
for attempt in {1..30}; do
  if docker exec "user-$NAME" bash -lc 'timeout 2 bash -c "</dev/tcp/127.0.0.1/18789"' >/dev/null 2>&1; then
    gateway_ready=true
    break
  fi
  sleep 2
done
if [[ "$gateway_ready" != true ]]; then
  echo 'Gateway did not become ready within 60 seconds' >&2
  docker exec "user-$NAME" supervisorctl status >&2 || true
  exit 1
fi
docker exec -i "user-$NAME" openclaw approvals set --stdin --gateway <<'JSON'
{"version":1,"socket":{"path":"/root/.openclaw/exec-approvals.sock"},"defaults":{"security":"allowlist","ask":"on-miss","askFallback":"deny","autoAllowSkills":false},"agents":{"main":{"security":"full","ask":"off","askFallback":"full","autoAllowSkills":true,"allowlist":[]}}}
JSON
bash "$BASE/zalo/register-watchdogs.sh" \
  --container "user-$NAME" \
  --member-data-dir "$DATA" \
  --member-home /root \
  --member-label "$NAME"
cp -a "$BASE/modules/image-generation/skills/." "$DATA/root/.openclaw/workspace/skills/"
docker exec "user-$NAME" supervisorctl restart openclaw-gateway
docker exec "user-$NAME" openclaw infer image providers --json | python3 -c 'import json,sys; providers=json.load(sys.stdin); assert any(provider.get("id")=="openai" and provider.get("configured") and provider.get("selected") for provider in providers), "Native image API provider is not configured"; print("native_image_api=configured")'
echo "Created user-$NAME. Before handoff, run @BotFather /setprivacy -> select this bot -> Disable, then run: docker exec user-$NAME openclaw channels status --probe"
