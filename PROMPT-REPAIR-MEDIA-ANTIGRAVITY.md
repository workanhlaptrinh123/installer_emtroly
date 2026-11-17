# Sửa gửi tệp Telegram/Zalo trên máy đang mở Antigravity

Đây là yêu cầu sửa instance hiện có, không cài mới và không nâng core.
Không SSH vào VPS, không sửa trợ lý khác và không gỡ OpenClaw.

Thông tin sự cố trên máy khách cần xác minh:
- Instance dự kiến: `C:\Users\Admin\.openclaw-member-cuong`
- Artifact cần giữ nguyên: `workspace\output\Ho_so_thanh_toan_Cuong_Hue_Thanh_Manh_HD85.docx`
- Nếu đường dẫn không tồn tại trên máy hiện tại, dừng đúng điểm và báo sai máy/instance; không tạo giả hợp đồng hoặc đoán số liệu.

Nguồn V6 và helper:
- Manifest: https://installer.emtroly.online/api/v6-skills/manifest
- File: https://installer.emtroly.online/api/v6-skills/<skill>/<file>
- Chính sách: reliable-media-delivery/references/installed-media-policy.md
- Helper: reliable-media-delivery/scripts/media_delivery.py
- Test offline: reliable-media-delivery/scripts/test_media_delivery.py

1. Xác định gateway/launcher/node/CLI/config/state/workspace thật của đúng instance cuong. Giữ token, model, owner, group policy, lịch sử và database. Không in secret hoặc nội dung hợp đồng.
2. Tải đầy đủ và kiểm tra SHA256 theo manifest các skill: reliable-media-delivery, openclaw-member-media-allowlist, openclaw-telegram-task-delivery; nếu Zalo đang bật thì thêm zalo-buffer-file-send, zalo-group-file-delivery-recovery và zalo-group-session-finder. File khách đã sửa riêng phải backup trước khi thay. Không chạy script Docker/Linux trên Windows.
3. Đọc lỗi gốc đã redacted từ tool/Gateway, phân loại: file/path/media read, tool policy, RPC auth/pairing/scope, cross-context, quyền Telegram group hoặc Zalo upload/receipt. Không gọi chung là “lỗi quyền kết nối” nếu chưa có bằng chứng.
4. Kiểm tra artifact tồn tại/đọc được/đúng DOCX. Dùng Python thật chạy test helper, install-policy vào đúng workspace/state và prepare file. Giữ nguyên bản gốc; sử dụng media path do helper trả về. Windows dùng argv/Path/JSON serializer, không ghép chuỗi escape.
5. Dùng CLI private với env/profile/config/state giống launcher. RPC/auth lỗi thì kiểm tra client đang gọi đúng cổng/instance và credential hiện có. Nếu có device pending, xác minh đúng thiết bị rồi thực hiện luồng duyệt hợp lệ theo CLI/schema. Không tắt auth/pairing, không mở cổng public, không cấp wildcard device, không lấy token của trợ lý khác.
6. Kiểm tra message/send-media tool thực sự được expose, policy agent/sender/group có cho messaging. Giữ full quyền cho các group theo chính sách hiện có; không biến lỗi media thành lý do khóa group wildcard. Giữ owner/QR/DM hiện có. Quyền thực thi OS không tự cấp thêm quyền Telegram hoặc scope Gateway.
7. Telegram: xác minh đúng bot/account/chat/thread từ phiên yêu cầu đã có, kiểm tra bot còn ở nhóm và có thể gửi document. Zalo: đúng account/session/group; nếu cross-context bị chặn thì điều phối về session Zalo tương ứng, không vô hiệu hóa bảo vệ cross-channel. Kiểm tra byte buffer, filename/MIME theo skill; không tạo listener/login thứ hai.
8. Trước retry hợp đồng, tra receipt/history để tránh gửi trùng. Khi đã xác minh đúng nhóm từ yêu cầu gốc và owner cho phép gửi, gửi chính artifact đó một lần; không tự gửi sang nhóm khác. Cần real media messageId và matching destination/thread; caption hoặc text receipt không đủ. Nếu chưa xác minh được nhóm/ủy quyền gửi, hỏi đúng một câu chọn nhóm; không đoán.
9. Thành công: lưu biên nhận private và báo filename + gửi tới đúng nhóm, không in credential hay nội dung tài liệu. Thất bại: giữ artifact, báo mã/lỗi gốc đã redacted và bước còn thiếu; timeout/mất receipt phải báo chưa xác nhận, không replay mù.
10. Ghi kết quả kiểm tra local vào acceptance.json: RPC, media tool, staging, Telegram/Zalo attachment delivery riêng. Chưa gửi thật thì pending_live_test, không nói đã sửa xong việc gửi file chỉ vì probe/dry-run/helper đạt.
