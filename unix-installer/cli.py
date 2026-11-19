"""Interactive, per-user Ubuntu terminal installer."""

import argparse
import getpass
import os
from pathlib import Path
import platform
import sys
import warnings

import python_runtime
import runner
import service
import settings


DEFAULT_OWNERS = "8764883034,8342048167,6980864856,1828236146,8977732250"
DEFAULT_BASE_URL = "https://codex.anhlaptrinh.vn/v1"


ERROR_MESSAGES = {
    "invalid-member": "Tên instance phải bắt đầu bằng chữ thường và chỉ gồm chữ thường, số, - hoặc _.",
    "missing-assistant-name": "Vui lòng nhập tên trợ lý.",
    "invalid-owners": "Telegram owner ID phải là số dương, cách nhau bằng dấu phẩy.",
    "duplicate-owners": "Không nhập trùng Telegram owner ID.",
    "invalid-qr-owner": "Owner nhận QR phải nằm trong danh sách owner ID.",
    "invalid-group": "Telegram group ID phải là số âm.",
    "invalid-telegram-token": "Telegram bot token không đúng định dạng.",
    "missing-api-key": "Vui lòng nhập provider API key.",
    "invalid-model": "Model không được hỗ trợ.",
    "invalid-base-url": "Provider URL phải là HTTPS và không chứa thông tin đăng nhập.",
    "invalid-port": "Port phải là 0 hoặc nằm trong khoảng 1024–65000.",
    "full-access-consent-required": "Chưa đồng ý Full Exec; không cài trợ lý.",
}


def preflight(interactive):
    if platform.system() != "Linux":
        raise RuntimeError("Bộ cài terminal chỉ hỗ trợ Ubuntu Linux.")
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        raise RuntimeError("Không chạy bằng root hoặc sudo; hãy đăng nhập bằng user Ubuntu thường.")
    if interactive and (not sys.stdin.isatty() or not sys.stdout.isatty()):
        raise RuntimeError("Cần terminal tương tác để nhập thông tin an toàn.")
    try:
        service.check_linux_user_service()
    except RuntimeError:
        raise RuntimeError("Không có systemd user service. Đăng nhập SSH trực tiếp bằng user thường; "
                           "kiểm tra 'systemctl --user status'.") from None


def bootstrap_python():
    current = Path(sys.executable).resolve()
    if python_runtime._verify(current):
        return
    print("Đang chuẩn bị Python riêng phù hợp; không thay Python hệ thống.", flush=True)
    target = python_runtime.install(Path.home().resolve() / ".local/share/installer_emtroly/dependencies")
    if target.resolve() == current:
        raise RuntimeError("Python hiện tại không đáp ứng yêu cầu.")
    environment = dict(os.environ)
    environment["PATH"] = str(target.parent) + os.pathsep + environment.get("PATH", "")
    os.execve(str(target), [str(target), str(Path(__file__).resolve()), *sys.argv[1:]], environment)


def prompt(label, default=""):
    suffix = " [" + default + "]" if default else ""
    return input(label + suffix + ": ").strip() or default


def secret(label, visible=False):
    if visible:
        return input(label + " (hiển thị trên màn hình): ").strip()
    with warnings.catch_warnings():
        warnings.simplefilter("error", getpass.GetPassWarning)
        try:
            return getpass.getpass(label + ": ").strip()
        except getpass.GetPassWarning:
            raise RuntimeError("Không thể ẩn thông tin bí mật trên terminal này.") from None


def collect():
    print("\nCài Em Trợ Lý cho Ubuntu (bản thử nghiệm)")
    print("Cần Internet và một bot Telegram riêng. Không cần quét QR trong lúc cài.")
    values = {
        "member": prompt("Tên instance", "member01"),
        "assistant_name": prompt("Tên trợ lý", "Trợ lý"),
        "owner_ids": prompt("Telegram owner ID (thay đổi nếu cần)", DEFAULT_OWNERS),
    }
    values["owner_ids"] = ",".join(owner.strip() for owner in values["owner_ids"].split(","))
    first_owner = values["owner_ids"].split(",", 1)[0].strip()
    group_id = prompt("Telegram group ID (số âm)")
    print("Nếu chọn hiện, người khác hoặc ảnh chụp màn hình có thể thấy token và API key.")
    show_secrets = prompt("Hiện token và API key khi nhập? [y/N]", "N").lower() == "y"
    values.update({
        "qr_owner_id": first_owner,
        "group_id": group_id,
        "telegram_token": secret("Telegram bot token", visible=show_secrets),
        "base_url": DEFAULT_BASE_URL,
        "ai_api_key": secret("Provider API key", visible=show_secrets),
        "model": "gpt-6.1-sol",
        "gateway_port": "0",
        "audience": "",
        "addressing": "",
        "style": "",
    })
    if prompt("Tùy chỉnh nâng cao? [y/N]", "N").lower() == "y":
        values.update({
            "qr_owner_id": prompt("Owner ID nhận QR", first_owner),
            "base_url": prompt("Provider URL", DEFAULT_BASE_URL),
            "model": prompt("Model", values["model"]),
            "gateway_port": prompt("Gateway port (0 = tự động)", "0"),
            "audience": prompt("Đối tượng phục vụ (có thể bỏ trống)"),
            "addressing": prompt("Cách xưng hô (có thể bỏ trống)"),
            "style": prompt("Phong cách trả lời (có thể bỏ trống)"),
        })
    print("\nCác Telegram ID sẽ được cấp Full Exec: " + values["owner_ids"])
    print("Các ID này có thể chạy lệnh và truy cập tệp của user này, kể cả ID không phải của bạn.")
    print("Chỉ tiếp tục nếu bạn tin tưởng TẤT CẢ các ID; nhấn Ctrl+C và chạy lại để thay đổi.")
    values["accept_full_access"] = prompt("Nhập DONGY để cấp quyền cho các ID trên và bắt đầu") == "DONGY"
    return values


def safe_error(error, values):
    message = ERROR_MESSAGES.get(str(error), str(error))
    for name in ("telegram_token", "ai_api_key"):
        value = values.get(name, "")
        if value:
            message = message.replace(value, "[đã ẩn]")
    return message


def main(argv=None):
    parser = argparse.ArgumentParser(description="Cài Em Trợ Lý trên Ubuntu qua terminal.")
    parser.add_argument("--check", action="store_true", help="Chỉ kiểm tra điều kiện, không cài.")
    args = parser.parse_args(argv)
    values = {}
    try:
        preflight(interactive=not args.check)
        if args.check:
            print("Điều kiện user/systemd đạt. Chưa tải môi trường hoặc kiểm tra Telegram/provider.")
            return 0
        bootstrap_python()
        values = collect()
        settings.validate(values)
        source = Path(__file__).resolve().parent.parent
        result = runner.install(values, source, progress=lambda message: print(message, flush=True))
        print("\nCài đặt hoàn tất; không cần quét QR để hoàn tất cài đặt.")
        print("Thư mục: " + result["root"])
        print("Lệnh kiểm tra: " + result["cli"]["command"] + " status")
        print("Mở terminal mới nếu lệnh chưa có trong PATH. Trên Telegram dùng /zaloqr hoặc /zalostatus.")
        return 0
    except (EOFError, KeyboardInterrupt):
        print("\nĐã dừng. Nếu đã tạo instance, hãy kiểm tra trước khi cài lại.", file=sys.stderr)
    except (RuntimeError, ValueError, FileExistsError) as error:
        print("Chưa hoàn tất: " + safe_error(error, values), file=sys.stderr)
    except Exception:
        print("Chưa hoàn tất do lỗi môi trường. Kiểm tra instance trước khi thử lại.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
