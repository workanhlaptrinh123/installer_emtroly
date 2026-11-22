"""Orchestrate isolated installation steps; callers must provide a UI and consent."""

import importlib.util
import os
from pathlib import Path
import platform
import socket

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
import zalo_setup


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
        raise FileExistsError("Instance already exists; it was not changed")
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
    return {
        "root": str(root),
        "gateway_port": port,
        "cli": cli,
        "codex": codex_info,
        "editor": editor_info,
    }
