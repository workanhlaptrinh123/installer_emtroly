<!-- member-media-delivery:v1:start -->
## Gửi tệp Telegram/Zalo — bắt buộc

- File đã tạo không đồng nghĩa đã gửi. Không gọi lỗi chung là “lỗi quyền kết nối” nếu chưa có mã/lỗi thực từ tool.
- Dùng đúng instance/config/workspace, bot/account và group/thread của yêu cầu hiện tại; không dùng CLI global hoặc token của instance khác.
- Xác minh file đọc được, đúng loại/kích thước. Dùng helper `skills/reliable-media-delivery/scripts/media_delivery.py prepare --state-dir <instance-state> --workspace <workspace> --file <file>` để chép vào media/outbound của CHÍNH instance. Helper chỉ chuẩn bị file, không gửi hoặc chứng minh kết nối.
- Trên Windows dùng argv/Path/JSON serializer cho đường dẫn, không ghép chuỗi backslash vào JSON/shell; không truyền đường dẫn Windows cho VPS/container.
- Kiểm tra message/send-media tool thực sự được expose và effective sender/agent/group policy cho phép messaging. Full exec không thay thế quyền message hoặc credential của Gateway.
- Nếu RPC unauthorized/pairing/scope lỗi: chẩn đoán bằng đúng config và credential local, không in token. Sửa client trỏ nhầm instance hoặc approve đúng device đã xác minh theo CLI/schema, không tắt auth/pairing, không tự duyệt mọi thiết bị và không mở gateway public. Restart riêng instance chỉ khi thực sự cần.
- Telegram: gửi document/media qua đúng bot/account, đúng chat/thread, kiểm tra quyền gửi document của bot trong nhóm. Bot admin, file tồn tại, dry-run và text probe không chứng minh gửi file thành công.
- Zalo: dùng session Zalo tương ứng; nếu tool chặn cross-context thì điều phối về đúng session, không tắt bảo vệ cross-channel toàn cục. Gửi target `group:<id>` đã xác minh, account hiện tại, filename và MIME; dùng `zalo-buffer-file-send` để kiểm tra bytes/buffer và outbound staging, không tạo Zalo listener thứ hai hoặc đăng nhập lại khi phiên đang khỏe.
- Mỗi tệp gửi một lần, một coordinator. Lưu receipt private theo request/file fingerprint: messageId không rỗng, đúng channel/account/destination/thread, với Zalo phải là media receipt. Không dùng receipt của text/caption để nhận là đã gửi attachment.
- Timeout/mất receipt là chưa xác nhận: tra receipt/lịch sử/trạng thái trước retry để tránh gửi trùng. Chỉ retry một lần khi chắc lần trước chưa gửi và nguyên nhân đã sửa. Không replay queue hoặc xóa database/credential để né lỗi.
- Khi gửi thành công bằng tool, ghi receipt và kết thúc `NO_REPLY`; khi lỗi, giữ artifact và báo đúng bước/mã lỗi đã redacted. Không chỉ đưa đường dẫn local cho khách thay cho việc gửi file, không công khai file/QR lên web.
- Nghiệm thu cài đặt phải phân biệt offline file staging, Gateway RPC, channel probe và attachment delivery thật. Attachment delivery chỉ đạt khi có biên nhận từ lần gửi thử được owner cho phép tới đúng nhóm. Chưa có lần gửi thật thì ghi `pending_live_test`, không giả là đã xác minh.
<!-- member-media-delivery:v1:end -->
