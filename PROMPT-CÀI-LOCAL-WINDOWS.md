# Cài trợ lý cá nhân Windows bằng bộ cài `.exe` — OpenClaw 2026.11.4

Ưu tiên chạy `emtroly.exe` trong release V6. Bộ cài
mở wizard để nhập các trường cần thiết, kiểm tra provider/Telegram, cài user-scope
và mặc định bật Zalo/mention/QR cùng Full Exec cho các Telegram Owner IDs đã nhập.
QR owner mặc định là Owner ID đầu tiên; Zalo là bắt buộc. Bộ cài chỉ cài plugin,
đăng ký lệnh và cấu hình account/binding; không dừng Gateway để chờ đăng nhập Zalo.
Sau khi cài, owner nhắn
`/start` rồi `/zaloqr` trong chat riêng, và có thể dùng `/zalostatus`. Bộ cài báo
thành công khi Gateway khỏe, plugin đã nạp và hai lệnh đã đăng ký; không cần quét
QR trong lúc cài. Không chạy
hai instance cùng `Name`; installer không ghi đè instance cũ.

Trước khi cài, người dùng phải xác nhận cảnh báo Full Exec và Zalo. Mọi thành viên
nhóm Telegram đã chọn có thể yêu cầu chạy lệnh. Zalo mặc định dùng allowlist;
chưa có lệnh Telegram để duyệt Zalo ID và cấp Full Exec. Chỉ dùng nhóm đáng tin cậy.

Nếu không thể chạy `.exe`, mới dùng prompt Antigravity bên dưới như phương án
phục hồi thủ công.

Không dùng bundle/bootstrap native cũ. Vào web installer, điền đầy đủ thông tin khách,
Telegram Bot Token, API key, Owner IDs, Group ID và credential module cần dùng.
Chọn Cài máy cá nhân, sao chép prompt riêng hoặc tải file Markdown, rồi mở file/dán
vào Antigravity trên chính máy khách để thực thi.

Prompt sinh riêng theo form, có mã nhận secret một lần trong 60 phút; không chia sẻ
công khai. Kiểm tra manifest/file và SHA256; website có snapshot riêng và chưa
được đồng bộ theo lần nâng template này.
Mẫu trong template nhắm OpenClaw 2026.11.4; không giả định website đang phát
đúng phiên bản hoặc manifest này khi snapshot web chưa được đồng bộ.
Không SSH vào VPS, không dùng Docker, không tự yêu cầu khách mở PowerShell.

Skill bắt buộc cho Zalo: openclaw-zalo-text-delivery-guard, bao gồm SKILL.md,
assets/guard.mjs, assets/test_guard.mjs, scripts/install.py và scripts/test_install.py.
Runtime patch upstream chỉ hỗ trợ Docker/Supervisor, không chạy installer đó trên
Windows. Bộ cài native chỉ dùng patch mention đã kiểm hash và test offline riêng;
quét QR/OAuth/chính sách hệ điều hành vẫn có thể cần khách tương tác.

## Mẫu yêu cầu không chứa secret

```text
/tao-tro-ly-openclaw-windows-macos-linux
Cài trực tiếp trợ lý cá nhân trên máy này bằng skill, OpenClaw 2026.11.4.
Dùng prompt riêng website đã sinh có đầy đủ dữ liệu khách và mã nhận secret.
Tải đủ skill từ manifest V6, không dùng bundle và không hỏi lại form.
Máy mới cài ngay; instance trùng tên phải backup trước nâng cấp; không chạm
instance khác hoặc VPS. Telegram/Zalo dùng đúng bot và owner đã nhập.
Kiểm tra đủ SHA256 file skill, config, RPC và channel probe; báo riêng phần
chưa xác minh, không coi có skill đồng nghĩa module đã hoạt động.
```
