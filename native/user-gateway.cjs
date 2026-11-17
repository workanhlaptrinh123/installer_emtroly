const fs = require('node:fs');
const path = require('node:path');
const {spawn} = require('node:child_process');

const root = __dirname;
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'installer-instance.json'), 'utf8'));
const pidFile = path.join(root, 'user-gateway.pid.json');
const action = process.argv[2];
if (action !== 'start') throw new Error('Only the validated instance helper may manage the gateway.');
fs.writeFileSync(pidFile, JSON.stringify({pid: null, cli_entry: manifest.cli_entry}), {mode: 0o600, flag: 'wx'});
const environment = {...process.env, HOME: manifest.home, OPENCLAW_PROFILE: manifest.profile,
  OPENCLAW_STATE_DIR: root, OPENCLAW_CONFIG_PATH: path.join(root, 'openclaw.json'),
  OPENCLAW_WORKSPACE_DIR: path.join(root, 'workspace'), PATH: manifest.path};
for (const name of ['OPENCLAW_HOME', 'OPENCLAW_GATEWAY_TOKEN', 'OPENCLAW_GATEWAY_PASSWORD',
  'OPENCLAW_GATEWAY_PORT', 'OPENCLAW_SYSTEMD_UNIT', 'OPENCLAW_LAUNCHD_LABEL',
  'OPENCLAW_WINDOWS_TASK_NAME', 'OPENCLAW_SERVICE_KIND', 'OPENCLAW_SERVICE_MARKER']) delete environment[name];
const log = fs.openSync(path.join(root, 'user-gateway.log'), 'a', 0o600);
const child = spawn(manifest.node, [manifest.cli_entry, 'gateway', 'run', '--port', String(manifest.port)],
  {cwd: root, env: environment, detached: true, windowsHide: true, stdio: ['ignore', log, log]});
child.once('error', () => { fs.unlinkSync(pidFile); process.stderr.write('User gateway could not start.\n'); process.exitCode = 1; });
child.once('spawn', () => {
  fs.writeFileSync(pidFile, JSON.stringify({pid: child.pid, cli_entry: manifest.cli_entry}), {mode: 0o600});
  child.unref();
});
fs.closeSync(log);
