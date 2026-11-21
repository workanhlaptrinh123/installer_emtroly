"""Desktop entry point for the experimental macOS and Ubuntu installer."""

import json
import os
from pathlib import Path
import queue
import re
import runpy
import shutil
import subprocess
import sys
import tempfile
import threading


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


ANSI_PATTERN = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]|\x1B\][^\x07]*(\x07|\x1B\\)")


def strip_ansi(text, secret=""):
    cleaned = ANSI_PATTERN.sub("", text or "")
    if secret and len(secret) >= 6:
        cleaned = cleaned.replace(secret, "[ĐÃ ẨN KHÓA BÍ MẬT]")
    return cleaned


def find_codex_binary():
    binary = shutil.which("codex")
    if binary:
        return Path(binary)
    home = Path.home()
    for base in (
        home / ".antigravity/extensions",
        home / ".vscode/extensions",
    ):
        if not base.is_dir():
            continue
        for candidate in sorted(base.glob("openai.chatgpt-*/bin/*/codex"), reverse=True):
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return candidate
    return None


def default_workspace_dir():
    home = Path.home()
    for candidate in sorted(home.glob(".openclaw-member-*")):
        if candidate.is_dir():
            return str(candidate)
    if (home / "openclaw").is_dir():
        return str(home / "openclaw")
    return str(home)


def pick_uniform_font_family(available_families):
    available = {name.lower(): name for name in available_families}
    for preferred in ("Segoe UI", "SF Pro Text", "Helvetica Neue", "Ubuntu", "Inter", "DejaVu Sans", "Arial"):
        match = available.get(preferred.lower())
        if match:
            return match
    return "TkDefaultFont"


def main():
    import tkinter as tk
    from tkinter import filedialog, font as tkfont, messagebox, ttk

    import runner

    source = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
    events = queue.Queue()
    codex_events = queue.Queue()

    window = tk.Tk()
    window.title("Em Trợ Lý - Cài đặt & Codex CLI")
    window.minsize(780, 680)
    window.configure(bg="#F3F6FB")

    family = pick_uniform_font_family(tkfont.families(window))
    font_title = (family, 15, "bold")
    font_section = (family, 11, "bold")
    font_bold = (family, 10, "bold")
    font_regular = (family, 10)
    font_hint = (family, 9)

    window.option_add("*Font", font_regular)
    style = ttk.Style(window)
    if "clam" in style.theme_names():
        style.theme_use("clam")

    style.configure(".", font=font_regular, foreground="#0F172A", background="#FFFFFF")
    style.configure("App.TFrame", background="#F3F6FB")
    style.configure("Card.TFrame", background="#FFFFFF")
    style.configure("Header.TFrame", background="#FFFFFF")
    style.configure("HeaderTitle.TLabel", font=font_title, foreground="#0F172A", background="#FFFFFF")
    style.configure("HeaderSub.TLabel", font=font_hint, foreground="#475569", background="#FFFFFF")
    style.configure("Section.TLabel", font=font_section, foreground="#0F172A", background="#FFFFFF")
    style.configure("Hint.TLabel", font=font_hint, foreground="#475569", background="#F8FAFC")
    style.configure("StatusOk.TLabel", font=font_bold, foreground="#059669", background="#FFFFFF")
    style.configure("StatusWarn.TLabel", font=font_bold, foreground="#B45309", background="#FFFFFF")
    style.configure("TNotebook", background="#F3F6FB", borderwidth=0)
    style.configure("TNotebook.Tab", font=font_bold, padding=(14, 8))
    style.configure("Primary.TButton", font=font_bold, foreground="#FFFFFF", background="#2563EB", padding=(14, 7))
    style.map("Primary.TButton", background=[("active", "#1D4ED8"), ("disabled", "#94A3B8")])
    style.configure("Secondary.TButton", font=font_regular, foreground="#0F172A", background="#F8FAFC", padding=(12, 6))

    window.columnconfigure(0, weight=1)
    window.rowconfigure(1, weight=1)

    header = ttk.Frame(window, style="Header.TFrame", padding=(22, 14))
    header.grid(row=0, column=0, sticky="ew")
    header.columnconfigure(1, weight=1)
    logo_img = None
    logo_file = source / "alt.png"
    if logo_file.is_file():
        try:
            raw_logo = tk.PhotoImage(file=str(logo_file))
            scale = max(1, round(raw_logo.height() / 46))
            logo_img = raw_logo.subsample(scale, scale)
            logo_lbl = tk.Label(header, image=logo_img, bg="#FFFFFF", bd=0, highlightthickness=0)
            logo_lbl.image = logo_img
            logo_lbl.grid(row=0, column=0, rowspan=2, sticky="w", padx=(0, 16))
            window.iconphoto(True, logo_img)
        except tk.TclError:
            logo_img = None

    ttk.Label(header, text="Em Trợ Lý", style="HeaderTitle.TLabel").grid(row=0, column=1, sticky="w")
    subtitle_var = tk.StringVar(value="Giao diện đơn giản, thân thiện · Cài đặt trợ lý và chỉnh sửa nhanh bằng Codex CLI")
    ttk.Label(header, textvariable=subtitle_var, style="HeaderSub.TLabel").grid(row=1, column=1, sticky="w", pady=(2, 0))

    notebook = ttk.Notebook(window)
    notebook.grid(row=1, column=0, sticky="nsew", padx=16, pady=(12, 16))

    tab_connect = ttk.Frame(notebook, style="Card.TFrame", padding=22)
    tab_profile = ttk.Frame(notebook, style="Card.TFrame", padding=22)
    tab_codex = ttk.Frame(notebook, style="Card.TFrame", padding=22)
    notebook.add(tab_connect, text="1. Kết nối & Bảo mật")
    notebook.add(tab_profile, text="2. Hồ sơ & Cài đặt")
    notebook.add(tab_codex, text="Codex CLI")

    quick_btn = ttk.Button(
        header,
        text="Mở Codex CLI",
        style="Secondary.TButton",
        command=lambda: notebook.select(tab_connect if notebook.index("current") == 2 else tab_codex),
    )
    quick_btn.grid(row=0, column=2, rowspan=2, sticky="e")

    variables = {}

    def add_fields(parent, title_text, field_specs):
        parent.columnconfigure(1, weight=1)
        ttk.Label(parent, text=title_text, style="Section.TLabel").grid(
            row=0, column=0, columnspan=2, sticky="w", pady=(0, 12)
        )
        for idx, (key, label, default, secret) in enumerate(field_specs, start=1):
            ttk.Label(parent, text=label).grid(row=idx, column=0, sticky="w", pady=5, padx=(0, 14))
            variable = tk.StringVar(value=default)
            variables[key] = variable
            if key == "model":
                widget = ttk.Combobox(
                    parent,
                    textvariable=variable,
                    state="readonly",
                    values=("gpt-6.2-sol", "GPT-6.1-terra", "gpt-6.2-astra"),
                )
            else:
                widget = ttk.Entry(parent, textvariable=variable, show="*" if secret else "")
            widget.grid(row=idx, column=1, sticky="ew", pady=5)
        return len(field_specs) + 1

    connect_fields = [
        ("member", "Tên định danh (chữ thường/số)", "member01", False),
        ("assistant_name", "Tên hiển thị trợ lý", "Trợ lý", False),
        ("owner_ids", "Telegram Owner IDs (dấu phẩy)", "", False),
        ("qr_owner_id", "Owner ID nhận QR Zalo", "", False),
        ("group_id", "Telegram Group ID (số âm)", "", False),
        ("telegram_token", "Telegram Bot Token", "", True),
        ("base_url", "Địa chỉ Provider (HTTPS)", "https://codex.anhlaptrinh.vn/v1", False),
        ("ai_api_key", "Provider API Key", "", True),
        ("model", "Mô hình AI (Model)", "gpt-6.2-sol", False),
        ("gateway_port", "Cổng Gateway (0 = tự động)", "0", False),
    ]
    next_row = add_fields(tab_connect, "Thông tin kết nối & mã bảo mật", connect_fields)
    ttk.Button(
        tab_connect,
        text="Tiếp theo →",
        style="Primary.TButton",
        command=lambda: notebook.select(tab_profile),
    ).grid(row=next_row, column=1, sticky="e", pady=(16, 0))

    profile_fields = [
        ("audience", "Đối tượng phục vụ (tùy chọn)", "", False),
        ("addressing", "Cách xưng hô (tùy chọn)", "", False),
        ("style", "Phong cách trả lời (tùy chọn)", "", False),
    ]
    p_row = add_fields(tab_profile, "Phong cách giao tiếp & xác nhận cài đặt", profile_fields)
    zalo_var = tk.BooleanVar(value=True)
    ttk.Checkbutton(
        tab_profile,
        text="Tích chọn để cài thêm Zalo cá nhân và lệnh quét mã /zaloqr (bỏ tích nếu không cần).",
        variable=zalo_var,
    ).grid(row=p_row, column=0, columnspan=2, sticky="w", pady=(12, 4))
    consent = tk.BooleanVar(value=False)
    ttk.Checkbutton(
        tab_profile,
        text="Tôi đồng ý cấp quyền Full Exec: Owner và nhóm đã chọn có thể đọc/sửa tệp và chạy lệnh.",
        variable=consent,
    ).grid(row=p_row + 1, column=0, columnspan=2, sticky="w", pady=(6, 8))

    status = tk.StringVar(value="Sẵn sàng cài đặt trọn gói từ A–Z. Cần kết nối Internet; không cần quét mã QR trong lúc cài.")
    status_box = ttk.Label(tab_profile, textvariable=status, style="Hint.TLabel", wraplength=700, padding=12)
    status_box.grid(row=p_row + 2, column=0, columnspan=2, sticky="ew", pady=(6, 14))

    busy = False
    codex_busy = False
    codex_proc = None

    # Giao diện Codex CLI chỉnh sửa trực tiếp
    tab_codex.columnconfigure(1, weight=1)
    tab_codex.rowconfigure(6, weight=1)

    ttk.Label(tab_codex, text="Ra lệnh & chỉnh sửa nhanh bằng Codex CLI", style="Section.TLabel").grid(
        row=0, column=0, sticky="w", pady=(0, 10)
    )
    codex_status_var = tk.StringVar()
    codex_status_lbl = ttk.Label(tab_codex, textvariable=codex_status_var, style="StatusOk.TLabel")
    codex_status_lbl.grid(row=0, column=1, columnspan=2, sticky="e", pady=(0, 10))

    ttk.Label(tab_codex, text="Thư mục cần sửa:").grid(row=1, column=0, sticky="w", padx=(0, 10), pady=4)
    codex_dir_var = tk.StringVar(value=default_workspace_dir())
    ttk.Entry(tab_codex, textvariable=codex_dir_var).grid(row=1, column=1, sticky="ew", pady=4)

    def choose_codex_dir():
        chosen = filedialog.askdirectory(initialdir=codex_dir_var.get() or str(Path.home()))
        if chosen:
            codex_dir_var.set(chosen)

    ttk.Button(tab_codex, text="Chọn thư mục...", style="Secondary.TButton", command=choose_codex_dir).grid(
        row=1, column=2, sticky="e", padx=(8, 0), pady=4
    )

    preset_frame = ttk.Frame(tab_codex, style="Card.TFrame")
    preset_frame.grid(row=2, column=0, columnspan=3, sticky="ew", pady=(6, 6))
    ttk.Label(preset_frame, text="Gợi ý nhanh:").pack(side="left", padx=(0, 8))

    prompt_text = tk.Text(
        tab_codex,
        height=4,
        font=font_regular,
        bg="#FFFFFF",
        fg="#0F172A",
        relief="solid",
        bd=1,
        padx=8,
        pady=6,
        wrap="word",
    )

    def set_preset(template):
        prompt_text.delete("1.0", "end")
        prompt_text.insert("1.0", template)
        prompt_text.focus_set()

    ttk.Button(
        preset_frame,
        text="Sửa cấu hình trợ lý",
        style="Secondary.TButton",
        command=lambda: set_preset("Hãy kiểm tra và chỉnh sửa cấu hình trong thư mục này theo yêu cầu: "),
    ).pack(side="left", padx=(0, 6))
    ttk.Button(
        preset_frame,
        text="Sửa nội dung / kỹ năng",
        style="Secondary.TButton",
        command=lambda: set_preset("Hãy chỉnh sửa nội dung hướng dẫn / kỹ năng theo yêu cầu sau: "),
    ).pack(side="left", padx=(0, 6))
    ttk.Button(
        preset_frame,
        text="Kiểm tra & tự sửa lỗi",
        style="Secondary.TButton",
        command=lambda: set_preset("Hãy kiểm tra các tệp trong thư mục này, sửa lỗi nếu có và tóm tắt dễ hiểu."),
    ).pack(side="left")

    ttk.Label(tab_codex, text="Nhập yêu cầu chỉnh sửa (bằng tiếng Việt tự nhiên):", font=font_bold).grid(
        row=3, column=0, columnspan=3, sticky="w", pady=(6, 4)
    )
    prompt_text.grid(row=4, column=0, columnspan=3, sticky="ew")

    action_bar = ttk.Frame(tab_codex, style="Card.TFrame")
    action_bar.grid(row=5, column=0, columnspan=3, sticky="ew", pady=(10, 8))
    allow_write_var = tk.BooleanVar(value=True)
    ttk.Checkbutton(
        action_bar,
        text="Cho phép Codex tự động sửa tệp trong thư mục này",
        variable=allow_write_var,
    ).pack(side="left")

    output_text = tk.Text(
        tab_codex,
        height=9,
        font=font_regular,
        bg="#F8FAFC",
        fg="#0F172A",
        relief="solid",
        bd=1,
        padx=10,
        pady=8,
        wrap="word",
        state="normal",
    )
    guide_message = (
        "Hướng dẫn sử dụng đơn giản:\n"
        "1. Chọn thư mục bạn muốn chỉnh sửa.\n"
        "2. Nhập yêu cầu bằng tiếng Việt ở ô phía trên.\n"
        "3. Bấm 'Thực hiện bằng Codex' để Codex CLI tự động đọc và sửa tệp giúp bạn.\n"
    )
    output_text.insert("1.0", guide_message)
    output_text.configure(state="disabled")
    output_text.grid(row=6, column=0, columnspan=3, sticky="nsew", pady=(4, 0))

    def append_codex_output(text):
        output_text.configure(state="normal")
        output_text.insert("end", text)
        output_text.see("end")
        output_text.configure(state="disabled")

    def clear_codex_output(initial=""):
        output_text.configure(state="normal")
        output_text.delete("1.0", "end")
        if initial:
            output_text.insert("1.0", initial)
        output_text.configure(state="disabled")

    def refresh_codex_state():
        found = find_codex_binary()
        if found:
            codex_status_var.set("● Sẵn sàng · Codex CLI")
            codex_status_lbl.configure(style="StatusOk.TLabel")
            if not codex_busy:
                run_codex_btn.state(["!disabled"])
        else:
            codex_status_var.set("○ Chưa tìm thấy lệnh codex trên máy")
            codex_status_lbl.configure(style="StatusWarn.TLabel")
            run_codex_btn.state(["disabled"])
        stop_codex_btn.state(["!disabled"] if codex_busy else ["disabled"])
        return found

    def stop_codex():
        nonlocal codex_proc
        if codex_proc and codex_proc.poll() is None:
            try:
                codex_proc.terminate()
            except OSError:
                pass

    def run_codex():
        nonlocal codex_busy, codex_proc
        if codex_busy:
            return
        binary = refresh_codex_state()
        if not binary:
            messagebox.showwarning("Thiếu Codex CLI", "Chưa tìm thấy Codex CLI trên máy.")
            return
        workspace = Path(codex_dir_var.get().strip()).expanduser()
        if not workspace.is_dir():
            messagebox.showwarning("Thư mục không hợp lệ", "Hãy chọn thư mục cần chỉnh sửa hợp lệ.")
            return
        prompt_value = prompt_text.get("1.0", "end").strip()
        if not prompt_value:
            messagebox.showwarning("Thiếu yêu cầu", "Hãy nhập nội dung bạn muốn Codex thực hiện.")
            return

        codex_busy = True
        clear_codex_output(f"Đang gửi yêu cầu tới Codex CLI...\nThư mục: {workspace}\n" + "-" * 56 + "\n")
        refresh_codex_state()
        allow_write = allow_write_var.get()
        api_key = variables["ai_api_key"].get().strip()
        selected_model = variables["model"].get().strip()
        selected_url = variables["base_url"].get().strip().rstrip("/")

        def worker():
            nonlocal codex_proc
            temp_home = None
            try:
                env = dict(os.environ, NO_COLOR="1", PYTHONUTF8="1")
                for key in ("ELECTRON_RUN_AS_NODE", "VSCODE_IPC_HOOK_CLI", "NODE_OPTIONS", "VSCODE_DEV"):
                    env.pop(key, None)
                default_home = Path.home() / ".codex"
                if not default_home.is_dir() and api_key:
                    temp_home = Path(tempfile.mkdtemp(prefix="emtroly-codex-"))
                    os.chmod(temp_home, 0o700)
                    (temp_home / "config.toml").write_text(
                        f'model_provider = "router"\nmodel = "{selected_model or "gpt-6.2-sol"}"\n'
                        'model_context_window = 272000\nmodel_auto_compact_token_limit = 200000\n'
                        'cli_auth_credentials_store = "file"\n\n'
                        '[model_providers.router]\nname = "router"\n'
                        f'base_url = "{selected_url or "https://codex.anhlaptrinh.vn/v1"}"\n'
                        'wire_api = "responses"\nrequires_openai_auth = true\n',
                        encoding="utf-8",
                    )
                    (temp_home / "auth.json").write_text(
                        json.dumps({"OPENAI_API_KEY": api_key}),
                        encoding="utf-8",
                    )
                    env["CODEX_HOME"] = str(temp_home)
                    env.pop("OPENAI_API_KEY", None)

                sandbox = "workspace-write" if allow_write else "read-only"
                cmd = [
                    str(binary),
                    "exec",
                    "--skip-git-repo-check",
                    "--color",
                    "never",
                    "--sandbox",
                    sandbox,
                    "-C",
                    str(workspace),
                    "-",
                ]
                codex_proc = subprocess.Popen(
                    cmd,
                    cwd=str(workspace),
                    env=env,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                )
                assert codex_proc.stdin is not None
                codex_proc.stdin.write(prompt_value + "\n")
                codex_proc.stdin.close()
                assert codex_proc.stdout is not None
                for line in codex_proc.stdout:
                    codex_events.put(("line", strip_ansi(line, api_key)))
                code = codex_proc.wait()
                codex_events.put(("done", code))
            except Exception as exc:
                codex_events.put(("line", f"\nKhông thể chạy Codex CLI: {strip_ansi(str(exc), api_key)}\n"))
                codex_events.put(("done", 1))
            finally:
                codex_proc = None
                if temp_home and temp_home.exists():
                    shutil.rmtree(temp_home, ignore_errors=True)

        threading.Thread(target=worker, daemon=True).start()

    ttk.Button(
        action_bar,
        text="Xóa kết quả",
        style="Secondary.TButton",
        command=lambda: clear_codex_output(guide_message),
    ).pack(side="right")
    stop_codex_btn = ttk.Button(action_bar, text="Dừng", style="Secondary.TButton", command=stop_codex)
    stop_codex_btn.pack(side="right", padx=(6, 6))
    run_codex_btn = ttk.Button(action_bar, text="Thực hiện bằng Codex", style="Primary.TButton", command=run_codex)
    run_codex_btn.pack(side="right")

    def on_tab_changed(_event=None):
        on_codex = notebook.index("current") == 2
        quick_btn.configure(text="← Về phần Cài đặt" if on_codex else "Mở Codex CLI")
        if on_codex:
            refresh_codex_state()

    notebook.bind("<<NotebookTabChanged>>", on_tab_changed)

    def close():
        if busy:
            if not messagebox.askyesno(
                "Xác nhận dừng và thoát",
                "Tiến trình đang chạy. Bạn có muốn dừng ngay tiến trình này và thoát giao diện không?",
            ):
                return
            stop_codex()
            window.destroy()
            os._exit(2)
        if codex_busy:
            if not messagebox.askyesno(
                "Xác nhận dừng và thoát",
                "Codex CLI đang thực hiện yêu cầu. Bạn có muốn dừng lệnh và thoát giao diện không?",
            ):
                return
            stop_codex()
        window.destroy()

    def start():
        nonlocal busy
        if busy:
            return
        values = {key: variable.get() for key, variable in variables.items()}
        values["accept_full_access"] = consent.get()
        values["configure_zalo"] = zalo_var.get()
        busy = True
        button.state(["disabled"])
        exit_btn.configure(text="Dừng & Thoát")

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
                    "linux-user-service-unavailable": "Không kết nối được dịch vụ systemd của người dùng. Hãy đăng nhập vào Ubuntu Desktop bằng tài khoản người dùng và thử lại; không chạy bằng sudo.",
                }
                message = (
                    messages.get(str(error), str(error))
                    if isinstance(error, (ValueError, RuntimeError, FileExistsError))
                    else "Lỗi không xác định. Kiểm tra môi trường và thử lại."
                )
                events.put(("failure", message))

        threading.Thread(target=work, daemon=True).start()

    def poll():
        nonlocal busy, codex_busy
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
                exit_btn.configure(text="Thoát")
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
                    codex_dir_var.set(value["root"])
                    status.set("Cài đặt hoàn tất. Đăng nhập Zalo sau bằng /zaloqr.")
                    messagebox.showinfo(
                        "Thành công",
                        "Gateway và lệnh Zalo đã được kiểm tra.\nThư mục: "
                        + value["root"]
                        + "\nLệnh: "
                        + command
                        + " status"
                        + extra,
                    )
                else:
                    status.set("Cài đặt chưa hoàn tất; không xóa thư mục đã tạo.")
                    messagebox.showerror(
                        "Chưa hoàn tất",
                        value + "\nNếu thư mục instance đã được tạo, kiểm tra trước khi thử lại.",
                    )

        while True:
            try:
                ckind, cval = codex_events.get_nowait()
            except queue.Empty:
                break
            if ckind == "line":
                append_codex_output(cval)
            elif ckind == "done":
                codex_busy = False
                append_codex_output(
                    "\n" + "-" * 56 + "\n"
                    + (
                        "Hoàn tất yêu cầu Codex CLI thành công.\n"
                        if cval == 0
                        else f"Codex CLI kết thúc với mã {cval}.\n"
                    )
                )
                refresh_codex_state()

        window.after(200, poll)

    install_actions = ttk.Frame(tab_profile, style="Card.TFrame")
    install_actions.grid(row=p_row + 3, column=0, columnspan=2, sticky="ew")
    ttk.Button(
        install_actions,
        text="← Quay lại",
        style="Secondary.TButton",
        command=lambda: notebook.select(tab_connect),
    ).pack(side="left")
    exit_btn = ttk.Button(install_actions, text="Thoát", style="Secondary.TButton", command=close)
    exit_btn.pack(side="left", padx=(8, 0))
    button = ttk.Button(install_actions, text="Bắt đầu cài đặt", style="Primary.TButton", command=start)
    button.pack(side="right")

    refresh_codex_state()
    window.protocol("WM_DELETE_WINDOW", close)
    window.after(200, poll)
    window.mainloop()


if __name__ == "__main__":
    main()
