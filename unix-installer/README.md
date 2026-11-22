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
| **macOS Apple Silicon (M1–M4)** | `emtroly-macos-arm64.zip` | Giải nén → mở ứng dụng **`EmTroLy.app`** (nếu macOS hỏi xác nhận lần đầu: Chuột phải → *Open*, hoặc chạy `xattr -cr EmTroLy.app`) |
| **macOS Intel (x64)** | `emtroly-macos-x64.zip` | Giải nén → mở ứng dụng **`EmTroLy.app`** |
| **Ubuntu / Debian Desktop (x64)** | `emtroly-linux-x64.deb` | Chạy `sudo apt install ./emtroly-linux-x64.deb` → mở **Em Trợ Lý** trong menu ứng dụng hoặc gõ `emtroly` (không chạy với `sudo`) |
| **Linux Portable (x64)** | `emtroly-linux-x64.tar.gz` | Giải nén `tar -xzf emtroly-linux-x64.tar.gz` → chạy `./emtroly` bằng user thường |

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
