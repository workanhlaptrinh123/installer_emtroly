"""Orchestrate isolated installation steps; callers must provide a UI and consent."""

import importlib.util
import os
from pathlib import Path
import platform
import shutil
import socket

from urllib.parse import urlsplit

import codex_setup
import dependencies
import ffmpeg
import instance
import license_gate
import payload
import provider
import python_runtime
import runtime
import service
import settings
import telegram
import uninstaller
import zalo_setup


DEFAULT_MIN_FREE_BYTES = 1_200_000_000
VALID_COMPONENTS = ("codex-cli", "antigravity-ide", "codex-extension", "openclaw")


def validate_ai_only(values: dict) -> dict:
    if not isinstance(values, dict):
        raise ValueError("invalid-settings")
    norm = settings.normalize(values)
    api_key = norm.get("ai_api_key", "")
    if not api_key:
        raise ValueError("missing-api-key")
    model = norm.get("model", "")
    if model.lower() not in settings.MODELS:
        raise ValueError("invalid-model")
    base_url = norm.get("base_url", "") or "https://codex.anhlaptrinh.vn/v1"
    try:
        if any(ch.isspace() or ord(ch) < 32 for ch in base_url):
            raise ValueError("invalid-base-url")
        parsed = urlsplit(base_url)
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError("invalid-base-url")
        _ = parsed.port
    except ValueError:
        raise ValueError("invalid-base-url") from None
    return {
        "ai_api_key": api_key,
        "model": model,
        "base_url": base_url.rstrip("/"),
    }


def check_disk_space(target_dir: Path) -> None:
    min_raw = os.environ.get("EMTROLY_MIN_FREE_BYTES", "").strip()
    min_bytes = int(min_raw) if min_raw.isdigit() else DEFAULT_MIN_FREE_BYTES
    sim_raw = os.environ.get("EMTROLY_SIMULATE_FREE_BYTES", "").strip()
    if sim_raw.isdigit():
        free_bytes = int(sim_raw)
    else:
        probe = Path(target_dir)
        while not probe.exists() and probe.parent != probe:
            probe = probe.parent
        free_bytes = shutil.disk_usage(probe).free
    if free_bytes < min_bytes:
        free_mb = round(free_bytes / (1024 * 1024))
        req_gb = round(min_bytes / (1024 * 1024 * 1024), 1)
        raise RuntimeError(
            f"Ổ đĩa không đủ dung lượng trống (còn {free_mb} MB, cần tối thiểu {req_gb} GB để cài đặt an toàn)."
        )


def choose_port(requested):
    candidates = [requested] if requested else range(19789, 65000, 120)
    for port in candidates:
        sockets = []
        try:
            for offset in (0, 1, 2):
                listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sockets.append(listener)
                listener.bind(("127.0.0.1", port + offset))
            return port
        except OSError:
            continue
        finally:
            for listener in sockets:
                listener.close()
    raise RuntimeError("No available gateway port")


def install(values, source, progress=lambda message: None):
    values_checked = settings.validate(values)
    source = Path(source).resolve(strict=True)
    home = Path.home().resolve(strict=True)
    if platform.system() not in {"Linux", "Darwin"}:
        raise RuntimeError("Only Ubuntu and macOS are supported")
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        raise RuntimeError("Run the installer as the desktop user, not root")
    prospective = home / (".openclaw-member-" + values_checked["member"])
    if prospective.exists() or prospective.is_symlink():
        if uninstaller.is_recoverable_incomplete_instance(prospective):
            progress("Phát hiện lần cài trước bị gián đoạn — đang tự động lưu trữ & dọn dẹp để cài mới...")
            uninstaller.archive_incomplete_instance(prospective, home)
        else:
            raise FileExistsError("Instance already exists; it was not changed")
    check_disk_space(home)
    if platform.system() == "Linux":
        service.check_linux_user_service()
    progress("Đang kiểm tra Telegram và nhà cung cấp AI...")
    telegram.verify_bot(values_checked["telegram_token"])
    values = dict(values)
    values["model"] = provider.verify(values_checked["base_url"], values_checked["ai_api_key"], values_checked["model"])
    if values["model"].lower() != values_checked["model"].lower():
        raise RuntimeError("Provider returned a different model")
    if values_checked["base_url"] == "https://codex.anhlaptrinh.vn/v1":
        try:
            license_gate.save_license_key(values_checked["ai_api_key"])
        except OSError:
            pass

    port = choose_port(values_checked["gateway_port"])
    progress("Đang chuẩn bị Node.js riêng...")
    dependency_root = home / ".local/share/installer_emtroly/dependencies"
    node, npm = dependencies.install_node(dependency_root)

    # Priority Step 2: Always install Codex CLI first, then Antigravity IDE & Codex Extension
    codex_info = codex_setup.install_codex_cli_first(values_checked, home, node, npm, progress=progress)
    editor_info = {"configured": False, "skipped": True}
    if not values_checked.get("skip_editor", False):
        try:
            editor_info = codex_setup.run_step_with_auto_heal(
                "editor",
                lambda: codex_setup.install_antigravity_and_extension(values_checked, home, progress=progress),
                values=values_checked,
                home=home,
                root_getter=lambda: None,
                source=source,
                node=node,
                progress=progress,
            )
        except Exception:
            editor_info = {"configured": False, "skipped": False, "deferred": True}

    root_holder = {"root": None}

    progress("Đang chuẩn bị Python...")
    python_binary = codex_setup.run_step_with_auto_heal(
        "python",
        lambda: python_runtime.install(dependency_root),
        values=values_checked,
        home=home,
        root_getter=lambda: root_holder["root"],
        source=source,
        node=node,
        progress=progress,
    )
    progress("Đang chuẩn bị FFmpeg...")
    ffmpeg_binary = codex_setup.run_step_with_auto_heal(
        "ffmpeg",
        lambda: ffmpeg.install(dependency_root),
        values=values_checked,
        home=home,
        root_getter=lambda: root_holder["root"],
        source=source,
        node=node,
        progress=progress,
    )
    progress("Đang tạo trợ lý riêng...")
    root = instance.initialize(values, home, port)
    uninstaller.write_installing_marker(root, values_checked["member"])
    root_holder["root"] = root

    enable_zalo = values_checked.get("configure_zalo", True)
    progress("Đang cài OpenClaw, bước này có thể mất vài phút...")
    entry, env = codex_setup.run_step_with_auto_heal(
        "openclaw-runtime",
        lambda: runtime.install(root, home, node, npm, extra_bins=(python_binary.parent, ffmpeg_binary.parent)),
        values=values_checked,
        home=home,
        root_getter=lambda: root,
        source=source,
        node=node,
        progress=progress,
    )
    progress("Đang cài các skill...")
    if enable_zalo:
        codex_setup.run_step_with_auto_heal(
            "skills",
            lambda: payload.install(root, source),
            values=values_checked,
            home=home,
            root_getter=lambda: root,
            source=source,
            node=node,
            progress=progress,
        )
    else:
        codex_setup.run_step_with_auto_heal(
            "skills",
            lambda: payload.install(root, source, enable_zalo=False),
            values=values_checked,
            home=home,
            root_getter=lambda: root,
            source=source,
            node=node,
            progress=progress,
        )
    progress("Đang cấu hình quyền Telegram và Zalo..." if enable_zalo else "Đang cấu hình quyền Telegram...")
    codex_setup.run_step_with_auto_heal(
        "zalo-setup",
        lambda: zalo_setup.configure(
            root, home, node, entry, env, values_checked["member"], values_checked["owner_ids"], source, enable_zalo=enable_zalo
        ),
        values=values_checked,
        home=home,
        root_getter=lambda: root,
        source=source,
        node=node,
        progress=progress,
    )
    try:
        def _start_and_verify_gateway():
            progress("Đang khởi động và kiểm tra Gateway...")
            if enable_zalo:
                service.install_and_verify(node, entry, env, port)
                progress("Đang đăng ký lệnh Telegram...")
                telegram.ensure_menu(values_checked["telegram_token"])
            else:
                service.install_and_verify(node, entry, env, port, enable_zalo=False)
            helper_path = source / "native/install_unix_cli.py"
            spec = importlib.util.spec_from_file_location("installer_unix_cli", helper_path)
            if spec is None or spec.loader is None:
                raise RuntimeError("Unix command helper is missing")
            helper = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(helper)
            return helper.install(
                root, home, node, entry, env["OPENCLAW_PROFILE"], runtime.OPENCLAW_VERSION, (python_binary.parent, ffmpeg_binary.parent)
            )

        cli = codex_setup.run_step_with_auto_heal(
            "gateway-verify",
            _start_and_verify_gateway,
            values=values_checked,
            home=home,
            root_getter=lambda: root,
            source=source,
            node=node,
            progress=progress,
        )
    except (OSError, ValueError, RuntimeError) as error:
        raise RuntimeError("Cài đặt chưa hoàn tất; Gateway có thể đã chạy. Không cài lại trước khi kiểm tra " +
                           str(root) + ". Chi tiết: " + str(error)) from None
    uninstaller.clear_installing_marker(root)
    return {
        "root": str(root),
        "gateway_port": port,
        "cli": cli,
        "codex": codex_info,
        "editor": editor_info,
    }


def _parse_version_tuple(raw: str) -> tuple[int, ...]:
    cleaned = str(raw or "").strip().lstrip("vV")
    main = cleaned.split("-", 1)[0].split("+", 1)[0]
    parts: list[int] = []
    for seg in main.split("."):
        try:
            parts.append(int(seg))
        except ValueError:
            parts.append(0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts)


def compare_versions(current: str, target: str) -> int:
    a = _parse_version_tuple(current)
    b = _parse_version_tuple(target)
    max_len = max(len(a), len(b))
    a_pad = a + (0,) * (max_len - len(a))
    b_pad = b + (0,) * (max_len - len(b))
    if a_pad < b_pad:
        return -1
    if a_pad > b_pad:
        return 1
    return 0


def get_openclaw_version_info(root: Path, source: Path | None = None) -> dict:
    import json

    target_ver = runtime.OPENCLAW_VERSION
    if source:
        manifest = Path(source) / "MANIFEST.txt"
        if manifest.is_file():
            for line in manifest.read_text(encoding="utf-8", errors="ignore").splitlines():
                if line.startswith("openclaw="):
                    val = line.split("=", 1)[1].strip()
                    if val:
                        target_ver = val
                    break

    installed = bool(root and (Path(root) / "openclaw.json").is_file())
    cur_ver = ""
    if installed:
        rt_dir = Path(root) / "runtime"
        if rt_dir.is_dir():
            for cand in sorted(rt_dir.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
                if not cand.is_dir():
                    continue
                pkg = cand / "node_modules/openclaw/package.json"
                if pkg.is_file():
                    try:
                        cur_ver = str(json.loads(pkg.read_text(encoding="utf-8")).get("version", "")).strip()
                        if cur_ver:
                            break
                    except Exception:
                        pass
                if cand.name and cand.name[0].isdigit():
                    cur_ver = cand.name
                    break

    needs_upgrade = bool(installed and cur_ver and compare_versions(cur_ver, target_ver) < 0)
    up_to_date = bool(installed and cur_ver and compare_versions(cur_ver, target_ver) >= 0)
    return {
        "installed": installed,
        "installed_version": cur_ver,
        "target_version": target_ver,
        "needs_upgrade": needs_upgrade,
        "up_to_date": up_to_date,
    }


def upgrade_openclaw_runtime(root: Path, home: Path, source: Path, progress=lambda message: None) -> dict:
    import json

    ver_info = get_openclaw_version_info(root, source)
    if ver_info["up_to_date"]:
        progress(f"✓ OpenClaw đã ở phiên bản mới nhất (v{ver_info['installed_version']}) — không cần nâng cấp.")
        return {"root": str(root), "upgraded": False, "skipped": True, **ver_info}

    target_ver = ver_info["target_version"]
    progress(f"Đang nâng cấp OpenClaw từ v{ver_info['installed_version'] or '?'} lên v{target_ver} (giữ nguyên dữ liệu cũ)...")
    dependency_root = home / ".local/share/installer_emtroly/dependencies"
    node, npm = dependencies.install_node(dependency_root)
    python_binary = python_runtime.install(dependency_root)
    ffmpeg_binary = ffmpeg.install(dependency_root)

    target_rt = root / "runtime" / target_ver
    if target_rt.exists():
        shutil.rmtree(target_rt, ignore_errors=True)
    entry, env = runtime.install(root, home, node, npm, extra_bins=(python_binary.parent, ffmpeg_binary.parent))

    cfg_path = root / "openclaw.json"
    port = 19789
    if cfg_path.is_file():
        try:
            cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
            port = int(cfg.get("gateway", {}).get("port") or 19789)
        except Exception:
            pass
    enable_zalo = (root / "workspace/skills/telegram-zalo-owner-login/SKILL.md").is_file()
    service.install_and_verify(node, entry, env, port, enable_zalo=enable_zalo)
    return {"root": str(root), "upgraded": True, "skipped": False, "installed_version": target_ver, "target_version": target_ver}


def install_components(components, values, source, progress=lambda message: None, force_reinstall: bool = False) -> dict:
    """Install one or more selected components independently in canonical order.
    Already-installed components are automatically skipped unless force_reinstall=True;
    OpenClaw is automatically upgraded in-place if its installed version is lower than target."""
    if isinstance(components, str):
        raw_list = [p.strip().lower() for p in components.split(",") if p.strip()]
    else:
        raw_list = [str(p).strip().lower() for p in (components or ()) if str(p).strip()]
    if not raw_list or any(item not in VALID_COMPONENTS for item in raw_list):
        raise ValueError("invalid-component-selection")
    ordered = [comp for comp in VALID_COMPONENTS if comp in raw_list]

    source = Path(source).resolve(strict=True)
    home = Path.home().resolve(strict=True)
    if platform.system() not in {"Linux", "Darwin"}:
        raise RuntimeError("Only Ubuntu and macOS are supported")
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        raise RuntimeError("Run the installer as the desktop user, not root")
    check_disk_space(home)

    member_name = str(values.get("member", "emtroly") or "emtroly").strip() or "emtroly"
    existing_oc_root = home / (".openclaw-member-" + member_name)
    oc_ver_info = get_openclaw_version_info(existing_oc_root, source)
    oc_already_installed = oc_ver_info["installed"]

    if "openclaw" in ordered and not oc_already_installed:
        values_checked = settings.validate(values)
    else:
        values_checked = validate_ai_only(values)

    progress("Đang xác thực khóa API và mô hình trên máy chủ AI...")
    verified_model = provider.verify(values_checked["base_url"], values_checked["ai_api_key"], values_checked["model"])
    if verified_model.lower() != values_checked["model"].lower():
        raise RuntimeError("Provider returned a different model")
    values_checked["model"] = verified_model
    if values_checked["base_url"] == "https://codex.anhlaptrinh.vn/v1":
        try:
            license_gate.save_license_key(values_checked["ai_api_key"])
        except OSError:
            pass

    results: dict = {"components": ordered, "skipped": []}
    dependency_root = home / ".local/share/installer_emtroly/dependencies"
    node_pair = None
    mod_status = codex_setup.get_modular_status(home, preferred_member=member_name)

    if "codex-cli" in ordered:
        if not force_reinstall and mod_status.get("codex_cli", {}).get("installed"):
            progress("✓ Codex CLI đã có sẵn trên máy — bỏ qua không cài lại.")
            results["codex"] = {"installed": True, "skipped": True, "reason": "already-installed"}
            results["skipped"].append("codex-cli")
        else:
            progress("Phần 1 · Đang chuẩn bị Node.js và kiểm tra/cài đặt Codex CLI riêng...")
            node_pair = dependencies.install_node(dependency_root)
            prev_force = os.environ.get("EMTROLY_FORCE_CODEX_INSTALL")
            try:
                os.environ["EMTROLY_FORCE_CODEX_INSTALL"] = "1"
                c_info = codex_setup.install_codex_cli_first(
                    values_checked, home, node_pair[0], node_pair[1], progress=progress, check_latest=bool(force_reinstall)
                )
            finally:
                if prev_force is None:
                    os.environ.pop("EMTROLY_FORCE_CODEX_INSTALL", None)
                else:
                    os.environ["EMTROLY_FORCE_CODEX_INSTALL"] = prev_force
            if not c_info.get("installed"):
                raise RuntimeError("codex-cli-install-failed: Chưa cài đặt được gói @openai/codex. Kiểm tra kết nối Internet và thử lại.")
            results["codex"] = c_info
            if c_info.get("skipped"):
                results["skipped"].append("codex-cli")

    if "antigravity-ide" in ordered:
        if not force_reinstall and mod_status.get("antigravity_ide", {}).get("installed"):
            progress("✓ Antigravity IDE đã có sẵn trên máy — bỏ qua không cài lại.")
            results["antigravity_ide"] = {"installed": True, "skipped": True, "reason": "already-installed"}
            results["skipped"].append("antigravity-ide")
        else:
            progress("Phần 2 · Đang kiểm tra và cấu hình Antigravity IDE riêng...")
            ide_res = codex_setup.install_antigravity_ide_only(values_checked, home, progress=progress)
            results["antigravity_ide"] = ide_res
            if ide_res.get("skipped"):
                results["skipped"].append("antigravity-ide")

    if "codex-extension" in ordered:
        if not force_reinstall and mod_status.get("codex_extension", {}).get("installed"):
            progress("✓ Codex Extension đã có sẵn trên máy — bỏ qua không cài lại.")
            results["codex_extension"] = {"configured": True, "installed": True, "skipped": True, "reason": "already-installed"}
            results["skipped"].append("codex-extension")
        else:
            progress("Phần 3 · Đang kiểm tra/cài đặt Codex Extension trong Antigravity IDE...")
            ext_res = codex_setup.install_codex_extension_only(values_checked, home, progress=progress)
            results["codex_extension"] = ext_res
            if ext_res.get("skipped"):
                results["skipped"].append("codex-extension")

    if "openclaw" in ordered:
        if oc_already_installed:
            if oc_ver_info["needs_upgrade"]:
                oc_upg = upgrade_openclaw_runtime(existing_oc_root, home, source, progress=progress)
                results["openclaw"] = oc_upg
                results["root"] = oc_upg["root"]
            else:
                progress(f"✓ Trợ lý OpenClaw đã ở phiên bản mới nhất (v{oc_ver_info['installed_version']}) — bỏ qua không cài lại.")
                results["openclaw"] = {"root": str(existing_oc_root), "installed": True, "skipped": True, **oc_ver_info}
                results["skipped"].append("openclaw")
        else:
            oc_values = dict(values)
            oc_values["skip_editor"] = True
            oc_values["model"] = verified_model
            oc_res = install(oc_values, source, progress=progress)
            results["openclaw"] = oc_res
            results["root"] = oc_res["root"]
            results["cli"] = oc_res["cli"]

    return results
