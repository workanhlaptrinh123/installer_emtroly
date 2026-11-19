"""Desktop entry point for the experimental macOS and Ubuntu installer."""

from pathlib import Path
import os
import runpy
import sys


def run_helper():
    from python_exec import restore_library_path

    restore_library_path(os.environ)
    script = Path(sys.argv[2]).resolve(strict=True)
    sys.argv = [str(script), *sys.argv[3:]]
    sys.path.insert(0, str(script.parent))
    runpy.run_path(str(script), run_name="__main__")


if __name__ == "__main__" and len(sys.argv) > 2 and sys.argv[1] == "--run-python-script":
    run_helper()
    raise SystemExit(0)


def main():
    import queue
    import threading
    import tkinter as tk
    from tkinter import messagebox, ttk

    import runner

    source = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
    events = queue.Queue()
    window = tk.Tk()
    window.title("Em Trợ Lý - macOS / Ubuntu")
    window.minsize(620, 650)
    frame = ttk.Frame(window, padding=20)
    frame.grid(sticky="nsew")
    window.columnconfigure(0, weight=1)
    window.rowconfigure(0, weight=1)
    frame.columnconfigure(1, weight=1)
    ttk.Label(frame, text="Cài đặt trợ lý", font=("TkDefaultFont", 18, "bold")).grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 10))
    fields = [
        ("member", "Tên instance", "member01", False),
        ("assistant_name", "Tên trợ lý", "Trợ lý", False),
        ("owner_ids", "Telegram owner ID (cách nhau bởi dấu phẩy)", "", False),
        ("qr_owner_id", "Owner ID nhận QR", "", False),
        ("group_id", "Telegram group ID (số âm)", "", False),
        ("telegram_token", "Telegram bot token", "", True),
        ("base_url", "Provider URL", "https://codex.anhlaptrinh.vn/v1", False),
        ("ai_api_key", "Provider API key", "", True),
        ("model", "Model", "gpt-6.1-sol", False),
        ("gateway_port", "Gateway port (0 = tự động)", "0", False),
        ("audience", "Đối tượng phục vụ", "", False),
        ("addressing", "Cách xưng hô", "", False),
        ("style", "Phong cách trả lời", "", False),
    ]
    variables = {}
    for row, (key, label, default, secret) in enumerate(fields, start=1):
        ttk.Label(frame, text=label).grid(row=row, column=0, sticky="w", pady=3, padx=(0, 12))
        variable = tk.StringVar(value=default)
        variables[key] = variable
        if key == "model":
            widget = ttk.Combobox(frame, textvariable=variable, state="readonly",
                                  values=("gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-astra"))
        else:
            widget = ttk.Entry(frame, textvariable=variable, show="*" if secret else "")
        widget.grid(row=row, column=1, sticky="ew", pady=3)
    consent = tk.BooleanVar(value=False)
    ttk.Checkbutton(frame, text="Tôi đồng ý cấp Full Exec: owner có thể điều khiển tệp và lệnh máy tính.",
                    variable=consent).grid(row=14, column=0, columnspan=2, sticky="w", pady=(12, 4))
    status = tk.StringVar(value="Cần Internet. Không cần quét QR trong lúc cài.")
    ttk.Label(frame, textvariable=status, wraplength=570).grid(row=15, column=0, columnspan=2, sticky="w", pady=8)
    busy = False

    def close():
        if not busy:
            window.destroy()
        else:
            messagebox.showinfo("Đang cài đặt", "Vui lòng đợi bước cài đặt hoàn tất.")

    def start():
        nonlocal busy
        if busy:
            return
        values = {key: variable.get() for key, variable in variables.items()}
        values["accept_full_access"] = consent.get()
        busy = True
        button.state(["disabled"])

        def work():
            try:
                result = runner.install(values, source, progress=lambda text: events.put(("progress", text)))
                events.put(("success", result))
            except Exception as error:
                messages = {
                    "invalid-member": "Tên instance phải gồm chữ thường, số, dấu gạch ngang hoặc gạch dưới.",
                    "missing-assistant-name": "Vui lòng nhập tên trợ lý.",
                    "invalid-owners": "Telegram owner ID phải là số dương, cách nhau bằng dấu phẩy.",
                    "duplicate-owners": "Không nhập trùng Telegram owner ID.",
                    "invalid-group": "Telegram group ID phải là số âm.",
                    "invalid-telegram-token": "Telegram bot token không đúng định dạng.",
                    "missing-api-key": "Vui lòng nhập provider API key.",
                    "invalid-model": "Model không được hỗ trợ.",
                    "invalid-base-url": "Provider URL phải là HTTPS và không chứa thông tin đăng nhập.",
                    "invalid-port": "Port phải là 0 hoặc nằm trong khoảng 1024–65000.",
                    "full-access-consent-required": "Cần xác nhận quyền Full Exec trước khi cài.",
                    "invalid-qr-owner": "Owner nhận QR phải nằm trong danh sách owner ID.",
                }
                message = messages.get(str(error), str(error)) if isinstance(error, (ValueError, RuntimeError, FileExistsError)) else "Lỗi không xác định. Kiểm tra môi trường và thử lại."
                events.put(("failure", message))

        threading.Thread(target=work, daemon=True).start()

    def poll():
        nonlocal busy
        while True:
            try:
                kind, value = events.get_nowait()
            except queue.Empty:
                break
            if kind == "progress":
                status.set(value)
            else:
                busy = False
                button.state(["!disabled"])
                variables["telegram_token"].set("")
                variables["ai_api_key"].set("")
                if kind == "success":
                    command = value["cli"]["command"]
                    shell = value["cli"].get("shell_path", {})
                    if value["cli"]["path_present"]:
                        extra = ""
                    elif shell.get("updated") or shell.get("reason") == "already-configured":
                        extra = "\nMở terminal mới trước khi dùng lệnh."
                    else:
                        extra = "\nThêm thư mục " + value["cli"]["directory"] + " vào PATH trước khi dùng lệnh."
                    status.set("Cài đặt hoàn tất. Đăng nhập Zalo sau bằng /zaloqr.")
                    messagebox.showinfo("Thành công", "Gateway và lệnh Zalo đã được kiểm tra.\nThư mục: " + value["root"] +
                                        "\nLệnh: " + command + " status" + extra)
                else:
                    status.set("Cài đặt chưa hoàn tất; không xóa thư mục đã tạo.")
                    messagebox.showerror("Chưa hoàn tất", value + "\nNếu thư mục instance đã được tạo, kiểm tra trước khi thử lại.")
        window.after(200, poll)

    button = ttk.Button(frame, text="Bắt đầu cài đặt", command=start)
    button.grid(row=16, column=0, columnspan=2, sticky="e")
    window.protocol("WM_DELETE_WINDOW", close)
    window.after(200, poll)
    window.mainloop()


if __name__ == "__main__":
    main()
