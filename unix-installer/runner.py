"""Orchestrate isolated installation steps; callers must provide a UI and consent."""

import importlib.util
import os
from pathlib import Path
import platform
import socket

import dependencies
import ffmpeg
import instance
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
    port = choose_port(values_checked["gateway_port"])
    progress("Đang chuẩn bị Node.js riêng...")
    dependency_root = home / ".local/share/installer_emtroly/dependencies"
    node, npm = dependencies.install_node(dependency_root)
    progress("Đang chuẩn bị Python...")
    python_binary = python_runtime.install(dependency_root)
    progress("Đang chuẩn bị FFmpeg...")
    ffmpeg_binary = ffmpeg.install(dependency_root)
    progress("Đang tạo trợ lý riêng...")
    root = instance.initialize(values, home, port)
    progress("Đang cài OpenClaw, bước này có thể mất vài phút...")
    entry, env = runtime.install(root, home, node, npm, extra_bins=(python_binary.parent, ffmpeg_binary.parent))
    progress("Đang cài các skill...")
    payload.install(root, source)
    enable_zalo = values_checked.get("configure_zalo", True)
    progress("Đang cấu hình quyền Telegram và Zalo..." if enable_zalo else "Đang cấu hình quyền Telegram...")
    zalo_setup.configure(root, home, node, entry, env, values_checked["member"], values_checked["owner_ids"], source,
                         enable_zalo=enable_zalo)
    try:
        progress("Đang khởi động và kiểm tra Gateway...")
        service.install_and_verify(node, entry, env, port)
        if enable_zalo:
            progress("Đang đăng ký lệnh Telegram...")
            telegram.ensure_menu(values_checked["telegram_token"])
        helper_path = source / "native/install_unix_cli.py"
        spec = importlib.util.spec_from_file_location("installer_unix_cli", helper_path)
        if spec is None or spec.loader is None:
            raise RuntimeError("Unix command helper is missing")
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        cli = helper.install(root, home, node, entry, env["OPENCLAW_PROFILE"], runtime.OPENCLAW_VERSION,
                             (python_binary.parent, ffmpeg_binary.parent))
    except (OSError, ValueError, RuntimeError) as error:
        raise RuntimeError("Cài đặt chưa hoàn tất; Gateway có thể đã chạy. Không cài lại trước khi kiểm tra " +
                           str(root) + ". Chi tiết: " + str(error)) from None
    return {"root": str(root), "gateway_port": port, "cli": cli}
