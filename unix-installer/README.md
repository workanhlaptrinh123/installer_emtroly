# macOS and Ubuntu installer preview

This is a development preview, not an official release. The Windows release
workflow is unchanged. The preview builds have not been validated end-to-end
on customer machines or with a real Telegram bot and Zalo account.

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
- macOS preview builds are unsigned and not notarized. Before distributing to
  customers, build and test both Intel and Apple Silicon, then arrange Apple
  signing/notarization. Do not disable system security as a workaround.

Run `python3 -m unittest discover -s unix-installer -p 'test_*.py'` for offline
tests. Set `UNIX_INSTALLER_LIVE_TEST=1` to run the slower network integration
using fake credentials; this does not start a gateway or contact Telegram.
`build-preview.sh` builds on the host OS when Python, Tk and PyInstaller are
present. `.github/workflows/unix-preview.yml` offers manual preview builds only;
it does not publish a Release or change the existing Windows pipeline.
