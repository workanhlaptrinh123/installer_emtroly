# Native installation entry — OpenClaw 2026.11.4

This is the canonical LOCAL path. Do not load the legacy main SKILL.md as an
installation recipe: its global/root/Administrator and 2026.9.4 instructions do
not apply here. This template entry selects 2026.11.4, the current OS user,
one private instance and only the requested module integrations. The deployed web
form is a separate snapshot and must be verified before use. Do not read all
189 skill instructions in this template; verify the separately deployed web manifest before use. Install their files and read only the selected skills.

## Execute once, resume by evidence

1. Inspect OS, identity, existing named instance, bot use and chosen port once.
   New machines proceed without asking to confirm the plan. Preserve unrelated
   instances. For upgrades, back up the selected config, credentials, workspace
   and consistent database before migration. Never delete locks/state or kill
   every Node process. If the target is ambiguous, stop for one clarification.
2. Reuse suitable Node/npm/Python. Python Store aliases are not interpreters.
   Node must meet the pinned runtime's requirements. Install missing dependencies
   user-scope from official sources with verified hashes; no forced UAC or global
   replacement. FFmpeg is needed only for a selected media integration.
3. Fetch the form's one-use secret handoff once into a private credential file.
   Preserve that file for retry; never echo its payload/token/API key, put secrets
   in command argv, or consume the handoff twice. User-scope ACL on Windows,
   mode 0600 on POSIX. An expired handoff requires a new web request.
4. Runtime: reuse `<instance>/runtime/node_modules/openclaw/openclaw.mjs` only if
   its actual version equals 2026.11.4. Otherwise install the exact package into
   that runtime using npm --prefix, --no-audit, --no-fund, --prefer-offline.
   Keep npm's integrity checks. Do not delete npm cache, install latest, or run
   audit fix --force. Reviewed project-scoped allowScripts goes in package.json
   or .npmrc, never --allow-scripts on a prefix install.
   Missing `openclaw` on PATH does not mean the package is absent. Before any
   install, resolve the real absolute Node executable and selected CLI entry and
   run `[node, cli_entry, "--version"]` with `shell=False`; require 2026.11.4.
   For an existing global runtime, locate it through the real npm.cmd and
   `npm prefix -g`, then verify version and selected-instance identity before
   reuse. Do not guess another account's AppData or install again for PATH alone.
   Windows must expose the private runtime through `scripts/install_windows_cli.py`
   after creating its config (see below); merely adding AppData/npm is insufficient
   for a prefix install. Never reinstall globally only to repair PATH. Preserve
   the user's other PATH entries; never use setx PATH or overwrite machine PATH.
   Use absolute Node/CLI argv for every command, including probes; paths with
   spaces such as `C:\Users\Minh Vuong` must work. Adjust dependency PATH only
   in the current process when necessary; do not overwrite machine PATH, use
   npx latest, or require a terminal restart for installation to continue. Record
   `absolute_cli_verified` only after the version check succeeds.
5. Use `scripts/local_install.py sync` with the web manifest/source URLs,
   `--expected-count` from the form, private `--cache-dir`, and the selected
   `--workspace`. Pass `--manifest-file` with the already fetched manifest to
   avoid requesting it twice. It downloads at most six files concurrently, validates all
   paths/SHA256, reuses matching workspace/cache files, backs up changed files,
   and verifies the full manifest before returning. No bundle/bootstrap.
6. Create/validate the selected config with correct HOME, state/config paths,
   loopback port/auth, private tokenFile and provider credential from the handoff.
   Preserve the requested model, agent main, ownership and group policies. Bind
   both selected channels to the same main agent. Never borrow another client's
   token. Upgrade migrations use doctor --fix only on the stopped selected
   instance after a consistent backup, not as a generic retry step.
7. Apply the Telegram owner/media policy once, then the Telegram group allowlist
   last, at the channel and selected account: groupPolicy=allowlist, groups keyed
   only by the declared negative Group ID, never a wildcard group. A missing or
   invalid Group ID stops setup; do not fall back to open admission. Keep
   groupAllowFrom=['*'] so every member of an allowed group can use full tools
   without a mention. Group IDs belong in groups, not groupAllowFrom. Verify
   account overrides and rejection of unlisted groups. On upgrade preserve
   existing explicit allowed groups and add the declared Group ID after backup,
   removing any old wildcard. DM remains owner-only; Zalo policy is unchanged.
   These rules override broader legacy skill instructions. Group access does
   not make anyone an owner or a QR recipient. Do not execute unrelated scripts.
8. Before the first gateway start, configure only selected modules/plugins. For
   owner QR use deploy-native.py --ensure once with exact state/home/Node/CLI and
   channel account arguments; existing identical managed payloads are reused.
   Do not run dry-run + apply + check as three separate normal-install phases.
9. Windows: run `scripts/install_windows_cli.py --root <instance> --home <user-home>
   --node <absolute-node> --cli-entry <absolute-entry> --port <config-port>`.
   It checks 2026.11.4 before writes, creates a current-user `openclaw.cmd` plus a
   uniquely named instance alias, persists User PATH through HKCU/Environment,
   and broadcasts the change. It never overwrites a foreign CLI; if
   `default_cli=false`, use the returned `cli_alias` and report the conflict.
   Apply its returned `environment` to every later absolute Node/CLI invocation:
   remove keys with empty values and set the others. These fix state/config and
   a stable per-instance profile so service names cannot collide. Include the
   Node directory and `user_bin` in the agent/shell PATH. An existing parent CMD
   cannot have its environment changed by a child process; refresh that shell's
   PATH explicitly when running its commands. The shim uses absolute Node/CLI
   paths and UTF-8, including account names with spaces or Vietnamese characters.
   If a standard gateway service already owns this root, inspect its task
   command/environment and pass its verified profile with `--profile <existing>`
   (`default` when previously unset) before generating the shim; do not create
   a second service under a new profile for the same instance.

   Run the actual standard commands `openclaw gateway install --force --port <port>`
   and `openclaw gateway start` via absolute Node/CLI argv and the returned env.
   This command is allowed and required on Windows, not a prohibited fallback.
   OpenClaw 2026.11.4 implements its own Scheduled Task, hidden supervisor and
   current-user login-item fallback for restricted Task Scheduler permissions.
   Do not also install the custom native_launcher or its Startup VBS on Windows.
   For an upgrade with that launcher, verify its root/home/CLI/port ownership,
   back it up, stop it through its own `stop` API and move only its exact Startup
   entry out of Startup before registering the standard gateway. Do not kill
   unrelated Node processes. If ownership is ambiguous, stop migration safely.
   If standard installation fails, inspect task/process state before rollback;
   never restart the old supervisor alongside a potentially running standard one.

   macOS/Linux retain `scripts/install_native_launcher.py` with real absolute
   paths and `--expected-os macos|linux`, using LaunchAgent or systemd --user.
   Keep one supervisor per instance. User-login startup is not execution while
   powered off/asleep/logged out; do not silently change power or sleep policy.
10. Final gate once after configuration: config validate, gateway health/RPC,
    skills readiness and channel probe; plugins doctor when plugin changes were
    made. Windows additionally verifies `where.exe openclaw` (or `cli_alias`),
    shim `--version`, persisted User PATH and standard `gateway status --json`
    with the exact state/config/profile/port and one gateway. Restart the standard
    gateway once and repeat health/channel probes; installation exit 0 or a PID
    alone is not acceptance. If the bot is silent, inspect only its logs, network,
    credentials and Telegram 409/polling conflicts; do not reinstall npm or blame
    a launcher without evidence. Ask the owner to message the bot and observe a
    real response before claiming the live test passed. Probe immediately, then
    bounded backoff for startup/transient failures;
    no unconditional sleeps or repeat npm/config generation after a channel
    failure. Use config/media-policy/owner tests relevant to the selected mode.
    Real attachment and QR receipts remain pending until actually tested.

## Timing and scope

Use `local_install.py step --state <instance> --name <fixed-step> --timeout <bound>
-- <executable> <argv...>` for dependency/runtime/config/plugin/launcher/probe
commands. It records only step name, seconds, exit/status, not argv, credentials
or child output, in install-timings.json. Never put secrets in command arguments.
For sync record its returned counts/seconds in acceptance. Do not run competing
step writers against the same timings file. Successful steps are reused only
after checking their actual artifact/version/hash, not just a prior passed flag.
Retry transient network/startup failures at most three times for that step;
unsupported OS/SDK/auth, hash mismatch and conflicting identity are not retry loops.

## Zalo only when selected

Install the version-matched official plugin, owner QR adapter and the selected
Zalo skills. QR is private to a verified Telegram owner in the correct bot; the
owner must first start that bot. Keep login alive while sending the fresh staged
image, demand an exact message receipt, then verify Zalo listener connectivity
after scan. `/zaloqr` in owner DM handles future logins; never publish QR.

Apply the requested open DM/all-groups-no-mention policies after owner helpers,
without granting public owner authority. Use reviewed native text splitting and
receipt-aware delivery. Run relevant guard tests once. Docker/Supervisor/cron
installers and host-side session-rotation scripts are not native installers.
Do not invent or patch a new watchdog/rotation runtime during customer setup.
If a required native hook/rotation transport is unsupported, report the exact
protection-incomplete component immediately; preserve the healthy core/Telegram
and do not spend the session repeatedly rebuilding it. No success claim from
merely copying a skill. Keep all full V6 skill files even when integrations are
not selected; files installed and integrations active are separate statuses.
