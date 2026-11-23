"""Desktop entry point for the official macOS and Linux installer (Em Trợ Lý)."""

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
import time


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
    try:
        import codex_setup

        found = codex_setup.find_codex_binary()
        if found:
            return found
    except Exception:
        pass
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


def find_installed_instance_root(preferred_member="emtroly"):
    home = Path.home()
    preferred = home / f".openclaw-member-{preferred_member}"
    if (preferred / "openclaw.json").is_file():
        return preferred
    for candidate in sorted(home.glob(".openclaw-member-*")):
        if (candidate / "openclaw.json").is_file():
            return candidate
    if (home / "openclaw/openclaw.json").is_file():
        return home / "openclaw"
    return None


def find_node_binary():
    home = Path.home()
    dep_root = home / ".local/share/installer_emtroly/dependencies"
    if dep_root.is_dir():
        for cand in sorted(dep_root.glob("node-v*/bin/node"), reverse=True):
            if cand.is_file() and os.access(cand, os.X_OK):
                return cand
    which_node = shutil.which("node")
    return Path(which_node) if which_node else None


def default_workspace_dir():
    inst = find_installed_instance_root()
    if inst:
        return str(inst)
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


def read_installer_version(source: Path) -> str:
    manifest = source / "MANIFEST.txt"
    if manifest.is_file():
        for line in manifest.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith("installer_version="):
                return line.split("=", 1)[1].strip()
    return "2026.11.22"


def main():
    import tkinter as tk
    from tkinter import filedialog, font as tkfont, messagebox, ttk

    import codex_setup
    import license_gate
    import provider
    import runner
    import settings
    import telegram
    import uninstaller

    source = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
    app_ver = read_installer_version(source)
    events = queue.Queue()
    codex_events = queue.Queue()
    qr_events = queue.Queue()

    window = tk.Tk()
    window.title(f"Em Trợ Lý v{app_ver} - Cài đặt, Zalo QR & Codex CLI")
    window.geometry("980x740")
    window.minsize(900, 710)
    window.configure(bg="#F1F5F9")

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
    style.configure("App.TFrame", background="#F1F5F9")
    style.configure("Card.TFrame", background="#FFFFFF")
    style.configure("Header.TFrame", background="#FFFFFF")
    style.configure("HeaderTitle.TLabel", font=font_title, foreground="#0F172A", background="#FFFFFF")
    style.configure("HeaderSub.TLabel", font=font_hint, foreground="#64748B", background="#FFFFFF")
    style.configure("Section.TLabel", font=font_section, foreground="#0F172A", background="#FFFFFF")
    style.configure("Hint.TLabel", font=font_hint, foreground="#475569", background="#F8FAFC")
    style.configure("BannerOk.TLabel", font=font_bold, foreground="#065F46", background="#ECFDF5")
    style.configure("StatusOk.TLabel", font=font_bold, foreground="#059669", background="#FFFFFF")
    style.configure("StatusWarn.TLabel", font=font_bold, foreground="#B45309", background="#FFFFFF")
    style.configure("TEntry", padding=(8, 6), fieldbackground="#FFFFFF", bordercolor="#CBD5E1")
    style.configure("TCombobox", padding=(8, 6), fieldbackground="#FFFFFF", bordercolor="#CBD5E1")
    style.configure("TNotebook", background="#F1F5F9", borderwidth=0)
    style.configure("TNotebook.Tab", font=font_bold, padding=(16, 9), background="#E2E8F0", foreground="#475569")
    style.map(
        "TNotebook.Tab",
        background=[("selected", "#FFFFFF"), ("active", "#EFF6FF")],
        foreground=[("selected", "#2563EB"), ("active", "#1D4ED8")],
    )
    style.configure("Primary.TButton", font=font_bold, foreground="#FFFFFF", background="#2563EB", padding=(16, 8))
    style.map("Primary.TButton", background=[("active", "#1D4ED8"), ("disabled", "#94A3B8")])
    style.configure("Secondary.TButton", font=font_regular, foreground="#1E293B", background="#F8FAFC", padding=(14, 7))

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
    subtitle_var = tk.StringVar(
        value=f"v{app_ver} (macOS & Linux) · Ưu tiên cài Codex CLI → Antigravity → OpenClaw & Zalo"
    )
    ttk.Label(header, textvariable=subtitle_var, style="HeaderSub.TLabel").grid(row=1, column=1, sticky="w", pady=(2, 0))

    notebook = ttk.Notebook(window)
    notebook.grid(row=1, column=0, sticky="nsew", padx=16, pady=(12, 16))

    tab_connect = ttk.Frame(notebook, style="Card.TFrame", padding=20)
    tab_profile = ttk.Frame(notebook, style="Card.TFrame", padding=20)
    tab_modular = ttk.Frame(notebook, style="Card.TFrame", padding=20)
    tab_zalo_qr = ttk.Frame(notebook, style="Card.TFrame", padding=20)
    tab_codex = ttk.Frame(notebook, style="Card.TFrame", padding=20)
    notebook.add(tab_connect, text="1. Kết nối & Bảo mật")
    notebook.add(tab_profile, text="2. Cài trọn gói A–Z")
    notebook.add(tab_modular, text="Cài từng phần")
    notebook.add(tab_zalo_qr, text="Quét QR Zalo")
    notebook.add(tab_codex, text="Codex CLI")

    header_actions = ttk.Frame(header, style="Header.TFrame")
    header_actions.grid(row=0, column=2, rowspan=2, sticky="e")

    quick_btn = ttk.Button(
        header_actions,
        text="Mở Codex CLI",
        style="Secondary.TButton",
        command=lambda: notebook.select(tab_connect if notebook.index("current") == 4 else tab_codex),
    )
    quick_btn.pack(side="left", padx=(0, 8))

    variables = {}
    secret_entries = []

    def add_fields(parent, title_text, field_specs):
        parent.columnconfigure(1, weight=1)
        ttk.Label(parent, text=title_text, style="Section.TLabel").grid(
            row=0, column=0, columnspan=3, sticky="w", pady=(0, 10)
        )
        for idx, (key, label, default, secret) in enumerate(field_specs, start=1):
            ttk.Label(parent, text=label).grid(row=idx, column=0, sticky="w", pady=4, padx=(0, 12))
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
                if secret:
                    secret_entries.append(widget)
            widget.grid(row=idx, column=1, sticky="ew", pady=4)
        return len(field_specs) + 1

    connect_fields = [
        ("member", "Tên định danh (chữ thường/số)", "emtroly", False),
        ("assistant_name", "Tên hiển thị trợ lý", "Trợ lý OpenClaw", False),
        ("telegram_token", "Telegram Bot Token", "", True),
        ("ai_api_key", "Provider API Key", "", True),
        ("owner_ids", "Telegram Owner IDs (dấu phẩy)", "", False),
        ("qr_owner_id", "Owner ID nhận QR Zalo", "", False),
        ("group_id", "Telegram Group ID (số âm)", "", False),
        ("base_url", "Địa chỉ Provider (HTTPS)", "https://codex.anhlaptrinh.vn/v1", False),
        ("model", "Mô hình AI (Model)", "gpt-6.2-sol", False),
        ("gateway_port", "Cổng Gateway (0 = tự động)", "0", False),
    ]
    next_row = add_fields(tab_connect, "1. Thông tin kết nối & mã bảo mật", connect_fields)

    live_banner_var = tk.StringVar(value="")

    def do_auto_fetch_ids():
        tok = telegram.normalize_token(variables["telegram_token"].get())
        if not tok:
            messagebox.showwarning("Thiếu Bot Token", "Hãy dán Telegram Bot Token trước rồi bấm Lấy ID tự động.")
            return
        variables["telegram_token"].set(tok)
        fetch_btn.state(["disabled"])
        live_banner_var.set("Đang đọc tin nhắn gần nhất từ Telegram Bot để lấy Owner ID & Group ID...")

        def _bg():
            try:
                info = telegram.fetch_ids_from_updates(tok)

                def _ok():
                    fetch_btn.state(["!disabled"])
                    if info["owner_id"]:
                        variables["owner_ids"].set(info["owner_id"])
                        if not variables["qr_owner_id"].get().strip():
                            variables["qr_owner_id"].set(info["owner_id"])
                    if info["group_id"]:
                        variables["group_id"].set(info["group_id"])
                    priv_note = (" " + info["privacy_warning"]) if info.get("privacy_warning") else ""
                    if info["owner_id"] or info["group_id"]:
                        live_banner_var.set(
                            f"✓ Bot {info['bot_username']}: Đã điền Owner={info['owner_id'] or '—'}, Group={info['group_id'] or '—'}.{priv_note}"
                        )
                    else:
                        live_banner_var.set(
                            f"Bot {info['bot_username']} hợp lệ nhưng chưa có tin nhắn mới — hãy nhắn /start cho bot rồi bấm lại.{priv_note}"
                        )

                window.after(0, _ok)
            except Exception as exc:
                window.after(
                    0,
                    lambda: (
                        fetch_btn.state(["!disabled"]),
                        live_banner_var.set("Không lấy được ID từ Telegram: " + strip_ansi(str(exc), tok)),
                    ),
                )

        threading.Thread(target=_bg, daemon=True).start()

    def do_test_connection():
        norm = settings.normalize({key: variable.get() for key, variable in variables.items()})
        tok = norm.get("telegram_token", "")
        key = norm.get("ai_api_key", "")
        url = norm.get("base_url", "")
        mdl = norm.get("model", "")
        if tok:
            variables["telegram_token"].set(tok)
        test_btn.state(["disabled"])
        live_banner_var.set("Đang kiểm tra kết nối Telegram Bot và máy chủ AI...")

        def _bg():
            try:
                me = telegram.verify_bot(tok)
                resolved_model = provider.verify(url, key, mdl)
                bot_u = ("@" + me["username"]) if isinstance(me, dict) and me.get("username") else "Bot hợp lệ"
                priv_note = telegram.privacy_warning(me)
                extra = f" · {priv_note}" if priv_note else ""
                window.after(
                    0,
                    lambda: (
                        test_btn.state(["!disabled"]),
                        live_banner_var.set(f"✓ Kết nối tốt! Telegram ({bot_u}) & Model ({resolved_model}) đều sẵn sàng.{extra}"),
                    ),
                )
            except Exception as exc:
                msg = codex_setup.scrub_secrets(str(exc), (tok, key))
                window.after(0, lambda: (test_btn.state(["!disabled"]), live_banner_var.set("! Kiểm tra chưa đạt: " + msg)))

        threading.Thread(target=_bg, daemon=True).start()

    fetch_btn = ttk.Button(tab_connect, text="Lấy ID tự động", style="Secondary.TButton", command=do_auto_fetch_ids)
    fetch_btn.grid(row=3, column=2, padx=(8, 0), pady=4, sticky="ew")
    test_btn = ttk.Button(tab_connect, text="Kiểm tra kết nối", style="Secondary.TButton", command=do_test_connection)
    test_btn.grid(row=4, column=2, padx=(8, 0), pady=4, sticky="ew")

    show_secret_var = tk.BooleanVar(value=False)

    def toggle_secrets():
        ch = "" if show_secret_var.get() else "*"
        for ent in secret_entries:
            ent.configure(show=ch)

    ctrl_bar = ttk.Frame(tab_connect, style="Card.TFrame")
    ctrl_bar.grid(row=next_row, column=0, columnspan=3, sticky="ew", pady=(8, 4))
    ttk.Checkbutton(ctrl_bar, text="Hiện mã bí mật", variable=show_secret_var, command=toggle_secrets).pack(side="left")

    def clear_saved_draft():
        license_gate.clear_saved_setup_draft()
        for k in ("telegram_token", "owner_ids", "qr_owner_id", "group_id", "audience", "addressing", "style"):
            variables[k].set("")
        live_banner_var.set("Đã xóa các thông số lưu nháp trên máy.")

    ttk.Button(ctrl_bar, text="Xóa thông số đã lưu", style="Secondary.TButton", command=clear_saved_draft).pack(
        side="left", padx=(12, 0)
    )
    ttk.Button(
        ctrl_bar,
        text="Tiếp theo →",
        style="Primary.TButton",
        command=lambda: notebook.select(tab_profile),
    ).pack(side="right")

    ttk.Label(tab_connect, textvariable=live_banner_var, style="Hint.TLabel", wraplength=740, padding=8).grid(
        row=next_row + 1, column=0, columnspan=3, sticky="ew", pady=(6, 0)
    )

    profile_fields = [
        ("audience", "Đối tượng phục vụ (tùy chọn)", "", False),
        ("addressing", "Cách xưng hô (tùy chọn)", "", False),
        ("style", "Phong cách trả lời (tùy chọn)", "", False),
    ]
    p_row = add_fields(tab_profile, "2. Tùy chọn cài đặt trọn gói A–Z & Bảo vệ tự sửa lỗi", profile_fields)

    ttk.Label(
        tab_profile,
        text="✓ Ưu tiên cài đặt Codex CLI → Antigravity IDE & Codex Extension trước tiên: nếu phát sinh sự cố khi cài môi trường hay OpenClaw/Zalo, Codex CLI sẽ tự động chẩn đoán và khắc phục ngay!",
        style="BannerOk.TLabel",
        wraplength=740,
        padding=10,
    ).grid(row=p_row, column=0, columnspan=3, sticky="ew", pady=(10, 6))

    zalo_var = tk.BooleanVar(value=True)
    ttk.Checkbutton(
        tab_profile,
        text="Cài đặt Zalo cá nhân & lệnh quét mã /zaloqr, /zalostatus (bỏ tích nếu không dùng Zalo).",
        variable=zalo_var,
    ).grid(row=p_row + 1, column=0, columnspan=3, sticky="w", pady=(4, 4))

    skip_editor_var = tk.BooleanVar(value=False)
    ttk.Checkbutton(
        tab_profile,
        text="Bỏ qua cấu hình Antigravity IDE (vẫn luôn cài đặt Codex CLI để tự sửa lỗi cài đặt).",
        variable=skip_editor_var,
    ).grid(row=p_row + 2, column=0, columnspan=3, sticky="w", pady=(2, 4))

    consent = tk.BooleanVar(value=False)
    ttk.Checkbutton(
        tab_profile,
        text="Tôi đồng ý cấp quyền Full Exec: Owner và nhóm Telegram đã chọn có thể đọc/sửa tệp và chạy lệnh.",
        variable=consent,
    ).grid(row=p_row + 3, column=0, columnspan=3, sticky="w", pady=(4, 8))

    status = tk.StringVar(
        value="Sẵn sàng cài đặt trọn gói từ A–Z (Codex CLI → Antigravity → OpenClaw & Zalo). Không cần quét QR trong lúc cài."
    )
    status_box = ttk.Label(tab_profile, textvariable=status, style="Hint.TLabel", wraplength=740, padding=12)
    status_box.grid(row=p_row + 4, column=0, columnspan=3, sticky="ew", pady=(6, 14))

    busy = False
    codex_busy = False
    codex_proc = None
    qr_proc = None
    qr_temp_dir = None
    qr_photo_ref = {"img": None, "mtime": 0.0}

    # =========================================================================
    # TAB 3: LIVE ZALO QR LOGIN (GUI + Simultaneous Telegram Owner Delivery)
    # =========================================================================
    tab_zalo_qr.columnconfigure(1, weight=1)
    ttk.Label(tab_zalo_qr, text="Quét mã QR đăng nhập Zalo cá nhân", style="Section.TLabel").grid(
        row=0, column=0, columnspan=2, sticky="w", pady=(0, 10)
    )
    qr_canvas_lbl = tk.Label(
        tab_zalo_qr,
        text="Bấm 'Tạo & Gửi mã QR Zalo'\nđể hiển thị mã QR tại đây\nvà gửi đồng thời qua Telegram",
        width=32,
        height=14,
        bg="#F8FAFC",
        fg="#475569",
        relief="solid",
        bd=1,
    )
    qr_canvas_lbl.grid(row=1, column=0, padx=(0, 18), pady=6, sticky="nw")

    qr_right = ttk.Frame(tab_zalo_qr, style="Card.TFrame")
    qr_right.grid(row=1, column=1, sticky="nsew", pady=6)
    qr_status_var = tk.StringVar(value="Chưa khởi tạo phiên quét mã QR.")
    qr_tg_var = tk.StringVar(value="Mã QR sẽ được tạo trực tiếp qua Gateway RPC (~5 giây) và gửi thẳng vào Telegram Owner.")
    ttk.Label(qr_right, textvariable=qr_status_var, font=font_bold, wraplength=440).pack(anchor="w", pady=(0, 8))
    ttk.Label(qr_right, textvariable=qr_tg_var, style="Hint.TLabel", wraplength=440, padding=10).pack(
        fill="x", pady=(0, 12)
    )
    ttk.Label(
        qr_right,
        text=(
            "Hướng dẫn:\n"
            "1. Mở ứng dụng Zalo trên điện thoại (hoặc mở ảnh gửi trong Telegram).\n"
            "2. Chọn biểu tượng Quét mã QR và bấm Đăng nhập.\n"
            "3. Phần mềm sẽ tự động xác nhận ngay khi kết nối thành công!"
        ),
        wraplength=440,
    ).pack(anchor="w", pady=(0, 14))

    def stop_qr_session():
        nonlocal qr_proc, qr_temp_dir
        if qr_proc and qr_proc.poll() is None:
            try:
                qr_proc.terminate()
            except OSError:
                pass
        qr_proc = None
        if qr_temp_dir and qr_temp_dir.exists():
            shutil.rmtree(qr_temp_dir, ignore_errors=True)
        qr_temp_dir = None

    def start_qr_session():
        nonlocal qr_proc, qr_temp_dir
        stop_qr_session()
        inst_root = find_installed_instance_root(variables["member"].get().strip() or "emtroly")
        if not inst_root:
            messagebox.showwarning("Chưa cài đặt", "Hãy hoàn tất cài đặt trợ lý OpenClaw trước khi quét QR Zalo.")
            return
        node_bin = find_node_binary()
        bridge_mjs = source / "windows-installer/zalo-qr-session.mjs"
        if not node_bin or not bridge_mjs.is_file():
            messagebox.showwarning("Thiếu thành phần", "Không tìm thấy Node.js hoặc công cụ tạo mã QR (zalo-qr-session.mjs).")
            return
        qr_temp_dir = Path(tempfile.mkdtemp(prefix="emtroly-unix-zaloqr-"))
        os.chmod(qr_temp_dir, 0o700)
        state_file = qr_temp_dir / "state.json"
        png_file = qr_temp_dir / "qr.png"
        qr_photo_ref["mtime"] = 0.0
        qr_canvas_lbl.configure(image="", text="Đang tạo mã QR Zalo (~5 giây)...")
        qr_status_var.set("Đang khởi tạo mã QR từ Gateway và gửi vào Telegram Owner...")

        owner_target = variables["qr_owner_id"].get().strip() or (
            variables["owner_ids"].get().split(",")[0].strip() if variables["owner_ids"].get().strip() else ""
        )
        cmd = [
            str(node_bin),
            str(bridge_mjs),
            "--root",
            str(inst_root),
            "--state-file",
            str(state_file),
            "--qr-out",
            str(png_file),
            "--force",
            "--timeout-seconds",
            "160",
        ]
        if re.fullmatch(r"[1-9][0-9]*", owner_target):
            cmd.extend(["--owner-id", owner_target])
        qr_proc = subprocess.Popen(cmd, cwd=str(inst_root), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        def _watch_qr(local_dir: Path, st_path: Path, img_path: Path, proc_ref: subprocess.Popen):
            while proc_ref.poll() is None and local_dir.exists():
                if st_path.is_file():
                    try:
                        st = json.loads(st_path.read_text(encoding="utf-8"))
                        qr_events.put(("state", (st, img_path)))
                        if st.get("connected") is True:
                            break
                    except Exception:
                        pass
                time.sleep(0.5)
            if st_path.is_file():
                try:
                    qr_events.put(("state", (json.loads(st_path.read_text(encoding="utf-8")), img_path)))
                except Exception:
                    pass
            qr_events.put(("done", proc_ref.returncode))

        threading.Thread(target=_watch_qr, args=(qr_temp_dir, state_file, png_file, qr_proc), daemon=True).start()

    qr_btns = ttk.Frame(qr_right, style="Card.TFrame")
    qr_btns.pack(anchor="w")
    ttk.Button(qr_btns, text="Tạo & Gửi mã QR Zalo", style="Primary.TButton", command=start_qr_session).pack(
        side="left", padx=(0, 8)
    )
    ttk.Button(qr_btns, text="Dừng phiên QR", style="Secondary.TButton", command=stop_qr_session).pack(side="left")

    # =========================================================================
    # TAB 4: CODEX CLI WORKSPACE & MANUAL AUTO-HEAL
    # =========================================================================
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
        text="Tự tìm & sửa lỗi",
        style="Secondary.TButton",
        command=lambda: set_preset(
            "Hãy kiểm tra toàn bộ cấu hình, trạng thái Gateway và plugin Zalo trong thư mục này; nếu có lỗi thì sửa trực tiếp và tóm tắt dễ hiểu."
        ),
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
            codex_status_var.set("○ Sẽ tự động cài Codex CLI ở Bước 2 khi bắt đầu cài đặt")
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
        api_key = variables["ai_api_key"].get().strip() or license_gate.get_saved_license_key()
        selected_model = variables["model"].get().strip()
        selected_url = variables["base_url"].get().strip().rstrip("/")

        def worker():
            nonlocal codex_proc
            temp_home = None
            try:
                env = dict(os.environ, NO_COLOR="1", PYTHONUTF8="1")
                node_b = find_node_binary()
                if node_b:
                    env["PATH"] = str(node_b.parent) + os.pathsep + env.get("PATH", "")
                for key in ("ELECTRON_RUN_AS_NODE", "VSCODE_IPC_HOOK_CLI", "NODE_OPTIONS", "VSCODE_DEV"):
                    env.pop(key, None)
                em_codex_home = codex_setup.codex_home_dir()
                if (em_codex_home / "auth.json").is_file() and (em_codex_home / "config.toml").is_file():
                    env["CODEX_HOME"] = str(em_codex_home)
                    env.pop("OPENAI_API_KEY", None)
                elif api_key:
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
        cur_idx = notebook.index("current")
        on_codex = cur_idx == 4
        quick_btn.configure(text="← Về phần Cài đặt" if on_codex else "Mở Codex CLI")
        if on_codex:
            refresh_codex_state()
        if cur_idx == 2:
            refresh_modular_status()

    notebook.bind("<<NotebookTabChanged>>", on_tab_changed)

    # =========================================================================
    # TAB MODULAR: MANUAL STEP-BY-STEP COMPONENT INSTALLATION
    # =========================================================================
    tab_modular.columnconfigure(1, weight=1)
    ttk.Label(
        tab_modular,
        text="Cài đặt từng phần thủ công (Chọn lẻ từng công cụ hoặc tích nhiều phần)",
        style="Section.TLabel",
    ).grid(row=0, column=0, columnspan=3, sticky="w", pady=(0, 4))
    ttk.Label(
        tab_modular,
        text="Phần 1, 2, 3 dùng trực tiếp Khóa bản quyền codex.anhlaptrinh.vn (không cần nhập Telegram). Phần 4 sử dụng thông tin Telegram ở Tab 1.",
        style="HeaderSub.TLabel",
        wraplength=760,
    ).grid(row=1, column=0, columnspan=3, sticky="w", pady=(0, 10))

    mod_checks = {
        "codex-cli": tk.BooleanVar(value=True),
        "antigravity-ide": tk.BooleanVar(value=False),
        "codex-extension": tk.BooleanVar(value=False),
        "openclaw": tk.BooleanVar(value=False),
    }
    mod_status_vars = {
        "codex-cli": tk.StringVar(value="Đang kiểm tra..."),
        "antigravity-ide": tk.StringVar(value="Đang kiểm tra..."),
        "codex-extension": tk.StringVar(value="Đang kiểm tra..."),
        "openclaw": tk.StringVar(value="Đang kiểm tra..."),
    }
    mod_specs = [
        ("codex-cli", "1. Codex CLI riêng (codex)", "Cài đặt và cấu hình lệnh codex chuẩn codex.anhlaptrinh.vn/v1 (~20 giây, không cần Telegram)."),
        ("antigravity-ide", "2. Antigravity IDE riêng", "Kiểm tra Antigravity IDE trên máy, gỡ quarantine macOS và tạo hồ sơ khởi chạy riêng."),
        ("codex-extension", "3. Codex Extension trong Antigravity", "Cài tiện ích openai.chatgpt vào Antigravity IDE riêng và tạo lối tắt EmTroLy - Antigravity."),
        ("openclaw", "4. Trợ lý OpenClaw riêng (+ Zalo tùy chọn)", "Cài Node.js, Python, FFmpeg, OpenClaw 2026.11.4 & Gateway (cần điền Telegram ở Tab 1)."),
    ]
    mod_single_btns = []

    def refresh_modular_status():
        try:
            st_map = codex_setup.get_modular_status(preferred_member=variables["member"].get().strip() or "emtroly")
            mapping = {
                "codex-cli": st_map["codex_cli"],
                "antigravity-ide": st_map["antigravity_ide"],
                "codex-extension": st_map["codex_extension"],
                "openclaw": st_map["openclaw"],
            }
            for comp_id, info in mapping.items():
                prefix = "✓ " if info["installed"] else "○ "
                mod_status_vars[comp_id].set(prefix + info["detail"])
        except Exception:
            pass

    def start_modular_components(selected_list):
        nonlocal busy
        if busy:
            return
        if not selected_list:
            messagebox.showwarning("Chưa chọn thành phần", "Hãy tích chọn ít nhất 1 thành phần để cài đặt.")
            return
        if "codex-extension" in selected_list and "antigravity-ide" not in selected_list:
            st_now = codex_setup.get_modular_status()
            if not st_now["antigravity_ide"]["installed"]:
                if messagebox.askyesno(
                    "Cần Antigravity IDE trước",
                    "Máy chưa cấu hình Antigravity IDE (Phần 2). Bạn có muốn kiểm tra/chuẩn bị Phần 2 trước rồi cài luôn Codex Extension không?",
                ):
                    selected_list = ["antigravity-ide", *selected_list]
                else:
                    return
        vals = collect_form_values()
        if not vals.get("ai_api_key"):
            vals["ai_api_key"] = license_gate.get_saved_license_key()
        if "openclaw" in selected_list and not consent.get():
            if not messagebox.askyesno(
                "Xác nhận Full Exec cho OpenClaw",
                "Cài đặt Phần 4 (OpenClaw) sẽ cấp quyền Full Exec cho các Owner & nhóm Telegram đã chọn. Bạn đồng ý tiếp tục?",
            ):
                return
            consent.set(True)
            vals["accept_full_access"] = True

        busy = True
        button.state(["disabled"])
        mod_run_selected_btn.state(["disabled"])
        for b_ref in mod_single_btns:
            b_ref.state(["disabled"])
        exit_btn.configure(text="Dừng & Thoát")
        mod_progress_var.set("Đang bắt đầu cài đặt thành phần: " + ", ".join(selected_list) + "...")

        def _mod_worker():
            try:
                res = runner.install_components(
                    selected_list,
                    vals,
                    source,
                    progress=lambda msg: events.put(("mod_progress", msg)),
                )
                events.put(("mod_success", res))
            except Exception as exc:
                err_txt = codex_setup.scrub_secrets(str(exc), (vals.get("telegram_token"), vals.get("ai_api_key")))
                events.put(("mod_failure", err_txt))

        threading.Thread(target=_mod_worker, daemon=True).start()

    for idx_m, (comp_key, comp_title, comp_desc) in enumerate(mod_specs, start=2):
        row_frame = tk.Frame(tab_modular, bg="#F8FAFC", bd=1, relief="solid", padx=12, pady=9)
        row_frame.grid(row=idx_m, column=0, columnspan=3, sticky="ew", pady=4)
        row_frame.columnconfigure(1, weight=1)
        ttk.Checkbutton(row_frame, variable=mod_checks[comp_key]).grid(row=0, column=0, rowspan=2, padx=(0, 10), sticky="nw")
        ttk.Label(row_frame, text=comp_title, font=font_bold, background="#F8FAFC").grid(row=0, column=1, sticky="w")
        ttk.Label(row_frame, textvariable=mod_status_vars[comp_key], font=font_hint, foreground="#1D4ED8", background="#F8FAFC").grid(
            row=0, column=2, padx=(8, 10), sticky="e"
        )
        ttk.Label(row_frame, text=comp_desc, font=font_hint, foreground="#475569", background="#F8FAFC", wraplength=540).grid(
            row=1, column=1, columnspan=2, sticky="w", pady=(2, 0)
        )
        single_b = ttk.Button(
            row_frame,
            text="Cài phần này",
            style="Secondary.TButton",
            command=lambda k=comp_key: start_modular_components([k]),
        )
        single_b.grid(row=0, column=3, rowspan=2, sticky="e")
        mod_single_btns.append(single_b)

    mod_progress_var = tk.StringVar(value="Mẹo: Tích chọn các phần bạn cần hoặc bấm 'Cài phần này' ở từng dòng.")
    ttk.Label(tab_modular, textvariable=mod_progress_var, style="Hint.TLabel", wraplength=760, padding=10).grid(
        row=6, column=0, columnspan=3, sticky="ew", pady=(8, 10)
    )
    mod_footer = ttk.Frame(tab_modular, style="Card.TFrame")
    mod_footer.grid(row=7, column=0, columnspan=3, sticky="ew")
    ttk.Button(mod_footer, text="Làm mới trạng thái", style="Secondary.TButton", command=refresh_modular_status).pack(side="left")
    mod_run_selected_btn = ttk.Button(
        mod_footer,
        text="Cài các phần đã tích chọn",
        style="Primary.TButton",
        command=lambda: start_modular_components([k for k, v in mod_checks.items() if v.get()]),
    )
    mod_run_selected_btn.pack(side="right")

    def collect_form_values():
        vals = {key: variable.get() for key, variable in variables.items()}
        vals["accept_full_access"] = consent.get()
        vals["configure_zalo"] = zalo_var.get()
        vals["skip_editor"] = skip_editor_var.get()
        vals = settings.normalize(vals)
        for key in ("member", "owner_ids", "group_id", "qr_owner_id", "gateway_port", "telegram_token"):
            if key in variables and isinstance(vals.get(key), str):
                variables[key].set(vals[key])
        return vals

    def persist_unix_draft():
        vals = collect_form_values()
        if any(
            vals.get(k, "").strip()
            for k in ("telegram_token", "owner_ids", "group_id", "qr_owner_id", "audience", "addressing", "style")
        ):
            try:
                license_gate.save_setup_draft(vals)
            except OSError:
                pass

    def close():
        persist_unix_draft()
        stop_qr_session()
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
        values = collect_form_values()
        try:
            license_gate.save_setup_draft(values)
        except OSError:
            pass
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
                events.put(("failure", codex_setup.scrub_secrets(message, (values.get("telegram_token"), values.get("ai_api_key")))))

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
                refresh_codex_state()
            elif kind == "mod_progress":
                mod_progress_var.set(value)
                status.set(value)
                refresh_codex_state()
            elif kind in ("mod_success", "mod_failure"):
                busy = False
                button.state(["!disabled"])
                mod_run_selected_btn.state(["!disabled"])
                for b_ref in mod_single_btns:
                    b_ref.state(["!disabled"])
                exit_btn.configure(text="Thoát")
                refresh_codex_state()
                refresh_modular_status()
                if kind == "mod_success":
                    done_names = ", ".join(value.get("components", []))
                    mod_progress_var.set(f"✓ Hoàn tất cài đặt thành phần: {done_names}!")
                    messagebox.showinfo("Hoàn tất cài từng phần", f"Đã cài đặt thành công: {done_names}!")
                else:
                    mod_progress_var.set("Chưa hoàn tất: " + value)
                    messagebox.showerror("Chưa hoàn tất", value)
            else:
                busy = False
                button.state(["!disabled"])
                mod_run_selected_btn.state(["!disabled"])
                for b_ref in mod_single_btns:
                    b_ref.state(["!disabled"])
                exit_btn.configure(text="Thoát")
                refresh_codex_state()
                if kind == "success":
                    variables["telegram_token"].set("")
                    command = value["cli"]["command"]
                    shell = value["cli"].get("shell_path", {})
                    if value["cli"]["path_present"]:
                        extra = ""
                    elif shell.get("updated") or shell.get("reason") == "already-configured":
                        extra = "\nMở terminal mới trước khi dùng lệnh."
                    else:
                        extra = "\nThêm thư mục " + value["cli"]["directory"] + " vào PATH trước khi dùng lệnh."
                    codex_dir_var.set(value["root"])
                    status.set("Hoàn tất cài đặt trọn gói! Chuyển sang tab 'Quét QR Zalo' nếu muốn kết nối Zalo ngay.")
                    messagebox.showinfo(
                        "Cài đặt hoàn tất",
                        "Đã cài đặt thành công Codex CLI, OpenClaw và Gateway!\nThư mục: "
                        + value["root"]
                        + "\nLệnh: "
                        + command
                        + " status"
                        + extra,
                    )
                    if zalo_var.get():
                        notebook.select(tab_zalo_qr)
                        start_qr_session()
                else:
                    status.set("Cài đặt chưa hoàn tất: " + value)
                    messagebox.showerror(
                        "Chưa hoàn tất",
                        value + "\nBạn có thể mở tab 'Codex CLI' để cho Codex kiểm tra và sửa tiếp.",
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
                    "\n"
                    + "-" * 56
                    + "\n"
                    + ("Hoàn tất yêu cầu Codex CLI thành công.\n" if cval == 0 else f"Codex CLI kết thúc với mã {cval}.\n")
                )
                refresh_codex_state()

        while True:
            try:
                qkind, qval = qr_events.get_nowait()
            except queue.Empty:
                break
            if qkind == "state":
                st, img_path = qval
                if st.get("message"):
                    qr_status_var.set(st["message"])
                if st.get("telegramNote"):
                    qr_tg_var.set(st["telegramNote"])
                if img_path.is_file():
                    try:
                        mt = img_path.stat().st_mtime
                        if mt != qr_photo_ref["mtime"] and img_path.stat().st_size > 64:
                            photo = tk.PhotoImage(file=str(img_path))
                            qr_photo_ref["img"] = photo
                            qr_photo_ref["mtime"] = mt
                            qr_canvas_lbl.configure(image=photo, text="", width=240, height=240)
                    except tk.TclError:
                        pass
                if st.get("connected") is True:
                    qr_canvas_lbl.configure(image="", text="✓ ĐÃ KẾT NỐI ZALO\nTRỰC TUYẾN!", fg="#065F46", bg="#ECFDF5")
                    stop_qr_session()
                    messagebox.showinfo("Đăng nhập Zalo thành công", "Trợ lý OpenClaw đã kết nối Zalo cá nhân thành công!")

        window.after(200, poll)

    def do_uninstall():
        if busy:
            return
        member_val = settings.clean_text(variables["member"].get()).lower() or "emtroly"
        if not messagebox.askyesno(
            "Xác nhận gỡ trợ lý cũ",
            f"Bạn có muốn dừng dịch vụ nền, sao lưu cấu hình và gỡ bỏ trợ lý '{member_val}' để cài lại từ đầu không?",
        ):
            return
        try:
            res = uninstaller.uninstall_instance(member_val)
            status.set(f"✓ Đã gỡ bỏ trợ lý '{member_val}' (đã sao lưu cấu hình tại {res['backup']}). Sẵn sàng cài mới!")
            messagebox.showinfo(
                "Đã gỡ cài đặt",
                f"Đã dừng dịch vụ và gỡ bỏ trợ lý '{member_val}' thành công.\nBản sao lưu cấu hình: {res['backup']}",
            )
        except FileNotFoundError:
            messagebox.showinfo("Chưa có trợ lý", f"Chưa tìm thấy trợ lý '{member_val}' trên máy — bạn có thể bấm Cài đặt ngay.")
        except Exception as exc:
            messagebox.showerror("Không thể gỡ cài đặt", str(exc))

    install_actions = ttk.Frame(tab_profile, style="Card.TFrame")
    install_actions.grid(row=p_row + 5, column=0, columnspan=3, sticky="ew")
    ttk.Button(
        install_actions,
        text="← Quay lại",
        style="Secondary.TButton",
        command=lambda: notebook.select(tab_connect),
    ).pack(side="left")
    exit_btn = ttk.Button(install_actions, text="Thoát", style="Secondary.TButton", command=close)
    exit_btn.pack(side="left", padx=(8, 0))
    ttk.Button(
        install_actions,
        text="Gỡ trợ lý cũ để cài lại",
        style="Secondary.TButton",
        command=do_uninstall,
    ).pack(side="left", padx=(8, 0))
    button = ttk.Button(install_actions, text="Cài đặt trọn gói A–Z", style="Primary.TButton", command=start)
    button.pack(side="right")

    # Restore previously entered form parameters (encrypted per-machine draft)
    saved_unix_draft = license_gate.get_saved_setup_draft()
    if isinstance(saved_unix_draft, dict):
        for key, variable in variables.items():
            val = saved_unix_draft.get(key)
            if isinstance(val, str) and val.strip():
                variable.set(val.strip())
        if "configure_zalo" in saved_unix_draft:
            zalo_var.set(bool(saved_unix_draft["configure_zalo"]))
        if "skip_editor" in saved_unix_draft:
            skip_editor_var.set(bool(saved_unix_draft["skip_editor"]))
        if "accept_full_access" in saved_unix_draft:
            consent.set(bool(saved_unix_draft["accept_full_access"]))
        status.set("✓ Đã tự động điền lại các thông số bạn đã nhập ở lần trước (lưu mã hóa an toàn trên máy).")

    # One-time per-machine license activation gate + Sign-out lock (matches Windows codex.anhlaptrinh.vn lock)
    saved_unix_key = license_gate.get_saved_license_key()
    license_overlay = tk.Frame(window, bg="#F3F6FB")
    card = tk.Frame(license_overlay, bg="#FFFFFF", bd=1, relief="solid", padx=28, pady=24)
    card.place(relx=0.5, rely=0.5, anchor="center", width=460)
    ttk.Label(card, text="Kích hoạt Em Trợ Lý", style="HeaderTitle.TLabel").pack(pady=(0, 6))
    ttk.Label(
        card,
        text="Nhập Provider API Key trên codex.anhlaptrinh.vn để mở khóa ứng dụng.",
        style="HeaderSub.TLabel",
        wraplength=400,
        justify="center",
    ).pack(pady=(0, 14))
    lic_var = tk.StringVar()
    lic_entry = ttk.Entry(card, textvariable=lic_var, show="*")
    lic_entry.pack(fill="x", pady=(0, 8))
    lic_msg = tk.StringVar(value="")
    ttk.Label(card, textvariable=lic_msg, foreground="#B91C1C", background="#FFFFFF", wraplength=400).pack(pady=(0, 10))
    lic_btns = ttk.Frame(card, style="Card.TFrame")
    lic_btns.pack(fill="x")

    def unlock_unix_app(verified_key: str, *, persist: bool = True):
        clean_k = (verified_key or "").strip()
        if clean_k:
            if persist:
                try:
                    license_gate.save_license_key(clean_k)
                except OSError:
                    pass
            if not variables["ai_api_key"].get().strip():
                variables["ai_api_key"].set(clean_k)
        lic_var.set("")
        lic_msg.set("")
        license_overlay.place_forget()
        signout_lic_btn.pack(side="left")

    def lock_and_sign_out_unix_license():
        if busy or codex_busy:
            messagebox.showwarning("Đang bận", "Hãy đợi tác vụ đang chạy hoàn tất trước khi thoát bản quyền.")
            return
        if not messagebox.askyesno(
            "Xác nhận thoát bản quyền",
            "Bạn có muốn thoát bản quyền trên giao diện ứng dụng không?\n\n"
            "(Các trợ lý OpenClaw / CLI đã cài trước đó vẫn chạy bình thường, nhưng bạn sẽ bắt buộc phải nhập lại Token codex.anhlaptrinh.vn để mở lại ứng dụng này.)",
        ):
            return
        license_gate.sign_out_license()
        variables["ai_api_key"].set("")
        lic_var.set("")
        lic_msg.set("Đã thoát bản quyền ứng dụng. Vui lòng nhập lại API Key trên codex.anhlaptrinh.vn để tiếp tục.")
        signout_lic_btn.pack_forget()
        license_overlay.place(relx=0, rely=0, relwidth=1, relheight=1)
        license_overlay.lift()
        lic_entry.focus_set()

    signout_lic_btn = ttk.Button(
        header_actions,
        text="Thoát bản quyền",
        style="Secondary.TButton",
        command=lock_and_sign_out_unix_license,
    )

    def do_activate():
        key_val = lic_var.get().strip()
        act_btn.state(["disabled"])
        lic_msg.set("Đang xác thực bản quyền với codex.anhlaptrinh.vn...")

        def _check():
            res = license_gate.verify_license_key(key_val)

            def _finish():
                act_btn.state(["!disabled"])
                if res["valid"]:
                    unlock_unix_app(key_val, persist=True)
                else:
                    lic_msg.set(res["message"])

            window.after(0, _finish)

        threading.Thread(target=_check, daemon=True).start()

    ttk.Button(lic_btns, text="Thoát", style="Secondary.TButton", command=window.destroy).pack(side="left")
    act_btn = ttk.Button(lic_btns, text="Kích hoạt & Mở khóa", style="Primary.TButton", command=do_activate)
    act_btn.pack(side="right")
    lic_entry.bind("<Return>", lambda _e: do_activate())

    if saved_unix_key:
        unlock_unix_app(saved_unix_key, persist=False)
    else:
        license_overlay.place(relx=0, rely=0, relwidth=1, relheight=1)
        license_overlay.lift()
        lic_entry.focus_set()

    refresh_modular_status()

    refresh_codex_state()
    window.protocol("WM_DELETE_WINDOW", close)
    window.after(200, poll)
    window.mainloop()


if __name__ == "__main__":
    main()
