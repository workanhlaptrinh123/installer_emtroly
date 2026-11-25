#!/usr/bin/env python3
"""Zero-dependency local Team Git Studio (Visual 3-Step Workflow App) for installer_emtroly.

Starts a localhost-only web UI (default http://127.0.0.1:8765) featuring:
- Auto-detection of active Gmail / Git email -> automatic personal branch prefix
- Step 1 (Morning): 1-click "Lay code moi nhat ve" (sync)
- Step 2 (Done coding): Auto-branch from Gmail -> check safety & conflict -> push -> Auto-PR -> Auto-Merge on Approve
- Conflict Advisor panel with 1-click AI resolution prompt copy
- Live interactive SVG branch & commit graph + Team Activity ("Ai dang lam gi?")
"""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import socket
import subprocess
import sys
import urllib.parse
import webbrowser

SCRIPT_DIR = Path(__file__).resolve().parent
TEAM_GIT_PY = SCRIPT_DIR / "team_git.py"
ROOT = SCRIPT_DIR.parents[3]
REPO_WEB_URL = "https://github.com/workanhlaptrinh123/installer_emtroly"


def run_cmd(cmd: list[str]) -> tuple[int, str]:
    proc = subprocess.run(
        cmd,
        cwd=str(ROOT),
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=False,
    )
    out = (proc.stdout or "") + (("\n" + proc.stderr) if proc.stderr else "")
    return proc.returncode, out.strip()


def run_git(*args: str) -> tuple[int, str]:
    return run_cmd(["git", *args])


def get_identity() -> tuple[str, str, str]:
    _, name = run_git("config", "user.name")
    _, email = run_git("config", "user.email")
    raw = ""
    if email and "@" in email:
        local_part = email.split("@", 1)[0]
        if "+" in local_part and email.lower().endswith("users.noreply.github.com"):
            local_part = local_part.split("+", 1)[1]
        raw = local_part
    if not raw:
        raw = name
    prefix = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-") or "dev"
    return name or "(chưa đặt tên)", email or "(chưa đặt email)", prefix


def collect_state(do_fetch: bool = False) -> dict:
    if do_fetch:
        run_git("fetch", "origin", "--prune")

    _, current_branch = run_git("rev-parse", "--abbrev-ref", "HEAD")
    git_user, git_email, branch_prefix = get_identity()

    _, counts_raw = run_git("rev-list", "--left-right", "--count", "origin/main...HEAD")
    counts = counts_raw.split()
    behind = int(counts[0]) if len(counts) == 2 and counts[0].isdigit() else 0
    ahead = int(counts[1]) if len(counts) == 2 and counts[1].isdigit() else 0

    _, dirty_raw = run_git("status", "--porcelain")
    dirty_files = []
    for line in dirty_raw.splitlines():
        if len(line) >= 4:
            dirty_files.append({"status": line[:2].strip() or "M", "path": line[3:].strip()})

    fmt_ref = "%(refname:short)|%(authorname)|%(committerdate:relative)|%(subject)"
    _, remote_raw = run_git("for-each-ref", "--sort=-committerdate", f"--format={fmt_ref}", "refs/remotes/origin")
    remote_branches = []
    for line in remote_raw.splitlines():
        parts = line.split("|", 3)
        if len(parts) != 4:
            continue
        ref_name, author, rel_time, subject = parts
        if ref_name in ("origin", "origin/HEAD", "origin/main"):
            continue
        short_name = ref_name.removeprefix("origin/")
        remote_branches.append({
            "ref": ref_name,
            "name": short_name,
            "author": author,
            "rel_time": rel_time,
            "subject": subject,
            "is_current": short_name == current_branch,
        })

    _, tags_raw = run_git("tag", "-l", "--sort=-v:refname")
    tags = [t.strip() for t in tags_raw.splitlines() if t.strip()][:8]

    sep = "\x1f"
    log_fmt = sep.join(["%H", "%h", "%P", "%D", "%an", "%cr", "%s"])
    _, log_raw = run_git("log", "--all", "--topo-order", "-n", "24", f"--format={log_fmt}")
    commits = []
    for line in log_raw.splitlines():
        parts = line.split(sep)
        if len(parts) != 7:
            continue
        full_h, short_h, parents_s, refs_s, author, rel_time, subject = parts
        refs = [r.strip() for r in refs_s.split(",") if r.strip()] if refs_s.strip() else []
        commits.append({
            "hash": full_h,
            "short": short_h,
            "parents": [p for p in parents_s.split() if p],
            "refs": refs,
            "author": author,
            "rel_time": rel_time,
            "subject": subject,
        })

    return {
        "repo_name": ROOT.name,
        "repo_url": REPO_WEB_URL,
        "current_branch": current_branch,
        "git_user": git_user,
        "git_email": git_email,
        "branch_prefix": branch_prefix,
        "ahead": ahead,
        "behind": behind,
        "dirty_files": dirty_files,
        "remote_branches": remote_branches,
        "tags": tags,
        "commits": commits,
    }


HTML_PAGE = r"""<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Team Git Studio — installer_emtroly</title>
  <style>
    :root {
      --bg: #0b1120;
      --panel: #131c31;
      --panel-2: #0f172a;
      --border: #26344d;
      --text: #f1f5f9;
      --muted: #94a3b8;
      --primary: #3b82f6;
      --primary-hover: #2563eb;
      --success: #22c55e;
      --success-bg: rgba(34, 197, 94, 0.14);
      --warning: #f59e0b;
      --warning-bg: rgba(245, 158, 11, 0.14);
      --danger: #ef4444;
      --danger-bg: rgba(239, 68, 68, 0.14);
      --lane-0: #38bdf8;
      --lane-1: #a78bfa;
      --lane-2: #34d399;
      --lane-3: #fbbf24;
      --lane-4: #f472b6;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: var(--bg);
      color: var(--text);
      font-size: 14px;
      line-height: 1.45;
    }
    header {
      position: sticky;
      top: 0;
      z-index: 20;
      background: rgba(11, 17, 32, 0.94);
      backdrop-filter: blur(10px);
      border-bottom: 1px solid var(--border);
      padding: 12px 22px;
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
    }
    .brand { display: flex; align-items: center; gap: 10px; font-weight: 700; font-size: 16px; }
    .identity-bar {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 8px;
    }
    .pill {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 4px 10px; border-radius: 999px; font-size: 12px; font-weight: 600;
      background: var(--panel); border: 1px solid var(--border); color: var(--text);
    }
    .pill.ok { border-color: rgba(34,197,94,0.5); color: #4ade80; background: var(--success-bg); }
    .pill.info { border-color: rgba(56,189,248,0.5); color: #38bdf8; background: rgba(56,189,248,0.12); }
    .pill.warn { border-color: rgba(245,158,11,0.55); color: #fbbf24; background: var(--warning-bg); }
    main {
      max-width: 1320px;
      margin: 0 auto;
      padding: 18px 22px 40px;
      display: grid;
      grid-template-columns: 400px 1fr;
      gap: 20px;
    }
    @media (max-width: 980px) { main { grid-template-columns: 1fr; } }
    .col { display: flex; flex-direction: column; gap: 16px; min-width: 0; }
    .card {
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 16px;
    }
    .step-card {
      position: relative;
      border-left: 3px solid var(--primary);
    }
    .step-card.s1 { border-left-color: #38bdf8; }
    .step-card.s2 { border-left-color: #22c55e; }
    .step-card.s3 { border-left-color: #a78bfa; }
    .card-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      margin-bottom: 10px;
    }
    .step-title {
      font-size: 14px;
      font-weight: 700;
      color: var(--text);
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .step-num {
      display: inline-flex; align-items: center; justify-content: center;
      width: 22px; height: 22px; border-radius: 6px;
      font-size: 12px; font-weight: 800;
      background: rgba(59,130,246,0.2); color: #60a5fa;
    }
    .s1 .step-num { background: rgba(56,189,248,0.2); color: #38bdf8; }
    .s2 .step-num { background: rgba(34,197,94,0.2); color: #4ade80; }
    .s3 .step-num { background: rgba(167,139,250,0.2); color: #c4b5fd; }
    .section-label {
      margin: 0 0 10px;
      font-size: 12px;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: var(--muted);
      display: flex;
      align-items: center;
      justify-content: space-between;
    }
    .stack { display: flex; flex-direction: column; gap: 9px; }
    .row { display: flex; gap: 8px; align-items: center; }
    input[type="text"] {
      width: 100%;
      padding: 9px 11px;
      border-radius: 9px;
      border: 1px solid var(--border);
      background: var(--panel-2);
      color: var(--text);
      font-size: 13px;
      outline: none;
    }
    input[type="text"]:focus { border-color: var(--primary); }
    button {
      padding: 9px 13px;
      border-radius: 9px;
      border: 1px solid var(--border);
      background: var(--panel-2);
      color: var(--text);
      font-size: 13px;
      font-weight: 600;
      cursor: pointer;
      transition: 0.15s ease;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 6px;
    }
    button:hover:not(:disabled) { border-color: var(--primary); background: #1a2742; }
    button.big { width: 100%; padding: 11px 14px; font-size: 14px; }
    button.btn-sync { background: #0284c7; border-color: #0ea5e9; color: #fff; }
    button.btn-sync:hover:not(:disabled) { background: #0369a1; }
    button.btn-pr { background: #16a34a; border-color: #22c55e; color: #fff; }
    button.btn-pr:hover:not(:disabled) { background: #15803d; }
    button.btn-approve { background: #7c3aed; border-color: #8b5cf6; color: #fff; }
    button.btn-approve:hover:not(:disabled) { background: #6d28d9; }
    button:disabled { opacity: 0.5; cursor: not-allowed; }
    .hint { font-size: 12px; color: var(--muted); }
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 12px; }
    .preview-chip {
      padding: 7px 10px;
      border-radius: 8px;
      background: var(--panel-2);
      border: 1px dashed var(--border);
      font-size: 12px;
      color: var(--muted);
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 6px;
    }
    .conflict-box {
      display: none;
      padding: 12px;
      border-radius: 10px;
      background: var(--danger-bg);
      border: 1px solid rgba(239, 68, 68, 0.5);
    }
    .conflict-box.show { display: flex; flex-direction: column; gap: 8px; }
    .list-item {
      padding: 8px 10px;
      border-radius: 9px;
      background: var(--panel-2);
      border: 1px solid transparent;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      font-size: 13px;
    }
    .list-item:hover { border-color: var(--border); }
    .badge {
      display: inline-block;
      padding: 1px 7px;
      border-radius: 6px;
      font-size: 11px;
      font-weight: 600;
      margin-right: 4px;
    }
    .badge.head { background: var(--success-bg); color: #4ade80; border: 1px solid rgba(34,197,94,0.45); }
    .badge.branch { background: rgba(56,189,248,0.16); color: #38bdf8; border: 1px solid rgba(56,189,248,0.4); }
    .badge.tag { background: var(--warning-bg); color: #fbbf24; border: 1px solid rgba(251,191,36,0.4); }
    .graph-wrap {
      overflow-x: auto;
      background: var(--panel-2);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 6px 0;
    }
    .commit-row {
      display: flex;
      align-items: center;
      height: 36px;
      padding-right: 14px;
      border-bottom: 1px solid rgba(38, 52, 77, 0.45);
    }
    .commit-row:last-child { border-bottom: none; }
    .commit-row:hover { background: rgba(59, 130, 246, 0.08); }
    .commit-meta { display: flex; align-items: center; gap: 6px; flex: 1; min-width: 0; overflow: hidden; }
    .commit-subject { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-weight: 500; }
    .commit-right { display: flex; align-items: center; gap: 10px; margin-left: 10px; flex-shrink: 0; font-size: 12px; color: var(--muted); }
    .two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
    @media (max-width: 720px) { .two-col { grid-template-columns: 1fr; } }
    pre#log-box {
      margin: 0;
      padding: 10px 12px;
      background: #070c18;
      border: 1px solid var(--border);
      border-radius: 9px;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 12px;
      max-height: 170px;
      overflow: auto;
      white-space: pre-wrap;
      word-break: break-word;
      color: #cbd5e1;
    }
    .status-ok { color: #4ade80; font-weight: 600; }
    .status-err { color: #f87171; font-weight: 600; }
    .file-tag { font-weight: 700; width: 22px; display: inline-block; color: #fbbf24; }
    a { color: inherit; text-decoration: none; }
  </style>
</head>
<body>
  <header>
    <div class="brand">
      <span>⚡ Team Git Studio</span>
      <span id="hdr-branch" class="pill">...</span>
      <span id="hdr-sync" class="pill">...</span>
    </div>
    <div class="identity-bar">
      <span id="hdr-gmail" class="pill info" title="Tự nhận diện từ Git Email">📧 ...</span>
      <button onclick="loadState(true)">🔄 Làm mới</button>
    </div>
  </header>

  <main>
    <!-- LEFT: 3-STEP DAILY WORKFLOW -->
    <div class="col">
      <!-- STEP 1 -->
      <div class="card step-card s1">
        <div class="card-head">
          <div class="step-title"><span class="step-num">1</span> Đầu ngày — Lấy code mới nhất</div>
          <span id="sync-badge" class="hint"></span>
        </div>
        <div class="stack">
          <div class="hint">Tự kéo code mới nhất từ <b>origin/main</b> về máy an toàn (tự bảo vệ file đang sửa dở nếu có).</div>
          <button class="big btn-sync" onclick="doSync()">📥 Lấy code mới nhất về</button>
        </div>
      </div>

      <!-- STEP 2 -->
      <div class="card step-card s2">
        <div class="card-head">
          <div class="step-title"><span class="step-num">2</span> Code xong — Tự tạo nhánh & Đẩy PR</div>
        </div>
        <div class="stack">
          <div class="preview-chip">
            <span>Tự nhận diện Gmail → nhánh:</span>
            <strong id="branch-preview" class="mono" style="color:#4ade80">...</strong>
          </div>
          <input id="inp-slug" type="text" placeholder="Tên đầu việc ngắn (tùy chọn, vd: fix-zalo-qr)" oninput="updatePreview()" />
          <input id="inp-msg" type="text" placeholder="Mô tả thay đổi (bắt buộc), vd: fix(zalo): sửa lỗi QR" />
          <button class="big btn-pr" onclick="doAutoPR()">🚀 Đẩy code lên (Tự tạo nhánh → Check → Tạo PR)</button>
          <button onclick="doCheckMerge()">🛡️ Chỉ kiểm tra an toàn & Conflict trước</button>

          <!-- Conflict Advisor -->
          <div id="conflict-box" class="conflict-box">
            <div style="font-weight:700;color:#fca5a5">⚠️ Phát hiện Conflict với main — Đã chặn không đè code!</div>
            <div id="conflict-files" class="mono" style="color:#fecaca;font-size:12px"></div>
            <div class="hint" style="color:#fecaca">Để sửa conflict tối ưu (giữ đúng cả code anh & sếp), bấm copy lệnh dưới và gửi cho AI:</div>
            <button onclick="copyConflictPrompt()">📋 Copy lệnh nhờ AI xử lý Conflict tối ưu</button>
          </div>
        </div>
      </div>

      <!-- STEP 3 -->
      <div class="card step-card s3">
        <div class="card-head">
          <div class="step-title"><span class="step-num">3</span> Kiểm tra PR & Bấm Merge</div>
        </div>
        <div class="stack">
          <div class="hint">GitHub đã tự kiểm tra & mở PR sẵn. Anh vào xem đèn <b>Xanh ✅</b> rồi bấm <b>Squash and merge</b> để gộp vào <b>main</b> (nhánh tạm tự xóa).</div>
          <a id="btn-pr-link" href="#" target="_blank">
            <button class="big btn-approve" type="button">✅ Mở danh sách PR trên GitHub để Merge ↗</button>
          </a>
        </div>
      </div>
    </div>

    <!-- RIGHT: LIVE VISUAL GRAPH & TEAM STATUS -->
    <div class="col">
      <div class="card">
        <div class="section-label">
          <span>Sơ đồ nhánh trực quan (Live Git Graph)</span>
          <span id="latest-tags" class="hint"></span>
        </div>
        <div class="graph-wrap" id="graph-container"></div>
      </div>

      <div class="two-col">
        <div class="card">
          <div class="section-label">
            <span>Ai đang làm gì? (Nhánh mở)</span>
            <span id="team-count" class="hint"></span>
          </div>
          <div id="team-branches" class="stack"></div>
        </div>

        <div class="card">
          <div class="section-label">
            <span>File đang sửa trên máy</span>
            <span id="dirty-count" class="hint"></span>
          </div>
          <div id="dirty-list" class="stack"></div>
        </div>
      </div>

      <div class="card">
        <div class="section-label">
          <span>Nhật ký hệ thống</span>
          <span id="log-status" class="hint">Sẵn sàng</span>
        </div>
        <pre id="log-box">Chào anh! Làm đúng 3 bước bên trái: (1) Đầu ngày bấm Lấy mới nhất → (2) Code xong bấm Đẩy code lên → (3) Duyệt PR để tự merge.</pre>
      </div>
    </div>
  </main>

  <script>
    const LANE_COLORS = ["#38bdf8", "#a78bfa", "#34d399", "#fbbf24", "#f472b6", "#fb7185"];
    let stateData = null;
    let lastConflictText = "";

    function setBusy(v, msg) {
      document.querySelectorAll("button").forEach(b => b.disabled = v);
      const st = document.getElementById("log-status");
      st.textContent = msg || (v ? "Đang xử lý..." : "Sẵn sàng");
      st.className = "hint";
    }

    function showLog(text, ok = true) {
      document.getElementById("log-box").textContent = text || "(không có output)";
      const st = document.getElementById("log-status");
      st.textContent = ok ? "✓ Thành công" : "✕ Cần xử lý";
      st.className = ok ? "status-ok" : "status-err";

      const cBox = document.getElementById("conflict-box");
      if (!ok && /CONFLICT/i.test(text || "")) {
        lastConflictText = text;
        document.getElementById("conflict-files").textContent = text.split("\n").filter(l => /CONFLICT|^\s*-/.test(l)).join("\n") || text;
        cBox.classList.add("show");
      } else if (ok) {
        cBox.classList.remove("show");
      }
    }

    function esc(s) {
      return String(s || "").replace(/[&<>"']/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c]));
    }

    function slugify(s) {
      return (s || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40);
    }

    function updatePreview() {
      if (!stateData) return;
      const el = document.getElementById("branch-preview");
      if (stateData.current_branch !== "main") {
        el.textContent = stateData.current_branch + " (đang ở nhánh riêng)";
        return;
      }
      const slug = slugify(document.getElementById("inp-slug").value);
      el.textContent = `${stateData.branch_prefix}/${slug || "work-<tự-động>"}`;
    }

    async function loadState(doFetch = false) {
      setBusy(true, doFetch ? "Đang đồng bộ từ GitHub..." : "Đang tải...");
      try {
        const res = await fetch(`/api/state?fetch=${doFetch ? 1 : 0}`);
        stateData = await res.json();
        renderState(stateData);
        if (doFetch) showLog("Đã cập nhật trạng thái mới nhất từ GitHub.", true);
      } catch (err) {
        showLog("Lỗi kết nối Team Git Studio: " + err, false);
      } finally {
        setBusy(false);
      }
    }

    function renderState(d) {
      const bEl = document.getElementById("hdr-branch");
      bEl.textContent = `🌿 ${d.current_branch}`;
      bEl.className = "pill " + (d.current_branch === "main" ? "ok" : "info");

      const sEl = document.getElementById("hdr-sync");
      sEl.textContent = d.behind > 0 ? `↓ Có ${d.behind} commit mới cần kéo` : `✓ Đã đồng bộ mới nhất`;
      sEl.className = "pill " + (d.behind > 0 ? "warn" : "ok");

      document.getElementById("sync-badge").textContent = d.behind > 0 ? `Cần kéo ${d.behind} commit` : "Đã mới nhất ✓";
      document.getElementById("hdr-gmail").textContent = `📧 ${d.git_email} (${d.branch_prefix})`;
      document.getElementById("btn-pr-link").href = `${d.repo_url}/pulls`;
      updatePreview();

      // Team remote branches
      const tb = document.getElementById("team-branches");
      document.getElementById("team-count").textContent = `${d.remote_branches.length} nhánh`;
      if (!d.remote_branches.length) {
        tb.innerHTML = `<div class="hint">Không có nhánh dở dang — mọi thứ đã gộp sạch vào <b>main</b> ✅</div>`;
      } else {
        tb.innerHTML = d.remote_branches.map(b => `
          <div class="list-item">
            <div style="min-width:0">
              <div class="mono" style="color:#38bdf8;font-weight:600">${esc(b.name)}</div>
              <div class="hint">${esc(b.author)} · ${esc(b.rel_time)}</div>
            </div>
            ${b.is_current
              ? `<span class="badge head">Đang mở</span>`
              : `<button onclick="doCheckout('${esc(b.name)}')">Chuyển</button>`}
          </div>
        `).join("");
      }

      // Dirty files
      const dl = document.getElementById("dirty-list");
      document.getElementById("dirty-count").textContent = `${d.dirty_files.length} file`;
      if (!d.dirty_files.length) {
        dl.innerHTML = `<div class="hint">Thư mục sạch — chưa có thay đổi nào chưa lưu.</div>`;
      } else {
        dl.innerHTML = d.dirty_files.slice(0, 10).map(f => `
          <div class="list-item mono">
            <div style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">
              <span class="file-tag">${esc(f.status)}</span>${esc(f.path)}
            </div>
          </div>
        `).join("") + (d.dirty_files.length > 10 ? `<div class="hint">... và ${d.dirty_files.length - 10} file khác</div>` : "");
      }

      document.getElementById("latest-tags").textContent = d.tags.length ? `Release mới nhất: ${d.tags[0]}` : "";
      renderGraph(d.commits);
    }

    function renderGraph(commits) {
      const wrap = document.getElementById("graph-container");
      if (!commits.length) { wrap.innerHTML = `<div class="hint" style="padding:12px">Chưa có commit nào.</div>`; return; }

      const lanes = [];
      const rowData = [];
      let maxLanes = 1;

      for (let i = 0; i < commits.length; i++) {
        const c = commits[i];
        let lane = lanes.indexOf(c.hash);
        if (lane === -1) {
          lane = lanes.indexOf(null);
          if (lane === -1) { lane = lanes.length; lanes.push(c.hash); }
          else { lanes[lane] = c.hash; }
        }
        const activeBefore = lanes.slice();
        const parentLanes = [];
        if (c.parents.length === 0) {
          lanes[lane] = null;
        } else {
          lanes[lane] = c.parents[0];
          parentLanes.push(lane);
          for (let p = 1; p < c.parents.length; p++) {
            const ph = c.parents[p];
            let pl = lanes.indexOf(ph);
            if (pl === -1) {
              pl = lanes.indexOf(null);
              if (pl === -1) { pl = lanes.length; lanes.push(ph); }
              else { lanes[pl] = ph; }
            }
            parentLanes.push(pl);
          }
        }
        for (let k = 0; k < lanes.length; k++) {
          if (lanes[k] && lanes.indexOf(lanes[k]) !== k) lanes[k] = null;
        }
        maxLanes = Math.max(maxLanes, lanes.length, lane + 1);
        rowData.push({ c, lane, parentLanes, activeBefore, activeAfter: lanes.slice() });
      }

      const rowH = 36, colW = 18;
      const svgW = Math.max(54, maxLanes * colW + 18);
      const svgH = commits.length * rowH;

      let svgParts = [];
      rowData.forEach((r, idx) => {
        const y = idx * rowH + rowH / 2;
        const x = 14 + r.lane * colW;
        const color = LANE_COLORS[r.lane % LANE_COLORS.length];

        r.activeAfter.forEach((h, lIdx) => {
          if (!h || lIdx === r.lane) return;
          const lx = 14 + lIdx * colW;
          const lc = LANE_COLORS[lIdx % LANE_COLORS.length];
          if (r.activeBefore[lIdx] === h) {
            svgParts.push(`<line x1="${lx}" y1="${idx * rowH}" x2="${lx}" y2="${(idx + 1) * rowH}" stroke="${lc}" stroke-width="2" opacity="0.65"/>`);
          }
        });
        if (idx > 0 && r.activeBefore[r.lane] === r.c.hash) {
          svgParts.push(`<line x1="${x}" y1="${idx * rowH}" x2="${x}" y2="${y}" stroke="${color}" stroke-width="2.2"/>`);
        }
        r.parentLanes.forEach(pl => {
          const px = 14 + pl * colW;
          const pc = LANE_COLORS[pl % LANE_COLORS.length];
          if (pl === r.lane) {
            svgParts.push(`<line x1="${x}" y1="${y}" x2="${px}" y2="${(idx + 1) * rowH}" stroke="${color}" stroke-width="2.2"/>`);
          } else {
            const ny = (idx + 1) * rowH;
            svgParts.push(`<path d="M ${x} ${y} C ${x} ${y + 12}, ${px} ${ny - 12}, ${px} ${ny}" fill="none" stroke="${pc}" stroke-width="2" opacity="0.85"/>`);
          }
        });
        svgParts.push(`<circle cx="${x}" cy="${y}" r="5" fill="${color}" stroke="#0b1120" stroke-width="2"/>`);
      });

      const rowsHtml = rowData.map(r => {
        const badges = r.c.refs.map(ref => {
          if (ref.startsWith("HEAD -> ")) return `<span class="badge head">${esc(ref.replace("HEAD -> ", "● "))}</span>`;
          if (ref.startsWith("tag: ")) return `<span class="badge tag">🏷 ${esc(ref.replace("tag: ", ""))}</span>`;
          if (ref === "origin/HEAD") return "";
          return `<span class="badge branch">${esc(ref)}</span>`;
        }).join("");
        return `
          <div class="commit-row">
            <div class="commit-meta">
              ${badges}
              <span class="commit-subject" title="${esc(r.c.subject)}">${esc(r.c.subject)}</span>
            </div>
            <div class="commit-right">
              <span>${esc(r.c.author)}</span>
              <span>${esc(r.c.rel_time)}</span>
              <span class="mono">${esc(r.c.short)}</span>
            </div>
          </div>`;
      }).join("");

      wrap.innerHTML = `<div style="display:flex;align-items:flex-start"><svg width="${svgW}" height="${svgH}" style="flex-shrink:0">${svgParts.join("")}</svg><div style="flex:1;min-width:0">${rowsHtml}</div></div>`;
    }

    async function runAction(payload, label) {
      setBusy(true, label);
      try {
        const res = await fetch("/api/action", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        });
        const data = await res.json();
        await loadState(false);
        showLog(data.output, data.ok);
      } catch (err) {
        showLog("Lỗi thực thi: " + err, false);
        setBusy(false);
      }
    }

    function doSync() {
      runAction({ action: "sync" }, "Đang kéo code mới nhất từ origin/main...");
    }

    function doCheckMerge() {
      runAction({ action: "check-merge" }, "Đang kiểm tra an toàn & conflict với origin/main...");
    }

    function doAutoPR() {
      const message = document.getElementById("inp-msg").value.trim();
      const slug = document.getElementById("inp-slug").value.trim();
      if (!message) {
        showLog("Vui lòng nhập mô tả thay đổi trước khi đẩy code lên PR.", false);
        document.getElementById("inp-msg").focus();
        return;
      }
      runAction({ action: "auto-pr", slug, message }, "Đang tự tạo nhánh theo Gmail, kiểm tra conflict & đẩy PR...");
    }

    function doCheckout(branch) {
      runAction({ action: "checkout", branch }, `Đang chuyển sang nhánh ${branch}...`);
    }

    function copyConflictPrompt() {
      const prompt = `Nhánh hiện tại đang có conflict với origin/main. Hãy kéo origin/main vào nhánh này, phân tích kỹ cả 2 phần code (của anh và của sếp), sửa conflict tối ưu để giữ đủ tính năng của cả 2, chạy test kiểm tra rồi đẩy PR lên giúp anh.\n\nChi tiết conflict:\n${lastConflictText}`;
      navigator.clipboard.writeText(prompt).then(() => {
        showLog("Đã copy lệnh xử lý Conflict tối ưu! Anh dán vào chat AI là AI sẽ tự gộp chuẩn cho anh.", true);
      });
    }

    loadState(false);
  </script>
</body>
</html>
"""


class DashboardHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:
        return

    def _send_json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path in ("/", "/index.html"):
            body = HTML_PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if parsed.path == "/api/state":
            qs = urllib.parse.parse_qs(parsed.query)
            do_fetch = qs.get("fetch", ["0"])[0] == "1"
            self._send_json(collect_state(do_fetch=do_fetch))
            return

        self.send_error(404, "Not Found")

    def do_POST(self) -> None:
        if self.path != "/api/action":
            self.send_error(404, "Not Found")
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            req = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self._send_json({"ok": False, "output": "Invalid JSON"}, status=400)
            return

        action = req.get("action")
        if action == "sync":
            code, out = run_cmd([sys.executable, str(TEAM_GIT_PY), "sync"])
            self._send_json({"ok": code == 0, "exit_code": code, "output": out})
            return

        if action == "check-merge":
            code, out = run_cmd([sys.executable, str(TEAM_GIT_PY), "check-merge"])
            self._send_json({"ok": code == 0, "exit_code": code, "output": out})
            return

        if action == "auto-pr":
            msg = str(req.get("message", "")).strip()
            slug = str(req.get("slug", "")).strip()
            if not msg:
                self._send_json({"ok": False, "output": "Thiếu mô tả thay đổi."}, status=400)
                return
            _, cur_branch = run_git("rev-parse", "--abbrev-ref", "HEAD")
            logs = []
            if cur_branch == "main" and slug:
                c1, o1 = run_cmd([sys.executable, str(TEAM_GIT_PY), "start", slug, "--carry"])
                logs.append(o1)
                if c1 != 0:
                    self._send_json({"ok": False, "exit_code": c1, "output": "\n".join(logs)})
                    return
            c2, o2 = run_cmd([sys.executable, str(TEAM_GIT_PY), "pr", "-m", msg])
            logs.append(o2)
            self._send_json({"ok": c2 == 0, "exit_code": c2, "output": "\n".join(x for x in logs if x)})
            return

        if action == "checkout":
            branch = str(req.get("branch", "")).strip()
            if not branch or branch.startswith("-"):
                self._send_json({"ok": False, "output": "Tên nhánh không hợp lệ."}, status=400)
                return
            code, out = run_git("checkout", branch)
            self._send_json({"ok": code == 0, "exit_code": code, "output": out or f"Đã chuyển sang nhánh {branch}."})
            return

        self._send_json({"ok": False, "output": f"Unknown action: {action}"}, status=400)


def find_port(preferred: int) -> int:
    for port in (preferred, 0):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", port))
                return s.getsockname()[1]
            except OSError:
                continue
    return preferred


def main() -> int:
    parser = argparse.ArgumentParser(description="Team Git Studio — Visual 3-Step Git App")
    parser.add_argument("--port", type=int, default=8765, help="Localhost port (default: 8765)")
    parser.add_argument("--no-open", action="store_true", help="Do not automatically open the browser")
    args = parser.parse_args()

    port = find_port(args.port)
    url = f"http://127.0.0.1:{port}"
    server = ThreadingHTTPServer(("127.0.0.1", port), DashboardHandler)
    print(f"Team Git Studio running at {url} (Ctrl+C to stop)", flush=True)
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped Team Git Studio.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
