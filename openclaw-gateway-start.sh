#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -f /root/.openclaw/openai-image.env ]]; then
  set -a
  # shellcheck disable=SC1091
  . /root/.openclaw/openai-image.env
  set +a
fi
exec openclaw gateway run
