# PROMPT CÀI ZALOUSER ĐẦY ĐỦ V6 — OpenClaw 2026.11.4

Dùng trên máy khách đang mở Antigravity. Không dùng bundle/bootstrap cũ, không SSH vào VPS.
Nhập thông tin và secret trên web installer trước, sau đó sao chép prompt riêng của job
sang Antigravity. File này là mẫu không chứa secret thật; không chạy trực tiếp với placeholder.
Website đang dùng snapshot riêng; chưa dùng mẫu phiên bản này với manifest web
cho đến khi website được cập nhật và kiểm tra đồng bộ riêng.

## Mục tiêu

- Cài OpenClaw `2026.11.4` vào instance riêng của khách.
- Cài và enable plugin `@openclaw/zalouser@2026.11.4` đúng core.
- Cài đủ manifest skill V6 từ endpoint từng file, xác minh SHA256.
- Telegram của khách nhận QR Zalo qua đúng bot/Owner ID đã nhập.
- Bind Zalo vào agent `main`; đặt `dmPolicy=open`, `allowFrom=["*"]` ở channel và account để mọi người nhắn riêng không cần mã ghép nối. Group không cần mention; không tự cấp owner cho người nhắn tin.
- Giữ credential/state riêng, không ảnh hưởng VPS chính, member khác hoặc instance khác trên máy.

## Bộ skill Zalo bắt buộc

Prompt thật phải tải đủ manifest V6. Riêng luồng Zalo phải có tối thiểu:

- `core-openclaw-zalo`
- `openclaw-telegram-zalo-qr-delivery`
- `openclaw-zalo-reply-mention`
- `cap-full-quyen-telegram-openclaw`
- `openclaw-zalo-qr-login`
- `openclaw-zalouser-onboarding-standard`
- `openclaw-zalouser-owner-access`
- `openclaw-zalo-reliability`
- `openclaw-zalo-reliability-deploy`
- `openclaw-zalo-no-response`
- `recover-openclaw-member-gateway`
- `member-vps-resource-oom-guard`
- `zalo-auto-send-contact`
- `zalo-buffer-file-send`
- `zalo-reliable-task-delivery`
- `openclaw-zalo-text-delivery-guard`

Nguồn canonical của toàn bộ V6 là manifest và file endpoint do web cấp:

- Manifest: `https://installer.emtroly.online/api/v6-skills/manifest`
- File skill: `https://installer.emtroly.online/api/v6-skills/<skill>/<file>`
- Template này có `189` skill; phải kiểm tra count/hash của đúng snapshot, không dùng danh sách rút gọn.

## Câu lệnh skill mẫu cho Antigravity

```text
/tao-tro-ly-openclaw-windows-macos-linux
/openclaw-zalouser-onboarding-standard
/openclaw-telegram-zalo-qr-delivery
/openclaw-zalo-text-delivery-guard

Đọc prompt riêng do web sinh cho khách này. Dùng đúng dữ liệu form và secret handoff,
không hỏi lại. Cài OpenClaw 2026.11.4, tải đủ skill V6 từng file theo manifest/hash đã đồng bộ,
cài @openclaw/zalouser@2026.11.4, cấu hình Telegram trước, tạo và gửi QR qua đúng bot
khách tới QR Owner ID, chờ quét/pairing rồi bind Zalo vào main. Kiểm tra version, config,
skills, RPC và channel probe. Không chạy installer Docker/Supervisor guard trên Windows.
Không báo thành công chỉ vì đã gửi QR; phải xác minh pairing/channel. Nếu một bước lỗi,
retry tối đa 3 lần rồi báo đúng điểm dừng, không chạy lại hoặc xóa toàn bộ instance.
```

`openclaw-zalo-text-delivery-guard` được tải đầy đủ gồm `SKILL.md`, assets, scripts và
test. Runtime patch của skill upstream chỉ áp dụng Docker/Supervisor; native Windows chỉ
cài và ghi nhận skill, không chạy script Docker guard.
