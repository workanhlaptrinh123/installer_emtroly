#!/usr/bin/env bash
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  if command bash "${BASH_SOURCE[0]}" "$@"; then
    if [[ $# -eq 0 ]]; then
      case ":${PATH-}:" in
        *":$HOME/.local/bin:"*) ;;
        *) export PATH="${PATH:+$PATH:}$HOME/.local/bin" ;;
      esac
      hash -r
      printf '%s\n' 'Đã cập nhật PATH cho terminal hiện tại.'
    fi
    return 0
  else
    return $?
  fi
fi
set -euo pipefail

base="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  printf '%s\n' 'Cách dùng: source install-macos.sh hoặc bash install-macos.sh [--check]' \
    'Chạy tương tác bằng tài khoản người dùng macOS thường, không dùng sudo/root.' \
    'Dùng --check để kiểm tra điều kiện mà không cài đặt.'
  exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--check" ) ]]; then
  printf '%s\n' 'Cách dùng: ./install-macos.sh [--check]' >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'Script install-macos.sh chỉ dành cho macOS (trên Linux hãy dùng install-ubuntu.sh).' >&2
  exit 1
fi
if [[ "$(id -u)" -eq 0 ]]; then
  printf '%s\n' 'Không chạy bộ cài bằng root/sudo. Hãy chạy bằng tài khoản người dùng macOS thường.' >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'Thiếu Python 3 trên máy Mac. Hãy chạy: xcode-select --install (hoặc brew install python) rồi thử lại.' >&2
  exit 1
fi
exec python3 "$base/unix-installer/cli.py" "$@"
