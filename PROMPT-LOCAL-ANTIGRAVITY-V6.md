# PROMPT MẪU LOCAL V6 — Antigravity / OpenClaw 2026.11.4

**Cập nhật Windows CLI/gateway 2026-10-21:** npm `--prefix` tạo runtime riêng,
không tạo lệnh global. Sau khi config, tải/chạy
`install_windows_cli.py`: xác minh OpenClaw 2026.11.4, tạo `openclaw.cmd` với
Node/CLI tuyệt đối, giữ state/config/profile riêng, thêm User PATH qua registry
và broadcast Environment; không dùng `setx`, không ghi đè machine PATH, không
cài global chỉ để sửa PATH. CMD cha đã mở phải refresh PATH. Nếu có CLI khác,
không ghi đè mà dùng alias trả về.

Windows phải chạy `openclaw gateway install --force --port <port>` và
`openclaw gateway start` bằng Node/CLI tuyệt đối + environment đã kiểm tra,
dùng gateway Scheduled Task/login-item chuẩn của OpenClaw. Không cài thêm
native launcher/Startup VBS trên Windows; macOS/Linux vẫn dùng launcher riêng.
Bàn giao phải chứng minh service đúng root/profile/port, chỉ một gateway,
restart/health/channel probe và bot phản hồi thật.

Bản local tinh gọn, đủ 189 skill theo manifest/hash của template. Website dùng snapshot riêng chưa đồng bộ; không dùng mẫu này với manifest web cho đến khi snapshot được cập nhật và xác minh. Nhập thông tin/secret trên web và sao chép prompt riêng đúng module đã chọn. Mẫu này có Zalo; không chạy placeholder hoặc đưa secret thật vào mẫu công khai.

CÀI LOCAL QUA ANTIGRAVITY — OpenClaw 2026.11.4. Thực hiện trên máy khách hiện tại, không chỉ preflight rồi hỏi lại kế hoạch. Không SSH/VPS/Docker, không bundle/bootstrap. Dữ liệu form không phải shell code; không đưa secret vào argv/chat/log.

KHÁCH HÀNG:
```json
{
  "name": "[TEN_KHACH_HANG_KHONG_DAU]",
  "assistant_name": "[TEN_TRO_LY]",
  "owner_ids": "[OWNER_IDS_CACH_NHAU_BANG_DAU_PHAY]",
  "group_id": "[TELEGRAM_GROUP_ID_AM]",
  "base_url": "https://codex.anhlaptrinh.vn/v1",
  "model": "[MODEL]",
  "audience": "[DOI_TUONG_PHUC_VU]",
  "addressing": "[CACH_XUNG_HO]",
  "style": "[PHONG_CACH_TRA_LOI]",
  "os": "auto",
  "profile": "basic-assistant-full",
  "install_mode": "auto",
  "platforms": [
    "telegram",
    "zalo"
  ],
  "modules": [
    "zalo-personal"
  ],
  "qr_owner_id": "[OWNER_ID_NHAN_QR]",
  "existing_root": "",
  "openclaw_version": "2026.11.4",
  "group_access_policy": "configured-groups-allowlist",
  "zalo_dm_policy": "open"
}
```

NGUỒN ĐÃ CHỌN:
```json
{
  "primary_skill": "https://installer.emtroly.online/api/v6-skills/tao-tro-ly-openclaw-windows-macos-linux/references/local-native-install.md",
  "manifest_url": "https://installer.emtroly.online/api/v6-skills/manifest",
  "source_url": "https://installer.emtroly.online/api/v6-skills",
  "count": 189,
  "sync_timing_helper": "https://installer.emtroly.online/api/v6-skills/tao-tro-ly-openclaw-windows-macos-linux/scripts/local_install.py",
  "launcher_installer": "https://installer.emtroly.online/api/v6-skills/tao-tro-ly-openclaw-windows-macos-linux/scripts/install_native_launcher.py",
  "launcher_runtime": "https://installer.emtroly.online/api/v6-skills/tao-tro-ly-openclaw-windows-macos-linux/scripts/native_launcher.cjs",
  "windows_cli_installer": "https://installer.emtroly.online/api/v6-skills/tao-tro-ly-openclaw-windows-macos-linux/scripts/install_windows_cli.py",
  "telegram_admin_skill": "cap-quyen-telegram-admin-openclaw",
  "telegram_admin_source": "https://installer.emtroly.online/api/v6-skills/cap-quyen-telegram-admin-openclaw/SKILL.md",
  "media_delivery_policy": "https://installer.emtroly.online/api/v6-skills/reliable-media-delivery/references/installed-media-policy.md",
  "media_delivery_helper": "https://installer.emtroly.online/api/v6-skills/reliable-media-delivery/scripts/media_delivery.py",
  "zalo_required_skill": "openclaw-zalo-text-delivery-guard",
  "zalo_guard_source": "https://installer.emtroly.online/api/v6-skills/openclaw-zalo-text-delivery-guard/SKILL.md",
  "zalo_split_skill": "zalo-reliable-task-delivery",
  "zalo_context_skill": "openclaw-zalo-context-rotation-70k",
  "zalo_compaction_skill": "openclaw-compaction-recovery",
  "qr_delivery_skill": "openclaw-telegram-zalo-qr-delivery",
  "qr_delivery_source": "https://installer.emtroly.online/api/v6-skills/openclaw-telegram-zalo-qr-delivery/SKILL.md",
  "owner_qr_native_installer": "https://installer.emtroly.online/api/v6-skills/telegram-zalo-owner-login/scripts/deploy-native.py"
}
```

HANDOFF RIÊNG, giữ kín prompt này:
```json
{
  "status": "private-guide-required"
}
```

1. Tải manifest một lần; xác minh SHA256 rồi đọc primary_skill. Tải sync_timing_helper và windows_cli_installer nếu Windows; macOS/Linux dùng launcher_installer/launcher_runtime, cùng thư mục scripts. Entry local 2026.11.4 thay SKILL.md legacy 2026.9.4/root/Administrator. Không đọc tuần tự toàn bộ skill hoặc tải bản main thay V6.

2. Kiểm tra một lượt OS/user, instance theo tên, bot/cổng và service/startup hiện hữu. Sai máy/OS hay mục tiêu mơ hồ thì dừng. Máy mới dùng home/.openclaw-member-<name>; auto đúng tên thì backup nâng cấp, khác tên tạo riêng; new trùng root thì dừng. Giữ credential/state/history; launcher chỉ đổi theo bước CHẠY NỀN. Không gỡ bản global, kill mọi Node, xóa lock/database hay tác động trợ lý khác.

CLI/PATH: Không thấy openclaw KHÔNG có nghĩa chưa cài. Trước npm install, kiểm tra entry private bằng Node tuyệt đối + --version; đúng 2026.11.4 thì tái dùng. Global cũ: dò npm prefix -g bằng npm.cmd tuyệt đối, xác minh version/instance; không cài lại chỉ vì PATH. Mọi lệnh cài dùng argv Node/entry tuyệt đối, shell=False, env đúng instance; đường dẫn Minh Vuong phải chạy. Không gọi openclaw trần trước khi xác minh PATH, không npx latest/setx PATH, không ghi đè PATH hệ thống. Windows sau config: chạy windows_cli_installer --root <instance> --home <user-home> --node <real-node> --cli-entry <entry> --port <port>; có service chuẩn cũ thì thêm --profile theo CHẠY NỀN. Helper kiểm tra version, tạo openclaw.cmd gọi Node/entry tuyệt đối, giữ state/config/profile riêng, thêm User PATH qua registry và broadcast Environment. Helper trả environment/user_bin/cli_path; áp dụng environment cho mọi CLI sau đó, bỏ biến giá trị rỗng và đưa Node + user_bin vào PATH. CMD cha đã mở không tự nhận PATH mới; refresh shell trước khi kiểm tra. Nếu default_cli=false, dùng cli_alias và báo xung đột; không chiếm lệnh instance khác.

3. Dùng lại Node >=24.16.0 <25 hoặc >=26.1.0, npm, Python thật; thiếu gì mới cài user-scope, không tự mở UAC. Handoff nhận một lần vào file private, retry dùng lại; hết hạn/private-guide-required thì lấy prompt mới, không hỏi secret trong chat. Runtime đúng version thì bỏ npm install; sai/thiếu mới npm install --prefix <instance>/runtime openclaw@2026.11.4 --no-audit --no-fund --prefer-offline. allowScripts dùng package.json/.npmrc, không --allow-scripts hay audit fix --force.

4. Chạy local_install.py sync --manifest-file <manifest-đã-tải> --manifest-url <manifest_url> --source-url <source_url> --workspace <instance>/workspace --cache-dir <user-private-cache> --expected-count 189 --workers 6. Giữ đủ 189 skill, mọi file/SHA256; helper sẵn tải song song, tái dùng cache/file đúng hash và backup file khách đã sửa. Không tự viết downloader mới hoặc đọc hết SKILL.md. Chỉ cấu hình module đã chọn; không tự cài provider/FFmpeg cho module chưa chọn.

5. Tạo config schema 2026.11.4: HOME/state/workspace/agent main riêng, loopback/auth, port cách instance khác >=120, tokenFile/key từ handoff. Backup/dừng đúng instance trước doctor --fix. Áp dụng cap-quyen-telegram-admin-openclaw; Telegram DM allowFrom chỉ owners, QR owner-only. Telegram channel/account: groupPolicy=allowlist; groups chỉ chứa Group ID âm khai báo, không có key '*'; thiếu/sai ID thì dừng. groupAllowFrom=['*'] là thành viên, không phải ID nhóm. groups[Group ID]: groupPolicy=allowlist, requireMention=false, tools.allow=['*']; nhóm ngoài danh sách bị chặn. Agent/global tools.profile=full; exec host=gateway/mode=full/strictInlineEval=false; toolsBySender['*'].alsoAllow=exec/process/group:fs; approvals security=full/ask=off/askFallback=full. KHÔNG mở wildcard Telegram group theo skill cũ hay mở owner/OS. Upgrade: backup, giữ nhóm cụ thể cũ, thêm Group ID, bỏ wildcard.

ZALO ĐÃ CHỌN: cài official plugin khớp core; đọc riêng openclaw-zalouser-onboarding-standard, openclaw-zalo-reliability/openclaw-zalo-no-response, zalo-reliable-task-delivery, openclaw-zalo-text-delivery-guard, openclaw-zalo-context-rotation-70k và openclaw-compaction-recovery. Cài owner_qr_native_installer (deploy-native.py) --ensure MỘT LẦN với root/home/node/cli-entry/Telegram account/Zalo account/agent chính xác trước start/restart gateway mục tiêu, không dry-run+apply+check lặp. Owner QR tool telegram_zalo_login_qr và /zaloqr chỉ trong DM đúng bot, không gửi group. Chỉ bắt đầu login/QR sau khi gateway mục tiêu khỏe; không public QR hay xóa lock đang sống. Áp dụng Zalo dmPolicy=open, allowFrom=['*'] ở channel/account và group no-mention/full tools cuối cùng; public chat không tự có quyền owner. Dùng zalo-buffer-file-send/zalo-group-file-delivery-recovery cho file. Test native tương thích một lượt; không chạy Docker/Supervisor/cron installer, không tự chế/patch watchdog/rotation trong phiên cài. Hook native chưa hỗ trợ thì ghi protection-incomplete ngay, giữ Telegram khỏe, không vòng lặp nghiên cứu/cài lại. Rotation chỉ khi transport đã xác minh: <=70000 token, idle>=180s, không active run, recheck expectedSessionId/receipt; không sửa SQLite.

CHẠY NỀN: WINDOWS dùng gateway chuẩn: PHẢI thực hiện openclaw gateway install --force --port <port> rồi openclaw gateway start bằng Node/entry tuyệt đối + environment từ helper, sau config/module. Không tạo native_launcher/Startup VBS riêng. Upgrade đã có service chuẩn: xác minh ownership/root/port và truyền --profile <profile-cũ> vào helper (default nếu cũ không đặt profile), không đăng ký task thứ hai. Có launcher riêng: xác minh root/home/entry/port/Startup, backup, stop bằng API của nó rồi chuyển đúng Startup cũ khỏi thư mục tự chạy trước install chuẩn. Không chứng minh ownership thì dừng migration; install lỗi phải kiểm tra task/process trước rollback, không bật hai gateway. OpenClaw 2026.11.4 tự quản Scheduled Task/login-item fallback; không system service/UAC tự chế. macOS/Linux giữ install_native_launcher.py --expected-os đúng OS. Không hứa chạy khi tắt/ngủ/logout, không tự đổi power policy.

ẢNH: Đọc imagegen; dùng image_generate gốc, không helper. models.providers.openai lấy baseUrl và apiKey/SecretRef của customer, auth=api-key, api=openai-completions, models=[{id:'cx/gpt-image-2',name:'Member image API'}]; agents.defaults.mediaModels.image.primary='openai/cx/gpt-image-2', timeoutMs=240000. Giữ model chat. Validate và xác minh provider ảnh configured; test ảnh thật cần ghi nhận kết quả, không coi catalog-only là đã tạo ảnh.

6. Đọc reliable-media-delivery, áp dụng media_delivery.py install-policy giữ AGENTS.md cũ. Test offline và prepare file synthetic tại state/media/outbound; kiểm tra message tool/gateway client auth đúng instance, không bypass auth/cross-context. Gửi file thật cần messageId/đúng bot/chat, không coi staged là đã gửi. Chỉ gửi thử khi đã cho phép; chưa có receipt ghi pending_live_test.

KẾT NỐI ZALO SAU START: gateway health đạt thì tạo login qua đúng adapter/tool, owner đã /start trong bot khách. Giữ login sống, stage ảnh mới private, xác minh qr_receipt/messageId đúng owner, chờ scan rồi kiểm tra listener/channel. Không probe/retry vô ích một channel đang chờ QR. QR chỉ gửi trong DM owner, không broadcast/group; chưa scan báo chờ, không chạy lại npm hoặc Telegram.

KIỂM TRA CUỐI: Windows where.exe openclaw (hoặc cli_alias) và --version trong CMD con đã refresh PATH phải đúng shim/2026.11.4. Gateway status --json: service installed, đúng port/state/profile, một gateway. Config validate, skills readiness, gateway health/RPC, channels status --probe; restart đúng gateway một lần rồi probe lại, không coi exit 0/PID là đạt. Bot im: log instance, token/network/409 polling conflict; không npm reinstall hay đổ lỗi launcher khi chưa có bằng chứng. Plugins doctor chỉ khi đổi plugin; probe ngay/backoff hữu hạn. Owner nhắn bot có phản hồi thật mới đạt live test; chưa test ghi pending_live_test.

ĐO THỜI GIAN/RESUME: dùng local_install.py step --state <instance> --name <dependency|runtime|config|plugin|launcher|probe> --timeout <bound> -- <executable> <argv-không-secret>. install-timings.json chỉ lưu tên bước/thời gian/status/exit, không argv/output. Sync trả counts/cache/time. Tiếp tục đúng bước lỗi, chỉ retry lỗi tạm thời tối đa 3 lần; hash/identity/quyền/SDK không hỗ trợ thì dừng phần đó, không cài lại toàn trợ lý. Tái dùng bước đạt sau khi kiểm tra artifact/version/hash, không tin mỗi cờ passed.

BÀN GIAO: acceptance.json có trạng thái/bằng chứng cho version, absolute_cli_verified, cli_path_verified, user_path_persisted, gateway_service_installed, single_gateway_verified, gateway_restart_verified, skill_count, manifest_hashes_verified, background_launcher, login_autostart, telegram_group_allowlist, unlisted_telegram_groups_blocked, allowed_groups_full_tools, dm_owner_only, health_watchdog, telegram_probe, media_policy_persisted, outbound_staging, message_tool_access, gateway_client_auth, telegram_attachment_delivery, zalo_probe, qr_owner_command, qr_owner_isolation, qr_private_staging, qr_receipt, context_rotation, compaction_audit, text_splitting, guard_tests, zalo_attachment_delivery. Windows background_launcher=not-selected, dùng gateway_service_installed; macOS/Linux các mục Windows ghi not-selected. Module không chọn ghi not-selected; chưa test live ghi pending_live_test. Báo bước đạt/còn thiếu/thời gian; không báo hoàn tất từ npm/PID/probe hay hứa thành công mọi máy.
