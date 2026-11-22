#!/usr/bin/env bash
set -Eeuo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$BASE/emtroly.exe}"
NSIS="${NSIS:-$(command -v makensis || true)}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
RELEASE_VERSION="${RELEASE_VERSION:-$(sed -n 's/^installer_version=//p' "$BASE/MANIFEST.txt")}"
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || exit 1
file_version="$RELEASE_VERSION"
if [[ ! "$file_version" =~ ^([0-9]+\.){3} ]]; then file_version+=".0"; fi

if [[ -n "$NSIS" && ! -x "$NSIS" ]]; then NSIS=""; fi
if [[ -z "$NSIS" ]]; then
  for candidate in \
    /tmp/nsis-stage/extract/usr/bin/makensis \
    /usr/bin/makensis \
    "/c/Program Files (x86)/NSIS/makensis.exe" \
    "/c/Program Files (x86)/NSIS/Bin/makensis.exe" \
    "/c/Program Files/NSIS/makensis.exe" \
    "/c/Program Files/NSIS/Bin/makensis.exe"; do
    if [[ -x "$candidate" ]]; then
      NSIS="$candidate"
      break
    fi
  done
fi

[[ -x "$NSIS" ]] || {
  echo "makensis not found: $NSIS" >&2
  exit 1
}

stage="$(mktemp -d /tmp/openclaw-member-nsis.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
payload="$stage/payload"
mkdir -p "$payload/windows-installer"

cp "$BASE/install-native-windows.ps1" "$payload/"
cp "$BASE/configure.py" "$payload/"
cp "$BASE/alt.png" "$payload/"
cp "$BASE/MANIFEST.txt" "$payload/"
cp -a "$BASE/native" "$payload/"
cp -a "$BASE/modules" "$payload/"
cp -a "$BASE/profiles" "$payload/"
cp -a "$BASE/zalo" "$payload/"
cp "$BASE/windows-installer/run-native-install.ps1" "$payload/windows-installer/"
cp "$BASE/windows-installer/launch-wizard.vbs" "$payload/windows-installer/"
cp "$BASE/windows-installer/wizard.ps1" "$payload/windows-installer/"
cp "$BASE/windows-installer/wizard-helpers.ps1" "$payload/windows-installer/"
cp "$BASE/windows-installer/zalo-qr-session.mjs" "$payload/windows-installer/"
cp "$BASE/windows-installer/codex-cli.ps1" "$payload/windows-installer/"
cp "$BASE/windows-installer/auto-heal-codex.ps1" "$payload/windows-installer/"
cp "$BASE/windows-installer/manage-instance.ps1" "$payload/windows-installer/"
cp "$BASE/windows-installer/alt.ico" "$payload/windows-installer/"
cp "$BASE/windows-installer/validation.ps1" "$payload/windows-installer/"
cp "$BASE/windows-installer/verify-openclaw-command.ps1" "$payload/windows-installer/"
cp "$BASE/windows-installer/install-antigravity-codex.ps1" "$payload/windows-installer/"
cp "$BASE/windows-installer/repair-antigravity-shortcut.ps1" "$payload/windows-installer/"
cp -a "$BASE/windows-installer/activation-probe" "$payload/windows-installer/"

find "$payload" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$payload" -type f -name '*.pyc' -delete
find "$payload" -type f -name '*.bak-*' -delete
"$PYTHON_BIN" - "$payload" <<'PY'
import sys
from pathlib import Path

for path in Path(sys.argv[1]).rglob('*.ps1'):
    data = path.read_bytes()
    if not data.startswith(b'\xef\xbb\xbf'):
        path.write_bytes(b'\xef\xbb\xbf' + data)
PY

mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
nsis_dir="$(dirname "$(dirname "$NSIS")")/share/nsis"
if [[ -d "$nsis_dir" && -z "${NSISDIR:-}" ]]; then export NSISDIR="$nsis_dir"; fi
nsis_args=(
  -D"PAYLOAD_DIR=$payload" \
  -D"OUTFILE=$OUT" \
  -D"RELEASE_VERSION=$RELEASE_VERSION" \
  -D"FILE_VERSION=$file_version" \
  -D"ICON_FILE=$BASE/windows-installer/alt.ico" \
  "$BASE/windows-installer/member-vps-installer.nsi"
)
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) nsis_args=(-DWINDOWS_BUILD "${nsis_args[@]}" ) ;;
esac
"$NSIS" "${nsis_args[@]}"

(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
printf 'Built %s\n' "$OUT"
