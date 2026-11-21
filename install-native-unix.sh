#!/usr/bin/env bash
set -Eeuo pipefail
NAME=""; OWNER_IDS=""; GROUP_ID=""; ASSISTANT_NAME="Trợ lý OpenClaw"; BASE_URL="https://codex.anhlaptrinh.vn/v1"; MODEL="gpt-6.2-sol"; PROFILE="basic-assistant-full"; MODULES=(); DRY_RUN=0; FULL_BUNDLE=0
AUDIENCE=""; ADDRESSING=""; STYLE=""; CREDENTIAL_FILE=""
while (($#)); do case "$1" in
  --name) NAME="$2"; shift 2;; --owner-ids) OWNER_IDS="$2"; shift 2;; --group-id) GROUP_ID="$2"; shift 2;; --assistant-name) ASSISTANT_NAME="$2"; shift 2;;
  --audience) AUDIENCE="$2"; shift 2;; --addressing) ADDRESSING="$2"; shift 2;; --style) STYLE="$2"; shift 2;;
  --credential-file) CREDENTIAL_FILE="$2"; shift 2;;
  --base-url) BASE_URL="$2"; shift 2;; --model) MODEL="$2"; shift 2;; --profile) PROFILE="$2"; shift 2;;
  --module) MODULES+=("$2"); shift 2;; --full-bundle) FULL_BUNDLE=1; shift;; --dry-run) DRY_RUN=1; shift;; *) exit 2;; esac; done
[[ -n "$NAME" && -n "$OWNER_IDS" && -n "$MODEL" ]] || { echo 'name, owner-ids and model are required' >&2; exit 2; }
[[ "$(id -u)" == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
if [[ -n "${OPENCLAW_ROOT:-}" ]]; then ROOT="$OPENCLAW_ROOT"
elif [[ "$(uname -s)" == Darwin ]]; then ROOT="/var/root/.openclaw"
else ROOT="/root/.openclaw"
fi
WORKSPACE="$ROOT/workspace"; BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ ! -e "$ROOT/openclaw.json" ]] || { echo 'Existing installation: use a backed-up upgrade flow, not the fresh Unix installer'; exit 1; }
[[ "$NAME" =~ ^[a-z][a-z0-9_-]{0,63}$ ]] || exit 2
if [[ "$DRY_RUN" == 1 ]]; then echo "DRY-RUN: native OpenClaw on $(uname -s) for $NAME; no changes made"; exit 0; fi
if [[ "$(uname -s)" == Darwin ]]; then
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  for dependency in node npm python3 ffmpeg; do
    command -v "$dependency" >/dev/null || { echo "Missing $dependency. Run brew install node python ffmpeg as your normal macOS user, then retry." >&2; exit 1; }
  done
fi
command -v node >/dev/null && command -v npm >/dev/null || { echo 'Install Node.js/npm on this computer before running the installer.' >&2; exit 1; }
if command -v apt-get >/dev/null; then apt-get update -qq; apt-get install -y -qq ca-certificates curl python3 python3-pip ffmpeg >/dev/null; fi
command -v python3 >/dev/null || { echo 'Python 3 is required.' >&2; exit 1; }
npm install -g openclaw@2026.11.4 >/dev/null
if [[ -z "$CREDENTIAL_FILE" ]]; then
  read -r -s -p 'Telegram Bot Token: ' TG; echo
  read -r -s -p 'Provider API Key: ' KEY; echo
fi
install -d -m 700 "$ROOT" "$WORKSPACE" "$WORKSPACE/skills"
export TG KEY NAME OWNER_IDS GROUP_ID BASE_URL MODEL ASSISTANT_NAME CREDENTIAL_FILE
trap 'unset TG KEY; if [[ -f "$BASE/settings.json" ]]; then shred -u "$BASE/settings.json" 2>/dev/null || rm -f "$BASE/settings.json"; fi' EXIT
python3 - "$BASE/settings.json" <<'PY'
import json, os, sys
if os.environ.get('CREDENTIAL_FILE'):
    with open(os.environ['CREDENTIAL_FILE']) as stream:
        payload = json.load(stream)
    os.environ['TG'] = str(payload.get('telegram_token', ''))
    os.environ['KEY'] = str(payload.get('ai_api_key', ''))
    if not os.environ['TG'].strip() or not os.environ['KEY'].strip():
        raise SystemExit('Missing installation credentials')
    destination = os.path.join(os.environ.get('OPENCLAW_ROOT', '/var/root/.openclaw' if sys.platform == 'darwin' else '/root/.openclaw'), 'installation-credentials.json')
    with open(destination, 'w') as stream:
        json.dump({'extra_secret': payload.get('extra_secret', ''), 'module_credentials': payload.get('module_credentials', {})}, stream)
    os.chmod(destination, 0o600)
owners=[item.strip() for item in os.environ['OWNER_IDS'].split(',') if item.strip()]
json.dump({'member': os.environ['NAME'], 'assistant_name': os.environ['ASSISTANT_NAME'], 'owner_ids': owners, 'group_id': os.environ['GROUP_ID'], 'telegram_token': os.environ['TG'], 'base_url': os.environ['BASE_URL'], 'api_key': os.environ['KEY'], 'api': 'openai-completions', 'model': os.environ['MODEL']}, open(sys.argv[1], 'w'), ensure_ascii=False)
PY
chmod 600 "$BASE/settings.json"
openclaw onboard --non-interactive --accept-risk --mode local --auth-choice skip --skip-channels --skip-search --skip-skills --install-daemon --skip-health --workspace "$WORKSPACE" --gateway-bind loopback --gateway-auth token --gateway-port 18789 --gateway-token chatbot >/dev/null
python3 "$BASE/configure.py" --settings "$BASE/settings.json" --root "$ROOT" --workspace "$WORKSPACE" --overwrite
rm -f "$BASE/settings.json"
"$BASE/native/install-module-manager-unix.sh"
if [[ "$FULL_BUNDLE" == 1 ]]; then
  for skill in "$BASE/native/skills"/*; do [[ -d "$skill" ]] || continue; cp -a "$skill" "$WORKSPACE/skills/"; done
else
  MANAGER=("$ROOT/module-manager.sh" install --profile "$PROFILE")
  for module in "${MODULES[@]}"; do MANAGER+=(--module "$module"); done
  "${MANAGER[@]}"
fi
ENSURE="$WORKSPACE/skills/tao-tro-ly-openclaw-windows-macos-linux/scripts/ensure_default_telegram_owner.py"
TRAIN="$WORKSPACE/skills/sync-openclaw-owner-training/scripts/sync_owner_training_policy.py"
ARGS=(--openclaw-root "$ROOT" --account-id "$NAME" --agent-id main --apply --backup-dir "$ROOT/backups/onboarding")
IFS=',' read -ra IDS <<< "$OWNER_IDS"; for owner in "${IDS[@]}"; do ARGS+=(--owner-id "${owner// /}"); done
python3 "$ENSURE" "${ARGS[@]}"
python3 "$TRAIN" --openclaw-root "$ROOT" --workspace "$WORKSPACE" --apply --backup-dir "$ROOT/backups/onboarding"
python3 "$BASE/native/finalize_permissions.py" --config "$ROOT/openclaw.json" --owners "$OWNER_IDS"
export AUDIENCE ADDRESSING STYLE
python3 - "$WORKSPACE" <<'PY'
import os, pathlib, sys
workspace = pathlib.Path(sys.argv[1])
profile = '# Hồ sơ trợ lý\n\n' + '\n\n'.join(f'{label}: {os.environ[key]}' for key, label in [('ASSISTANT_NAME', 'Tên trợ lý'), ('AUDIENCE', 'Đối tượng phục vụ'), ('ADDRESSING', 'Cách xưng hô'), ('STYLE', 'Phong cách trả lời')]) + '\n'
(workspace / 'CUSTOMER_PROFILE.md').write_text(profile)
instructions = workspace / 'AGENTS.md'
reference = 'Đọc CUSTOMER_PROFILE.md để áp dụng tên trợ lý, đối tượng phục vụ, cách xưng hô và phong cách trả lời.'
text = instructions.read_text() if instructions.exists() else ''
if reference not in text:
    instructions.write_text(text + '\n\n' + reference + '\n')
PY
openclaw config validate --json
openclaw skills check
openclaw gateway restart >/dev/null
openclaw gateway status
echo "NATIVE INSTALL COMPLETE: $ROOT"
