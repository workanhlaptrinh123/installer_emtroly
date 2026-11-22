const fs = require('node:fs');
const path = require('node:path');
const {spawn} = require('node:child_process');

const root = __dirname;
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'installer-instance.json'), 'utf8'));
const pidFile = path.join(root, 'user-gateway.pid.json');
const stopFile = path.join(root, 'user-gateway.stop');
const logPath = path.join(root, 'user-gateway.log');
const action = process.argv[2];

if (action !== 'start' && action !== 'supervise') {
  throw new Error('Only the validated instance helper may manage the gateway.');
}

function buildGatewayEnvironment() {
  const environment = {
    ...process.env,
    HOME: manifest.home,
    OPENCLAW_PROFILE: manifest.profile,
    OPENCLAW_STATE_DIR: root,
    OPENCLAW_CONFIG_PATH: path.join(root, 'openclaw.json'),
    OPENCLAW_WORKSPACE_DIR: path.join(root, 'workspace'),
    PATH: manifest.path,
  };
  for (const name of [
    'OPENCLAW_HOME',
    'OPENCLAW_GATEWAY_TOKEN',
    'OPENCLAW_GATEWAY_PASSWORD',
    'OPENCLAW_GATEWAY_PORT',
    'OPENCLAW_SYSTEMD_UNIT',
    'OPENCLAW_LAUNCHD_LABEL',
    'OPENCLAW_WINDOWS_TASK_NAME',
    'OPENCLAW_SERVICE_KIND',
    'OPENCLAW_SERVICE_MARKER',
  ]) {
    delete environment[name];
  }
  return environment;
}

if (action === 'start') {
  try {
    if (fs.existsSync(stopFile)) fs.unlinkSync(stopFile);
  } catch {}
  fs.writeFileSync(
    pidFile,
    JSON.stringify({pid: null, supervisorPid: null, startedAt: Date.now(), cli_entry: manifest.cli_entry}),
    {mode: 0o600, flag: 'wx'},
  );
  const environment = buildGatewayEnvironment();
  const log = fs.openSync(logPath, 'a', 0o600);
  const supervisor = spawn(process.execPath, [__filename, 'supervise'], {
    cwd: root,
    env: environment,
    detached: true,
    windowsHide: true,
    stdio: ['ignore', log, log],
  });
  supervisor.once('error', () => {
    try { fs.unlinkSync(pidFile); } catch {}
    process.stderr.write('User gateway could not start.\n');
    process.exitCode = 1;
  });
  supervisor.once('spawn', () => {
    supervisor.unref();
    const deadline = Date.now() + 3000;
    const poll = () => {
      try {
        const rec = JSON.parse(fs.readFileSync(pidFile, 'utf8'));
        if (rec && rec.pid) return;
      } catch {}
      if (Date.now() < deadline) {
        setTimeout(poll, 60);
      }
    };
    poll();
  });
  fs.closeSync(log);
} else if (action === 'supervise') {
  const environment = buildGatewayEnvironment();
  const customBackoff = Number(process.env.EMTROLY_SUPERVISOR_BACKOFF_MS || '0');
  const maxCrashes = Number(process.env.EMTROLY_SUPERVISOR_MAX_CRASHES || '5');
  const backoffs = [3000, 8000, 15000];
  let activeChild = null;
  let crashCount = 0;
  let stopping = false;

  const shouldStop = () => stopping || fs.existsSync(stopFile) || !fs.existsSync(pidFile);

  const shutdown = () => {
    stopping = true;
    if (activeChild && activeChild.pid) {
      try { activeChild.kill('SIGTERM'); } catch {}
    }
    try { if (fs.existsSync(stopFile)) fs.unlinkSync(stopFile); } catch {}
    process.exit(0);
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);

  const launchOnce = () => {
    if (shouldStop()) {
      try { if (fs.existsSync(stopFile)) fs.unlinkSync(stopFile); } catch {}
      process.exit(0);
      return;
    }
    const log = fs.openSync(logPath, 'a', 0o600);
    const childStartedAt = Date.now();
    const child = spawn(
      manifest.node,
      [manifest.cli_entry, 'gateway', 'run', '--port', String(manifest.port)],
      {cwd: root, env: environment, windowsHide: true, stdio: ['ignore', log, log]},
    );
    fs.closeSync(log);
    activeChild = child;

    child.once('spawn', () => {
      try {
        if (!fs.existsSync(stopFile)) {
          fs.writeFileSync(
            pidFile,
            JSON.stringify({
              pid: child.pid,
              supervisorPid: process.pid,
              startedAt: childStartedAt,
              cli_entry: manifest.cli_entry,
            }),
            {mode: 0o600},
          );
        }
      } catch {}
    });

    child.once('error', (err) => {
      try {
        fs.appendFileSync(logPath, `[emtroly-supervisor] gateway spawn error: ${err.message}\n`, {mode: 0o600});
      } catch {}
    });

    child.once('exit', (code, sig) => {
      activeChild = null;
      if (shouldStop()) {
        try { if (fs.existsSync(stopFile)) fs.unlinkSync(stopFile); } catch {}
        process.exit(0);
        return;
      }
      if (Date.now() - childStartedAt >= 45000) {
        crashCount = 0;
      }
      crashCount += 1;
      if (crashCount > maxCrashes) {
        try {
          fs.appendFileSync(logPath, `[emtroly-supervisor] exceeded max rapid restarts (${maxCrashes}); stopping.\n`, {mode: 0o600});
          if (fs.existsSync(pidFile)) fs.unlinkSync(pidFile);
        } catch {}
        process.exit(1);
        return;
      }
      const delayMs = customBackoff > 0 ? customBackoff : backoffs[Math.min(crashCount - 1, backoffs.length - 1)];
      try {
        fs.appendFileSync(
          logPath,
          `[emtroly-supervisor] gateway exited (code=${code}, signal=${sig}); restarting in ${delayMs}ms (attempt ${crashCount}/${maxCrashes})...\n`,
          {mode: 0o600},
        );
      } catch {}
      setTimeout(launchOnce, delayMs);
    });
  };

  launchOnce();
}
