# Bộ cài đặt Em Trợ Lý cho macOS và Linux (Ubuntu / Debian)

Tài liệu hướng dẫn sử dụng các bản cài đặt chính thức trên **macOS** và **Linux** (đồng bộ tính năng với bản Windows `emtroly.exe`):
- Khóa kích hoạt bản quyền theo máy (`codex.anhlaptrinh.vn`) + Tự động lưu nháp thông số mã hóa.
- **Thứ tự ưu tiên cài đặt thông minh**: Luôn cài đặt & cấu hình **Codex CLI** đầu tiên → cấu hình **Antigravity IDE & Codex Extension** → cài môi trường riêng (`Node.js`, `Python`, `FFmpeg`), **OpenClaw**, **Gateway** và **Zalo (`/zaloqr`, `/zalostatus`)**.
- **Codex CLI Auto-Heal**: Nếu gặp sự cố kỹ thuật trong quá trình cài đặt, Codex CLI tự động chẩn đoán và sửa lỗi ngay tại chỗ (tối đa 2 lượt, tự che toàn bộ Token/API Key).
- **Quét QR Zalo trực tiếp trên giao diện** đồng thời gửi ảnh QR vào Telegram của Chủ sở hữu qua Gateway RPC (~5 giây).

---

## 1. Các tệp phát hành trên GitHub Releases

| Nền tảng | Tệp cài đặt | Cách mở / cài đặt |
|---|---|---|
| **macOS Apple Silicon (M1–M4)** | `emtroly-macos-arm64.zip` | Kiểm tra SHA-256 → giải nén → mở **`EmTroLy.app`** |
| **macOS Intel (x64)** | `emtroly-macos-x64.zip` | Kiểm tra SHA-256 → giải nén → mở **`EmTroLy.app`** |
| **Ubuntu / Debian Desktop (x64)** | `emtroly-linux-x64.deb` | Chạy `sudo apt install ./emtroly-linux-x64.deb` → mở **Em Trợ Lý** trong menu ứng dụng hoặc gõ `emtroly` (không chạy với `sudo`) |
| **Linux Portable (x64)** | `emtroly-linux-x64.tar.gz` | Giải nén `tar -xzf emtroly-linux-x64.tar.gz` → chạy `./emtroly` bằng user thường |

### Nếu macOS báo “Apple cannot check it for malicious software”

Bản phát hành có file `*.macos-signing.txt` để xác nhận trạng thái ký và
notarization. Với bản `notarized`, mở app bình thường. Với bản ad-hoc chưa có
notarization, hãy xác minh checksum trước rồi xóa quarantine cho đúng app:

```bash
cd ~/Downloads
shasum -a 256 -c emtroly-macos-arm64.zip.sha256
unzip -q -o emtroly-macos-arm64.zip
xattr -dr com.apple.quarantine EmTroLy.app
open EmTroLy.app
```

Trên máy Intel thay tên archive và file checksum bằng `emtroly-macos-x64`.
Finder cũng cho phép Control-click vào `EmTroLy.app`, chọn **Open**, rồi xác
nhận lần đầu. Không tắt Gatekeeper trên toàn hệ thống.

---

## 2. Cài đặt qua Terminal (cho VPS Ubuntu không màn hình hoặc macOS Terminal)

### Trên Ubuntu / Linux:
Đăng nhập trực tiếp bằng tài khoản người dùng thường (không dùng `root` / `sudo`, cần `systemd --user`):
```bash
./install-ubuntu.sh --check
source install-ubuntu.sh
```
*(Để giữ dịch vụ trợ lý tự chạy sau khi đăng xuất SSH trên VPS, quản trị viên có thể bật: `sudo loginctl enable-linger "$USER"`).*

### Trên macOS Terminal:
Chạy bằng tài khoản người dùng macOS thường (dịch vụ nền dùng `launchd` LaunchAgent):
```bash
./install-macos.sh --check
source install-macos.sh
```

---

## 3. Build thủ công & Kiểm thử tự động

Chạy toàn bộ bộ kiểm thử đơn vị:
```bash
python3 -m unittest discover -s unix-installer -p 'test_*.py'
python3 -m unittest discover -s native -p test_install_unix_cli.py
```

Đóng gói bản phát hành trên máy macOS hoặc Linux (cần Python 3.12+, `tkinter`, `sqlite3`, `pyinstaller==6.17.0`):
```bash
bash ./build-unix-installer.sh
```
Trên Ubuntu/Debian, đóng gói thêm tệp `.deb`:
```bash
python3 unix-installer/build-ubuntu-deb.py build/emtroly-linux-x64/dist/emtroly build/emtroly-linux-x64/emtroly-linux-x64.deb --version 2026.11.22.9 --architecture amd64 --minimum-glibc 2.35
```
