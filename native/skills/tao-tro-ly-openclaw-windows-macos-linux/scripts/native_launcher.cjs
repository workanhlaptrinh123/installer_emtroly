const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

function loadSettings(filename) {
  const settings = JSON.parse(fs.readFileSync(filename, 'utf8'));
  for (const name of ['root', 'home', 'node', 'cli_entry']) {
    if (!path.isAbsolute(settings[name]) || !fs.existsSync(settings[name])) throw new Error('Invalid native launcher paths');
  }
  if (!Number.isInteger(settings.port) || settings.port < 1024 || settings.port > 65535) throw new Error('Invalid gateway port');
  if (!fs.existsSync(path.join(settings.root, 'openclaw.json'))) throw new Error('Selected config is missing');
  return settings;
}

function environment(settings) {
  const result = { ...process.env, HOME: settings.home, OPENCLAW_STATE_DIR: settings.root,
    OPENCLAW_CONFIG_PATH: path.join(settings.root, 'openclaw.json'), OPENCLAW_WORKSPACE_DIR: path.join(settings.root, 'workspace') };
  if (settings.path) result.PATH = settings.path;
  for (const name of ['OPENCLAW_HOME', 'OPENCLAW_PROFILE', 'OPENCLAW_GATEWAY_TOKEN', 'OPENCLAW_GATEWAY_PASSWORD',
    'OPENCLAW_GATEWAY_PORT', 'OPENCLAW_SYSTEMD_UNIT', 'OPENCLAW_LAUNCHD_LABEL', 'OPENCLAW_WINDOWS_TASK_NAME']) delete result[name];
  return result;
}

function alive(processId) {
  if (!Number.isInteger(processId) || processId < 1) return false;
  try { process.kill(processId, 0); return true; } catch (error) { return error.code === 'EPERM'; }
}

function writeJson(filename, value) {
  const temporary = filename + '.' + crypto.randomUUID();
  fs.writeFileSync(temporary, JSON.stringify(value), { mode: 0o600 });
  fs.renameSync(temporary, filename);
}

async function main(action, filename) {
  const settings = loadSettings(filename);
  const lock = path.join(settings.root, 'native-launcher.lock');
  const ownerFile = path.join(lock, 'owner.json');
  let record;
  try { record = JSON.parse(fs.readFileSync(ownerFile, 'utf8')); } catch {}
  if (action === 'status') {
    return { supervisor_running: Boolean(record && alive(record.pid)), gateway_pid: record?.childPid ?? null, health: 'not_probed' };
  }
  if (action === 'stop') {
    if (!record || !alive(record.pid)) return { stopped: false, reason: 'no_live_supervisor' };
    if (record.config !== path.resolve(filename)) throw new Error('Launcher identity mismatch');
    writeJson(path.join(lock, 'stop.json'), { token: record.token });
    for (let attempt = 0; attempt < 100 && fs.existsSync(ownerFile); attempt += 1) await new Promise(resolve => setTimeout(resolve, 100));
    if (fs.existsSync(ownerFile)) throw new Error('Stop pending; do not kill another process or start a duplicate');
    return { stopped: true };
  }
  if (action === 'start') {
    if (record && alive(record.pid)) return { already_running: true };
    if (record && alive(record.childPid)) throw new Error('Unsupervised gateway may still be running; do not start another');
    const output = fs.openSync(path.join(settings.root, 'native-launcher.log'), 'a', 0o600);
    const supervisor = spawn(process.execPath, [__filename, 'supervise', path.resolve(filename)], {
      detached: true, windowsHide: true, stdio: ['ignore', output, output], env: environment(settings), cwd: settings.root,
    });
    fs.closeSync(output);
    await new Promise((resolve, reject) => { supervisor.once('spawn', resolve); supervisor.once('error', reject); });
    supervisor.unref();
    return { started: true, health: 'pending_probe' };
  }
  if (action !== 'supervise') throw new Error('Unsupported launcher action');
  try { fs.mkdirSync(lock, { mode: 0o700 }); } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    if (!record || alive(record.pid) || alive(record.childPid)) return { already_running: true, reason: 'lock_held' };
    fs.renameSync(lock, lock + '.stale-' + crypto.randomUUID());
    fs.mkdirSync(lock, { mode: 0o700 });
  }
  const token = crypto.randomUUID();
  record = { token, pid: process.pid, childPid: null, config: path.resolve(filename) };
  writeJson(ownerFile, record);
  let stopping = false;
  let child;
  let killTimer;
  let failures = 0;
  const stop = () => {
    stopping = true;
    child?.kill('SIGTERM');
    killTimer ??= setTimeout(() => child?.kill('SIGKILL'), 8000);
  };
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);
  const timer = setInterval(() => {
    try { if (JSON.parse(fs.readFileSync(path.join(lock, 'stop.json'), 'utf8')).token === token) stop(); } catch {}
  }, 250);
  try {
    while (!stopping) {
      const started = Date.now();
      child = spawn(settings.node, [settings.cli_entry, 'gateway', 'run', '--port', String(settings.port)], {
        windowsHide: true, stdio: ['ignore', 'inherit', 'inherit'], env: environment(settings), cwd: settings.root,
      });
      await new Promise(resolve => {
        child.once('spawn', () => { record.childPid = child.pid; writeJson(ownerFile, record); });
        child.once('error', resolve);
        child.once('close', resolve);
      });
      record.childPid = null;
      clearTimeout(killTimer);
      writeJson(ownerFile, record);
      if (stopping) break;
      failures = Date.now() - started > 60000 ? 0 : failures + 1;
      const delay = Math.min(60000, 1000 * 2 ** Math.min(failures, 6));
      for (let elapsed = 0; elapsed < delay && !stopping; elapsed += 250) await new Promise(resolve => setTimeout(resolve, 250));
    }
  } finally {
    clearInterval(timer);
    clearTimeout(killTimer);
    try { if (JSON.parse(fs.readFileSync(ownerFile, 'utf8')).token === token) fs.rmSync(lock, { recursive: true }); } catch {}
  }
  return { stopped: true };
}

module.exports = { loadSettings, environment, alive, main };
if (require.main === module) {
  main(process.argv[2], process.argv[3]).then(result => console.log(JSON.stringify(result)), () => {
    console.error('Native launcher failed; inspect this instance only.');
    process.exitCode = 1;
  });
}
