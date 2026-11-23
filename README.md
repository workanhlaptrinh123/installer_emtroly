# installer_emtroly

## Cross-Platform Installers (Windows, macOS & Linux)

Official GitHub Releases publish synchronized `emtroly` installers for all three desktop/server platforms:

- **Windows x64**:
  - **Immutable Direct-Click Setup (`EmTroLy-Setup.exe` + `EmTroLy-Setup.exe.sha256`)**: Fixed-hash lightweight GUI bootstrapper (`releases/latest/download/EmTroLy-Setup.exe`) that verifies `emtroly.exe.sha256`, downloads the latest `emtroly.exe` without browser Mark-of-the-Web, and launches the full installer UI directly. Because `EmTroLy-Setup.exe` keeps an identical SHA-256 across all future releases, Microsoft SmartScreen reputation submission is required only once.
  - **Full Standalone Offline/Bundled Installer (`emtroly.exe` + `emtroly.exe.sha256`)**
  - **1-Line SmartScreen-Free Windows PowerShell Launcher** (auto-verifies SHA-256 and opens `emtroly.exe` without browser Mark-of-the-Web SmartScreen prompt):
    ```powershell
    irm https://raw.githubusercontent.com/workanhlaptrinh123/installer_emtroly/main/install-windows.ps1 | iex
    ```
  - *(If launching `emtroly.exe` directly from browser Downloads before Authenticode EV/Azure signing secrets are configured, click **More info** → **Run anyway** once; subsequent launches via the Desktop shortcut `Em Tro Ly - Anh Lap Trinh` never prompt).*
- **macOS Apple Silicon (M1/M2/M3/M4)**: `emtroly-macos-arm64.zip` (+ `emtroly-macos-arm64.zip.sha256`, containing `EmTroLy.app`)
- **macOS Intel (x64)**: `emtroly-macos-x64.zip` (+ `emtroly-macos-x64.zip.sha256`, containing `EmTroLy.app`)
- **Linux Ubuntu / Debian (x64)**: `emtroly-linux-x64.deb` (+ `emtroly-linux-x64.deb.sha256`) and portable `emtroly-linux-x64.tar.gz` (+ `emtroly-linux-x64.tar.gz.sha256`)
- **Headless Terminal Installers (macOS & Ubuntu VPS)**:
  - Ubuntu / Linux: `./install-ubuntu.sh --check` then `source install-ubuntu.sh`
  - macOS Terminal: `./install-macos.sh --check` then `source install-macos.sh`

All platforms share the same priority architecture: **Codex CLI is always installed and configured first**, followed by **Antigravity IDE & Codex Extension** setup, and then **OpenClaw + Gateway + Zalo (`/zaloqr`, `/zalostatus`)** with automatic **Codex CLI Auto-Heal** if any technical error occurs during installation. See `unix-installer/README.md` for macOS and Linux details.

## Native image API key — 2026-10-23

Image generation uses OpenClaw's native `image_generate` tool, not a custom helper.
`models.providers.openai` explicitly uses the same base URL and API-key SecretRef
as the member's `customer` provider, with `auth: "api-key"`. The default image
model is `agents.defaults.mediaModels.image.primary: "openai/cx/gpt-image-2"`;
the upstream API receives model `cx/gpt-image-2`. Chat models remain unchanged.

`configure.py`, the native Windows installer and the web local-install prompt
apply this binding. The image module's skill overrides name the native
`image_generate` tool and are republished to the native skill catalog/bundle.
The Docker installer copies these two instructions after Golden-image startup,
restarts only its Gateway and checks that the native provider is configured and
selected. This provider check is not proof of image generation or delivery.
An explicitly authorized live test uses `openclaw infer image generate` directly;
it may incur image-generation charges. No Python/curl image helper is installed.

## Current installation flow — 2026-11-20

### Public Zalo chat default — 2026-10-16

Installer releases use the calendar format `YYYY.MM.DD`; the current installer
release is `2026.11.18`. The bundled OpenClaw runtime remains tracked separately
as `2026.11.4` in `MANIFEST.txt`.

New Zalo onboarding sets `dmPolicy=open` and includes `*` in `allowFrom` at
both channel and account level. After QR login and a healthy connection, anyone
can DM without pairing; groups remain open without mention. Owner commands,
elevated owners and Telegram QR recipients stay explicitly verified, never wildcard.
This is broad public admission to an assistant with full tools: share only with
trusted users/groups. Publishing this default does not modify existing members.

### Attachment delivery — 2026-10-16

New VPS workspaces persist a managed attachment-delivery policy in `AGENTS.md`
and have a private outbound directory. Local Antigravity prompts require the same
cross-platform staging helper, offline tests, exact instance Gateway auth and
per-channel attachment receipts. File staging or text probes are not live file delivery.
Existing Windows instances can use `PROMPT-REPAIR-MEDIA-ANTIGRAVITY.md` without
reinstalling. No remote Windows repair or real customer delivery is claimed by
publishing this installer update.

- New VPS members use Golden image `member-vps-golden:20261116` with OpenClaw `2026.11.4`; existing members are not upgraded or restarted by publishing this release.
- Local Windows users can use the standalone `.exe` wizard in this release. The separately deployed web/Antigravity installer remains a different flow and was not updated by this release.
- This template contains 189 skills. The separate web installer has its own release snapshot; do not assume its manifest or prompt uses this template until separately updated and verified.
- `openclaw-zalo-text-delivery-guard` has passed offline tests against the `2026.11.4` Docker plugin. A real Zalo account has not been tested; the Docker/Supervisor installer is not a native Windows/macOS installer.
- The rebuilt native bundle and standalone `.exe` are release artifacts. Other historical web snapshots and bootstrap references must not be assumed to be updated.
- The Telegram module includes `cap-full-quyen-telegram-openclaw` and its three skill dependencies. The bundled orchestration helper targets a host-managed Docker member, not a native local install; use it only for explicitly verified owners and targets.
- The Zalo module includes `openclaw-telegram-zalo-qr-delivery`; the optional mention patch and other advanced Zalo checks are deferred so the core install reaches `/zaloqr` faster. Live mention rendering remains a separate follow-up test.
- Local prompts require a per-instance background launcher with restart backoff and login autostart. User-scope Windows starts after the user signs in; it cannot answer while the computer is shut down or asleep. Verify the launcher and RPC before claiming background operation.
- Zalo QR delivery requires the customer's bot, an authorized owner DM, allowed media tools and a real message receipt. If Telegram blocks the DM, ask the owner to send `/start` to that exact bot; bot admin rights do not override Telegram's DM restrictions.
- New VPS installs with Zalo register the member watchdog and enable the Zalo 70k context-rotation job after a verified gateway/database preflight. Long-text delivery and compaction remain receipt- and schema-checked; native Windows/macOS never runs the Linux/Docker rotation installer.
- The Windows wizard permits Full Exec for every member of the explicitly selected Telegram group. DMs remain Owner-ID restricted; add only trusted people to that group.

## Local Windows web flow — 2026-10-13

New web requests collect Telegram token, AI API key, optional secrets and module
credentials before generating the Antigravity guide. A private one-use code
retrieves the credentials over HTTPS after archive verification; the guide is
not public data and expires after 60 minutes. Raw secrets are not embedded in
the guide. Additional credentials are saved under the instance with user ACLs;
OAuth/QR and provider-specific activation may still need user interaction.

`bootstrap-native.ps1 -UserInstall` creates a per-user Windows assistant without
requiring the operator to open PowerShell or elevate for the core fresh install.
Antigravity executes the script with its own local tools. The gateway runs as a
hidden user process and is launched from the user's Startup folder on login,
not as an Administrator Scheduled Task or a whole-machine service. Existing
legacy service upgrades still use their verified backup/elevation workflow.
An existing user-mode instance is not overwritten by the fresh installer.
Company policies or blocked dependencies can still require intervention.
Native Windows lifecycle and full Telegram/Zalo messaging have not been tested
on a real Windows customer machine from this VPS; script parsing, mocked
process isolation and private-secret API/browser tests do not prove end-to-end
success. Main VPS/member runtime and Golden artifacts are not changed by this
local update.

### Standalone Windows `.exe` installer — 2026-11-16

Artifact: `emtroly.exe` with the adjacent `emtroly.exe.sha256`
file. Double-clicking the executable opens a Windows Forms wizard. The wizard
asks for assistant name, provider HTTPS URL, model, Telegram owner
IDs, negative Telegram Group ID, bot token, provider API key, optional profile
text, and explicit Full Exec confirmation. Zalo QR setup is required.
The OpenClaw instance is created at `%USERPROFILE%\openclaw`; an existing
directory is never overwritten.

The installer runs in user scope and does not require Docker or Administrator
for a fresh instance. It requires Windows PowerShell 5.1, Windows x64,
Internet access, and permission to install user dependencies. Before creating
the instance it checks the provider `/models` endpoint and Telegram `getMe`,
then prioritizes installing Codex CLI first, followed by Antigravity IDE and
the Codex Extension on Antigravity (so Codex CLI is ready from the start to
automatically diagnose and repair any subsequent installation errors), and then
installs the runtime dependencies, OpenClaw, and Zalo. It checks OpenClaw config, the selected skill catalog, Full Exec
approval state, Gateway RPC health, and registration of `/zaloqr` and
`/zalostatus` before showing completion. If Antigravity/Codex still needs a
follow-up retry after OpenClaw finishes, the bot remains running; choose
**Thử lại bước Codex** in the wizard, or reopen the EXE and
enter the provider API key to retry. No Telegram token or QR scan is needed
for this retry. Only a completed bot setup can create the pending editor job.
The pending record contains a job ID and model, no credentials. Existing
installations from older releases have no such record. Credentials are passed through a
short-lived ACL-protected file, never as command-line values, and are removed
after the runner reads them. Runtime credential files remain protected inside
the user's instance because the bot needs them after installation.

For missing or unsupported tools the Windows installer downloads a private
Node.js 24.21.0 toolchain (including npm) and Python 3.13.16, and downloads
FFmpeg 9.0.2 when absent. Node and FFmpeg archives are checked against SHA-256;
the Python installer is checked for a valid Python Software Foundation
signature. Downloads require Internet access and sufficient disk space; the
installer does not require winget for these dependencies. Existing suitable
tools are reused without uninstalling other OpenClaw instances. A failed
partial instance is deliberately left in place and must not be overwritten.

After a successful user-scope installation, the installer creates a verified
`openclaw.cmd` shim in the current user's `AppData\Local\OpenClaw\bin` and
persists that directory in the user's PATH without replacing the machine PATH.
Open a new PowerShell window after installation, then `openclaw status` and
other CLI arguments are passed to the selected private runtime. If another
unrelated `openclaw` command already owns the generic name, the installer
preserves it and reports a conflict instead of claiming full success.
The selected command and path are also recorded in the instance's
`windows-cli.json`. Existing terminals must be reopened to pick up the User
PATH change; an existing installation is not automatically modified.

The Windows installer uses the smaller `installer-basic` OpenClaw profile:
Telegram Full Exec, Zalo QR, image generation and basic Word/Excel/PowerPoint
document workflows. Advanced Zalo, watchdog, research, video, Drive and website
modules are left out of this first local install and can be added later from the
module catalog. Antigravity IDE and the private Codex Extension remain part of
the installer flow described below.

The Windows installer additionally installs Antigravity IDE
2.7.0 and Codex extension 26.51111.21308 using pinned downloads and SHA-256.
It verifies Google's Authenticode signature before running the IDE installer. Antigravity user data, the
extension directory, and `CODEX_HOME` are isolated under
`%LOCALAPPDATA%\EmTroLy`. A dedicated desktop shortcut starts the editor with
those paths; other Codex, ChatGPT and Antigravity installations are not
configured. The same provider API key is stored in the private Codex home and
used by OpenClaw; the Telegram bot token remains separate. The installer
reports the assistant ready after OpenClaw, Zalo, `/zaloqr`, `/zalostatus`,
image generation and the basic DOCX/Excel/PowerPoint document skills are
installed and checked. Antigravity/Codex is an optional later step and does
not block the basic assistant result.

Selecting “Máy đã có Antigravity IDE” skips the entire IDE and Codex step.
Setup does not search for an executable, prompt for a file, change the editor
or configure a Codex key. OpenClaw, PATH and the Telegram Zalo commands are
still installed and verified. Leave it unchecked for the complete installation.
When installing a new IDE, a stale uninstall registry entry is not treated as proof of an existing
application if its recorded paths no longer contain an Antigravity executable.
Residual installation folders are preserved and a separate installation path
is chosen. Ambiguous registry entries still require manual inspection.

Every push to `main` runs tests and creates a Windows installer artifact kept
for seven days. Pushing a `vYYYY.MM.DD` tag (or `vYYYY.MM.DD.N` for a same-day fix) runs the checks again and publishes
the installer and checksums as a GitHub Release; a `main` push alone does not
publish a Release.

The Zalo installer checks whether the matching plugin is already enabled
before requesting another enable operation. Native CLI stderr is captured
separately; only an allowlisted diagnostic code is shown on failure. For an
existing partial installation, copy `zalo/diagnose-zalo-windows.ps1` to that
Windows machine and run it in PowerShell as the same Windows user with
`-Member <member-name>`. It displays only restricted status codes and does not
overwrite the instance or print credentials. The diagnostic does not resume
installation or verify actual Telegram/Zalo messaging.

The wizard requires Zalo and a Full Exec confirmation. It installs Zalo Personal,
the owner-only QR plugin, image generation and the basic Office document skills
for DOCX, Excel and PowerPoint workflows. Success means the Gateway is healthy,
both `/zaloqr` and `/zalostatus` are registered and the Telegram command menu
confirms both commands. Advanced Zalo checks and mention handling are deferred
to a later maintenance step so they do not slow the core installation. This is
the final step: the wizard reports success immediately, without waiting for a
message or QR scan.
The installer does not send a QR during installation: a configured
Telegram owner opens the bot's private chat, sends `/start`, and then requests
`/zaloqr`; after scanning, `/zalostatus` reports Zalo status. Native skill
commands are kept out of the limited Telegram menu so the two Zalo commands
cannot be pushed out by a large skill catalog. Every Telegram Owner ID entered in
the wizard is synchronized into the owner policy and receives Full Exec. The
wizard, runner, and user-startup Gateway launcher use hidden Windows processes,
so no black terminal window is required. Zalo access defaults to an allowlist;
this installer does not provide a Telegram command to approve Zalo IDs or grant
them Full Exec. Actual Windows installation, Telegram receipt, Zalo QR scan and
native mention rendering require separate live verification.

Before installation the wizard requires explicit confirmation of Full Exec and
Zalo. The configured Telegram group admits its members to Full Exec: these users
could request local commands or read, change or delete files. Only use a trusted
group. The installer uses its user-startup gateway launcher; the internal
`gateway install` shim does not run the upstream `gateway install --force`.
The final installer checks every entered owner's Telegram allowlists, approver
and approval targets, the agent binding and the Full Exec policy before reporting
success; these config checks do not replace a live test.

V6 inherits the clean-install and fast Golden image workflow from V5. It adds a
versioned module catalog, a default complete assistant profile and optional
member modules. Customer history, runtime databases, OpenClaw state, Telegram
state, logs and credentials remain excluded from the release. Run
`bash verify-release-clean.sh` before publishing or using a future release.

Golden image OpenClaw mới, kế thừa baseline môi trường V2 đã làm sạch cho cài
member mới. Bản release không chứa cấu hình, token, session, lịch sử, database
hoặc dữ liệu runtime của bất kỳ member nào.

## Thành phần mặc định

- Từ cập nhật 2026-10-09, profile `basic-assistant-full` và module `zalo-personal` cài sẵn skill `openclaw-telegram-zalo-qr-delivery` vào workspace, trên Docker và native bundle. Khi owner nhắn “Gửi anh QR đăng nhập Zalo”, bot được hướng dẫn tự tạo QR và gửi ảnh trực tiếp vào Telegram riêng; owner chỉ quét/xác nhận trên điện thoại, không mặc định phải mở dashboard nhập `connect zalouser`.
- Luồng QR yêu cầu plugin Zalo đã được cài/enable và bot có quyền thực thi login, đọc/gửi media; không tự mở rộng quyền hoặc công khai QR. Cập nhật template không tự đăng nhập và không rollout lên member đang chạy. Kiểm tra bằng `openclaw skills --agent main info openclaw-telegram-zalo-qr-delivery` trong runtime mới; chỉ báo gửi QR/đăng nhập thành công sau biên nhận/probe thực tế.

- Image `member-vps-golden:20261116`, dựa trên `vps-user-env:latest`.
- OpenClaw `2026.11.4` được đóng sẵn trong image và native installer.
- Module `zalo-personal` có guard đã thử offline với core/plugin `2026.11.4`; chưa kiểm thử tài khoản Zalo thật. Native Windows/macOS không chạy script Docker/Supervisor guard.
- Skill mention có patch tham khảo đã test offline với plugin `2026.11.4` nguyên bản. Docker/Supervisor không tự áp dụng patch vì nó xung đột text-delivery guard; native Windows `.exe` chỉ áp dụng patch sau kiểm tra đúng hash plugin và test offline. Live mention vẫn cần owner kiểm tra thật.
- Dữ liệu từng member được lưu ngoài release tại `/root/Apps/member_vps/docker-users/data/<member>`; template V5 không chứa customer state.
- V5 không mang theo lịch sử mẫu ANVI hoặc `conversations.db`; các thư mục runtime chỉ giữ `.gitkeep` khi cần giữ cấu trúc.
- Mỗi member có hai thư mục persistent: `root` được mount vào `/root`, `home` được mount vào `/home/<member>`.
- Installer bung `v2-derived-root-template.tar.gz` và `v2-derived-home-template.tar.gz` vào hai thư mục persistent để giữ đủ baseline V2.
- Ứng dụng và cấu hình riêng của Nhà máy sản xuất video đã được loại khỏi baseline V5.
- VPS và luồng local Antigravity hiện tại: Telegram dùng groupPolicy=allowlist và groups chỉ chứa Group ID đã khai báo, không có wildcard. Mọi thành viên trong nhóm được phép có full tools/file/exec/process, không cần mention; nhóm ngoài allowlist bị chặn dù đã thêm bot. Telegram DM vẫn owner-only, Zalo giữ chính sách riêng. Script bootstrap Windows legacy bên dưới chỉ giữ để tham khảo/rollback, không phải luồng cài local hiện tại; script cũng không được fallback sang wildcard khi thiếu Group ID.
- Trước khi bàn giao bot cho group, bắt buộc vào BotFather → `/setprivacy` → chọn bot → `Disable`; đây là quyền do Telegram quản lý, không có Bot API/OpenClaw nào tự bật thay được.
- Bộ đọc tài liệu hỗ trợ Word `.doc/.docx/.docm`, Excel `.xls/.xlsx` và PowerPoint `.ppt/.pptx`; V5 cài `antiword`, `catdoc`, `xls2csv` và `catppt` cho định dạng Office cũ.
- OpenClaw, Node, FFmpeg và Supervisor từ base image.
- Telegram/OpenClaw được cấu hình riêng cho từng khách.
- Profile `basic-assistant-full` được nạp khi container khởi động. Profile này
  gồm các module nền tảng đã đóng sẵn trong image, không cần tải dependency khi
  tạo member.
- Module nâng cao được phát hành riêng trong cùng catalog và chỉ được bật khi
  member cần; chọn bằng `profile` hoặc `modules` trong settings riêng của
  member.
- PDF scan được hỗ trợ OCR tiếng Việt/Anh bằng Tesseract; bot phải OCR và đối chiếu theo số trang trước khi kết luận nội dung pháp lý.
- API key lưu trong file mode `600` và chỉ được export vào tiến trình gateway; không ghi giá trị thật vào `openclaw.json`.
- Container dùng `--restart unless-stopped`, nên không cần mở Docker Desktop thủ công sau khi máy khởi động nếu Docker Desktop đã bật auto-start.

## Cài member mới

### Native Windows (không Docker)

Ưu tiên bộ cài `.exe` ở mục trên cho máy Windows x64 mới. Luồng Antigravity/web là phương án riêng: snapshot website chưa được đồng bộ và phải kiểm tra phiên bản trước khi sử dụng. Ví dụ dưới đây dành cho người vận hành chạy script native trực tiếp, không phải trình cài đồ họa.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-native-windows.ps1 -Name member01 -OwnerIds '123456789,987654321' `
  -GroupId '-1001234567890' -BaseUrl 'https://codex.anhlaptrinh.vn/v1' -Model 'gpt-6.1-sol' -DryRun
```

Bỏ `-DryRun` để cài thật. Script hỏi Bot Token/API key bằng ô nhập bảo mật và không in chúng ra màn hình.

### Cài bằng một link

Sau khi upload `native-full-bundle.tar.gz` lên GitHub Release/CDN, khách không cần nhận file thủ công. Gửi `bootstrap-native.ps1` hoặc lệnh bootstrap kèm URL archive và SHA256 của đúng phiên bản. Bootstrap tải, kiểm tra checksum, giải nén tạm rồi mới chạy installer; không đặt secret vào URL.

Bootstrap dùng chung bundle cho cả ba hệ điều hành:

- Windows: `bootstrap-native.ps1` → Windows daemon.
- macOS: `bootstrap-native.sh` → launchd/local gateway, runtime `/var/root/.openclaw`.
- Linux: `bootstrap-native.sh` → systemd/local gateway, runtime `/root/.openclaw`.

Trên macOS/Linux phải chạy bằng `root` hoặc `sudo -H`; trên Windows phải chạy PowerShell Administrator. Mỗi launcher tự cài dependency nền tảng tương ứng, cài profile core/module đã chọn, áp dụng owner/approval/Full Exec, validate và kiểm tra skill. Có thể dùng `--full-bundle` hoặc `-FullBundle` để đồng bộ toàn bộ skill trong native manifest; bộ cài vẫn chỉ kích hoạt module đã chọn.

Bộ native đầy đủ gồm `native-full-bundle.tar.gz`. Khi gửi cho khách, giải nén cùng thư mục với script; bộ này chứa 189 skill đã làm sạch và catalog module. Installer mặc định chỉ cài profile/module được chọn; full bundle vẫn giữ làm phương án recovery/compatibility. Cả hai chế độ đều áp dụng owner policy/approval, cấu hình Full Exec và chạy `openclaw skills check` trước khi restart gateway.

Native Windows là bộ cài cho máy khách không có Docker. Script tự chuẩn bị Node.js 24.21.0, Python 3.13.16 và FFmpeg 9.0.2 khi thiếu hoặc không đạt kiểm tra, không phụ thuộc winget; giữ đủ owner allowlist, group allowlist và Full Exec `gateway/full` (OpenClaw mới biểu diễn quyền tương đương `security=full`, `ask=off` bằng `mode=full`); gateway vẫn chỉ bind loopback. Golden Docker vẫn giữ cho VPS/phát triển; hai môi trường không dùng chung runtime hoặc credential.

### Windows/Docker Desktop

Dùng `install-member-local.ps1`. Image Golden đã chứa module; script chỉ import image một lần, bơm settings riêng và khởi động container. Không giải nén archive member cũ.

```powershell
.\install-member-local.ps1 -Name member01 -TelegramToken $tg -ProviderApiKey $key `
  -BaseUrl 'https://codex.anhlaptrinh.vn/v1' -Model 'gpt-6.1-sol' `
  -OwnerIds '123456789,987654321' -GroupId '-1001234567890'
```

Chạy thử trước bằng cách thêm `-DryRun`.

### Bắt buộc sau khi tạo bot Telegram

Thực hiện một lần cho mỗi bot mới:

1. Mở cuộc trò chuyện với `@BotFather`.
2. Gửi `/setprivacy`.
3. Chọn đúng bot member vừa tạo.
4. Chọn `Disable`.
5. Thêm bot vào group và cấp quyền đọc tin nhắn nếu Telegram yêu cầu.
6. Kiểm tra bằng `openclaw channels status --probe`; trạng thái cần có `connected`, `works` và `audit ok`.

OpenClaw chỉ cho phép các Telegram group thuộc allowlist đã khai báo, nhưng không thể thay đổi Privacy Mode của BotFather bằng token bot. Nếu bước này chưa hoàn tất, Telegram sẽ không chuyển phần lớn tin nhắn group không mention cho bot.

1. Copy `settings.example.json` thành một file riêng bên ngoài release, ví dụ `customer.json`.
2. Điền `member`, Telegram token, owner IDs, provider base URL/API key/model.
3. Chạy dry-run:

```bash
bash install.sh /path/customer.json dry-run
```

4. Cài thật:

```bash
bash install.sh /path/customer.json
```

Không đưa file settings thật vào Git, archive, Docker image hoặc chat log.

## Module V6

Liệt kê module trong một member:

```bash
docker exec user-MEMBER member-module list
```

Kiểm tra profile/module trước khi cài:

```bash
docker exec user-MEMBER member-module validate
```

Settings riêng có thể chọn profile và thêm module:

```json
{
  "profile": "zalo",
  "modules": ["google-drive-sync"]
}
```

Profile mặc định là `basic-assistant-full`. Module `zalo-personal` được cài mặc
định trên Docker/Linux và sau khi tạo user sẽ tự đăng ký kiểm tra Zalo không
phản hồi, Shared Watchdog Center, Gateway/Supervisor recovery và Resource/OOM
Guard. Khi Zalo chưa onboarding, chưa quét QR hoặc đang pairing, watchdog ghi
`not_configured` và không restart. Bộ kiểm tra chỉ tự phục hồi khi channel đã
được cấu hình nhưng thật sự unhealthy; không gửi tin nhắn thật và không đụng
credential, QR, cookie hoặc session.
Các profile có sẵn gồm `social`, `zalo`, `video` và `business`. Zalo vẫn cần
QR/onboarding và credential riêng; không đặt secret trong module hoặc image.
Metadata cho phép `zalo-personal` trên Docker/Linux/Windows. Windows native có
`zalo/onboard-zalouser-windows.ps1`: cài plugin đúng phiên bản core, cấu hình
account/binding và cài lệnh `/zaloqr` trước lần khởi động Gateway đầu tiên; owner
tự yêu cầu QR qua Telegram sau khi cài. Luồng cài nhanh không dừng hoặc chờ
Gateway để đăng nhập Zalo. Đây là luồng đã triển khai trong source, không
phải chứng nhận đã kiểm thử end-to-end trên mọi máy Windows. Phải quét/pairing,
probe và test nhắn tin thật trước khi báo hoàn tất. Zalo dùng danh sách cho phép;
không dùng Group ID Telegram làm ID Zalo
và không tự cấp quyền owner Zalo sau khi quét QR.

### Native local module manager

V6 native local now includes a cross-platform module manager. A new local
installation installs the selected core profile by default and stores the
catalog and clean skill payload under the member's OpenClaw home. Use
`--full-bundle` when the whole native bundle is intentionally required for
recovery or compatibility.

After an existing native installation receives the manager, modules can be
added directly on that machine without Docker:

```bash
bash /path/to/native/install-module-manager-unix.sh
member-module-native validate --module zalo-personal
member-module-native install --module zalo-personal
member-module-native list
```

On Windows, run PowerShell as Administrator:

```powershell
.\native\install-module-manager-windows.ps1
& "$env:USERPROFILE\.openclaw\module-manager.ps1" -Command validate -Module zalo-personal
& "$env:USERPROFILE\.openclaw\module-manager.ps1" -Command install -Module zalo-personal
```

The native manager keeps `modules.json`, `module-state/`, a catalog and a
clean cached skill source under the local OpenClaw home. It validates platform,
dependencies and payloads before install, then attempts a Gateway restart after
an install. Modules that require external credentials still need separate
onboarding after installation.

## Thêm module cho các lần cài sau

Module chỉ được promote khi đã làm sạch secret, session và dữ liệu khách:

```bash
bash docker/promote-module.sh \
  --container user-MEMBER \
  --id ten-module \
  --source /root/Apps/ten-module
```

Sau đó build lại Golden:

```bash
bash build-golden.sh 20261005
```

Bản build mới giữ module nền trong profile `basic-assistant-full`; module nâng cao
chỉ được cài cho member có trong settings/profile tương ứng. Member cũ không tự
đổi vì dữ liệu của họ nằm trong volume riêng; muốn nâng cấp phải dùng quy trình
upgrade có kiểm soát.

## Module format

```text
modules/ten-module/
├── module.json
├── skills/       # copy vào /root/.openclaw/workspace/skills/
├── apps/         # copy vào /root/Apps/
└── supervisor/   # tùy chọn, copy supervisor .conf
```

`module.json` bắt buộc có `id` và `version`. Không đặt token, API key, cookie, session, credential, database runtime hoặc dữ liệu khách trong module.

## Zalo Personal

V5 có sẵn quy trình onboarding Zalo Personal nhưng không chứa session, QR,
cookie, pairing code hay danh tính owner của member nào. Cài sau trên đúng
container bằng [zalo/README.md](zalo/README.md):

1. Chạy preflight và backup.
2. Cài `@openclaw/zalouser` đúng release với OpenClaw core.
3. Cấu hình account `default`, binding vào agent `main`, DM/group policy.
4. Gửi QR qua Telegram owner để người dùng quét trên điện thoại.
5. Duyệt pairing hoặc thêm owner Zalo sau khi xác minh ID.
6. Đăng ký Gateway/Zalo/resource watchdog và chạy các probe xác nhận. Luồng
   mặc định dùng `openclaw-zalo-no-response` → `shared-watchdog-center` →
   `recover-openclaw-member-gateway` (Supervisor guard) →
   `member-vps-resource-oom-guard`.

Không copy profile Zalo từ member khác. Không tự động quét QR hoặc gửi tin
Zalo thật trong bước healthcheck. Khi cần cấp full owner và mở group không cần
mention, dùng script trong `zalo/` với các ID đã xác minh của member đó.
# Owner QR update — 2026-10-16

New Zalo installs include `telegram-zalo-owner-login` in the full V6
manifest. Docker onboarding deploys and checks the owner-gated tool and `/zaloqr`
command on the selected member only. Native Antigravity instructions use the
separate Node/CLI adapter, not Docker/Supervisor scripts. Owners first open the
customer's Telegram bot and press Start, then request a QR privately. QR must stay
in private outbound media, with an exact message receipt. Plugin installation is
not proof of live delivery or Zalo connectivity; keep `pending_live_test` until
verified. Existing members are not automatically changed by this release update.
