# macOS and Ubuntu installer preview

This is a development preview, not an official release. The Windows release
workflow is unchanged. The preview builds have not been validated end-to-end
on customer machines or with a real Telegram bot and Zalo account.

## Ubuntu terminal preview

For Ubuntu Desktop or a headless Ubuntu VPS, clone the repository as a normal
user and run `./install-ubuntu.sh`. The existing root `install.sh` is a
different Docker member installer and must not be used for this workflow.
The terminal installer does not provide a browser dashboard. If the repository
is private, the user needs GitHub read access before cloning.

Run `./install-ubuntu.sh --check` first to check the Linux user and systemd
user-service prerequisites without downloading or creating an assistant. Log
in directly over SSH as the non-root user; `sudo`, `su`, and containers without
a working systemd user service are not supported installation contexts. To
keep a user service available after logout/reboot on a VPS, an administrator
may opt in to `sudo loginctl enable-linger "$USER"` after verifying the account.
The installer never changes linger, SSH configuration, firewall, or other users.

If the bootstrap Python is missing, the script asks before using sudo and apt
to install `python3` and `ca-certificates`. When Python is present but older
than 3.11 or lacks SQLite/SSL, it downloads a checksum-verified private Python
and re-executes the installer with it. The normal flow prepares private Node,
Python and FFmpeg as needed; it does not replace system runtimes.

The prompts require owner ID(s), a negative Telegram group ID, bot token,
provider URL and API key; credentials are entered without terminal echo. Use a
dedicated bot, do not paste secrets into shell commands or chat, and authorize
Full Exec only for trusted owners. Full Exec permits those owners to execute
commands and access files available to that Linux account. A successful
installer checks service/plugin/command registration; real Telegram delivery,
QR scanning and Zalo connection are separate acceptance checks.

- Each assistant is isolated under `~/.openclaw-member-<name>`; an existing
  instance with the same name is never overwritten.
- The installer asks for explicit consent before enabling owner Full Exec.
  This allows the configured owners to execute commands and access files.
- Node.js is pinned and installed privately. Python and FFmpeg are downloaded
  into the user's private dependency directory if suitable versions are absent.
  Python builds come from python-build-standalone; FFmpeg builds come from
  imageio-ffmpeg. Their respective licenses and distribution terms apply.
- Gateway health, plugin loading, QR command registration and the Telegram
  command menu must pass before the installer reports success. Logging in to
  Zalo is a separate step: `/zaloqr`, then `/zalostatus`.
- A shell PATH update is backed up first and never overwrites a pre-existing
  OpenClaw command. If another OpenClaw already exists, an instance-specific
  alias is used instead. Restart the terminal after installation.
- Linux requires a desktop session and a working systemd user service. On
  macOS, the gateway uses the user launch service. The computer must be on
  and the user session available for the gateway to respond.
- Ubuntu x64 builds can also be packaged as a `.deb` preview with
  `python3 unix-installer/build-ubuntu-deb.py <binary> <new-file.deb> --architecture amd64 --minimum-glibc 2.35`.
  That example assumes the executable was built on Ubuntu 22.04; set the
  minimum glibc to match the build machine, not the intended target machine.
  The `.deb` declares SQLite and system CA certificates as dependencies;
  the portable `.tar.gz` requires these libraries to be available already.
  On a test machine, install it with `sudo apt install ./<new-file.deb>`, then
  open **Em Tro Ly (ban thu)** from the desktop application menu as the normal
  logged-in user. Never launch the assistant installer with `sudo`. Removing
  the package does not remove installed assistant data in the user's home.
- macOS preview builds are unsigned and not notarized. Before distributing to
  customers, build and test both Intel and Apple Silicon, then arrange Apple
  signing/notarization. Do not disable system security as a workaround.

Run `python3 -m unittest discover -s unix-installer -p 'test_*.py'` for offline
tests. Set `UNIX_INSTALLER_LIVE_TEST=1` to run the slower network integration
using fake credentials; this does not start a gateway or contact Telegram.
The Ubuntu workflow's `live_test` also installs the `.deb` into a clean
Ubuntu 22.04 container and runs the packaged smoke test.
`build-preview.sh` builds on the host OS when Python, Tk and PyInstaller are
present. `.github/workflows/unix-preview.yml` offers manual preview builds only;
it does not publish a Release or change the existing Windows pipeline. Its
optional `systemd_test` creates and removes a separate temporary user service
only on a disposable Ubuntu GitHub runner, using fake credentials and with
Telegram disabled. This is not a substitute for testing a customer's desktop.
