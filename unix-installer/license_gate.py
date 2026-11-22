"""One-time per-machine customer license activation for macOS & Linux installer."""

from __future__ import annotations

import base64
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import platform
import subprocess
import urllib.error
import urllib.request
import uuid

OFFICIAL_AUTHORITY_BASE = "https://codex.anhlaptrinh.vn/v1"


def get_machine_binding_id() -> str:
    override = os.environ.get("EMTROLY_TEST_MACHINE_ID", "").strip()
    if override:
        return override
    for candidate in (Path("/etc/machine-id"), Path("/var/lib/dbus/machine-id")):
        if candidate.is_file():
            try:
                val = candidate.read_text(encoding="utf-8").strip()
                if val:
                    return val
            except OSError:
                pass
    if platform.system() == "Darwin":
        try:
            out = subprocess.check_output(
                ["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
                text=True,
                timeout=5,
                stderr=subprocess.DEVNULL,
            )
            for line in out.splitlines():
                if "IOPlatformUUID" in line and '"' in line:
                    parts = [p for p in line.split('"') if p.strip()]
                    if parts:
                        return parts[-1].strip()
        except Exception:
            pass
    return f"{platform.node()}|{os.environ.get('USER', '')}|{uuid.getnode()}"


def get_activation_file_path() -> Path:
    cfg_root = os.environ.get("XDG_CONFIG_HOME", "").strip()
    base = Path(cfg_root) if cfg_root else (Path.home() / ".config")
    return base / "anhlaptrinh" / "emtroly" / "activation.dat"


def get_signed_out_flag_path() -> Path:
    cfg_root = os.environ.get("XDG_CONFIG_HOME", "").strip()
    base = Path(cfg_root) if cfg_root else (Path.home() / ".config")
    return base / "anhlaptrinh" / "emtroly" / "signed-out.flag"


def is_signed_out() -> bool:
    return get_signed_out_flag_path().is_file()


def _derive_keystream(machine_id: str, nonce: bytes, length: int) -> bytes:
    out = bytearray()
    counter = 0
    while len(out) < length:
        block = hashlib.sha256(
            f"EmTroLy-Unix-Machine-v1|{machine_id}|".encode("utf-8")
            + nonce
            + counter.to_bytes(4, "big")
        ).digest()
        out.extend(block)
        counter += 1
    return bytes(out[:length])


def seal_machine_activation(api_key: str, machine_id: str | None = None) -> str:
    clean = (api_key or "").strip()
    if not clean:
        raise ValueError("missing-api-key")
    mid = (machine_id or get_machine_binding_id()).strip()
    payload = json.dumps(
        {
            "key": clean,
            "machine": mid,
            "activatedAt": datetime.now(timezone.utc).isoformat(),
        },
        separators=(",", ":"),
    ).encode("utf-8")
    nonce = os.urandom(16)
    stream = _derive_keystream(mid, nonce, len(payload))
    cipher = bytes(a ^ b for a, b in zip(payload, stream))
    mac = hmac.new(
        hashlib.sha256(f"EmTroLy-Unix-MAC-v1|{mid}".encode("utf-8")).digest(),
        nonce + cipher,
        hashlib.sha256,
    ).digest()
    return base64.b64encode(nonce + mac + cipher).decode("ascii")


def unseal_machine_activation(encoded: str, machine_id: str | None = None) -> str:
    if not encoded or not encoded.strip():
        return ""
    try:
        raw = base64.b64decode(encoded.strip(), validate=True)
        if len(raw) <= 48:
            return ""
        nonce, mac, cipher = raw[:16], raw[16:48], raw[48:]
        mid = (machine_id or get_machine_binding_id()).strip()
        expected_mac = hmac.new(
            hashlib.sha256(f"EmTroLy-Unix-MAC-v1|{mid}".encode("utf-8")).digest(),
            nonce + cipher,
            hashlib.sha256,
        ).digest()
        if not hmac.compare_digest(mac, expected_mac):
            return ""
        stream = _derive_keystream(mid, nonce, len(cipher))
        plain = bytes(a ^ b for a, b in zip(cipher, stream))
        obj = json.loads(plain.decode("utf-8"))
        if isinstance(obj, dict) and obj.get("machine") == mid and isinstance(obj.get("key"), str):
            return obj["key"].strip()
    except Exception:
        return ""
    return ""


def save_license_key(api_key: str) -> Path:
    sealed = seal_machine_activation(api_key)
    target = get_activation_file_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(sealed + "\n", encoding="ascii")
    try:
        os.chmod(target, 0o600)
    except OSError:
        pass
    flag = get_signed_out_flag_path()
    try:
        if flag.exists():
            flag.unlink()
    except OSError:
        pass
    return target


def get_saved_license_key() -> str:
    if is_signed_out():
        return ""
    target = get_activation_file_path()
    if not target.is_file():
        return ""
    try:
        return unseal_machine_activation(target.read_text(encoding="ascii"))
    except OSError:
        return ""


def clear_saved_license_key() -> None:
    target = get_activation_file_path()
    try:
        if target.exists():
            target.unlink()
    except OSError:
        pass


def sign_out_license() -> None:
    """Sign out of the app UI license without disturbing running background services/CLI."""
    clear_saved_license_key()
    flag = get_signed_out_flag_path()
    flag.parent.mkdir(parents=True, exist_ok=True)
    flag.write_text(
        json.dumps({"signedOutAt": datetime.now(timezone.utc).isoformat()}) + "\n",
        encoding="utf-8",
    )
    try:
        os.chmod(flag, 0o600)
    except OSError:
        pass
    draft = get_saved_setup_draft()
    if isinstance(draft, dict) and draft.get("ai_api_key"):
        draft["ai_api_key"] = ""
        try:
            save_setup_draft(draft)
        except OSError:
            pass


def get_setup_draft_file_path() -> Path:
    cfg_root = os.environ.get("XDG_CONFIG_HOME", "").strip()
    base = Path(cfg_root) if cfg_root else (Path.home() / ".config")
    return base / "anhlaptrinh" / "emtroly" / "setup-draft.dat"


def seal_setup_draft(draft: dict, machine_id: str | None = None) -> str:
    mid = (machine_id or get_machine_binding_id()).strip()
    normalized = {
        "machine": mid,
        "savedAt": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"),
        "member": str(draft.get("member", "")).strip(),
        "assistant_name": str(draft.get("assistant_name", "")).strip(),
        "owner_ids": str(draft.get("owner_ids", "")).strip(),
        "qr_owner_id": str(draft.get("qr_owner_id", "")).strip(),
        "group_id": str(draft.get("group_id", "")).strip(),
        "telegram_token": str(draft.get("telegram_token", "")).strip(),
        "base_url": str(draft.get("base_url", "")).strip().rstrip("/"),
        "ai_api_key": str(draft.get("ai_api_key", "")).strip(),
        "model": str(draft.get("model", "")).strip(),
        "gateway_port": str(draft.get("gateway_port", "")).strip(),
        "audience": str(draft.get("audience", "")).strip(),
        "addressing": str(draft.get("addressing", "")).strip(),
        "style": str(draft.get("style", "")).strip(),
        "configure_zalo": bool(draft.get("configure_zalo", True)),
        "accept_full_access": bool(draft.get("accept_full_access", False)),
    }
    payload = json.dumps(normalized, separators=(",", ":")).encode("utf-8")
    nonce = os.urandom(16)
    stream = _derive_keystream(f"draft|{mid}", nonce, len(payload))
    cipher = bytes(a ^ b for a, b in zip(payload, stream))
    mac = hmac.new(
        hashlib.sha256(f"EmTroLy-Unix-DraftMAC-v1|{mid}".encode("utf-8")).digest(),
        nonce + cipher,
        hashlib.sha256,
    ).digest()
    return base64.b64encode(nonce + mac + cipher).decode("ascii")


def unseal_setup_draft(encoded: str, machine_id: str | None = None) -> dict | None:
    if not encoded or not encoded.strip():
        return None
    try:
        raw = base64.b64decode(encoded.strip(), validate=True)
        if len(raw) <= 48:
            return None
        nonce, mac, cipher = raw[:16], raw[16:48], raw[48:]
        mid = (machine_id or get_machine_binding_id()).strip()
        expected_mac = hmac.new(
            hashlib.sha256(f"EmTroLy-Unix-DraftMAC-v1|{mid}".encode("utf-8")).digest(),
            nonce + cipher,
            hashlib.sha256,
        ).digest()
        if not hmac.compare_digest(mac, expected_mac):
            return None
        stream = _derive_keystream(f"draft|{mid}", nonce, len(cipher))
        plain = bytes(a ^ b for a, b in zip(cipher, stream))
        obj = json.loads(plain.decode("utf-8"))
        if isinstance(obj, dict) and obj.get("machine") == mid:
            return obj
    except Exception:
        return None
    return None


def save_setup_draft(draft: dict) -> Path:
    sealed = seal_setup_draft(draft)
    target = get_setup_draft_file_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(".tmp")
    tmp.write_text(sealed + "\n", encoding="ascii")
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    tmp.replace(target)
    try:
        os.chmod(target, 0o600)
    except OSError:
        pass
    return target


def get_saved_setup_draft() -> dict | None:
    target = get_setup_draft_file_path()
    if not target.is_file():
        return None
    try:
        return unseal_setup_draft(target.read_text(encoding="ascii"))
    except OSError:
        return None


def clear_saved_setup_draft() -> None:
    target = get_setup_draft_file_path()
    try:
        if target.exists():
            target.unlink()
    except OSError:
        pass


def verify_license_key(
    api_key: str,
    authority_base_url: str | None = None,
    opener=None,
) -> dict:
    clean = (api_key or "").strip()
    if not clean:
        return {
            "valid": False,
            "revoked": False,
            "network_error": False,
            "models": [],
            "message": "Vui lòng nhập Khóa kích hoạt (Provider API Key) do Anh Lập Trình cấp.",
        }

    env_base = os.environ.get("EMTROLY_LICENSE_API_BASE", "").strip()
    target_base = (authority_base_url or env_base or OFFICIAL_AUTHORITY_BASE).strip().rstrip("/")
    is_local_test = bool(env_base) and target_base.startswith("http://127.0.0.1:")
    if not is_local_test and target_base != OFFICIAL_AUTHORITY_BASE:
        return {
            "valid": False,
            "revoked": True,
            "network_error": False,
            "models": [],
            "message": "Chỉ chấp nhận khóa bản quyền chính thức từ máy chủ codex.anhlaptrinh.vn.",
        }

    req = urllib.request.Request(
        f"{target_base}/models",
        headers={
            "Authorization": f"Bearer {clean}",
            "Accept": "application/json",
            "User-Agent": "AnhLapTrinh-EmTroLy/1.0",
        },
        method="GET",
    )
    open_fn = opener or urllib.request.urlopen
    try:
        with open_fn(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        ids = [str(item.get("id", "")).strip() for item in data.get("data", []) if isinstance(item, dict) and item.get("id")]
        if not ids:
            return {
                "valid": False,
                "revoked": True,
                "network_error": False,
                "models": [],
                "message": "Khóa kích hoạt chưa được cấp quyền mô hình trên hệ thống Anh Lập Trình.",
            }
        return {
            "valid": True,
            "revoked": False,
            "network_error": False,
            "models": ids,
            "message": "Đã xác thực bản quyền thành công trên hệ thống Anh Lập Trình.",
        }
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            return {
                "valid": False,
                "revoked": True,
                "network_error": False,
                "models": [],
                "message": "Khóa kích hoạt không hợp lệ hoặc đã bị thu hồi quyền sử dụng.",
            }
        return {
            "valid": False,
            "revoked": False,
            "network_error": True,
            "models": [],
            "message": f"Máy chủ xác thực trả về lỗi HTTP {exc.code}. Hãy thử lại sau.",
        }
    except Exception:
        return {
            "valid": False,
            "revoked": False,
            "network_error": True,
            "models": [],
            "message": "Không kết nối được máy chủ codex.anhlaptrinh.vn. Hãy kiểm tra mạng rồi thử lại.",
        }
