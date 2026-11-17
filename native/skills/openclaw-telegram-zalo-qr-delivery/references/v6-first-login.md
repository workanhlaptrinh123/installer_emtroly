# Chuẩn bị đăng nhập Zalo lần đầu trên V6

Chỉ dùng khi owner đã xác minh yêu cầu kết nối Zalo trong chính bot/runtime mới cài. Không yêu cầu nhập token Telegram hoặc API key lại; sử dụng credential riêng mà installer đã cấp cho runtime. Không tự thêm owner hay cấp quyền cho người đang nhắn.

## Chuẩn bị tối thiểu

1. Đọc trạng thái/config có chọn lọc để xác minh runtime, Telegram account, owner và agent. V6 mặc định dùng agent `main`, nhưng phải xác minh thực tế. Nếu có nhiều agent/Zalo account hoặc binding Zalo khác `main`, không chạy helper bên dưới; giữ nguyên cấu hình và xử lý theo account/binding thực đã xác minh.
2. Backup config trong thư mục private của runtime; trên VPS dùng `/root/_Backups`, còn Windows/macOS dùng backup directory riêng tư của runtime. Không ghi config vào log hoặc đưa backup ra web. Lấy phiên bản core từ CLI hiện tại, không hardcode phiên bản host khác.
3. Kiểm tra `openclaw plugins info zalouser --json`. Nếu plugin chưa được cài, dùng cú pháp đã được runtime hỗ trợ để cài `@openclaw/zalouser` **cùng phiên bản core**, ví dụ:

   ```bash
   openclaw plugins install --pin "@openclaw/zalouser@$CORE_VERSION"
   openclaw plugins enable zalouser
   openclaw plugins doctor
   ```

   Nếu package đúng phiên bản không có hoặc doctor báo không tương thích, dừng và báo nguyên nhân; không cài `latest`/force hoặc đổi core ngoài yêu cầu. Với Windows dùng đúng CLI entrypoint/instance environment của installer, không nhầm profile mặc định.
4. Với cấu hình V6 một agent `main`, chạy script nằm **cạnh skill trong workspace hiện tại**, không dùng đường dẫn host ngoài container:

   ```bash
   python3 "$SKILL_DIR/scripts/configure_zalo.py" --root "$OPENCLAW_STATE_DIR" --open-groups 0
   ```

   Trên Windows dùng Python/py theo môi trường đã cài và truyền `OPENCLAW_CLI_ENTRY` đúng instance nếu cần. Xác định `OPENCLAW_STATE_DIR` thật trước khi chạy; không đặt biến rỗng. Script tạo channel/account `default` và binding vào `main`, giữ credential/provider/Telegram; mặc định V6 đặt Zalo DM open và allowFrom=["*"] ở cả channel/account để ai cũng chat riêng không cần pairing; owner/elevated/QR recipient vẫn chỉ ID đã xác minh, không wildcard, validate candidate trước khi replace, và từ chối nhiều Zalo account hoặc binding không phải `main`.
5. Không mở group hoặc cấp công cụ công khai chỉ để đăng nhập (`--open-groups 0`). Nếu plugin mới cần reload Gateway, thông báo ngắn về gián đoạn và chỉ reload **Gateway của runtime đích** bằng đúng Supervisor/systemd/Windows service của installer; không khởi chạy daemon thứ hai, không restart host/member khác. Việc này dành cho setup plugin lần đầu, không phải cách ép sinh QR cho account đang hoạt động.
6. Xác minh config/plugin hợp lệ và Telegram của bot đích hoạt động lại, sau đó quay về `SKILL.md`: khởi tạo login, theo dõi ảnh và gửi ngay khi tiến trình đang chờ owner quét. Không tự chạy helper legacy có đồng bộ QR công khai.

## Khi bị chặn

Nếu thiếu quyền cài plugin/sửa config/reload hoặc không có môi trường CLI/Python, không né policy. Báo bước cụ thể bị chặn và phần quản trị cần chuẩn bị. Không nói dashboard là bắt buộc chỉ vì runtime chưa có plugin. Không tự nâng cấp core, thay session Zalo cũ hay đổi định tuyến hiện có.
