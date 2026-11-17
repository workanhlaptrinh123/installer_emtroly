# V6 modules

V6 separates the member runtime into a stable core, default core modules and
optional modules. Every module is versioned and must contain a `module.json`.

Core modules are selected by `profiles/basic-assistant-full.json` and are
installed from the image without downloading dependencies during member
provisioning. Optional modules are selected per member through the member
settings file or a profile.

Zalo Personal (`zalo-personal`) is selectable in both new-install and member
module-update forms. Selecting it on a new VPS install also enables Zalo
onboarding. For an existing VPS, select the member and this module; the updater
backs up its configuration, installs/enables the plugin and waits for QR login.
Choose a verified Telegram owner to receive the QR through the member's own
bot, not the installer bot. Updates appear in Recent Jobs and Telegram status
buttons. Telegram tokens, provider keys and the existing member are reused;
no reinstall or credential copy from another member is needed. The default
profile may include Zalo skill files without activating a Zalo account.

Modules contain clean code, skills, scripts and service templates only. Native
local installations use the same catalog through `native/module-manager.py`,
`native/module-manager.sh` and `native/module-manager.ps1`; Docker keeps using
the container-side `member-module`. Both managers write per-member state and
never share credentials.

Modules contain clean code, skills, scripts and service templates only. They
must never contain credentials, tokens, cookies, browser profiles, sessions,
databases, logs, generated media or customer history. The native skill mapping
used by local installations is stored in `native/module-skills.json`.
