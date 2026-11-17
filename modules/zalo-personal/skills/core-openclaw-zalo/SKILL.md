---
name: core-openclaw-zalo
description: Điều phối vận hành, đăng nhập, owner access, group, delivery và recovery cho OpenClaw Zalo.
---

Đây là skill chính (entry point). Dùng nó để chọn và điều phối các skill chuyên biệt bên dưới; không tạo workflow trùng lặp khi skill phụ đã có hướng dẫn chi tiết.

Khi owner nhắn qua Telegram yêu cầu QR đăng nhập Zalo, ưu tiên `openclaw-telegram-zalo-qr-delivery` trong thư mục skills của workspace hiện tại. Tự tạo và gửi ảnh QR trong đúng runtime; không mặc định yêu cầu owner mở dashboard hoặc nhập `connect zalouser`. Nếu thiếu quyền/công cụ, báo chính xác giới hạn đã kiểm tra, không tự cấp quyền hoặc công khai QR.

Skill liên quan: openclaw-zalo-reliability, openclaw-zalo-reliability-deploy, openclaw-zalo-no-response, openclaw-zalo-qr-login, openclaw-zalouser-onboarding-standard, openclaw-zalouser-owner-access, zalo-group-session-finder, zalo-group-file-delivery-recovery, zalo-reliable-task-delivery, zalo-separated-services

Giữ nguyên nguyên tắc an toàn của project và đọc AGENTS.md, Second AI Brain, checklist production trước khi thay đổi hệ thống.
