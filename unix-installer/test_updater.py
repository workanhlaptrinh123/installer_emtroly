"""Unit and integration tests for unix-installer/updater.py."""

from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
import urllib.error
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import updater  # noqa: E402


class FakeHttpResponse:
    def __init__(self, body: bytes, *, url: str = "https://github.com/workanhlaptrinh123/installer_emtroly"):
        self._stream = io.BytesIO(body)
        self.url = url
        self.headers = {"Content-Length": str(len(body))}

    def read(self, size: int = -1) -> bytes:
        return self._stream.read(size)

    def geturl(self) -> str:
        return self.url

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class FakeOpener:
    def __init__(self, handler):
        self._handler = handler

    def open(self, req, timeout=15):
        url = req.full_url if hasattr(req, "full_url") else str(req)
        return self._handler(url)


class UnixUpdaterTests(unittest.TestCase):
    def test_version_comparison_and_trusted_github_urls(self):
        self.assertEqual(updater.compare_versions("2026.11.24.2", "v2026.11.24.3"), -1)
        self.assertEqual(updater.compare_versions("v2026.11.24.3", "2026.11.24.3"), 0)
        self.assertEqual(updater.compare_versions("2026.12.1", "2026.11.24.9"), 1)

        self.assertTrue(updater.is_trusted_github_url("https://api.github.com/repos/a/b/releases/latest"))
        self.assertTrue(updater.is_trusted_github_url("https://objects.githubusercontent.com/github-production-release-asset/x"))
        self.assertFalse(updater.is_trusted_github_url("http://github.com/a/b"))
        self.assertFalse(updater.is_trusted_github_url("https://evil-github.com/emtroly.zip"))
        self.assertFalse(updater.is_trusted_github_url("https://user:pass@github.com/a/b"))
        self.assertFalse(updater.is_trusted_github_url("http://127.0.0.1:8080/latest", allow_loopback=False))
        self.assertTrue(updater.is_trusted_github_url("http://127.0.0.1:8080/latest", allow_loopback=True))

    def test_check_for_updates_api_and_rate_limit_fallback(self):
        release_json = {
            "tag_name": "v2026.12.01.1",
            "html_url": "https://github.com/workanhlaptrinh123/installer_emtroly/releases/tag/v2026.12.01.1",
            "body": "Thêm nút cập nhật phiên bản mới tự động",
            "assets": [
                {
                    "name": "emtroly-macos-arm64.zip",
                    "browser_download_url": "https://github.com/workanhlaptrinh123/installer_emtroly/releases/download/v2026.12.01.1/emtroly-macos-arm64.zip",
                    "size": 123456,
                },
                {
                    "name": "emtroly-macos-arm64.zip.sha256",
                    "browser_download_url": "https://github.com/workanhlaptrinh123/installer_emtroly/releases/download/v2026.12.01.1/emtroly-macos-arm64.zip.sha256",
                    "size": 90,
                },
            ],
        }
        opener = FakeOpener(lambda url: FakeHttpResponse(json.dumps(release_json).encode("utf-8"), url=url))

        upd = updater.check_for_updates(
            "2026.11.24.3",
            system="Darwin",
            machine="arm64",
            is_frozen=True,
            opener=opener,
        )
        self.assertTrue(upd["ok"])
        self.assertTrue(upd["has_update"])
        self.assertEqual(upd["latest_version"], "2026.12.01.1")
        self.assertEqual(upd["asset_name"], "emtroly-macos-arm64.zip")
        self.assertEqual(upd["install_kind"], "macos-app")

        same = updater.check_for_updates(
            "2026.12.01.1",
            system="Darwin",
            machine="arm64",
            is_frozen=True,
            opener=opener,
        )
        self.assertTrue(same["ok"])
        self.assertFalse(same["has_update"])

        # Rate-limit fallback: api.github.com returns 403, MANIFEST.txt succeeds
        def _rate_limited(url: str):
            if "api.github.com" in url:
                raise urllib.error.HTTPError(url, 403, "rate limit exceeded", {}, io.BytesIO(b""))
            if url.endswith("/MANIFEST.txt"):
                return FakeHttpResponse(b"product=installer_emtroly\ninstaller_version=2026.12.05.2\n", url=url)
            raise AssertionError(f"Unexpected URL: {url}")

        fb = updater.check_for_updates(
            "2026.11.24.3",
            system="Linux",
            machine="x86_64",
            executable="/home/user/emtroly",
            is_frozen=True,
            opener=FakeOpener(_rate_limited),
        )
        self.assertTrue(fb["ok"])
        self.assertTrue(fb["has_update"])
        self.assertEqual(fb["latest_version"], "2026.12.05.2")
        self.assertTrue(fb["download_url"].endswith("/v2026.12.05.2/emtroly-linux-x64.tar.gz"))

    def test_download_sha256_verification_and_linux_macos_apply(self):
        prev_skip = os.environ.get("EMTROLY_TEST_SKIP_UPDATE_RELAUNCH")
        os.environ["EMTROLY_TEST_SKIP_UPDATE_RELAUNCH"] = "1"
        try:
            with tempfile.TemporaryDirectory(prefix="emtroly-unix-upd-test-") as td:
                root = Path(td)
                # 1. Build a valid Linux .tar.gz containing new executable
                tar_buf = io.BytesIO()
                new_elf = b"#!/bin/sh\necho emtroly-v2026.12.10\n"
                with tarfile.open(fileobj=tar_buf, mode="w:gz") as tf:
                    ti = tarfile.TarInfo(name="emtroly")
                    ti.size = len(new_elf)
                    ti.mode = 0o755
                    tf.addfile(ti, io.BytesIO(new_elf))
                tar_bytes = tar_buf.getvalue()
                tar_sha = hashlib.sha256(tar_bytes).hexdigest()

                info_linux = {
                    "latest_version": "2026.12.10",
                    "asset_name": "emtroly-linux-x64.tar.gz",
                    "download_url": "https://github.com/workanhlaptrinh123/installer_emtroly/releases/download/v2026.12.10/emtroly-linux-x64.tar.gz",
                    "sha256_url": "https://github.com/workanhlaptrinh123/installer_emtroly/releases/download/v2026.12.10/emtroly-linux-x64.tar.gz.sha256",
                    "install_kind": "linux-binary",
                }
                good_opener = FakeOpener(
                    lambda url: FakeHttpResponse(
                        f"{tar_sha}  emtroly-linux-x64.tar.gz\n".encode("ascii") if url.endswith(".sha256") else tar_bytes,
                        url=url,
                    )
                )
                dl = updater.download_and_verify_update(info_linux, dest_dir=root / "cache", opener=good_opener)
                self.assertTrue(dl["ok"])
                self.assertEqual(dl["sha256"], tar_sha)

                fake_running_exe = root / "bin/emtroly"
                fake_running_exe.parent.mkdir(parents=True)
                fake_running_exe.write_bytes(b"old-binary")
                applied = updater.apply_and_relaunch_update(
                    dl["archive_path"],
                    info_linux,
                    executable=fake_running_exe,
                    is_frozen=True,
                )
                self.assertTrue(applied["ok"])
                self.assertEqual(fake_running_exe.read_bytes(), new_elf)

                # 2. Tampered SHA-256 must fail closed and leave no .part file
                bad_opener = FakeOpener(
                    lambda url: FakeHttpResponse(
                        ("0" * 64 + "  emtroly-linux-x64.tar.gz\n").encode("ascii") if url.endswith(".sha256") else tar_bytes,
                        url=url,
                    )
                )
                bad_cache = root / "bad-cache"
                with self.assertRaises(ValueError):
                    updater.download_and_verify_update(info_linux, dest_dir=bad_cache, opener=bad_opener)
                self.assertEqual(list(bad_cache.glob("*")), [])

                # 3. macOS .zip bundle swap
                zip_path = root / "emtroly-macos-arm64.zip"
                with zipfile.ZipFile(zip_path, "w") as zf:
                    zf.writestr("EmTroLy.app/Contents/MacOS/EmTroLy", "new-macos-binary")
                old_app_exe = root / "Apps/EmTroLy.app/Contents/MacOS/EmTroLy"
                old_app_exe.parent.mkdir(parents=True)
                old_app_exe.write_text("old-macos-binary", encoding="utf-8")
                mac_applied = updater.apply_and_relaunch_update(
                    zip_path,
                    {"install_kind": "macos-app"},
                    executable=old_app_exe,
                    is_frozen=True,
                )
                self.assertTrue(mac_applied["ok"])
                self.assertEqual(old_app_exe.read_text(encoding="utf-8"), "new-macos-binary")
        finally:
            if prev_skip is None:
                os.environ.pop("EMTROLY_TEST_SKIP_UPDATE_RELAUNCH", None)
            else:
                os.environ["EMTROLY_TEST_SKIP_UPDATE_RELAUNCH"] = prev_skip


if __name__ == "__main__":
    unittest.main()
