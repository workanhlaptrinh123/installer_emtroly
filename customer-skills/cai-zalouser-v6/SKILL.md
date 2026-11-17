---
name: cai-zalouser-v6
description: Cài trợ lý cá nhân Telegram và Zalo Personal cho khách bằng Antigravity, OpenClaw 2026.11.4 và đầy đủ manifest skill V6; không dùng bundle hoặc thao tác trên VPS khác.
---

# Cài Zalo Personal cho khách — V6

## Dữ liệu và nguồn

Dùng prompt riêng sinh từ form web: tên khách/trợ lý, Owner IDs, Telegram Group ID,
Base URL/model, module, QR Owner ID và mã HTTPS nhận token/API key một lần.
Không hỏi lại trường đã có hoặc in credential/mã nhận vào log/chat. Mẫu công khai
không chứa mã nhận hợp lệ; cần tạo yêu cầu riêng trên web trước khi cài thật.

Nguồn đầy đủ của V6:

- Manifest: `https://installer.emtroly.online/api/v6-skills/manifest`
- File: `https://installer.emtroly.online/api/v6-skills/<skill>/<file>`
- Template có 189 skill; website có snapshot riêng chưa đồng bộ với lần nâng này.
  Kiểm tra count, tập tên và SHA256 từng file của đúng snapshot; tải đủ mọi skill,
  không chỉ skill Zalo hoặc module được chọn. Mỗi file đặt tại
  `<instance>/workspace/skills/<skill>/<file>`. Tải song song tối đa 6 file, retry
  hữu hạn, không tải lại file có đúng hash. Không dùng bundle/archive native cũ.

Đặc biệt phải có toàn bộ folder `openclaw-zalo-text-delivery-guard`, bao gồm
`SKILL.md`, `agents/openai.yaml`, `assets/guard.mjs`, `assets/test_guard.mjs`,
`scripts/install.py` và `scripts/test_install.py`.

## Cài đặt trên đúng máy khách

1. Kiểm tra một lượt OS/instance/cổng. Dùng prompt local riêng và skill
   `tao-tro-ly-openclaw-windows-macos-linux` của V6. Phiên cài này pin
   `openclaw@2026.11.4`, override pin/đường dẫn legacy không đúng máy khách.
   Windows dùng user hiện tại; không mặc định yêu cầu khách mở PowerShell/Admin.
   Auto: instance trùng tên có backup trước nâng cấp; bản khác tên giữ nguyên.
   New: không ghi đè thư mục tồn tại. Không SSH/cài Docker hoặc sửa member khác.
2. Cài runtime riêng, validate config candidate theo schema 2026.11.4. Telegram
   nhận đúng token và provider API key từ handoff riêng. Chọn agent `main`, Owner
   IDs đúng form; chỉ nhóm Telegram được chỉ định không cần mention. Group được
   dùng công cụ theo quyền công bố trên form, không tự biến thành owner.
3. Cài official plugin `@openclaw/zalouser@2026.11.4`, kiểm tra core/plugin khớp
   version; không tự bỏ qua install policy/capability warning chưa rà soát. Dùng
   `openclaw-zalouser-onboarding-standard` nhưng không chạy helper
   Docker/Supervisor trên Windows. Giữ credential và Telegram đang khỏe.
4. Dùng `openclaw-telegram-zalo-qr-delivery`: owner đã `/start` bot của khách,
   tạo QR trên máy này và gửi qua chính bot đó tới QR Owner ID thuộc danh sách
   owner. QR là dữ liệu đăng nhập riêng tư, không đưa lên public web/CDN.
   Giữ lượt login trong khi khách quét/xác nhận; không tạo hai lượt cùng account.
5. Xác minh pairing và binding Zalo account vào `main`. Group Zalo mà tài khoản
   tham gia không cần mention/quyền công cụ theo form đã công bố. Telegram Group
   ID không phải ID Zalo. Chỉ cấp owner cho người được xác minh, không suy từ tên.

## Guard và kiểm chứng

`openclaw-zalo-text-delivery-guard` phải hiện diện và được CLI nhận diện.
Upstream runtime installer chỉ hỗ trợ Docker/Supervisor, kể cả core native đã
là 2026.11.4: không chạy installer đó trên Windows/macOS/native Linux. Báo rõ
`skill-installed/runtime-unsupported` nếu chưa có native adapter được kiểm thử.
Không dùng giới hạn này làm lý do dừng cài core/Telegram/Zalo.

Chỉ báo đăng nhập Zalo thành công sau pairing và channel probe của đúng account.
Kiểm tra version, config validate, đủ manifest/hash skill, gateway RPC/health và
channels probe. Báo riêng core, Telegram, Zalo, module và guard; chưa thử nhắn tin
thật thì không tuyên bố đã chứng minh trả lời. Retry lỗi tạm thời tối đa 3 lần mỗi
bước; không xóa config/database/lock hoặc cài lại toàn bộ để né lỗi. Chỉ hỏi khi
cần tương tác QR/OAuth/quyền OS hoặc có xung đột thật, không dừng xin xác nhận lại
form đã đầy đủ. Không hứa mọi máy đều luôn thành công.
