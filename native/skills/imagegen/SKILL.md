---
name: imagegen
description: Tạo và sửa ảnh bằng công cụ image_generate gốc OpenClaw, gọi trực tiếp API bằng khóa riêng của member.
---

# Tạo ảnh trực tiếp bằng API key

Dùng công cụ **`image_generate` gốc của OpenClaw**. Không dùng Codex `image_gen`, không tạo/chạy helper Python, curl hay SDK thay cho công cụ gốc.

- Model đã cấu hình: `openai/cx/gpt-image-2` (upstream nhận `cx/gpt-image-2`).
- Provider `models.providers.openai` trỏ cùng `baseUrl` và `apiKey`/SecretRef với `customer`, có `auth: "api-key"`; không dùng key OpenAI global, OAuth hoặc key của member khác.
- Mặc định tại `agents.defaults.mediaModels.image.primary`. Khi tạo/sửa ảnh, gọi `image_generate` với prompt, kích thước và ảnh tham chiếu nếu có; không cần exec.
- `image_generate` có thể trả task ID trước khi xong. Dùng status của công cụ/task, đợi kết quả; không nhận đã tạo ảnh chỉ từ task ID và không tạo task trùng sau timeout.
- Lỗi 401 cần kiểm tra provider ảnh đang dùng đúng endpoint/key customer, không xin key mới khi key customer chưa được kiểm tra. Không xuất key/config đầy đủ ra chat hoặc log. 429 là quota/rate limit, không phải thiếu công cụ.
- Không tự đổi model/provider, không thay ảnh AI bằng SVG/Pillow rồi nhận là ảnh đã tạo.
- Giữ đúng bot/account/chat khi gửi ảnh; kiểm tra artifact và receipt theo `reliable-media-delivery`. Ảnh tạo được chưa đồng nghĩa đã gửi.

## Cấu hình gốc khi cài

```json
{
  "models": {"providers": {"openai": {
    "baseUrl": "<cùng baseUrl của customer>",
    "apiKey": {"source": "file", "provider": "customer", "id": "value"},
    "auth": "api-key",
    "api": "openai-completions",
    "models": [{"id": "cx/gpt-image-2", "name": "Member image API"}]
  }}},
  "agents": {"defaults": {"mediaModels": {"image": {
    "primary": "openai/cx/gpt-image-2", "timeoutMs": 240000
  }}}}
}
```

Không ghi đè provider/model chat `customer`. Với config customer dùng kiểu key khác, tái sử dụng đúng giá trị/SecretRef của instance, không thay bằng key ví dụ.
