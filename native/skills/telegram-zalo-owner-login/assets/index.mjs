import { execFile, spawn } from "node:child_process";
import { appendFileSync, chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import os from "node:os";
import path from "node:path";

const settings = JSON.parse(readFileSync(new URL("./settings.json", import.meta.url), "utf8"));
const stateRoot = settings.runtimeRoot;
let loginActive = false;

function normalizedTarget(value) {
  const raw = String(value ?? "").trim();
  if (!raw) return "";
  if (raw.includes(":group:") || raw.startsWith("-")) return raw;
  const parts = raw.split(":").filter(Boolean);
  const tail = parts.at(-1) ?? "";
  if (/^[1-9]\d*$/.test(tail)) return tail;
  return raw.replace(/^telegram:/, "").replace(/^user:/, "");
}

export function telegramOwners(config) {
  return new Set((config.commands?.ownerAllowFrom ?? []).flatMap((entry) => {
    const match = String(entry).match(/^(?:telegram:)?([1-9]\d*)$/);
    return match ? [match[1]] : [];
  }));
}

function currentConfig() {
  return JSON.parse(readFileSync(path.join(stateRoot, "openclaw.json"), "utf8"));
}

function isDirectTelegramContext(context, sender) {
  const fromRaw = String(context.from ?? "").trim();
  const toRaw = String(context.to ?? context.deliveryContext?.to ?? "").trim();
  const sessionKey = String(context.sessionKey ?? "").trim();
  if (
    fromRaw.startsWith("telegram:group:") ||
    toRaw.startsWith("telegram:group:") ||
    toRaw.startsWith("-") ||
    sessionKey.includes(":telegram:group:")
  ) {
    return false;
  }
  if (toRaw && normalizedTarget(toRaw) === sender) return true;
  if (fromRaw && normalizedTarget(fromRaw) === sender) return true;
  if (sessionKey.includes(`:telegram:direct:${sender}`)) return true;
  return false;
}

export function authorizedToolContext(context, config = currentConfig()) {
  const route = context.deliveryContext ?? {};
  const sender = normalizedTarget(context.requesterSenderId ?? "");
  const channel = route.channel ?? context.messageChannel;
  const accountId = route.accountId ?? context.agentAccountId;
  return context.senderIsOwner === true && Boolean(sender) && telegramOwners(config).has(sender)
    && channel === "telegram"
    && (!accountId || accountId === settings.telegramAccount)
    && isDirectTelegramContext(context, sender)
    && (!context.agentId || context.agentId === settings.agentId)
    && typeof context.assertInvocationCurrent === "function";
}

export function authorizedCommandContext(context, config = currentConfig()) {
  const sender = normalizedTarget(context.senderId ?? "") || normalizedTarget(context.from ?? "");
  const channel = context.channelId ?? context.channel ?? (String(context.from ?? "").startsWith("telegram:") ? "telegram" : "");
  return context.isAuthorizedSender !== false && context.senderIsOwner !== false && Boolean(sender) && telegramOwners(config).has(sender)
    && channel === "telegram"
    && (!context.accountId || context.accountId === settings.telegramAccount)
    && isDirectTelegramContext(context, sender)
    && (!context.agentId || context.agentId === settings.agentId);
}

export function summarizeZaloHealth(health, accountId) {
  if (health?.ok !== true) return "Không kiểm tra được Gateway; chưa thể xác nhận kết nối Zalo.";
  const account = health.channels?.zalouser?.accounts?.[accountId] ?? health.channels?.zalouser;
  if (!account) return "Không thấy tài khoản Zalo đã cấu hình trong trạng thái Gateway.";
  const linked = account.linked === true ? "đã đăng nhập" : account.linked === false ? "chưa đăng nhập" : "chưa xác định đăng nhập";
  const running = account.running === true ? "đang chạy" : account.running === false ? "chưa chạy" : "chưa xác định hoạt động";
  const connected = account.connected === true ? "đã báo kết nối" : account.connected === false ? "chưa kết nối" : "chưa xác minh kết nối";
  return `Zalo: ${linked}; ${running}; ${connected}. Nếu chưa đăng nhập, dùng /zaloqr.`;
}

function writeGuiZaloStatusCache(payload) {
  try {
    const dir = path.join(stateRoot, "state");
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const dst = path.join(dir, "emtroly-zalo-status.json");
    const tmp = `${dst}.tmp-${process.pid}`;
    writeFileSync(tmp, JSON.stringify({ updatedAt: Date.now(), ...payload }), { encoding: "utf8", mode: 0o600 });
    renameSync(tmp, dst);
  } catch {}
}

function readLocalTelegramToken() {
  const tokPath = path.join(stateRoot, "telegram.token");
  if (existsSync(tokPath)) {
    try {
      const v = readFileSync(tokPath, "utf8").trim();
      if (v) return v;
    } catch {}
  }
  try {
    const cfg = currentConfig();
    const accTok = cfg?.channels?.telegram?.accounts?.[settings.telegramAccount]?.botToken
      ?? cfg?.channels?.telegram?.botToken;
    if (typeof accTok === "string" && accTok.trim() && !accTok.includes("${")) return accTok.trim();
  } catch {}
  return "";
}

async function sendDirectTelegramPhoto(ownerId, pngInput, caption, signal) {
  const token = readLocalTelegramToken();
  if (!token) return null;
  let bytes = null;
  if (Buffer.isBuffer(pngInput)) {
    bytes = pngInput;
  } else if (typeof pngInput === "string" && existsSync(pngInput)) {
    bytes = readFileSync(pngInput);
  }
  if (!bytes || bytes.length === 0) return null;
  const apiBase = (process.env.EMTROLY_TELEGRAM_API_BASE || "https://api.telegram.org").replace(/\/+$/, "");
  const form = new FormData();
  form.append("chat_id", ownerId);
  form.append("caption", caption);
  form.append("photo", new Blob([bytes], { type: "image/png" }), "zalo-login-qr.png");
  const ctrl = new AbortController();
  const onAbort = () => ctrl.abort();
  signal?.addEventListener("abort", onAbort, { once: true });
  const timer = setTimeout(() => ctrl.abort(), 20000);
  try {
    const resp = await fetch(`${apiBase}/bot${token}/sendPhoto`, {
      method: "POST",
      body: form,
      signal: ctrl.signal,
    });
    const data = await resp.json().catch(() => ({}));
    if (resp.ok && data?.ok && data?.result?.message_id) {
      return String(data.result.message_id);
    }
  } catch {} finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", onAbort);
  }
  return null;
}

function extractLastJson(output) {
  if (!output) return null;
  const trimmed = output.trim();
  try { return JSON.parse(trimmed); } catch {}
  for (let i = trimmed.lastIndexOf("{"); i >= 0; i = trimmed.lastIndexOf("{", i - 1)) {
    try { return JSON.parse(trimmed.slice(i)); } catch {}
  }
  return null;
}

async function readZaloHealth() {
  const environment = { ...process.env, HOME: settings.runtimeHome, OPENCLAW_STATE_DIR: stateRoot, OPENCLAW_CONFIG_PATH: path.join(stateRoot, "openclaw.json") };
  delete environment.OPENCLAW_PROFILE;
  delete environment.OPENCLAW_HOME;
  return new Promise((resolve) => {
    execFile(settings.cliCommand ?? "/usr/bin/openclaw", [...(settings.cliPrefix ?? []), "gateway", "health", "--json"],
      { env: environment, timeout: 30000, maxBuffer: 1024 * 1024, windowsHide: true }, (error, stdout) => {
        if (error) return resolve(null);
        resolve(extractLastJson(stdout));
      });
  });
}

function cliProcess(args, { signal, timeoutMs, logPath }) {
  const environment = { ...process.env, HOME: settings.runtimeHome, OPENCLAW_STATE_DIR: stateRoot, OPENCLAW_CONFIG_PATH: path.join(stateRoot, "openclaw.json") };
  delete environment.OPENCLAW_PROFILE;
  delete environment.OPENCLAW_HOME;
  const child = spawn(settings.cliCommand ?? "/usr/bin/openclaw", [...(settings.cliPrefix ?? []), ...args], {
    detached: process.platform !== "win32",
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
    env: environment,
  });
  let output = "";
  let closed = false;
  let killTimer;
  const stop = () => {
    if (closed || !child.pid) return;
    try {
      if (process.platform === "win32") child.kill("SIGTERM");
      else process.kill(-child.pid, "SIGTERM");
    } catch {}
    killTimer ??= setTimeout(() => {
      try {
        if (process.platform === "win32") child.kill("SIGKILL");
        else process.kill(-child.pid, "SIGKILL");
      } catch {}
    }, 1500);
  };
  const collect = (chunk) => {
    const text = chunk.toString();
    output = (output + text).slice(-131072);
    if (logPath) appendFileSync(logPath, text, { mode: 0o600 });
  };
  child.stdout.on("data", collect);
  child.stderr.on("data", collect);
  const timeout = setTimeout(stop, timeoutMs);
  signal?.addEventListener("abort", stop, { once: true });
  if (signal?.aborted) stop();
  const done = new Promise((resolve) => {
    const finish = (code) => {
      if (closed) return;
      closed = true;
      clearTimeout(timeout);
      clearTimeout(killTimer);
      signal?.removeEventListener("abort", stop);
      resolve({ code, output });
    };
    child.once("error", () => finish(-1));
    child.once("close", (code) => finish(code ?? -1));
  });
  return { done, stop, get output() { return output; }, get closed() { return closed; } };
}

async function callGatewayRpc(method, params, timeoutMs, signal, logPath) {
  const proc = cliProcess(
    ["gateway", "call", method, "--params", JSON.stringify(params), "--timeout", String(timeoutMs), "--json"],
    { signal, timeoutMs: timeoutMs + 10000, logPath },
  );
  const res = await proc.done;
  if (res.code !== 0 || !res.output) return null;
  return extractLastJson(res.output);
}

function parseReceipt(output, ownerId) {
  for (const candidate of output.matchAll(/^\{[^\r\n]*\}[ \t]*$|^\{\r?\n[\s\S]*?^\}[ \t]*$/gm)) {
    try {
      const value = JSON.parse(candidate[0]);
      const payload = value.payload ?? value;
      const messageId = value.messageId ?? payload.messageId ?? payload.result?.message_id;
      const chat = normalizedTarget(payload.chatId ?? payload.to ?? payload.result?.chat?.id ?? "");
      if (payload.ok !== false && chat === ownerId && messageId) return String(messageId);
    } catch {}
  }
  throw new Error("Telegram chưa trả biên nhận ảnh rõ ràng; không gửi lại tự động để tránh trùng QR.");
}

function sameResolvedDirectory(dirA, dirB) {
  try {
    const realA = realpathSync.native(dirA);
    const realB = realpathSync.native(dirB);
    return process.platform === "win32" ? realA.toLowerCase() === realB.toLowerCase() : realA === realB;
  } catch {
    return process.platform === "win32"
      ? path.resolve(dirA).toLowerCase() === path.resolve(dirB).toLowerCase()
      : path.resolve(dirA) === path.resolve(dirB);
  }
}

function isPngHeader(buf) {
  return Boolean(buf && buf.length >= 32 && buf.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])));
}

export async function loginAndSendQr(ownerId, assertCurrent, signal) {
  assertCurrent();
  if (loginActive) return { status: "already_running", message: "Đang có lượt đăng nhập chờ quét; không tạo phiên song song." };
  loginActive = true;
  let login;
  let mediaDirectory;
  let receipt;
  let receiptError;
  let lockDirectory;
  let lockToken;
  try {
    const locksRoot = path.join(stateRoot, "locks");
    mkdirSync(locksRoot, { recursive: true, mode: 0o700 });
    const requestedLock = path.join(locksRoot, "telegram-zalo-owner-login");
    try {
      mkdirSync(requestedLock, { mode: 0o700 });
    } catch (error) {
      if (error.code === "EEXIST") {
        // Recover stale lock older than 4 minutes
        try {
          const prev = JSON.parse(readFileSync(path.join(requestedLock, "owner.json"), "utf8"));
          if (prev?.startedAt && Date.now() - Number(prev.startedAt) > 240000) {
            rmSync(requestedLock, { recursive: true, force: true });
            mkdirSync(requestedLock, { mode: 0o700 });
          } else {
            return { status: "already_running", message: "Đang có phiên tạo QR Zalo hoạt động. Vui lòng quét mã đã gửi hoặc đợi ít phút rồi thử lại." };
          }
        } catch {
          return { status: "already_running", message: "Có lượt đăng nhập/lock đang tồn tại. Không tạo phiên song song." };
        }
      } else {
        throw error;
      }
    }
    lockDirectory = requestedLock;
    lockToken = randomUUID();
    writeFileSync(path.join(lockDirectory, "owner.json"), JSON.stringify({ token: lockToken, pid: process.pid, startedAt: Date.now() }), { mode: 0o600 });

    const startedAt = Date.now();
    const privateRoot = path.join(stateRoot, "tmp", "telegram-zalo-login");
    mkdirSync(privateRoot, { recursive: true, mode: 0o700 });
    const privateDirectory = mkdtempSync(path.join(privateRoot, "attempt-"));
    chmodSync(privateDirectory, 0o700);
    const mediaRoot = path.join(stateRoot, "media", "outbound");
    const stageOutboundMedia = (buf) => {
      mkdirSync(mediaRoot, { recursive: true, mode: 0o700 });
      if (!mediaDirectory || !existsSync(mediaDirectory)) {
        mediaDirectory = mkdtempSync(path.join(mediaRoot, "zalo-login-"));
        chmodSync(mediaDirectory, 0o700);
      }
      const dst = path.join(mediaDirectory, "qr.png");
      writeFileSync(dst, buf, { mode: 0o600 });
      return dst;
    };

    const qrCaption = "Anh/chị mở Zalo trên điện thoại → Quét mã QR này và bấm Đăng nhập ngay nhé (mã có hiệu lực trong ít phút).";

    // =======================================================================
    // 1. PRIMARY IN-GATEWAY RPC PATH (`web.login.start` + `web.login.wait`)
    //    Generates QR in ~3-5s without SQLite plugin-lifecycle lease deadlock!
    // =======================================================================
    assertCurrent();
    const rpcStart = await callGatewayRpc(
      "web.login.start",
      { channel: "zalouser", accountId: settings.zaloAccount, force: true, timeoutMs: 30000 },
      35000,
      signal,
      path.join(privateDirectory, "rpc-start.log"),
    );
    if (signal?.aborted) throw new Error("Lượt đăng nhập đã bị hủy.");

    if (rpcStart && typeof rpcStart.qrDataUrl === "string" && rpcStart.qrDataUrl.trim()) {
      const rawB64 = rpcStart.qrDataUrl.trim().replace(/^data:image\/[a-zA-Z0-9.+-]+;base64,/i, "");
      const pngBytes = Buffer.from(rawB64, "base64");
      if (!isPngHeader(pngBytes)) {
        throw new Error("Ảnh QR từ Gateway không hợp lệ.");
      }
      assertCurrent();

      receipt = await sendDirectTelegramPhoto(ownerId, pngBytes, qrCaption, signal);
      if (!receipt) {
        const mediaPath = stageOutboundMedia(pngBytes);
        const delivery = cliProcess(
          ["message", "send", "--channel", "telegram", "--account", settings.telegramAccount, "--target", ownerId, "--media", mediaPath, "--message", qrCaption, "--json"],
          { signal, timeoutMs: 60000, logPath: path.join(privateDirectory, "delivery.log") },
        );
        const deliveryResult = await delivery.done;
        assertCurrent();
        if (deliveryResult.code !== 0) throw new Error("Gửi ảnh QR qua Telegram chưa thành công.");
        try {
          receipt = parseReceipt(deliveryResult.output, ownerId);
        } catch (err) {
          receiptError = err;
        }
      }

      let connected = false;
      const waitDeadline = startedAt + 155000;
      while (Date.now() < waitDeadline) {
        assertCurrent();
        if (signal?.aborted) break;
        const sliceMs = Math.min(18000, Math.max(3000, waitDeadline - Date.now()));
        const waitRes = await callGatewayRpc(
          "web.login.wait",
          { channel: "zalouser", accountId: settings.zaloAccount, timeoutMs: sliceMs },
          sliceMs + 5000,
          signal,
          path.join(privateDirectory, "rpc-wait.log"),
        );
        if (waitRes?.connected === true) {
          connected = true;
          break;
        }
        const msg = String(waitRes?.message ?? "");
        if (/declined|expired|no active zalo qr/i.test(msg)) break;
      }

      if (connected) {
        await callGatewayRpc("channels.start", { channel: "zalouser", accountId: settings.zaloAccount }, 15000, signal);
        writeGuiZaloStatusCache({ gatewayHealthy: true, linked: true, connected: true, running: true, telegramRunning: true });
      }
      assertCurrent();

      if (receiptError) {
        return {
          status: "qr_delivery_unconfirmed",
          qrSent: null,
          loginCompleted: connected,
          message: receiptError.message,
        };
      }
      return {
        status: connected ? "login_completed" : "qr_sent_not_logged_in",
        qrSent: Boolean(receipt),
        telegramMessageId: receipt,
        message: connected
          ? "✅ Đăng nhập Zalo cá nhân thành công! Trợ lý OpenClaw đã kết nối Zalo và sẵn sàng nhận/gửi tin nhắn."
          : "Đã gửi ảnh mã QR vào Telegram của anh/chị, nhưng phiên chờ quét đã hết thời gian. Hãy gõ lại /zaloqr nếu cần tạo mã mới.",
      };
    }

    // =======================================================================
    // 2. FALLBACK CLI PATH (`channels login --channel zalouser`)
    // =======================================================================
    assertCurrent();
    login = cliProcess(["channels", "login", "--channel", "zalouser", "--account", settings.zaloAccount, "--agent", settings.agentId, "--verbose"], {
      signal, timeoutMs: 180000, logPath: path.join(privateDirectory, "login.log"),
    });
    while (!login.closed && Date.now() - startedAt < 170000) {
      assertCurrent();
      if (signal?.aborted) throw new Error("Lượt đăng nhập đã bị hủy.");
      if (/Scan QR image: [^\r\n]+\.png/.test(login.output)) break;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    assertCurrent();
    const qrMatch = login.output.match(/Scan QR image: ([^\r\n]+\.png)/);
    if (!qrMatch) {
      return { status: "qr_unavailable", message: "Runtime chưa tạo ảnh QR; hãy kiểm tra Gateway đang chạy rồi thử lại /zaloqr." };
    }
    const qrSource = path.resolve(qrMatch[1].trim());
    const expectedQrDir = path.join(os.tmpdir(), "openclaw");
    if (!sameResolvedDirectory(path.dirname(qrSource), expectedQrDir)
      || !/^openclaw-zalouser-qr-[A-Za-z0-9_-]+\.png$/.test(path.basename(qrSource))
      || lstatSync(qrSource).isSymbolicLink() || statSync(qrSource).size > 5242880) {
      throw new Error("Runtime trả đường dẫn QR ngoài vị trí/tên file đã xác minh.");
    }
    const image = readFileSync(qrSource);
    if (statSync(qrSource).mtimeMs < startedAt - 2000 || !isPngHeader(image)) {
      throw new Error("Ảnh QR không hợp lệ hoặc không thuộc lượt đăng nhập hiện tại.");
    }
    assertCurrent();

    receipt = await sendDirectTelegramPhoto(ownerId, image, qrCaption, signal);
    if (!receipt) {
      const mediaPath = stageOutboundMedia(image);
      const delivery = cliProcess(["message", "send", "--channel", "telegram", "--account", settings.telegramAccount,
        "--target", ownerId, "--media", mediaPath, "--message", qrCaption, "--json"],
      { signal, timeoutMs: 60000, logPath: path.join(privateDirectory, "delivery.log") });
      const deliveryResult = await delivery.done;
      assertCurrent();
      if (deliveryResult.code !== 0) throw new Error("Gửi ảnh Telegram chưa thành công; không tự gửi lại khi biên nhận chưa rõ.");
      try {
        receipt = parseReceipt(deliveryResult.output, ownerId);
      } catch (error) {
        receiptError = error;
      }
    }

    while (!login.closed && Date.now() - startedAt < 180000) {
      assertCurrent();
      if (signal?.aborted) throw new Error("Lượt đăng nhập đã bị hủy sau khi gửi QR.");
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    const outcome = await login.done;
    if (outcome.code === 0) {
      writeGuiZaloStatusCache({ gatewayHealthy: true, linked: true, connected: true, running: true, telegramRunning: true });
    }
    assertCurrent();
    if (receiptError) {
      return {
        status: "qr_delivery_unconfirmed",
        qrSent: null,
        loginCompleted: outcome.code === 0,
        message: receiptError.message + " Đã giữ phiên login đến khi CLI kết thúc hoặc hết hạn; không tự gửi lại QR hay khẳng định giao ảnh thành công.",
      };
    }
    return {
      status: outcome.code === 0 ? "login_completed" : "qr_sent_not_logged_in",
      telegramMessageId: receipt,
      message: outcome.code === 0
        ? "✅ Đăng nhập Zalo cá nhân thành công! Trợ lý OpenClaw đã kết nối Zalo và sẵn sàng hoạt động."
        : "Đã gửi ảnh QR có biên nhận, nhưng chưa xác minh đăng nhập; QR có thể hết hạn hoặc chưa được xác nhận.",
    };
  } catch (error) {
    return { status: "failed", qrSent: Boolean(receipt), message: error.message };
  } finally {
    login?.stop();
    if (login) await login.done;
    if (mediaDirectory) rmSync(mediaDirectory, { recursive: true, force: true });
    if (lockDirectory) {
      try {
        const lock = JSON.parse(readFileSync(path.join(lockDirectory, "owner.json"), "utf8"));
        if (lock.token === lockToken) rmSync(lockDirectory, { recursive: true, force: true });
      } catch {}
    }
    loginActive = false;
  }
}

export default {
  id: settings.pluginId,
  name: "Owner Telegram Zalo QR Login",
  register(api) {
    api.registerTool({
      contextVersion: 2,
      create(context) {
        if (!authorizedToolContext(context)) return null;
        return {
          name: "telegram_zalo_login_qr",
          label: "Tạo và gửi QR đăng nhập Zalo",
          description: "Khi owner yêu cầu đăng nhập Zalo qua Telegram riêng: tạo QR và tự gửi ảnh ngay trong lúc chờ quét. Không dùng exec channels login. Không cần dashboard. Chỉ dùng khi owner yêu cầu tạo QR/đăng nhập, không dùng để kiểm tra trạng thái.",
          parameters: { type: "object", properties: { confirm: { type: "boolean", const: true } }, required: ["confirm"], additionalProperties: false },
          async execute(_toolCallId, params, signal) {
            if (params.confirm !== true) throw new Error("Cần yêu cầu đăng nhập rõ ràng từ owner.");
            const guard = () => {
              context.assertInvocationCurrent();
              if (!authorizedToolContext(context)) throw new Error("Quyền owner hoặc Telegram riêng không còn hợp lệ.");
            };
            const ownerTarget = normalizedTarget(context.requesterSenderId);
            const result = await loginAndSendQr(ownerTarget, guard, signal);
            return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
          },
        };
      },
    }, { name: "telegram_zalo_login_qr" });
    api.registerCommand({
      name: "zalostatus",
      description: "Kiểm tra trạng thái Zalo trong Telegram riêng của owner",
      channels: ["telegram"],
      requireAuth: true,
      requiredScopes: ["operator.admin"],
      exposeSenderIsOwner: true,
      acceptsArgs: false,
      async handler(context) {
        if (!authorizedCommandContext(context)) return { text: "Lệnh này chỉ dành cho Telegram owner đã cấu hình, trong chat riêng (DM) với bot." };
        context.assertOwnerCurrent?.();
        const health = await readZaloHealth();
        context.assertOwnerCurrent?.();
        if (!authorizedCommandContext(context)) return { text: "Quyền owner không còn hợp lệ." };
        return { text: summarizeZaloHealth(health, settings.zaloAccount) };
      },
    });
    api.registerCommand({
      name: "zaloqr",
      description: "Tạo QR đăng nhập Zalo và gửi riêng cho owner",
      channels: ["telegram"],
      requireAuth: true,
      requiredScopes: ["operator.admin"],
      exposeSenderIsOwner: true,
      acceptsArgs: false,
      nativeProgressMessages: { telegram: "Em đang tạo mã QR Zalo và sẽ gửi ảnh ngay tại đây (~5 giây)..." },
      async handler(context) {
        if (!authorizedCommandContext(context)) return { text: "Vì lý do bảo mật Zalo, lệnh /zaloqr chỉ dùng trong tin nhắn riêng (DM) giữa Chủ sở hữu và bot." };
        const guard = () => {
          context.assertOwnerCurrent?.();
          if (!authorizedCommandContext(context)) throw new Error("Quyền owner hoặc Telegram riêng không còn hợp lệ.");
        };
        const ownerTarget = normalizedTarget(context.senderId ?? "") || normalizedTarget(context.from ?? "");
        const result = await loginAndSendQr(ownerTarget, guard);
        return { text: result.message };
      },
    });
  },
};
