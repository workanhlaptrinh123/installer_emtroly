"""Exercise the packaged runner with mocked external operations and fake data."""

import json
import os
from pathlib import Path
import sys
import tempfile
import tkinter
import sqlite3
import ssl

import runner


def main():
    source = Path(sys._MEIPASS).resolve(strict=True)
    assert (source / "native/skills/telegram-zalo-owner-login/SKILL.md").is_file()
    assert (source / "zalo/configure-zalo.py").is_file()
    assert (source / "windows-installer/zalo-qr-session.mjs").is_file()
    tkinter.Tcl().eval("info patchlevel")
    with tempfile.TemporaryDirectory(prefix="installer-frozen-smoke-") as temporary:
        home = Path(temporary).resolve()
        os.environ["HOME"] = str(home)
        os.environ["SHELL"] = "/bin/bash"
        runner.os.geteuid = lambda: 1000
        node = home / "node"
        node.write_text('#!/bin/sh\necho "OpenClaw 2026.11.4"\n')
        node.chmod(0o700)
        npm = home / "npm"
        npm.touch()
        runner.telegram.verify_bot = lambda token: None
        runner.provider.verify = lambda url, key, model: model
        runner.choose_port = lambda requested: 19789
        runner.service.check_linux_user_service = lambda: None
        runner.dependencies.install_node = lambda directory: (node, npm)
        runner.python_runtime.install = lambda directory: Path(sys.executable)
        runner.ffmpeg.install = lambda directory: Path(sys.executable)
        def initialize(values, selected_home, port):
            root = selected_home / ".openclaw-member-member01"
            root.mkdir()
            (root / "openclaw.json").write_text("{}")
            return root
        def install_runtime(root, selected_home, selected_node, selected_npm, extra_bins=()):
            entry = root / "openclaw.mjs"
            entry.touch()
            return entry, {"OPENCLAW_PROFILE": "member-member01"}
        runner.instance.initialize = initialize
        runner.runtime.install = install_runtime
        runner.payload.install = lambda *args: None
        runner.zalo_setup.configure = lambda *args: None
        runner.service.install_and_verify = lambda *args: None
        runner.telegram.ensure_menu = lambda token: None
        settings = {"member": "member01", "assistant_name": "Assistant", "owner_ids": "12345",
                    "qr_owner_id": "12345", "group_id": "-12345", "telegram_token": "123456:" + "x" * 30,
                    "base_url": "https://example.com/v1", "ai_api_key": "fake-key", "model": "gpt-6.2-sol",
                    "gateway_port": "0", "accept_full_access": True}
        result = runner.install(settings, source)
        assert result["gateway_port"] == 19789
        assert (Path(result["cli"]["directory"]) / result["cli"]["command"]).is_file()
        assert result["cli"]["shell_path"]["updated"] is True
        print(json.dumps({"frozen_smoke": "ok", "external_operations": "mocked"}))


if __name__ == "__main__":
    main()
