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
  printf '%s\n' 'Cách dùng: source install-ubuntu.sh hoặc bash install-ubuntu.sh [--check]' \
    'Chạy tương tác bằng user Ubuntu thường, không dùng root.' \
    'Dùng --check để kiểm tra điều kiện mà không cài đặt.'
  exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--check" ) ]]; then
  printf '%s\n' 'Cách dùng: ./install-ubuntu.sh [--check]' >&2
  exit 2
fi
if [[ "$(uname -s)" != Linux ]]; then
  printf '%s\n' 'Bộ cài terminal chỉ hỗ trợ Ubuntu Linux.' >&2
  exit 1
fi
if [[ "$(id -u)" -eq 0 ]]; then
  printf '%s\n' 'Không chạy bộ cài bằng root. Hãy đăng nhập bằng user Ubuntu thường.' >&2
  exit 1
fi
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
  printf '%s\n' 'Cần systemd user service. Hãy đăng nhập SSH trực tiếp bằng user thường và kiểm tra systemctl --user status.' >&2
  exit 1
fi
bootstrap_ready() {
  command -v python3 >/dev/null 2>&1 && python3 -c \
    'import ssl, urllib.request, tarfile, hashlib; paths = ssl.get_default_verify_paths(); assert paths.cafile or paths.capath' >/dev/null 2>&1
}
if ! bootstrap_ready; then
  printf '%s\n' 'Thiếu Python 3, thư viện chuẩn hoặc chứng chỉ CA hệ thống.' >&2
  if [[ "${1:-}" == "--check" || ! -t 0 || ! -t 1 ]]; then
    printf '%s\n' 'Hãy cài python3 và ca-certificates bằng trình quản lý gói rồi thử lại.' >&2
    exit 1
  fi
  if ! command -v apt-get >/dev/null 2>&1 || ! command -v sudo >/dev/null 2>&1; then
    printf '%s\n' 'Tự cài môi trường cần có apt-get và sudo.' >&2
    exit 1
  fi
  read -r -p 'Cho phép sudo cài python3 và ca-certificates? [y/N] ' answer
  if [[ ! "$answer" =~ ^[yY]$ ]]; then
    printf '%s\n' 'Đã hủy; chưa cài gói hệ thống.' >&2
    exit 1
  fi
  sudo apt-get update
  sudo apt-get install -y python3 ca-certificates
  if ! bootstrap_ready; then
    printf '%s\n' 'Python vẫn chưa sẵn sàng; chưa cài trợ lý.' >&2
    exit 1
  fi
fi
exec python3 "$base/unix-installer/cli.py" "$@"
