"""GitHub release version checker and SHA-256 verified self-updater for macOS & Linux."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

import net_utils
import python_exec


OFFICIAL_REPO = "workanhlaptrinh123/installer_emtroly"
USER_AGENT = "AnhLapTrinh-EmTroLy-UnixUpdater/1.0"
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?$")
SHA256_RE = re.compile(r"\b([a-fA-F0-9]{64})\b")


def _parse_version_tuple(raw: str) -> tuple[int, ...]:
    cleaned = str(raw or "").strip().lstrip("vV")
    main = cleaned.split("-", 1)[0].split("+", 1)[0]
    parts: list[int] = []
    for seg in main.split("."):
        try:
            parts.append(int(seg))
        except ValueError:
            parts.append(0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts)


def compare_versions(current: str, target: str) -> int:
    a = _parse_version_tuple(current)
    b = _parse_version_tuple(target)
    max_len = max(len(a), len(b))
    a_pad = a + (0,) * (max_len - len(a))
    b_pad = b + (0,) * (max_len - len(b))
    if a_pad < b_pad:
        return -1
    if a_pad > b_pad:
        return 1
    return 0


def is_trusted_github_url(url: str, *, allow_loopback: bool = False) -> bool:
    raw = str(url or "").strip()
    if not raw:
        return False
    parsed = urllib.parse.urlsplit(raw)
    host = (parsed.hostname or "").lower()
    if allow_loopback and parsed.scheme == "http" and host == "127.0.0.1":
        return True
    if parsed.scheme != "https" or not host or parsed.username or parsed.password:
        return False
    return (
        host in {"github.com", "api.github.com"}
        or host.endswith(".github.com")
        or host.endswith(".githubusercontent.com")
    )


def detect_platform_asset(
    *,
    system: str | None = None,
    machine: str | None = None,
    executable: str | Path | None = None,
    is_frozen: bool | None = None,
) -> dict:
    sys_name = system or platform.system()
    arch_raw = (machine or platform.machine() or "").lower()
    if arch_raw in {"x86_64", "amd64"}:
        arch = "x64"
    elif arch_raw in {"arm64", "aarch64"}:
        arch = "arm64"
    else:
        arch = arch_raw or "x64"

    frozen = bool(getattr(sys, "frozen", False)) if is_frozen is None else bool(is_frozen)
    exe_path = Path(executable or sys.executable)

    if sys_name == "Darwin":
        asset_name = f"emtroly-macos-{arch}.zip"
        return {
            "supported": arch in {"arm64", "x64"},
            "asset_name": asset_name,
            "install_kind": "macos-app" if frozen else "download-only",
            "platform_label": f"macOS ({arch})",
        }

    if sys_name == "Linux":
        resolved_str = ""
        try:
            resolved_str = str(exe_path.resolve())
        except OSError:
            resolved_str = str(exe_path)
        if (
            frozen
            and arch == "x64"
            and resolved_str.startswith("/usr/lib/emtroly/")
            and shutil.which("pkexec")
            and shutil.which("dpkg")
        ):
            return {
                "supported": True,
                "asset_name": "emtroly-linux-x64.deb",
                "install_kind": "linux-deb",
                "platform_label": "Ubuntu / Debian (.deb)",
            }
        return {
            "supported": arch in {"x64", "arm64"},
            "asset_name": f"emtroly-linux-{arch}.tar.gz",
            "install_kind": "linux-binary" if frozen else "download-only",
            "platform_label": f"Linux ({arch})",
        }

    return {
        "supported": False,
        "asset_name": "",
        "install_kind": "unsupported",
        "platform_label": sys_name,
    }


def check_for_updates(
    current_version: str,
    *,
    repo: str = OFFICIAL_REPO,
    api_base_url: str | None = None,
    system: str | None = None,
    machine: str | None = None,
    executable: str | Path | None = None,
    is_frozen: bool | None = None,
    opener=None,
) -> dict:
    cur_ver = str(current_version or "").strip().lstrip("vV") or "0.0.0"
    target_info = detect_platform_asset(
        system=system,
        machine=machine,
        executable=executable,
        is_frozen=is_frozen,
    )
    asset_name = target_info["asset_name"]
    sha_asset_name = f"{asset_name}.sha256" if asset_name else ""

    env_api = os.environ.get("EMTROLY_UPDATE_API_BASE", "").strip()
    effective_base = (api_base_url or env_api or f"https://api.github.com/repos/{repo}/releases").rstrip("/")
    allow_loopback = bool(
        (api_base_url or env_api) and re.match(r"^http://127\.0\.0\.1:\d+", effective_base)
    )

    release_page_url = f"https://github.com/{repo}/releases/latest"
    if not target_info["supported"] or not asset_name:
        return {
            "ok": False,
            "has_update": False,
            "building_assets": False,
            "current_version": cur_ver,
            "latest_version": "",
            "tag_name": "",
            "asset_name": "",
            "download_url": "",
            "sha256_url": "",
            "release_url": release_page_url,
            "release_notes": "",
            "install_kind": target_info["install_kind"],
            "message": f"Chưa hỗ trợ tự cập nhật trên nền tảng {target_info['platform_label']}.",
        }

    if not is_trusted_github_url(f"{effective_base}/latest", allow_loopback=allow_loopback):
        return {
            "ok": False,
            "has_update": False,
            "building_assets": False,
            "current_version": cur_ver,
            "latest_version": "",
            "tag_name": "",
            "asset_name": asset_name,
            "download_url": "",
            "sha256_url": "",
            "release_url": release_page_url,
            "release_notes": "",
            "install_kind": target_info["install_kind"],
            "message": "Địa chỉ máy chủ kiểm tra cập nhật không hợp lệ (chỉ chấp nhận GitHub chính thức).",
        }

    latest_ver = ""
    tag_name = ""
    download_url = ""
    sha256_url = ""
    asset_size = 0
    release_notes = ""

    try:
        req = urllib.request.Request(
            f"{effective_base}/latest",
            headers={
                "User-Agent": USER_AGENT,
                "Accept": "application/vnd.github+json",
            },
        )
        with net_utils.urlopen_with_retry(req, timeout=12, retries=2, opener=opener) as resp:
            payload = json.loads(resp.read().decode("utf-8", errors="replace"))
        tag_name = str(payload.get("tag_name") or "").strip()
        latest_ver = tag_name.lstrip("vV")
        if payload.get("html_url"):
            release_page_url = str(payload["html_url"]).strip()
        body_txt = str(payload.get("body") or "").strip()
        if body_txt:
            release_notes = (body_txt[:500].rstrip() + "...") if len(body_txt) > 500 else body_txt

        assets_by_name = {
            str(a.get("name") or ""): a
            for a in (payload.get("assets") or [])
            if isinstance(a, dict)
        }
        # If .deb is not present in assets on Linux, gracefully fall back to portable .tar.gz
        chosen_asset = assets_by_name.get(asset_name)
        chosen_sha = assets_by_name.get(sha_asset_name)
        install_kind = target_info["install_kind"]
        if (not chosen_asset or not chosen_sha) and install_kind == "linux-deb":
            fallback_tar = "emtroly-linux-x64.tar.gz"
            if fallback_tar in assets_by_name and f"{fallback_tar}.sha256" in assets_by_name:
                asset_name = fallback_tar
                sha_asset_name = f"{fallback_tar}.sha256"
                chosen_asset = assets_by_name[asset_name]
                chosen_sha = assets_by_name[sha_asset_name]
                install_kind = "linux-binary"
        target_info["install_kind"] = install_kind
        if chosen_asset:
            download_url = str(chosen_asset.get("browser_download_url") or "").strip()
            asset_size = int(chosen_asset.get("size") or 0)
        if chosen_sha:
            sha256_url = str(chosen_sha.get("browser_download_url") or "").strip()
    except Exception:
        pass

    # Fallback when GitHub API rate-limits anonymous IPs (HTTP 403 / 429)
    if (
        not latest_ver
        and not allow_loopback
        and effective_base == f"https://api.github.com/repos/{repo}/releases"
    ):
        try:
            manifest_req = urllib.request.Request(
                f"https://github.com/{repo}/releases/latest/download/MANIFEST.txt",
                headers={"User-Agent": USER_AGENT},
            )
            with net_utils.urlopen_with_retry(manifest_req, timeout=12, retries=2, opener=opener) as resp:
                manifest_txt = resp.read().decode("utf-8", errors="replace")
            m = re.search(r"(?m)^installer_version=([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$", manifest_txt)
            if m:
                latest_ver = m.group(1).strip()
                tag_name = f"v{latest_ver}"
                download_url = f"https://github.com/{repo}/releases/download/{tag_name}/{asset_name}"
                sha256_url = f"{download_url}.sha256"
                release_page_url = f"https://github.com/{repo}/releases/tag/{tag_name}"
        except Exception:
            pass

    if not latest_ver or not VERSION_RE.fullmatch(latest_ver):
        return {
            "ok": False,
            "has_update": False,
            "building_assets": False,
            "current_version": cur_ver,
            "latest_version": "",
            "tag_name": "",
            "asset_name": asset_name,
            "download_url": "",
            "sha256_url": "",
            "release_url": release_page_url,
            "release_notes": "",
            "install_kind": target_info["install_kind"],
            "message": "Không kiểm tra được phiên bản mới trên GitHub. Vui lòng kiểm tra kết nối mạng rồi thử lại.",
        }

    cmp = compare_versions(cur_ver, latest_ver)
    resolved_tag = tag_name or f"v{latest_ver}"
    if cmp < 0:
        urls_ok = is_trusted_github_url(download_url, allow_loopback=allow_loopback) and is_trusted_github_url(
            sha256_url, allow_loopback=allow_loopback
        )
        if not urls_ok:
            return {
                "ok": True,
                "has_update": False,
                "building_assets": True,
                "current_version": cur_ver,
                "latest_version": latest_ver,
                "tag_name": resolved_tag,
                "asset_name": asset_name,
                "download_url": "",
                "sha256_url": "",
                "asset_size": 0,
                "release_url": release_page_url,
                "release_notes": release_notes,
                "install_kind": target_info["install_kind"],
                "message": f"Phiên bản mới v{latest_ver} vừa phát hành và đang hoàn tất đóng gói cho {target_info['platform_label']} — vui lòng thử lại sau ít phút.",
            }
        return {
            "ok": True,
            "has_update": True,
            "building_assets": False,
            "current_version": cur_ver,
            "latest_version": latest_ver,
            "tag_name": resolved_tag,
            "asset_name": asset_name,
            "download_url": download_url,
            "sha256_url": sha256_url,
            "asset_size": asset_size,
            "release_url": release_page_url,
            "release_notes": release_notes,
            "install_kind": target_info["install_kind"],
            "message": f"Đã có phiên bản mới Em Trợ Lý v{latest_ver} trên GitHub (đang dùng v{cur_ver}).",
        }

    return {
        "ok": True,
        "has_update": False,
        "building_assets": False,
        "current_version": cur_ver,
        "latest_version": latest_ver,
        "tag_name": resolved_tag,
        "asset_name": asset_name,
        "download_url": download_url,
        "sha256_url": sha256_url,
        "asset_size": asset_size,
        "release_url": release_page_url,
        "release_notes": release_notes,
        "install_kind": target_info["install_kind"],
        "message": f"Bạn đang sử dụng phiên bản Em Trợ Lý mới nhất (v{cur_ver}).",
    }


def _compute_file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(131072), b""):
            digest.update(chunk)
    return digest.hexdigest().lower()


def download_and_verify_update(
    update_info: dict,
    *,
    dest_dir: Path | None = None,
    allow_loopback: bool = False,
    progress=None,
    opener=None,
) -> dict:
    env_api = os.environ.get("EMTROLY_UPDATE_API_BASE", "").strip()
    loopback_ok = allow_loopback or bool(env_api and re.match(r"^http://127\.0\.0\.1:\d+", env_api))

    dl_url = str(update_info.get("download_url") or "").strip()
    sha_url = str(update_info.get("sha256_url") or "").strip()
    latest_ver = str(update_info.get("latest_version") or "").strip().lstrip("vV")
    asset_name = str(update_info.get("asset_name") or "").strip()

    if not latest_ver or not VERSION_RE.fullmatch(latest_ver) or not asset_name or "/" in asset_name or "\\" in asset_name:
        raise ValueError("Thông tin gói cập nhật không hợp lệ.")
    if not is_trusted_github_url(dl_url, allow_loopback=loopback_ok) or not is_trusted_github_url(
        sha_url, allow_loopback=loopback_ok
    ):
        raise ValueError("Đường dẫn tải bản cập nhật không thuộc máy chủ GitHub chính thức.")

    if progress:
        progress(f"Đang xác minh mã kiểm tra an toàn SHA-256 cho bản v{latest_ver}...", 5)

    sha_req = urllib.request.Request(sha_url, headers={"User-Agent": USER_AGENT})
    with net_utils.urlopen_with_retry(sha_req, timeout=25, retries=2, opener=opener) as sha_resp:
        sha_txt = sha_resp.read().decode("utf-8", errors="replace")
    m = SHA256_RE.search(sha_txt)
    if not m:
        raise ValueError("Không đọc được mã kiểm tra toàn vẹn SHA-256 chính thức từ GitHub Release.")
    expected_hash = m.group(1).lower()

    cache_root = Path(dest_dir) if dest_dir else (Path.home() / ".cache/installer_emtroly/updates")
    cache_root.mkdir(parents=True, exist_ok=True)
    safe_ver = re.sub(r"[^0-9A-Za-z._-]", "", latest_ver)
    target_path = cache_root / f"v{safe_ver}-{asset_name}"

    if target_path.is_file() and _compute_file_sha256(target_path) == expected_hash:
        if progress:
            progress(f"Đã xác minh bản cập nhật v{latest_ver} sẵn sàng (100%)!", 100)
        return {
            "ok": True,
            "archive_path": str(target_path),
            "sha256": expected_hash,
            "version": latest_ver,
        }

    part_path = target_path.with_name(f"{target_path.name}.part-{os.getpid()}")
    try:
        dl_req = urllib.request.Request(dl_url, headers={"User-Agent": USER_AGENT})
        with net_utils.urlopen_with_retry(dl_req, timeout=180, retries=2, opener=opener) as resp:
            final_url = getattr(resp, "url", "") or (resp.geturl() if hasattr(resp, "geturl") else "")
            if final_url and not is_trusted_github_url(final_url, allow_loopback=loopback_ok):
                raise ValueError("Máy chủ chuyển hướng tải về không thuộc GitHub chính thức.")
            headers = getattr(resp, "headers", None) or {}
            total_bytes = int(headers.get("Content-Length") or update_info.get("asset_size") or 0)
            hasher = hashlib.sha256()
            read_total = 0
            with part_path.open("wb") as out_f:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    out_f.write(chunk)
                    hasher.update(chunk)
                    read_total += len(chunk)
                    if progress:
                        mb_done = read_total / (1024 * 1024)
                        if total_bytes > 0:
                            pct = min(96, max(6, int((read_total * 96) / total_bytes)))
                            mb_all = total_bytes / (1024 * 1024)
                            progress(
                                f"Đang tải bản cập nhật v{latest_ver}... {pct}% ({mb_done:.1f} / {mb_all:.1f} MB)",
                                pct,
                            )
                        else:
                            progress(f"Đang tải bản cập nhật v{latest_ver}... ({mb_done:.1f} MB)", 50)

        actual_hash = hasher.hexdigest().lower()
        if actual_hash != expected_hash:
            raise ValueError("Mã kiểm tra SHA-256 của bản cập nhật không khớp. Đã hủy để bảo vệ máy tính.")

        os.replace(part_path, target_path)
        return {
            "ok": True,
            "archive_path": str(target_path),
            "sha256": expected_hash,
            "version": latest_ver,
        }
    finally:
        if part_path.exists():
            try:
                part_path.unlink()
            except OSError:
                pass


def _clean_relaunch_env() -> dict[str, str]:
    env = dict(os.environ)
    python_exec.restore_library_path(env)
    for k in ("_MEIPASS2", "TCL_LIBRARY", "TK_LIBRARY"):
        env.pop(k, None)
    return env


def _resolve_macos_app_bundle(exe_path: Path) -> Path | None:
    try:
        cur = exe_path.resolve()
    except OSError:
        cur = exe_path
    for parent in (cur, *cur.parents):
        if parent.suffix == ".app" and parent.is_dir():
            return parent
    return None


def apply_and_relaunch_update(
    archive_path: str | Path,
    update_info: dict,
    *,
    executable: str | Path | None = None,
    is_frozen: bool | None = None,
    progress=None,
) -> dict:
    pkg_path = Path(archive_path).resolve(strict=True)
    kind = str(update_info.get("install_kind") or "download-only")
    frozen = bool(getattr(sys, "frozen", False)) if is_frozen is None else bool(is_frozen)
    exe_path = Path(executable or sys.executable)
    skip_relaunch = os.environ.get("EMTROLY_TEST_SKIP_UPDATE_RELAUNCH") == "1"

    if kind == "macos-app" and frozen:
        if progress:
            progress("Đang giải nén và cập nhật ứng dụng EmTrợLý.app...", 98)
        stage_dir = Path(tempfile.mkdtemp(prefix="emtroly-macos-upd-"))
        try:
            if shutil.which("ditto"):
                subprocess.run(["ditto", "-x", "-k", str(pkg_path), str(stage_dir)], check=True, timeout=60)
            else:
                with zipfile.ZipFile(pkg_path, "r") as zf:
                    zf.extractall(stage_dir)
            apps = sorted(stage_dir.glob("*.app"))
            if not apps:
                raise RuntimeError("Không tìm thấy gói ứng dụng .app bên trong bản cập nhật.")
            new_app = apps[0]
            net_utils.clear_macos_quarantine(new_app)

            cur_app = _resolve_macos_app_bundle(exe_path)
            if cur_app and os.access(cur_app.parent, os.W_OK):
                target_app = cur_app
            else:
                user_apps = Path.home() / "Applications"
                user_apps.mkdir(parents=True, exist_ok=True)
                target_app = user_apps / new_app.name

            backup_app = target_app.with_name(f"{target_app.name}.bak-{os.getpid()}")
            if target_app.exists():
                shutil.move(str(target_app), str(backup_app))
            try:
                shutil.move(str(new_app), str(target_app))
            except Exception:
                if backup_app.exists() and not target_app.exists():
                    shutil.move(str(backup_app), str(target_app))
                raise
            finally:
                if backup_app.exists():
                    shutil.rmtree(backup_app, ignore_errors=True)

            net_utils.clear_macos_quarantine(target_app)
            if not skip_relaunch:
                subprocess.Popen(
                    ["open", "-n", str(target_app)],
                    env=_clean_relaunch_env(),
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            return {
                "ok": True,
                "relaunched": not skip_relaunch,
                "installed_path": str(target_app),
            }
        finally:
            shutil.rmtree(stage_dir, ignore_errors=True)

    if kind == "linux-binary" and frozen:
        if progress:
            progress("Đang giải nén và cập nhật tệp thực thi Em Trợ Lý...", 98)
        try:
            target_exe = exe_path.resolve()
        except OSError:
            target_exe = exe_path
        if not os.access(target_exe.parent, os.W_OK):
            local_bin = Path.home() / ".local/bin"
            local_bin.mkdir(parents=True, exist_ok=True)
            target_exe = local_bin / "emtroly"

        new_bin = target_exe.with_name(f".{target_exe.name}.upd-{os.getpid()}")
        try:
            with tarfile.open(pkg_path, "r:gz") as tf:
                members = [
                    m
                    for m in tf.getmembers()
                    if m.isfile() and not m.name.startswith("/") and ".." not in Path(m.name).parts
                ]
                if not members:
                    raise RuntimeError("Gói cập nhật Linux không chứa tệp thực thi hợp lệ.")
                extracted = tf.extractfile(members[0])
                if extracted is None:
                    raise RuntimeError("Không thể đọc tệp thực thi từ gói cập nhật.")
                with extracted, new_bin.open("wb") as out_f:
                    shutil.copyfileobj(extracted, out_f)
            new_bin.chmod(0o755)
            os.replace(new_bin, target_exe)
        finally:
            if new_bin.exists():
                try:
                    new_bin.unlink()
                except OSError:
                    pass

        if not skip_relaunch:
            subprocess.Popen(
                [str(target_exe)],
                env=_clean_relaunch_env(),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        return {
            "ok": True,
            "relaunched": not skip_relaunch,
            "installed_path": str(target_exe),
        }

    if kind == "linux-deb" and frozen and shutil.which("pkexec") and shutil.which("dpkg"):
        if progress:
            progress("Đang cài đặt gói .deb mới (vui lòng xác nhận mật khẩu hệ thống nếu được hỏi)...", 98)
        proc = subprocess.run(["pkexec", "dpkg", "-i", str(pkg_path)], check=False)
        if proc.returncode == 0:
            if not skip_relaunch:
                subprocess.Popen(
                    ["/usr/bin/emtroly"],
                    env=_clean_relaunch_env(),
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            return {
                "ok": True,
                "relaunched": not skip_relaunch,
                "installed_path": "/usr/bin/emtroly",
            }
        return {
            "ok": True,
            "relaunched": False,
            "installed_path": str(pkg_path),
            "manual_command": f"sudo apt install -y {pkg_path}",
        }

    downloads_dir = Path.home() / "Downloads"
    final_dest = pkg_path
    if downloads_dir.is_dir() and os.access(downloads_dir, os.W_OK):
        cand = downloads_dir / pkg_path.name
        if cand != pkg_path:
            shutil.copy2(pkg_path, cand)
            final_dest = cand
    return {
        "ok": True,
        "relaunched": False,
        "installed_path": str(final_dest),
    }
