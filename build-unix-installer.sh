#!/usr/bin/env bash
set -Eeuo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"
SYSTEM="$(uname -s)"
ARCH="$(uname -m)"

case "$ARCH" in
  x86_64|amd64) ARCH=x64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

case "$SYSTEM" in
  Darwin) PLATFORM=macos ;;
  Linux)  PLATFORM=linux ;;
  *) echo "Unsupported build platform: $SYSTEM" >&2; exit 1 ;;
esac

RELEASE_VERSION="${RELEASE_VERSION:-$(tr -d '\r' < "$BASE/MANIFEST.txt" | sed -n 's/^installer_version=//p' | head -n 1)}"
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || {
  echo "Invalid release version: $RELEASE_VERSION" >&2
  exit 1
}

"$PYTHON" -c 'import tkinter, PyInstaller, sqlite3' || {
  echo 'Python tkinter, sqlite3 and PyInstaller are required on the build machine.' >&2
  exit 1
}

OUTPUT="${OUTPUT:-$BASE/build/emtroly-$PLATFORM-$ARCH}"
[[ "$OUTPUT" = /* && ! -e "$OUTPUT" ]] || {
  echo "OUTPUT must be a new absolute directory: $OUTPUT" >&2
  exit 1
}
mkdir -p "$OUTPUT"

"$PYTHON" "$BASE/unix-installer/stage_payload.py" "$BASE" "$OUTPUT/payload"

ICON_ARGS=()
if [[ "$SYSTEM" == Darwin && -f "$BASE/alt.png" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  iconset="$OUTPUT/EmTroLy.iconset"
  mkdir -p "$iconset"
  for sz in 16 32 128 256 512; do
    sips -z "$sz" "$sz" "$BASE/alt.png" --out "$iconset/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
    sz2=$((sz * 2))
    sips -z "$sz2" "$sz2" "$BASE/alt.png" --out "$iconset/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1 || true
  done
  if iconutil -c icns "$iconset" -o "$OUTPUT/EmTroLy.icns" >/dev/null 2>&1; then
    ICON_ARGS=(--icon "$OUTPUT/EmTroLy.icns")
  fi
fi

APP_NAME="emtroly"
if [[ "$SYSTEM" == Darwin ]]; then
  APP_NAME="EmTroLy"
fi

"$PYTHON" -m PyInstaller --noconfirm --onefile --windowed --name "$APP_NAME" \
  "${ICON_ARGS[@]}" \
  --paths "$BASE/unix-installer" \
  --distpath "$OUTPUT/dist" --workpath "$OUTPUT/work" --specpath "$OUTPUT" \
  --hidden-import sqlite3 --hidden-import runpy --hidden-import contextlib \
  --hidden-import shlex --hidden-import uuid --hidden-import argparse --hidden-import copy \
  --hidden-import datetime --hidden-import dataclasses --hidden-import stat --hidden-import typing \
  --hidden-import codex_setup --hidden-import license_gate --hidden-import runner \
  --hidden-import net_utils --hidden-import uninstaller --hidden-import updater --hidden-import webbrowser \
  --hidden-import ssl --hidden-import http.client \
  --hidden-import configuration --hidden-import secrets --hidden-import hmac --hidden-import base64 \
  --hidden-import hashlib --hidden-import tarfile --hidden-import zipfile --hidden-import importlib.util \
  --hidden-import urllib.request --hidden-import urllib.error --hidden-import urllib.parse \
  --hidden-import dependencies --hidden-import ffmpeg --hidden-import instance \
  --hidden-import payload --hidden-import provider --hidden-import python_exec \
  --hidden-import python_runtime --hidden-import runtime --hidden-import service \
  --hidden-import settings --hidden-import telegram --hidden-import zalo_setup \
  --add-data "$OUTPUT/payload/native:native" \
  --add-data "$OUTPUT/payload/modules:modules" \
  --add-data "$OUTPUT/payload/profiles:profiles" \
  --add-data "$OUTPUT/payload/zalo:zalo" \
  --add-data "$BASE/windows-installer/zalo-qr-session.mjs:windows-installer" \
  --add-data "$BASE/alt.png:." \
  --add-data "$BASE/MANIFEST.txt:." \
  "$BASE/unix-installer/gui.py"

ARTIFACT_BASE="emtroly-$PLATFORM-$ARCH"

if [[ "$SYSTEM" == Darwin ]]; then
  APP_PATH="$OUTPUT/dist/$APP_NAME.app"
  SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:-${APPLE_SIGNING_IDENTITY:-}}"
  SIGNING_STATUS="ad-hoc"
  NOTARIZATION_STATUS="not-requested"

  command -v codesign >/dev/null 2>&1 || {
    echo 'macOS build requires codesign.' >&2
    exit 1
  }

  if [[ -n "$SIGNING_IDENTITY" ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_PATH"
    SIGNING_STATUS="developer-id"
  else
    # Ad-hoc signing keeps local builds executable. Gatekeeper still requires
    # the user to approve or clear quarantine until a Developer ID build is used.
    codesign --force --deep --sign - "$APP_PATH"
  fi
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"

  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT/$ARTIFACT_BASE.zip"

  if [[ "$SIGNING_STATUS" == "developer-id" && "${MACOS_NOTARIZE:-auto}" != "never" &&
        -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    command -v xcrun >/dev/null 2>&1 || {
      echo 'xcrun is required for macOS notarization.' >&2
      exit 1
    }
    xcrun notarytool submit "$OUTPUT/$ARTIFACT_BASE.zip" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --wait
    xcrun stapler staple "$APP_PATH"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    spctl --assess --type execute --verbose=2 "$APP_PATH"
    # Recreate the archive after stapling the notarization ticket.
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT/$ARTIFACT_BASE.zip"
    NOTARIZATION_STATUS="notarized"
  elif [[ "$SIGNING_STATUS" == "developer-id" ]]; then
    NOTARIZATION_STATUS="not-configured"
  fi

  if [[ "${MACOS_NOTARIZE_REQUIRED:-0}" == "1" && "$NOTARIZATION_STATUS" != "notarized" ]]; then
    echo 'Tagged macOS releases require Developer ID signing and Apple notarization.' >&2
    echo 'Configure MACOS_CERTIFICATE_P12_BASE64, APPLE_ID, APPLE_TEAM_ID and APPLE_APP_SPECIFIC_PASSWORD in CI.' >&2
    exit 1
  fi

  {
    printf 'signing=%s\n' "$SIGNING_STATUS"
    printf 'notarization=%s\n' "$NOTARIZATION_STATUS"
    printf 'identity=%s\n' "${SIGNING_IDENTITY:-none}"
  } > "$OUTPUT/$ARTIFACT_BASE.macos-signing.txt"
  (cd "$OUTPUT" && shasum -a 256 "$ARTIFACT_BASE.zip" > "$ARTIFACT_BASE.zip.sha256")
  printf 'Built macOS release: %s/%s.zip\n' "$OUTPUT" "$ARTIFACT_BASE"
else
  (cd "$OUTPUT/dist" && tar -czf "$OUTPUT/$ARTIFACT_BASE.tar.gz" "$APP_NAME")
  (cd "$OUTPUT" && sha256sum "$ARTIFACT_BASE.tar.gz" > "$ARTIFACT_BASE.tar.gz.sha256")
  printf 'Built Linux portable archive: %s/%s.tar.gz\n' "$OUTPUT" "$ARTIFACT_BASE"
fi
