const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');
const launcher = require('./native_launcher.cjs');

test('isolated environment removes ambient profile and gateway secret overrides', () => {
  const oldProfile = process.env.OPENCLAW_PROFILE;
  process.env.OPENCLAW_PROFILE = 'another-customer';
  const env = launcher.environment({ root: '/fixture', home: '/home' });
  assert.equal(env.OPENCLAW_PROFILE, undefined);
  assert.equal(env.OPENCLAW_STATE_DIR, '/fixture');
  if (oldProfile === undefined) delete process.env.OPENCLAW_PROFILE;
  else process.env.OPENCLAW_PROFILE = oldProfile;
});

test('absolute paths with spaces start without PATH, restart own child and stop by private token', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'native launcher Minh Vuong '));
  const entry = path.join(root, 'fake.mjs');
  const config = path.join(root, 'settings.json');
  fs.writeFileSync(path.join(root, 'openclaw.json'), '{}');
  fs.writeFileSync(entry, `import fs from 'node:fs'; import path from 'node:path';
const root=process.env.OPENCLAW_STATE_DIR; const marker=path.join(root,'runs.json');
const count=fs.existsSync(marker)?JSON.parse(fs.readFileSync(marker))+1:1;
fs.writeFileSync(marker,JSON.stringify(count));
if(count===1) process.exit(1); else setInterval(()=>{},1000);`);
  fs.writeFileSync(config, JSON.stringify({ root, home: root, node: process.execPath, cli_entry: entry, port: 23456, path: path.join(root, 'no-executables') }));
  const executable = path.join(__dirname, 'native_launcher.cjs');
  const call = action => spawnSync(process.execPath, [executable, action, config], { encoding: 'utf8', timeout: 15000, env: { ...process.env, PATH: path.join(root, 'no-executables') } });
  try {
    assert.equal(call('start').status, 0);
    let runs = 0;
    for (let attempt = 0; attempt < 80; attempt += 1) {
      await new Promise(resolve => setTimeout(resolve, 100));
      try { runs = JSON.parse(fs.readFileSync(path.join(root, 'runs.json'))); } catch {}
      if (runs >= 2) break;
    }
    assert.equal(runs, 2);
    assert.equal(JSON.parse(call('start').stdout).already_running, true);
    const status = JSON.parse(call('status').stdout);
    assert.equal(status.supervisor_running, true);
    assert.equal(status.health, 'not_probed');
    assert.equal(call('stop').status, 0);
    assert.equal(JSON.parse(call('status').stdout).supervisor_running, false);
  } finally {
    call('stop');
    fs.rmSync(root, { recursive: true, force: true });
  }
});
