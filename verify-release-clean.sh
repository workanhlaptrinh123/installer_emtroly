#!/usr/bin/env bash
set -Eeuo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

check_archive() {
  local archive="$1"
  local name
  name="$(basename "$archive")"
  while IFS= read -r path; do
    [[ "$path" == */customer_history/ || "$path" == */customer_history/.gitkeep ]] && continue
    case "$path" in
      */customer_history/*|*/database/conversations.db|*/.openclaw/*|*/telegram.token|*/member-provider.secret|*/gateway.log|*/gateway-error.log)
        printf 'forbidden runtime/customer state in %s: %s\n' "$name" "$path" >&2
        fail=1
        ;;
    esac
  done < <(tar -tzf "$archive")
}

check_archive "$BASE/v2-derived-root-template.tar.gz"
check_archive "$BASE/v2-derived-home-template.tar.gz"

if tar -tzf "$BASE/golden-image.tar.gz" | grep -E '(^|/)(\.openclaw|telegram\.token|member-provider\.secret|gateway\.log|gateway-error\.log)(/|$)' >/dev/null; then
  printf 'forbidden runtime state in golden image\n' >&2
  fail=1
fi

if (( fail )); then
  exit 1
fi

printf 'clean release audit passed\n'
