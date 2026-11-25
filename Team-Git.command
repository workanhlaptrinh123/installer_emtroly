#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
echo "Dang mo giao dien Team Git Studio (http://127.0.0.1:8765)..."
python3 .agents/skills/git-team-flow/scripts/team_git.py ui --port 8765
