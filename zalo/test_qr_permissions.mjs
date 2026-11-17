import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("../native/skills/openclaw-zalo-qr-login/scripts/send_zalo_qr_to_telegram_owner.mjs", import.meta.url), "utf8");
const section = source.slice(source.indexOf("function fail("), source.indexOf("function resolveTelegramAccount("));
const context = vm.createContext({});
vm.runInContext(section, context);

const owner = "123456789";
const config = {
  commands: { ownerAllowFrom: [`telegram:${owner}`] },
  channels: { telegram: { allowFrom: [owner], execApprovals: { approvers: [owner] } } },
  approvals: { plugin: { targets: [{ channel: "telegram", to: owner, accountId: "fixture" }] } },
};

test("configured owner can receive QR without unrelated elevated permission", () => {
  assert.doesNotThrow(() => context.validateOwnerPermissions(config, owner));
});

test("missing owner, DM, approver or delivery target is rejected", () => {
  for (const key of ["owner", "dm", "approver", "target"]) {
    const invalid = structuredClone(config);
    if (key === "owner") invalid.commands.ownerAllowFrom = ["*"];
    if (key === "dm") invalid.channels.telegram.allowFrom = ["*"];
    if (key === "approver") invalid.channels.telegram.execApprovals.approvers = [];
    if (key === "target") invalid.approvals.plugin.targets = [];
    assert.throws(() => context.validateOwnerPermissions(invalid, owner), /missing required permissions/);
  }
});
