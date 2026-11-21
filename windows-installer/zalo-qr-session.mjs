#!/usr/bin/env node
/**
 * Live Zalo QR Login Bridge for Em Tro Ly (WPF GUI + Telegram Owner Delivery)
 * - Spawns official `openclaw channels login --channel zalouser --account default --verbose`
 * - Captures generated QR PNG immediately for instant display inside the WPF GUI
 * - Simultaneously delivers the QR PNG to the configured Telegram Owner ID via Bot API
 * - Detects phone scan completion (`Login successful.`), restarts/enables zalouser channel if needed,
 *   notifies Telegram Owner, and writes `{ phase: "connected", connected: true }` for the GUI!
 */

import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

function parseArgs(argv) {
  const opts = {
    root: "",
    stateFile: "",
    qrOut: "",
    ownerId: "",
    accountId: "default",
    timeoutSeconds: 160,
    syncStatus: false,
    telegramApiBase: process.env.EMTROLY_TELEGRAM_API_BASE || "https://api.telegram.org",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--root") opts.root = argv[++i] || "";
    else if (a === "--state-file") opts.stateFile = argv[++i] || "";
    else if (a === "--qr-out") opts.qrOut = argv[++i] || "";
    else if (a === "--owner-id") opts.ownerId = argv[++i] || "";
    else if (a === "--account") opts.accountId = argv[++i] || "default";
    else if (a === "--timeout-seconds") opts.timeoutSeconds = Number(argv[++i] || "160");
    else if (a === "--sync-status") opts.syncStatus = true;
  }
  if (!opts.root) {
    throw new Error("Missing required --root");
  }
  if (!opts.syncStatus && (!opts.stateFile || !opts.qrOut)) {
    throw new Error("Missing required --state-file or --qr-out");
  }
  return opts;
}

function writePersistentZaloStatus(root, payload) {
  try {
    const stateDir = path.join(root, "state");
    fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    const dst = path.join(stateDir, "emtroly-zalo-status.json");
    const tmp = `${dst}.tmp-${process.pid}`;
    fs.writeFileSync(
      tmp,
      JSON.stringify({ updatedAt: Date.now(), ...payload }),
      { encoding: "utf8", mode: 0o600 },
    );
    fs.renameSync(tmp, dst);
  } catch {}
}

function stripAnsi(text) {
  return String(text || "").replace(/\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])/g, "");
}

function writeState(stateFile, payload) {
  const tmp = `${stateFile}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify({ updatedAt: Date.now(), ...payload }), { encoding: "utf8", mode: 0o600 });
  fs.renameSync(tmp, stateFile);
}

function resolveCliEntry(root) {
  const instPath = path.join(root, "installer-instance.json");
  if (fs.existsSync(instPath)) {
    try {
      const inst = JSON.parse(fs.readFileSync(instPath, "utf8"));
      if (inst.cli_entry && fs.existsSync(inst.cli_entry)) return inst.cli_entry;
    } catch {}
  }
  const fallback = path.join(root, "runtime", "2026.11.4", "node_modules", "openclaw", "openclaw.mjs");
  if (fs.existsSync(fallback)) return fallback;
  throw new Error("Không tìm thấy tệp thực thi OpenClaw CLI.");
}

function resolveOwnerId(root, explicitOwner) {
  if (explicitOwner && /^[1-9]\d*$/.test(explicitOwner.trim())) return explicitOwner.trim();
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(root, "openclaw.json"), "utf8"));
    for (const item of cfg?.commands?.ownerAllowFrom ?? []) {
      const m = String(item).match(/^(?:telegram:)?([1-9]\d*)$/);
      if (m) return m[1];
    }
    for (const item of cfg?.channels?.telegram?.allowFrom ?? []) {
      const s = String(item).trim();
      if (/^[1-9]\d*$/.test(s)) return s;
    }
  } catch {}
  return "";
}

function readTelegramToken(root) {
  const tokPath = path.join(root, "telegram.token");
  if (!fs.existsSync(tokPath)) return "";
  try {
    return fs.readFileSync(tokPath, "utf8").trim();
  } catch {
    return "";
  }
}

async function sendTelegramQrPhoto(apiBase, token, ownerId, pngPath, caption) {
  if (!token || !ownerId || !fs.existsSync(pngPath)) {
    return { sent: false, note: "Chưa cấu hình Telegram Owner hoặc Token để gửi kèm qua Telegram." };
  }
  try {
    const bytes = fs.readFileSync(pngPath);
    const form = new FormData();
    form.append("chat_id", ownerId);
    form.append("caption", caption);
    form.append("photo", new Blob([bytes], { type: "image/png" }), "zalo-login-qr.png");
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 18_000);
    try {
      const resp = await fetch(`${apiBase.replace(/\/+$/, "")}/bot${token}/sendPhoto`, {
        method: "POST",
        body: form,
        signal: ctrl.signal,
      });
      const data = await resp.json().catch(() => ({}));
      if (resp.ok && data?.ok) {
        const suffix = ownerId.length > 4 ? `...${ownerId.slice(-4)}` : ownerId;
        return { sent: true, note: `✓ Đã gửi đồng thời mã QR vào Telegram Chủ sở hữu (ID ${suffix}).` };
      }
      const desc = String(data?.description || "");
      if (/chat not found|bot was blocked|user is deactivated/i.test(desc)) {
        return {
          sent: false,
          note: "Chủ sở hữu chưa bấm /start với Bot trên Telegram — bạn hãy quét trực tiếp mã QR ngay trên màn hình này!",
        };
      }
      return { sent: false, note: "Tạm chưa gửi được ảnh qua Telegram — bạn hãy quét trực tiếp mã QR trên màn hình này." };
    } finally {
      clearTimeout(timer);
    }
  } catch {
    return { sent: false, note: "Mạng Telegram phản hồi chậm — bạn có thể quét trực tiếp mã QR ngay trên màn hình này." };
  }
}

async function sendTelegramText(apiBase, token, ownerId, text) {
  if (!token || !ownerId) return;
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 12_000);
    try {
      await fetch(`${apiBase.replace(/\/+$/, "")}/bot${token}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=utf-8" },
        body: JSON.stringify({ chat_id: ownerId, text }),
        signal: ctrl.signal,
      });
    } finally {
      clearTimeout(timer);
    }
  } catch {}
}

function runGatewayCall(cliEntry, env, method, params, timeoutMs = 20_000) {
  try {
    const res = spawnSync(
      process.execPath,
      [cliEntry, "gateway", "call", method, "--params", JSON.stringify(params), "--timeout", String(timeoutMs), "--json"],
      { env, encoding: "utf8", timeout: timeoutMs + 5_000, windowsHide: true },
    );
    if (res.status === 0 && res.stdout) return JSON.parse(res.stdout);
  } catch {}
  return null;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const cliEntry = resolveCliEntry(opts.root);

  const childEnv = {
    ...process.env,
    HOME: process.env.USERPROFILE || os.homedir(),
    OPENCLAW_STATE_DIR: opts.root,
    OPENCLAW_CONFIG_PATH: path.join(opts.root, "openclaw.json"),
  };
  delete childEnv.OPENCLAW_PROFILE;
  delete childEnv.OPENCLAW_HOME;

  if (opts.syncStatus) {
    try {
      const res = spawnSync(
        process.execPath,
        [cliEntry, "gateway", "health", "--json"],
        { env: childEnv, encoding: "utf8", timeout: 14_000, windowsHide: true },
      );
      if (res.status === 0 && res.stdout) {
        const health = JSON.parse(res.stdout);
        const zRoot = health?.channels?.zalouser ?? {};
        const zAcc = zRoot?.accounts?.[opts.accountId] ?? zRoot;
        const linked = zAcc?.linked === true || zRoot?.linked === true;
        const connected = zAcc?.connected === true || zRoot?.connected === true;
        const running = zAcc?.running === true || zRoot?.running === true;
        const telegramRunning = health?.channels?.telegram?.running === true;
        writePersistentZaloStatus(opts.root, {
          gatewayHealthy: health?.ok === true,
          linked,
          connected,
          running,
          telegramRunning,
        });
      }
    } catch {}
    process.exit(0);
  }

  const ownerId = resolveOwnerId(opts.root, opts.ownerId);
  const tgToken = readTelegramToken(opts.root);

  writeState(opts.stateFile, {
    phase: "starting",
    qrReady: false,
    connected: false,
    telegramSent: false,
    message: "Đang khởi tạo mã QR đăng nhập Zalo cá nhân...",
    telegramNote: "Chuẩn bị gửi mã QR tới Telegram chủ sở hữu...",
  });

  // Stop active zalouser listener cleanly if already running so login session acquires socket cleanly
  const chStatus = runGatewayCall(cliEntry, childEnv, "channels.status", {}, 12_000);
  const wasRunning = chStatus?.channels?.zalouser?.running === true;
  if (wasRunning) {
    runGatewayCall(cliEntry, childEnv, "channels.stop", { channel: "zalouser", accountId: opts.accountId }, 15_000);
  }

  const startedAt = Date.now();
  const expiresAt = startedAt + opts.timeoutSeconds * 1000;

  const loginArgs = [cliEntry, "channels", "login", "--channel", "zalouser", "--account", opts.accountId, "--verbose"];
  const child = spawn(process.execPath, loginArgs, {
    env: childEnv,
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
  });

  let combinedOutput = "";
  let qrHandled = false;
  let tgDeliveryState = { sent: false, note: "Đang gửi đồng thời mã QR qua Telegram..." };
  let settled = false;

  const cleanupChild = () => {
    if (!settled && child.pid) {
      try { child.kill("SIGTERM"); } catch {}
    }
  };
  process.on("SIGTERM", () => { cleanupChild(); process.exit(2); });
  process.on("SIGINT", () => { cleanupChild(); process.exit(2); });

  const onChunk = (chunk) => {
    combinedOutput = (combinedOutput + chunk.toString("utf8")).slice(-24_000);
    if (qrHandled) return;
    const clean = stripAnsi(combinedOutput);
    const match = /Scan QR image:\s*([^\r\n]+\.png)/i.exec(clean);
    const srcPng = match?.[1]?.trim();
    if (!srcPng || !fs.existsSync(srcPng)) return;
    try {
      const bytes = fs.readFileSync(srcPng);
      // Verify valid PNG magic header
      if (bytes.length < 24 || bytes[0] !== 0x89 || bytes[1] !== 0x50 || bytes[2] !== 0x4e || bytes[3] !== 0x47) {
        return;
      }
      fs.copyFileSync(srcPng, opts.qrOut);
      qrHandled = true;

      writeState(opts.stateFile, {
        phase: "qr_ready",
        qrReady: true,
        connected: false,
        startedAt,
        expiresAt,
        telegramSent: false,
        message: "Mở Zalo trên điện thoại và quét mã QR để đăng nhập.",
        telegramNote: ownerId ? "Đang gửi đồng thời mã QR vào Telegram Chủ sở hữu..." : "Hãy quét mã QR trực tiếp trên màn hình.",
      });

      if (ownerId && tgToken) {
        sendTelegramQrPhoto(
          opts.telegramApiBase,
          tgToken,
          ownerId,
          opts.qrOut,
          "Mã QR đăng nhập Zalo cá nhân cho trợ lý OpenClaw (Anh Lập Trình).\nHãy mở Zalo trên điện thoại → Quét mã QR và bấm Đăng nhập ngay nhé!",
        ).then((res) => {
          tgDeliveryState = res;
          if (!settled) {
            writeState(opts.stateFile, {
              phase: "qr_ready",
              qrReady: true,
              connected: false,
              startedAt,
              expiresAt,
              telegramSent: res.sent,
              message: "Mở Zalo trên điện thoại và quét mã QR để đăng nhập.",
              telegramNote: res.note,
            });
          }
        });
      }
    } catch {}
  };

  child.stdout.on("data", onChunk);
  child.stderr.on("data", onChunk);

  const exitResult = await new Promise((resolve) => {
    const timer = setTimeout(() => {
      try { child.kill("SIGTERM"); } catch {}
      resolve({ code: 124, timedOut: true });
    }, opts.timeoutSeconds * 1000);

    child.once("error", (err) => {
      clearTimeout(timer);
      resolve({ code: 1, error: err.message });
    });
    child.once("close", (code) => {
      clearTimeout(timer);
      resolve({ code: code ?? 1, timedOut: false });
    });
  });

  settled = true;
  const cleanFinal = stripAnsi(combinedOutput);
  const loginSucceeded = exitResult.code === 0 && (qrHandled || /Login successful\./i.test(cleanFinal));

  if (loginSucceeded) {
    runGatewayCall(cliEntry, childEnv, "channels.start", { channel: "zalouser", accountId: opts.accountId }, 20_000);
    writePersistentZaloStatus(opts.root, {
      gatewayHealthy: true,
      linked: true,
      connected: true,
      running: true,
      telegramRunning: true,
    });
    if (ownerId && tgToken) {
      await sendTelegramText(
        opts.telegramApiBase,
        tgToken,
        ownerId,
        "✅ Đăng nhập Zalo thành công! Trợ lý OpenClaw đã kết nối tài khoản Zalo cá nhân của bạn.",
      );
    }
    writeState(opts.stateFile, {
      phase: "connected",
      qrReady: qrHandled,
      connected: true,
      telegramSent: tgDeliveryState.sent,
      message: "Đăng nhập Zalo thành công! Kênh Zalo cá nhân của trợ lý đã hoạt động.",
      telegramNote: tgDeliveryState.sent
        ? "✓ Đã gửi thông báo đăng nhập Zalo thành công vào Telegram Chủ sở hữu."
        : tgDeliveryState.note,
    });
    process.exit(0);
  }

  if (wasRunning) {
    runGatewayCall(cliEntry, childEnv, "channels.start", { channel: "zalouser", accountId: opts.accountId }, 15_000);
  }

  if (exitResult.timedOut) {
    writeState(opts.stateFile, {
      phase: "expired",
      qrReady: false,
      connected: false,
      telegramSent: tgDeliveryState.sent,
      message: "Mã QR đã hết thời gian chờ quét. Hãy bấm \"Tạo mã QR mới\" để lấy mã mới.",
      telegramNote: tgDeliveryState.note,
    });
    process.exit(2);
  }

  writeState(opts.stateFile, {
    phase: "error",
    qrReady: false,
    connected: false,
    telegramSent: tgDeliveryState.sent,
    message: "Chưa tạo hoặc hoàn tất được phiên đăng nhập QR Zalo. Hãy kiểm tra Gateway đang chạy rồi bấm \"Tạo mã QR mới\".",
    telegramNote: tgDeliveryState.note,
  });
  process.exit(1);
}

main().catch((err) => {
  process.stderr.write(`${err?.message || err}\n`);
  process.exit(1);
});
