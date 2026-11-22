"""Resilient network downloads (retry + SSL CA fallback) and macOS quarantine helpers."""

from __future__ import annotations

import http.client
import os
from pathlib import Path
import platform
import socket
import ssl
import subprocess
import time
import urllib.error
import urllib.request


SYSTEM_CA_BUNDLES = (
    "/etc/ssl/cert.pem",
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/ca-bundle.pem",
)

RETRYABLE_HTTP_CODES = {408, 429, 500, 502, 503, 504}


def find_system_ca_bundle(candidates=SYSTEM_CA_BUNDLES) -> str | None:
    env_cert = os.environ.get("SSL_CERT_FILE", "").strip()
    if env_cert and Path(env_cert).is_file():
        return env_cert
    for candidate in candidates:
        if Path(candidate).is_file():
            return candidate
    return None


def build_ssl_context(candidates=SYSTEM_CA_BUNDLES) -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    verify_paths = ssl.get_default_verify_paths()
    has_default_ca = bool(
        (verify_paths.cafile and Path(verify_paths.cafile).is_file())
        or (verify_paths.capath and Path(verify_paths.capath).is_dir())
    )
    if not has_default_ca or os.environ.get("EMTROLY_FORCE_SYSTEM_CA") == "1":
        fallback_ca = find_system_ca_bundle(candidates)
        if fallback_ca:
            ctx.load_verify_locations(cafile=fallback_ca)
    return ctx


def _is_ssl_cert_error(exc: BaseException) -> bool:
    if isinstance(exc, ssl.SSLCertVerificationError):
        return True
    if isinstance(exc, urllib.error.URLError) and isinstance(exc.reason, ssl.SSLCertVerificationError):
        return True
    return "CERTIFICATE_VERIFY_FAILED" in str(exc)


def _is_transient_error(exc: BaseException) -> bool:
    if isinstance(exc, urllib.error.HTTPError):
        return exc.code in RETRYABLE_HTTP_CODES
    if isinstance(exc, urllib.error.URLError):
        if _is_ssl_cert_error(exc):
            return False
        return True
    return isinstance(
        exc,
        (
            TimeoutError,
            socket.timeout,
            ConnectionError,
            http.client.IncompleteRead,
            http.client.RemoteDisconnected,
        ),
    )


def urlopen_with_retry(request_or_url, *, timeout: int = 60, retries: int | None = None, backoff: float | None = None, opener=None):
    if retries is None:
        env_retries = os.environ.get("EMTROLY_DOWNLOAD_RETRIES", "").strip()
        retries = int(env_retries) if env_retries.isdigit() and 1 <= int(env_retries) <= 5 else 3
    if backoff is None:
        try:
            backoff = float(os.environ.get("EMTROLY_RETRY_BACKOFF", "0.5"))
        except ValueError:
            backoff = 0.5

    last_error: BaseException | None = None
    use_custom_ssl = os.environ.get("EMTROLY_FORCE_SYSTEM_CA") == "1"

    for attempt in range(1, max(1, retries) + 1):
        try:
            if opener is not None:
                return opener.open(request_or_url, timeout=timeout)
            if use_custom_ssl:
                return urllib.request.urlopen(request_or_url, timeout=timeout, context=build_ssl_context())
            return urllib.request.urlopen(request_or_url, timeout=timeout)
        except Exception as exc:
            last_error = exc
            if opener is None and not use_custom_ssl and _is_ssl_cert_error(exc) and find_system_ca_bundle():
                use_custom_ssl = True
                try:
                    return urllib.request.urlopen(request_or_url, timeout=timeout, context=build_ssl_context())
                except Exception as ssl_exc:
                    last_error = ssl_exc
                    if not _is_transient_error(ssl_exc):
                        raise
            if not _is_transient_error(last_error) or attempt >= retries:
                raise
            if backoff > 0:
                time.sleep(backoff * (2 ** (attempt - 1)))

    assert last_error is not None
    raise last_error


def clear_macos_quarantine(target: Path) -> bool:
    if platform.system() != "Darwin":
        return False
    p = Path(target)
    if not p.exists():
        return False
    try:
        subprocess.run(
            ["xattr", "-dr", "com.apple.quarantine", str(p)],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=15,
            check=False,
        )
        return True
    except (OSError, subprocess.SubprocessError):
        return False
