#!/usr/bin/env bash
set -Eeuo pipefail
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-20261116}"
IMAGE="member-vps-golden:$VERSION"
docker build --pull=false -t "$IMAGE" "$BASE"
archive="$BASE/.golden-image.$$.tar.gz"
trap 'rm -f "$archive"' EXIT
docker save "$IMAGE" | gzip -n > "$archive"
mv -f "$archive" "$BASE/golden-image.tar.gz"
(cd "$BASE" && sha256sum golden-image.tar.gz > SHA256SUMS)
{
  echo "release=member-vps-golden-$VERSION"
  echo "image=$IMAGE"
  echo "base_image=vps-user-env:latest"
echo "openclaw=2026.11.4"
  printf 'core_profile=basic-assistant-full\n'
  printf 'modules='
  find "$BASE/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f,' | sed 's/,$//'
  printf '\n'
  echo "secrets=customer-injected-at-install-time"
  echo "customer_state=excluded"
} > "$BASE/MANIFEST.txt"
echo "Built $IMAGE and $BASE/golden-image.tar.gz"
