---
name: 9router-image
description: Dùng image_generate gốc OpenClaw gọi 9Router bằng API key riêng của member.
---

# 9Router Image — Member API Key

Đọc skill `imagegen` trong cùng workspace và gọi công cụ `image_generate` gốc, không dùng helper/exec/curl.

Model `openai/cx/gpt-image-2` dùng provider OpenAI-compatible có `baseUrl` và API key/SecretRef giống provider `customer` của chính member, `auth=api-key`. OpenClaw gửi trực tiếp upstream model `cx/gpt-image-2` tới `/images/generations`; không gọi API OpenAI public bằng key 9Router, không dùng OAuth.

Khi lỗi 401, kiểm tra mapping endpoint/key trong provider ảnh, không yêu cầu key khác hoặc kết luận key customer hết hiệu lực khi chưa kiểm chứng. Không in key vào log/chat. Dùng task/status của image_generate và receipt đúng channel; không báo thành công từ task ID hoặc file path đơn thuần.
