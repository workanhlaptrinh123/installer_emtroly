# Quy trình Zalo Personal cho Member VPS

Quy trình này dành cho OpenClaw chạy trong Docker member. Mỗi member dùng
một tài khoản Zalo riêng; không sao chép session, cookie, QR hoặc dữ liệu của
member khác.

## 1. Chuẩn bị

Xác định các giá trị không bí mật:

```text
CONTAINER=user-<member>
MEMBER_LABEL=<member>
MEMBER_HOME=/home/<member>
TELEGRAM_ACCOUNT_ID=<telegram-account>
ZALO_ACCOUNT_ID=default
```

Đảm bảo Gateway đang chạy dưới Supervisor và Telegram owner đã được xác minh.
Chạy script từ host VPS:

```bash
bash zalo/onboard-zalouser-member.sh \
  --container user-<member> \
  --member-label <member> \
  --telegram-account <telegram-account> \
  --dry-run
```

## 2. Cài và cấu hình plugin

Sau khi dry-run đạt, chạy apply:

```bash
bash zalo/onboard-zalouser-member.sh \
  --container user-<member> \
  --member-label <member> \
  --telegram-account <telegram-account> \
  --apply
```

Script sẽ backup `openclaw.json`, cài `@openclaw/zalouser` cùng release với
OpenClaw core, tạo account `default`, binding vào `main`, validate config và
khởi động lại đúng Gateway Supervisor. Mặc định Zalo DM dùng `open` và
`allowFrom = ["*"]` ở cả channel/account: sau đăng nhập, mọi người có thể
nhắn riêng mà không cần mã ghép nối. Đây không phải quyền owner; danh sách
owner/elevated và người nhận QR vẫn xác minh riêng, không thêm wildcard.
Telegram DM không thay đổi. Group dùng
allowlist an toàn. Chỉ thêm `--open-groups` khi chủ member yêu cầu bot trả lời
mọi người trong group mà không cần mention. Web và bot cài đặt luôn truyền
`--open-groups`: group mặc định mở, không cần mention và mọi thành viên được
dùng đầy đủ công cụ runtime qua `groups.*.tools.allow = ["*"]`. Áp dụng cả
group đã khai báo cụ thể để không bị ghi đè bởi cấu hình riêng của group.
Chính sách này không thay đổi danh sách owner hoặc Telegram DM.
Đây là cấu hình rủi ro cao: chỉ đưa trợ lý vào nhóm đáng tin cậy, vì thành viên
có thể yêu cầu chạy lệnh và thao tác file trong runtime của member.

## 3. Đăng nhập QR

Chỉ chạy sau khi owner đồng ý quét QR:

```bash
bash zalo/onboard-zalouser-member.sh \
  --container user-<member> \
  --member-label <member> \
  --telegram-account <telegram-account> \
  --qr-telegram-id <verified-telegram-owner-id> \
  --qr
```

QR được gửi qua Telegram cho đúng owner để quét bằng ứng dụng Zalo. Không ghi
QR hoặc cookie vào log, tài liệu, image hay release. Sau khi quét, phải kiểm tra
`configured`, `linked`, `running`, `connected`, `works` bằng probe.

## 4. Cấp quyền Zalo owner

Khi người dùng nhắn bot, OpenClaw trả `Your Zalo user id` và pairing code.
Duyệt code trên chính container:

```bash
docker exec -e HOME=/root user-<member> \
  openclaw pairing approve zalouser <PAIRING_CODE>
```

Sau khi xác minh đúng danh tính, đồng bộ full owner bằng updater chuẩn trong
skill `openclaw-zalouser-owner-access`. Không dùng tên hiển thị để định tuyến;
luôn dùng Zalo user ID.

## 5. Kiểm tra cuối

```bash
docker exec -e HOME=/root user-<member> openclaw config validate
docker exec -e HOME=/root user-<member> openclaw plugins doctor
docker exec -e HOME=/root user-<member> openclaw channels status --probe
```

Installer V6 tự đăng ký ba watchdog riêng cho Gateway, Zalo channel và resource
guard. Khi Zalo chưa onboarding hoặc chưa quét QR, trạng thái được ghi là
`not_configured` và không restart. Không
gửi tin nhắn thật trong healthcheck. Nếu bot nhận tin nhưng không trả lời,
kiểm tra lần lượt quyền sender, session route, model/provider và outbound Zalo.

## Bảo mật

Không đưa token Telegram, API key, mật khẩu SSH, Zalo session, cookie, QR,
pairing code hoặc private ID vào template. Backup production phải nằm trong
`/root/_Backups` với quyền root-only.
