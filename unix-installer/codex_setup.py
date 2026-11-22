"""Priority Codex CLI installation, Antigravity IDE extension setup, and Auto-Heal for macOS & Linux."""

from __future__ import annotations

from datetime import datetime
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import tempfile

import net_utils


NON_HEALABLE_CODES = {
    "invalid-settings",
    "invalid-member",
    "missing-assistant-name",
    "invalid-owners",
    "duplicate-owners",
    "invalid-group",
    "invalid-telegram-token",
    "missing-api-key",
    "invalid-model",
    "invalid-base-url",
    "invalid-port",
    "full-access-consent-required",
    "invalid-qr-owner",
    "linux-user-service-unavailable",
}

TELEGRAM_TOKEN_RE = re.compile(r"[0-9]{5,}:[A-Za-z0-9_-]{20,}")
API_KEY_RE = re.compile(r"sk-[A-Za-z0-9_-]{12,}")
GATEWAY_TOKEN_RE = re.compile(r'("token"\s*:\s*")[0-9a-fA-F]{24,}(")')


def scrub_secrets(text: str, secrets=()) -> str:
    if not text:
        return ""
    cleaned = str(text)
    for secret in secrets:
        if isinstance(secret, str) and len(secret.strip()) >= 6:
            cleaned = cleaned.replace(secret.strip(), "[REDACTED_SECRET]")
    cleaned = TELEGRAM_TOKEN_RE.sub("[REDACTED_TELEGRAM_TOKEN]", cleaned)
    cleaned = API_KEY_RE.sub("[REDACTED_API_KEY]", cleaned)
    cleaned = GATEWAY_TOKEN_RE.sub(r"\1[REDACTED_GATEWAY_TOKEN]\2", cleaned)
    return cleaned


def data_root(home: Path | None = None) -> Path:
    resolved_home = Path(home) if home is not None else Path.home()
    return resolved_home / ".local/share/installer_emtroly"


def codex_home_dir(home: Path | None = None) -> Path:
    return data_root(home) / "codex-home"


def _write_private_file(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(tmp, flags, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)
    try:
        os.chmod(tmp, mode)
    except OSError:
        pass
    os.replace(tmp, path)


def write_codex_home(home: Path, api_key: str, model: str, base_url: str) -> Path:
    c_home = codex_home_dir(home)
    c_home.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(c_home, 0o700)
    except OSError:
        pass
    safe_model = model.strip() if re.fullmatch(r"[A-Za-z0-9._-]+", (model or "").strip()) else "gpt-6.2-sol"
    safe_url = (base_url or "https://codex.anhlaptrinh.vn/v1").strip().rstrip("/")
    config_toml = (
        'model_provider = "router"\n'
        f'model = "{safe_model}"\n'
        "model_context_window = 272000\n"
        "model_auto_compact_token_limit = 200000\n"
        'cli_auth_credentials_store = "file"\n\n'
        "[model_providers.router]\n"
        'name = "router"\n'
        f'base_url = "{safe_url}"\n'
        'wire_api = "responses"\n'
        "requires_openai_auth = true\n"
    )
    _write_private_file(c_home / "config.toml", config_toml, 0o600)
    if api_key and api_key.strip():
        _write_private_file(c_home / "auth.json", json.dumps({"OPENAI_API_KEY": api_key.strip()}) + "\n", 0o600)
    return c_home


def find_codex_binary(home: Path | None = None, *, isolated_only: bool = False) -> Path | None:
    env_override = os.environ.get("EMTROLY_AUTOHEAL_BIN", "").strip()
    if env_override:
        cand = Path(env_override)
        if cand.is_file() and os.access(cand, os.X_OK):
            return cand

    resolved_home = Path(home) if home is not None else Path.home()
    em_root = data_root(resolved_home)

    isolated_candidates = [
        em_root / "codex-cli/node_modules/.bin/codex",
    ]
    ext_root = em_root / "antigravity/Extensions"
    if ext_root.is_dir():
        isolated_candidates.extend(sorted(ext_root.glob("openai.chatgpt-*/bin/*/codex"), reverse=True))

    for cand in isolated_candidates:
        if cand.is_file() and os.access(cand, os.X_OK):
            return cand

    if isolated_only:
        return None

    for base in (resolved_home / ".antigravity/extensions", resolved_home / ".vscode/extensions"):
        if not base.is_dir():
            continue
        for cand in sorted(base.glob("openai.chatgpt-*/bin/*/codex"), reverse=True):
            if cand.is_file() and os.access(cand, os.X_OK):
                return cand

    for cmd_name in ("codex-emtroly", "codex"):
        found = shutil.which(cmd_name)
        if found:
            p = Path(found)
            if p.is_file() and os.access(p, os.X_OK):
                return p
    return None


def register_codex_shim(home: Path, codex_bin: Path, c_home: Path, extra_bin_dir: Path | None = None) -> dict:
    bin_dir = home / ".local/bin"
    bin_dir.mkdir(parents=True, exist_ok=True, mode=0o755)
    path_prefix = f'export PATH={shlex.quote(str(extra_bin_dir))}:"$PATH"\n' if extra_bin_dir else ""
    shim_text = (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "unset OPENAI_API_KEY ELECTRON_RUN_AS_NODE VSCODE_IPC_HOOK_CLI NODE_OPTIONS VSCODE_DEV\n"
        f"export CODEX_HOME={shlex.quote(str(c_home))}\n"
        f"{path_prefix}"
        f"exec {shlex.quote(str(codex_bin))} \"$@\"\n"
    )
    alias_path = bin_dir / "codex-emtroly"
    _write_private_file(alias_path, shim_text, 0o755)

    default_shim = bin_dir / "codex"
    existing = shutil.which("codex")
    external_conflict = False
    if existing:
        try:
            if Path(existing).resolve() != default_shim.resolve() and Path(existing).parent.resolve() != bin_dir.resolve():
                external_conflict = True
        except OSError:
            external_conflict = True

    selected_name = "codex-emtroly"
    selected_path = alias_path
    if not external_conflict:
        _write_private_file(default_shim, shim_text, 0o755)
        selected_name = "codex"
        selected_path = default_shim

    return {"registered": True, "command": selected_name, "path": str(selected_path)}


def install_codex_cli_first(values: dict, home: Path, node: Path, npm: Path, progress=lambda _m: None) -> dict:
    """Always configure and install Codex CLI first so it can auto-heal subsequent steps."""
    progress("Bước 2 · Đang cài đặt và cấu hình ưu tiên Codex CLI trước tiên...")
    c_home = write_codex_home(
        home,
        values.get("ai_api_key", ""),
        values.get("model", "gpt-6.2-sol"),
        values.get("base_url", "https://codex.anhlaptrinh.vn/v1"),
    )

    existing = find_codex_binary(home, isolated_only=True)
    if existing:
        shim = register_codex_shim(home, existing, c_home, extra_bin_dir=node.parent)
        return {"installed": True, "executable": str(existing), "codex_home": str(c_home), "shim": shim}

    base_url = (values.get("base_url") or "").strip().rstrip("/")
    should_install_npm = (
        base_url == "https://codex.anhlaptrinh.vn/v1"
        or os.environ.get("EMTROLY_FORCE_CODEX_INSTALL") == "1"
    )
    if should_install_npm and npm.is_file() and node.is_file():
        cli_prefix = data_root(home) / "codex-cli"
        cli_prefix.mkdir(parents=True, exist_ok=True, mode=0o700)
        pkg_json = cli_prefix / "package.json"
        if not pkg_json.is_file():
            _write_private_file(pkg_json, '{"name":"emtroly-codex-cli","private":true}\n', 0o600)
        env = dict(os.environ, NO_COLOR="1")
        env["PATH"] = str(node.parent) + os.pathsep + env.get("PATH", "")
        try:
            subprocess.run(
                [str(npm), "install", "--prefix", str(cli_prefix), "@openai/codex", "--no-audit", "--no-fund"],
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=300,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            pass

    final_bin = find_codex_binary(home, isolated_only=not should_install_npm)
    if final_bin:
        net_utils.clear_macos_quarantine(final_bin)
        shim = register_codex_shim(home, final_bin, c_home, extra_bin_dir=node.parent)
        return {"installed": True, "executable": str(final_bin), "codex_home": str(c_home), "shim": shim}
    return {"installed": False, "executable": "", "codex_home": str(c_home), "shim": None}


def find_antigravity_cli(home: Path | None = None) -> tuple[Path | None, Path | None]:
    """Locate Antigravity IDE binary & CLI on macOS or Linux if present."""
    resolved_home = Path(home) if home is not None else Path.home()
    sys_name = platform.system()
    candidates: list[tuple[Path, Path]] = []

    env_cli = os.environ.get("EMTROLY_ANTIGRAVITY_CLI", "").strip()
    if env_cli:
        p = Path(env_cli)
        if p.is_file() and os.access(p, os.X_OK):
            return p, p

    if sys_name == "Darwin":
        for app_root in (
            Path("/Applications/Antigravity.app"),
            Path("/Applications/Antigravity IDE.app"),
            resolved_home / "Applications/Antigravity.app",
            resolved_home / "Applications/Antigravity IDE.app",
        ):
            for cli_rel in ("Contents/Resources/app/bin/antigravity", "Contents/Resources/app/bin/antigravity-ide"):
                cli_path = app_root / cli_rel
                if cli_path.is_file() and os.access(cli_path, os.X_OK):
                    candidates.append((app_root, cli_path))
    elif sys_name == "Linux":
        for bin_path in (
            Path("/usr/bin/antigravity"),
            Path("/usr/bin/antigravity-ide"),
            Path("/opt/Antigravity/bin/antigravity"),
            Path("/opt/antigravity-ide/bin/antigravity-ide"),
            resolved_home / ".local/bin/antigravity",
        ):
            if bin_path.is_file() and os.access(bin_path, os.X_OK):
                candidates.append((bin_path, bin_path))

    if candidates:
        return candidates[0]

    for name in ("antigravity", "antigravity-ide"):
        which_cli = shutil.which(name)
        if which_cli:
            p = Path(which_cli)
            return p, p
    return None, None


def install_antigravity_and_extension(values: dict, home: Path, progress=lambda _m: None) -> dict:
    """Configure isolated Antigravity profile & install Codex Extension (`openai.chatgpt`) before OpenClaw."""
    if values.get("skip_editor"):
        return {"configured": False, "skipped": True, "reason": "skip-editor"}

    app_target, ide_cli = find_antigravity_cli(home)
    if not ide_cli:
        return {"configured": False, "skipped": True, "reason": "antigravity-not-installed"}

    progress("Bước 2 · Đang cấu hình Antigravity IDE và cài đặt Codex Extension...")
    ag_root = data_root(home) / "antigravity"
    user_data = ag_root / "UserData"
    ext_dir = ag_root / "Extensions"
    settings_dir = user_data / "User"
    for folder in (ag_root, user_data, ext_dir, settings_dir):
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)

    editor_settings = {
        "extensions.autoUpdate": False,
        "extensions.autoCheckUpdates": False,
        "extensions.ignoreRecommendations": True,
        "update.mode": "none",
    }
    _write_private_file(settings_dir / "settings.json", json.dumps(editor_settings, indent=2) + "\n", 0o600)

    c_home = codex_home_dir(home)
    env = dict(os.environ, CODEX_HOME=str(c_home), NO_COLOR="1")
    for k in ("OPENAI_API_KEY", "VSCODE_IPC_HOOK_CLI", "ELECTRON_RUN_AS_NODE", "NODE_OPTIONS", "VSCODE_DEV"):
        env.pop(k, None)

    res = subprocess.run(
        [
            str(ide_cli),
            "--user-data-dir",
            str(user_data),
            "--extensions-dir",
            str(ext_dir),
            "--install-extension",
            "openai.chatgpt",
            "--force",
        ],
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=600,
        check=False,
    )
    if res.returncode != 0:
        raise RuntimeError("editor-extension-install-failed: " + (res.stderr or res.stdout)[-400:].strip())

    # Create isolated desktop / Applications launcher
    if platform.system() == "Darwin":
        apps_dir = home / "Applications"
        apps_dir.mkdir(parents=True, exist_ok=True)
        launcher = apps_dir / "EmTroLy - Antigravity.command"
        launcher_body = (
            "#!/usr/bin/env bash\n"
            "unset OPENAI_API_KEY ELECTRON_RUN_AS_NODE VSCODE_IPC_HOOK_CLI NODE_OPTIONS VSCODE_DEV\n"
            f"export CODEX_HOME={shlex.quote(str(c_home))}\n"
            f"exec {shlex.quote(str(ide_cli))} --user-data-dir {shlex.quote(str(user_data))} "
            f"--extensions-dir {shlex.quote(str(ext_dir))} --new-window\n"
        )
        _write_private_file(launcher, launcher_body, 0o755)
        net_utils.clear_macos_quarantine(launcher)
        net_utils.clear_macos_quarantine(ext_dir)
    elif platform.system() == "Linux":
        apps_dir = home / ".local/share/applications"
        apps_dir.mkdir(parents=True, exist_ok=True)
        wrapper = data_root(home) / "launch-antigravity.sh"
        wrapper_body = (
            "#!/usr/bin/env bash\n"
            "unset OPENAI_API_KEY ELECTRON_RUN_AS_NODE VSCODE_IPC_HOOK_CLI NODE_OPTIONS VSCODE_DEV\n"
            f"export CODEX_HOME={shlex.quote(str(c_home))}\n"
            f"exec {shlex.quote(str(ide_cli))} --user-data-dir {shlex.quote(str(user_data))} "
            f"--extensions-dir {shlex.quote(str(ext_dir))} --new-window \"$@\"\n"
        )
        _write_private_file(wrapper, wrapper_body, 0o755)
        desktop_entry = (
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=Em Trợ Lý - Antigravity IDE\n"
            "Comment=Antigravity IDE và Codex riêng của Em Trợ Lý\n"
            f"Exec={shlex.quote(str(wrapper))}\n"
            "Terminal=false\n"
            "Categories=Development;Utility;\n"
        )
        _write_private_file(apps_dir / "emtroly-antigravity.desktop", desktop_entry, 0o755)

    return {"configured": True, "skipped": False, "cli": str(ide_cli)}


def is_auto_healable(stage: str, error: Exception) -> bool:
    if stage in {"input", "preflight", "provider", "telegram"}:
        return False
    if isinstance(error, FileExistsError):
        return False
    msg = str(error).strip()
    if not msg or msg in NON_HEALABLE_CODES:
        return False
    return True


def build_auto_heal_prompt(
    stage: str,
    error_text: str,
    values: dict,
    home: Path,
    root: Path | None,
    source: Path,
    attempt: int,
) -> str:
    secrets = [values.get("telegram_token", ""), values.get("ai_api_key", "")]
    safe_err = scrub_secrets(error_text, secrets)
    sys_label = "macOS (launchd)" if platform.system() == "Darwin" else "Linux (systemd --user)"
    owners_val = values.get("owner_ids", "")
    owners_str = ",".join(owners_val) if isinstance(owners_val, list) else str(owners_val)
    return (
        f"Bạn là hệ thống tự động chẩn đoán và sửa lỗi cài đặt của bộ cài 'Anh Lập Trình - Em Trợ Lý' trên {sys_label} "
        f"(Lần tự sửa thứ {attempt}/2).\n"
        "Một bước cài đặt vừa gặp sự cố. Hãy kiểm tra nguyên nhân thực tế trên máy và SỬA TRỰC TIẾP để bước kiểm tra tiếp theo thành công.\n\n"
        "THÔNG TIN SỰ CỐ:\n"
        f"- Bước gặp lỗi (stage): {stage}\n"
        f"- Chi tiết lỗi (đã ẩn mã bí mật): {safe_err}\n\n"
        "THÔNG SỐ CÀI ĐẶT:\n"
        f"- Hệ điều hành: {sys_label}\n"
        f"- Thư mục người dùng: {home}\n"
        f"- Thư mục trợ lý OpenClaw: {root or (home / ('.openclaw-member-' + str(values.get('member', 'emtroly'))))}\n"
        f"- Thư mục bộ nguồn (source): {source}\n"
        f"- Thư mục môi trường riêng: {data_root(home)}\n"
        f"- Tên tài khoản Telegram: {values.get('member', 'emtroly')}\n"
        f"- Telegram Owner IDs: {owners_str}\n"
        f"- Model AI: {values.get('model', 'gpt-6.2-sol')}\n\n"
        "NGUYÊN TẮC BẮT BUỘC:\n"
        f"1. Chỉ thao tác trong phạm vi thư mục của user hiện tại ({home}). Không dùng sudo, không xóa dữ liệu cá nhân.\n"
        "2. Tuyệt đối KHÔNG in nội dung telegram.token, member-provider.secret hoặc auth.json ra màn hình.\n"
        "3. Nếu lỗi ở bước `editor`: kiểm tra cài đặt tiện ích `openai.chatgpt` trong thư mục Extensions riêng.\n"
        "4. Nếu lỗi ở bước `gateway` / `zalo`: kiểm tra tiến trình cổng bị kẹt, trạng thái `systemctl --user` (Linux) hoặc `launchctl` (macOS), "
        "và kiểm tra `openclaw plugins list` / `openclaw gateway health --json`.\n"
        "5. Cuối cùng, tóm tắt ngắn gọn 1–2 câu tiếng Việt bạn đã sửa gì.\n"
    )


def invoke_codex_auto_heal(
    stage: str,
    error_text: str,
    values: dict,
    home: Path,
    root: Path | None,
    source: Path,
    *,
    node: Path | None = None,
    progress=lambda _m: None,
    attempt: int = 1,
    timeout: int = 240,
) -> dict:
    api_key = (values.get("ai_api_key") or "").strip()
    if not api_key:
        return {"invoked": False, "reason": "missing-api-key", "exit_code": 2, "summary": ""}

    base_url = (values.get("base_url") or "").strip().rstrip("/")
    allow_global_codex = base_url == "https://codex.anhlaptrinh.vn/v1"
    codex_bin = find_codex_binary(home, isolated_only=not allow_global_codex)
    if not codex_bin:
        return {"invoked": False, "reason": "codex-unavailable", "exit_code": 2, "summary": ""}

    progress(f"Phát hiện sự cố tại bước {stage} — Codex CLI đang tự động chẩn đoán và sửa lỗi (lần {attempt}/2)...")
    secrets = [values.get("telegram_token", ""), api_key]

    with tempfile.TemporaryDirectory(prefix="emtroly-unix-heal-") as tmp_str:
        tmp_dir = Path(tmp_str)
        os.chmod(tmp_dir, 0o700)
        c_home = write_codex_home(
            home,
            api_key,
            values.get("model", "gpt-6.2-sol"),
            base_url or "https://codex.anhlaptrinh.vn/v1",
        )
        summary_file = tmp_dir / "last-message.txt"
        work_dir = root if (root and root.is_dir()) else (data_root(home) if data_root(home).is_dir() else home)
        prompt = build_auto_heal_prompt(stage, error_text, values, home, root, source, attempt)

        env = dict(os.environ, CODEX_HOME=str(c_home), NO_COLOR="1", PYTHONUTF8="1")
        if node and node.parent.is_dir():
            env["PATH"] = str(node.parent) + os.pathsep + env.get("PATH", "")
        for rm_key in ("OPENAI_API_KEY", "ELECTRON_RUN_AS_NODE", "VSCODE_IPC_HOOK_CLI", "NODE_OPTIONS", "VSCODE_DEV"):
            env.pop(rm_key, None)

        model = values.get("model", "gpt-6.2-sol")
        cmd = [
            str(codex_bin),
            "exec",
            "--skip-git-repo-check",
            "--color",
            "never",
            "--sandbox",
            "danger-full-access",
            "-m",
            str(model),
            "-C",
            str(work_dir),
            "-o",
            str(summary_file),
            "-",
        ]
        try:
            proc = subprocess.run(
                cmd,
                input=prompt,
                cwd=str(work_dir),
                env=env,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
                check=False,
            )
            exit_code = proc.returncode
            raw_out = (proc.stdout or "") + "\n" + (proc.stderr or "")
        except subprocess.TimeoutExpired:
            exit_code = 124
            raw_out = "Hết thời gian chờ Codex CLI tự sửa lỗi."

        summary = summary_file.read_text(encoding="utf-8").strip() if summary_file.is_file() else ""
        if not summary:
            tail = [ln.strip() for ln in raw_out.splitlines() if ln.strip()][-3:]
            summary = " ".join(tail)
        safe_summary = scrub_secrets(summary, secrets)[:320]

        stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        audit_line = f"[{stamp}] stage={stage} attempt={attempt} exit={exit_code} summary={safe_summary}\n"
        audit_dirs = [data_root(home) / "logs"]
        if root and root.is_dir():
            audit_dirs.append(root / "logs")
        for a_dir in audit_dirs:
            try:
                a_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
                with (a_dir / "codex-autoheal.log").open("a", encoding="utf-8") as fh:
                    fh.write(audit_line)
            except OSError:
                pass

        return {"invoked": True, "exit_code": exit_code, "summary": safe_summary}


def run_step_with_auto_heal(
    stage: str,
    action,
    *,
    values: dict,
    home: Path,
    root_getter=lambda: None,
    source: Path,
    node: Path | None = None,
    progress=lambda _m: None,
    on_before_retry=None,
):
    last_summary = ""
    try:
        return action()
    except Exception as first_err:
        if not is_auto_healable(stage, first_err):
            raise
        current_err = first_err
        for attempt in (1, 2):
            heal = invoke_codex_auto_heal(
                stage,
                str(current_err),
                values,
                home,
                root_getter(),
                source,
                node=node,
                progress=progress,
                attempt=attempt,
            )
            if not heal.get("invoked"):
                break
            if heal.get("summary"):
                last_summary = heal["summary"]
            progress(f"Codex CLI đã xử lý sự cố bước {stage} (lần {attempt}/2). Đang kiểm tra nghiệm thu lại...")
            if on_before_retry is not None:
                on_before_retry()
            try:
                return action()
            except Exception as retry_err:
                current_err = retry_err
                if not is_auto_healable(stage, current_err):
                    raise
        if last_summary:
            raise RuntimeError(f"{current_err} (Ghi chú từ Codex tự sửa lỗi: {last_summary})") from None
        raise current_err
