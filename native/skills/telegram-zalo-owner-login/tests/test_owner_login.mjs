import assert from "node:assert/strict";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

const fixture = mkdtempSync(path.join(os.tmpdir(), "owner-qr-test-"));
const state = path.join(fixture, "state");
mkdirSync(state);
const settings = { pluginId: "telegram-zalo-owner-login", runtimeRoot: state, runtimeHome: fixture,
  telegramAccount: "fixture", zaloAccount: "default", agentId: "main",
  cliCommand: process.execPath, cliPrefix: [path.join(fixture, "cli.mjs")] };
writeFileSync(path.join(fixture, "settings.json"), JSON.stringify(settings));
writeFileSync(path.join(state, "openclaw.json"), JSON.stringify({ commands: { ownerAllowFrom: ["telegram:123456789", "987654321", "*", "zalouser:111111111"] } }));
copyFileSync(fileURLToPath(new URL("../assets/index.mjs", import.meta.url)), path.join(fixture, "index.mjs"));
writeFileSync(path.join(fixture, "cli.mjs"), `
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
const args = process.argv.slice(2);
if (args[0] === 'channels') {
  const directory = path.join(os.tmpdir(), 'openclaw');
  fs.mkdirSync(directory, {recursive:true});
  const qr = path.join(directory, 'openclaw-zalouser-qr-fixture-' + process.pid + '.png');
  fs.writeFileSync(qr, Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), Buffer.alloc(32)]));
  console.log('Scan QR image: ' + qr);
  const timer = setInterval(() => {
    if (fs.existsSync(path.join(process.env.HOME, 'delivered'))) {
      clearInterval(timer); fs.rmSync(qr); process.exit(0);
    }
  }, 50);
} else {
  const account = args[args.indexOf('--account') + 1];
  const target = args[args.indexOf('--target') + 1];
  const media = args[args.indexOf('--media') + 1];
  if (account !== 'fixture' || !media.startsWith(path.join(process.env.OPENCLAW_STATE_DIR, 'media', 'outbound'))) process.exit(2);
  fs.writeFileSync(path.join(process.env.HOME, 'delivered'), JSON.stringify({target, media}));
  console.log(JSON.stringify({payload:{ok:true, chatId:process.env.OWNER_QR_TEST_MODE === 'wrong-chat' ? '111111111' : target, messageId:'synthetic-receipt'}}));
}
`);
const plugin = await import(pathToFileURL(path.join(fixture, "index.mjs")));
const toolContext = { requesterSenderId: "123456789", senderIsOwner: true, agentId: "main",
  deliveryContext: { channel: "telegram", accountId: "fixture", to: "telegram:123456789" },
  assertInvocationCurrent() {} };

test("numeric owners only; public admission never grants ownership", () => {
  assert.deepEqual([...plugin.telegramOwners(JSON.parse(readFileSync(path.join(state, "openclaw.json"))))].sort(), ["123456789", "987654321"]);
  assert.equal(plugin.authorizedToolContext(toolContext), true);
  assert.equal(plugin.authorizedToolContext({ ...toolContext, requesterSenderId: "987654321", deliveryContext: { ...toolContext.deliveryContext, to: "telegram:987654321" } }), true);
  assert.equal(plugin.authorizedToolContext({ ...toolContext, senderIsOwner: false }), false);
  assert.equal(plugin.authorizedToolContext({ ...toolContext, requesterSenderId: "111111111" }), false);
  assert.equal(plugin.authorizedToolContext({ ...toolContext, deliveryContext: { ...toolContext.deliveryContext, to: "-100123456789" } }), false);
  assert.equal(plugin.authorizedToolContext({ ...toolContext, deliveryContext: { ...toolContext.deliveryContext, accountId: "other" } }), false);
  assert.equal(plugin.authorizedToolContext({ ...toolContext, agentId: "other" }), false);
});

test("command and tool registration are private-owner gated", () => {
  let command;
  let tool;
  plugin.default.register({ registerTool(value) { tool = value; }, registerCommand(value) { command = value; } });
  assert.equal(command.name, "zaloqr");
  assert.equal(command.requireAuth, true);
  assert.equal(tool.create({ ...toolContext, senderIsOwner: false }), null);
  assert.equal(tool.create(toolContext).name, "telegram_zalo_login_qr");
  const context = { senderId: "123456789", isAuthorizedSender: true, senderIsOwner: true,
    channel: "telegram", accountId: "fixture", to: "123456789", agentId: "main", assertOwnerCurrent() {} };
  assert.equal(plugin.authorizedCommandContext(context), true);
  assert.equal(plugin.authorizedCommandContext({ ...context, senderId: "987654321", to: "987654321" }), true);
  assert.equal(plugin.authorizedCommandContext({ ...context, to: "-100123456789" }), false);
});

test("Zalo status exposes only selected account and fails closed", async () => {
  const commands = [];
  plugin.default.register({ registerTool() {}, registerCommand(value) { commands.push(value); } });
  const command = commands.find((value) => value.name === "zalostatus");
  assert.ok(command);
  assert.equal(command.requireAuth, true);
  const context = { senderId: "123456789", isAuthorizedSender: true, senderIsOwner: true,
    channel: "telegram", accountId: "fixture", to: "-100123456789", agentId: "main", assertOwnerCurrent() {} };
  assert.match((await command.handler(context)).text, /chỉ dành cho/);
  assert.match(plugin.summarizeZaloHealth({ ok: true, channels: { zalouser: { accounts: {
    default: { linked: false, running: false, lastError: "SECRET" },
  } } } }, "default"), /chưa đăng nhập; chưa chạy; chưa xác minh kết nối/);
  assert.doesNotMatch(plugin.summarizeZaloHealth({ ok: true, channels: { zalouser: { accounts: {
    default: { linked: true, running: true, connected: true, lastError: "SECRET" },
  } } } }, "default"), /SECRET/);
  assert.match(plugin.summarizeZaloHealth(null, "default"), /Không kiểm tra được/);
  assert.match(plugin.summarizeZaloHealth({ ok: true, channels: {} }, "default"), /Không thấy/);
});




test("existing lock prevents another login and is not deleted", async () => {
  const lock = path.join(state, "locks", "telegram-zalo-owner-login");
  mkdirSync(lock, { recursive: true });
  const result = await plugin.loginAndSendQr("123456789", () => {});
  assert.equal(result.status, "already_running");
  assert.equal(existsSync(lock), true);
  rmSync(lock, { recursive: true });
});

test("synthetic CLI sends private staged media with exact receipt; no network", async () => {
  const result = await plugin.loginAndSendQr("123456789", () => {});
  assert.equal(result.status, "login_completed");
  assert.equal(result.telegramMessageId, "synthetic-receipt");
  const delivered = JSON.parse(readFileSync(path.join(fixture, "delivered")));
  assert.equal(delivered.target, "123456789");
  assert.equal(existsSync(delivered.media), false);
  assert.deepEqual(readdirSync(path.join(state, "locks")), []);
});

test("wrong destination receipt fails closed without retry or login success", async () => {
  rmSync(path.join(fixture, "delivered"), { force: true });
  process.env.OWNER_QR_TEST_MODE = "wrong-chat";
  try {
    const result = await plugin.loginAndSendQr("123456789", () => {});
    assert.equal(result.status, "qr_delivery_unconfirmed");
    assert.equal(result.qrSent, null);
    assert.match(result.message, /biên nhận/);
    assert.deepEqual(readdirSync(path.join(state, "locks")), []);
  } finally {
    delete process.env.OWNER_QR_TEST_MODE;
  }
});

test.after(() => rmSync(fixture, { recursive: true, force: true }));
