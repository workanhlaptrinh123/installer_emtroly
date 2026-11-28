"""Priority Codex CLI installation, Antigravity IDE extension setup, and Auto-Heal for macOS & Linux."""

from __future__ import annotations

from datetime import datetime
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import tempfile
import urllib.error
from urllib.parse import urlsplit
import urllib.request

import net_utils


NON_HEALABLE_CODES = {
    "invalid-settings",
    "invalid-member",
    "missing-assistant-name",
    "invalid-owners",
    "duplicate-owners",
    "invalid-group",
    "invalid-telegram-token",
    "missing-api-key",
    "invalid-model",
    "invalid-base-url",
    "invalid-port",
    "full-access-consent-required",
    "invalid-qr-owner",
    "linux-user-service-unavailable",
}

TELEGRAM_TOKEN_RE = re.compile(r"[0-9]{5,}:[A-Za-z0-9_-]{20,}")
API_KEY_RE = re.compile(r"sk-[A-Za-z0-9_-]{12,}")
GATEWAY_TOKEN_RE = re.compile(r'("token"\s*:\s*")[0-9a-fA-F]{24,}(")')


def scrub_secrets(text: str, secrets=()) -> str:
    if not text:
        return ""
    cleaned = str(text)
    for secret in secrets:
        if isinstance(secret, str) and len(secret.strip()) >= 6:
            cleaned = cleaned.replace(secret.strip(), "[REDACTED_SECRET]")
    cleaned = TELEGRAM_TOKEN_RE.sub("[REDACTED_TELEGRAM_TOKEN]", cleaned)
    cleaned = API_KEY_RE.sub("[REDACTED_API_KEY]", cleaned)
    cleaned = GATEWAY_TOKEN_RE.sub(r"\1[REDACTED_GATEWAY_TOKEN]\2", cleaned)
    return cleaned


def data_root(home: Path | None = None) -> Path:
    resolved_home = Path(home) if home is not None else Path.home()
    return resolved_home / ".local/share/installer_emtroly"


def codex_home_dir(home: Path | None = None) -> Path:
    return data_root(home) / "codex-home"


def _write_private_file(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(tmp, flags, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)
    try:
        os.chmod(tmp, mode)
    except OSError:
        pass
    os.replace(tmp, path)


def sync_default_codex_home(home: Path, api_key: str, model: str, base_url: str) -> Path | None:
    """Link default ~/.codex to codex.anhlaptrinh.vn while preserving existing projects/plugins/mcp sections."""
    if os.environ.get("EMTROLY_SKIP_DEFAULT_CODEX_SYNC") == "1":
        return None
    clean_url = (base_url or "").strip().rstrip("/")
    clean_key = (api_key or "").strip()
    if clean_url != "https://codex.anhlaptrinh.vn/v1" or not clean_key:
        return None
    safe_model = model.strip() if re.fullmatch(r"[A-Za-z0-9._-]+", (model or "").strip()) else "gpt-6.2-sol"
    dot_codex = Path(home) / ".codex"
    dot_codex.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(dot_codex, 0o700)
    except OSError:
        pass

    cfg_path = dot_codex / "config.toml"
    existing_raw = cfg_path.read_text(encoding="utf-8", errors="ignore") if cfg_path.is_file() else ""
    top_lines: list[str] = []
    section_lines: list[str] = []
    in_section = False
    skip_router = False
    top_key_re = re.compile(r"^\s*(model_provider|model|model_context_window|model_auto_compact_token_limit|cli_auth_credentials_store)\s*=")
    sec_re = re.compile(r"^\s*\[([^\]]+)\]\s*(?:#.*)?$")
    for line in existing_raw.splitlines():
        m_sec = sec_re.match(line)
        if m_sec:
            in_section = True
            sec_name = m_sec.group(1).strip().lower()
            if sec_name == "model_providers.router":
                skip_router = True
                continue
            skip_router = False
            section_lines.append(line)
            continue
        if not in_section:
            if not top_key_re.match(line):
                top_lines.append(line)
        elif not skip_router:
            section_lines.append(line)

    out_lines = [
        'model_provider = "router"',
        f'model = "{safe_model}"',
        "model_context_window = 272000",
        "model_auto_compact_token_limit = 200000",
        'cli_auth_credentials_store = "file"',
    ]
    out_lines.extend(l for l in top_lines if l.strip())
    while section_lines and not section_lines[-1].strip():
        section_lines.pop()
    if section_lines:
        out_lines.append("")
        out_lines.extend(section_lines)
    out_lines.extend([
        "",
        "[model_providers.router]",
        'name = "router"',
        f'base_url = "{clean_url}"',
        'wire_api = "responses"',
        "requires_openai_auth = true",
    ])
    _write_private_file(cfg_path, "\n".join(out_lines) + "\n", 0o600)

    auth_path = dot_codex / "auth.json"
    auth_obj: dict = {}
    if auth_path.is_file():
        try:
            loaded = json.loads(auth_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                for k, v in loaded.items():
                    if k not in {"OPENAI_API_KEY", "auth_mode", "tokens", "last_refresh"}:
                        auth_obj[k] = v
        except Exception:
            pass
    auth_obj["OPENAI_API_KEY"] = clean_key
    _write_private_file(auth_path, json.dumps(auth_obj) + "\n", 0o600)
    return dot_codex


def write_codex_home(home: Path, api_key: str, model: str, base_url: str) -> Path:
    c_home = codex_home_dir(home)
    c_home.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(c_home, 0o700)
    except OSError:
        pass
    safe_model = model.strip() if re.fullmatch(r"[A-Za-z0-9._-]+", (model or "").strip()) else "gpt-6.2-sol"
    safe_url = (base_url or "https://codex.anhlaptrinh.vn/v1").strip().rstrip("/")
    config_toml = (
        'model_provider = "router"\n'
        f'model = "{safe_model}"\n'
        "model_context_window = 272000\n"
        "model_auto_compact_token_limit = 200000\n"
        'cli_auth_credentials_store = "file"\n\n'
        "[model_providers.router]\n"
        'name = "router"\n'
        f'base_url = "{safe_url}"\n'
        'wire_api = "responses"\n'
        "requires_openai_auth = true\n"
    )
    _write_private_file(c_home / "config.toml", config_toml, 0o600)
    if api_key and api_key.strip():
        _write_private_file(c_home / "auth.json", json.dumps({"OPENAI_API_KEY": api_key.strip()}) + "\n", 0o600)
    sync_default_codex_home(home, api_key, safe_model, safe_url)
    return c_home


def find_codex_binary(home: Path | None = None, *, isolated_only: bool = False) -> Path | None:
    env_override = os.environ.get("EMTROLY_AUTOHEAL_BIN", "").strip()
    if env_override:
        cand = Path(env_override)
        if cand.is_file() and os.access(cand, os.X_OK):
            return cand

    resolved_home = Path(home) if home is not None else Path.home()
    em_root = data_root(resolved_home)

    isolated_candidates = [
        em_root / "codex-cli/node_modules/.bin/codex",
    ]
    ext_root = em_root / "antigravity/Extensions"
    if ext_root.is_dir():
        isolated_candidates.extend(sorted(ext_root.glob("openai.chatgpt-*/bin/*/codex"), reverse=True))

    for cand in isolated_candidates:
        if cand.is_file() and os.access(cand, os.X_OK):
            return cand

    if isolated_only:
        return None

    for base in (resolved_home / ".antigravity/extensions", resolved_home / ".vscode/extensions"):
        if not base.is_dir():
            continue
        for cand in sorted(base.glob("openai.chatgpt-*/bin/*/codex"), reverse=True):
            if cand.is_file() and os.access(cand, os.X_OK):
                return cand

    for cmd_name in ("codex-emtroly", "codex"):
        found = shutil.which(cmd_name)
        if found:
            p = Path(found)
            if p.is_file() and os.access(p, os.X_OK):
                return p
    return None


def register_codex_shim(home: Path, codex_bin: Path, c_home: Path, extra_bin_dir: Path | None = None) -> dict:
    bin_dir = home / ".local/bin"
    bin_dir.mkdir(parents=True, exist_ok=True, mode=0o755)
    path_prefix = f'export PATH={shlex.quote(str(extra_bin_dir))}:"$PATH"\n' if extra_bin_dir else ""
    shim_text = (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "unset OPENAI_API_KEY ELECTRON_RUN_AS_NODE VSCODE_IPC_HOOK_CLI NODE_OPTIONS VSCODE_DEV\n"
        f"export CODEX_HOME={shlex.quote(str(c_home))}\n"
        f"{path_prefix}"
        f"exec {shlex.quote(str(codex_bin))} \"$@\"\n"
    )
    alias_path = bin_dir / "codex-emtroly"
    _write_private_file(alias_path, shim_text, 0o755)

    default_shim = bin_dir / "codex"
    existing = shutil.which("codex")
    external_conflict = False
    if existing:
        try:
            if Path(existing).resolve() != default_shim.resolve() and Path(existing).parent.resolve() != bin_dir.resolve():
                external_conflict = True
        except OSError:
            external_conflict = True

    selected_name = "codex-emtroly"
    selected_path = alias_path
    if not external_conflict:
        _write_private_file(default_shim, shim_text, 0o755)
        selected_name = "codex"
        selected_path = default_shim

    return {"registered": True, "command": selected_name, "path": str(selected_path)}


def _parse_version_parts(raw: str) -> tuple[tuple[int, ...], str]:
    clean = str(raw or "").strip().lstrip("vV")
    no_build = clean.split("+", 1)[0]
    if "-" in no_build:
        main_str, pre_str = no_build.split("-", 1)
    else:
        main_str, pre_str = no_build, ""
    nums: list[int] = []
    for seg in main_str.split("."):
        try:
            nums.append(int(seg))
        except ValueError:
            nums.append(0)
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums), pre_str


def compare_versions(current: str, target: str) -> int:
    a_nums, a_pre = _parse_version_parts(current)
    b_nums, b_pre = _parse_version_parts(target)
    max_len = max(len(a_nums), len(b_nums))
    a_pad = a_nums + (0,) * (max_len - len(a_nums))
    b_pad = b_nums + (0,) * (max_len - len(b_nums))
    if a_pad < b_pad:
        return -1
    if a_pad > b_pad:
        return 1
    if not a_pre and b_pre:
        return 1
    if a_pre and not b_pre:
        return -1
    if a_pre == b_pre:
        return 0
    for ap, bp in zip(a_pre.split("."), b_pre.split(".")):
        if ap.isdigit() and bp.isdigit():
            ai, bi = int(ap), int(bp)
            if ai != bi:
                return -1 if ai < bi else 1
        elif ap != bp:
            return -1 if ap < bp else 1
    return -1 if len(a_pre.split(".")) < len(b_pre.split(".")) else (1 if len(a_pre.split(".")) > len(b_pre.split(".")) else 0)


def _is_trusted_metadata_url(url: str, trusted_hosts: tuple[str, ...], *, allow_loopback: bool = False) -> bool:
    if not url:
        return False
    parsed = urlsplit(url.strip())
    if allow_loopback and parsed.scheme == "http" and parsed.hostname == "127.0.0.1":
        return True
    if parsed.scheme != "https" or not parsed.hostname:
        return False
    host = parsed.hostname.lower()
    return any(host == h or host.endswith("." + h) for h in trusted_hosts)


def fetch_latest_npm_codex_version(timeout: float = 5.0) -> str:
    if os.environ.get("EMTROLY_SKIP_REMOTE_VERSION_CHECK") == "1":
        return ""
    custom = os.environ.get("EMTROLY_CODEX_NPM_LATEST_URL", "").strip()
    url = custom or "https://registry.npmjs.org/@openai/codex/latest"
    allow_loopback = bool(custom and custom.startswith("http://127.0.0.1:"))
    if not _is_trusted_metadata_url(url, ("registry.npmjs.org",), allow_loopback=allow_loopback):
        return ""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "AnhLapTrinh-EmTroLy-Installer/1.0", "Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read(262144).decode("utf-8", errors="ignore"))
        ver = str((payload or {}).get("version") or "").strip()
        if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?", ver):
            return ver
    except (OSError, ValueError, urllib.error.URLError, TimeoutError):
        pass
    return ""


def fetch_latest_codex_extension_version(timeout: float = 5.0) -> str:
    if os.environ.get("EMTROLY_SKIP_REMOTE_VERSION_CHECK") == "1":
        return ""
    custom = os.environ.get("EMTROLY_CODEX_OPENVSX_URL", "").strip()
    url = custom or "https://open-vsx.org/api/openai/chatgpt/latest"
    allow_loopback = bool(custom and custom.startswith("http://127.0.0.1:"))
    if not _is_trusted_metadata_url(url, ("open-vsx.org",), allow_loopback=allow_loopback):
        return ""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "AnhLapTrinh-EmTroLy-Installer/1.0", "Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read(262144).decode("utf-8", errors="ignore"))
        ver = str((payload or {}).get("version") or "").strip()
        if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", ver):
            return ver
    except (OSError, ValueError, urllib.error.URLError, TimeoutError):
        pass
    return ""


def _probe_binary_version(binary: Path, c_home: Path | None = None) -> str:
    if not binary or not binary.is_file() or not os.access(binary, os.X_OK):
        return ""
    env = dict(os.environ, NO_COLOR="1")
    if c_home:
        env["CODEX_HOME"] = str(c_home)
    try:
        res = subprocess.run(
            [str(binary), "--version"],
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if res.returncode == 0:
            txt = (res.stdout or "") + " " + (res.stderr or "")
            m = re.search(r"([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?)", txt)
            if m:
                return m.group(1)
    except (OSError, subprocess.SubprocessError):
        pass
    return ""


def get_installed_codex_cli_info(home: Path | None = None) -> dict:
    resolved_home = Path(home) if home is not None else Path.home()
    em_root = data_root(resolved_home)
    npm_bin = em_root / "codex-cli/node_modules/.bin/codex"
    npm_pkg = em_root / "codex-cli/node_modules/@openai/codex/package.json"
    ver = ""
    if npm_pkg.is_file():
        try:
            ver = str(json.loads(npm_pkg.read_text(encoding="utf-8")).get("version", "")).strip()
        except Exception:
            ver = ""
    if npm_bin.is_file() and os.access(npm_bin, os.X_OK):
        if not ver:
            ver = _probe_binary_version(npm_bin, codex_home_dir(resolved_home))
        return {"installed": True, "source": "npm", "version": ver, "path": str(npm_bin)}

    ext_info = get_installed_codex_extension_info(resolved_home)
    if ext_info["installed"] and ext_info["binary"]:
        return {
            "installed": True,
            "source": "extension",
            "version": _probe_binary_version(Path(ext_info["binary"]), codex_home_dir(resolved_home)),
            "extension_version": ext_info["version"],
            "path": ext_info["binary"],
        }
    return {"installed": False, "source": "none", "version": "", "path": ""}


def get_installed_codex_extension_info(home: Path | None = None) -> dict:
    resolved_home = Path(home) if home is not None else Path.home()
    ext_root = data_root(resolved_home) / "antigravity/Extensions"
    if not ext_root.is_dir():
        return {"installed": False, "version": "", "path": "", "binary": "", "dirs": []}
    candidates = []
    for ext_dir in sorted(ext_root.glob("openai.chatgpt-*")):
        if not ext_dir.is_dir():
            continue
        ver = ""
        pkg_path = ext_dir / "package.json"
        if pkg_path.is_file():
            try:
                pkg = json.loads(pkg_path.read_text(encoding="utf-8"))
                if pkg.get("publisher") == "openai" and pkg.get("name") == "chatgpt":
                    ver = str(pkg.get("version") or "").strip()
            except Exception:
                ver = ""
        if not ver:
            m = re.match(r"openai\.chatgpt-([0-9]+\.[0-9]+\.[0-9]+)", ext_dir.name)
            if m:
                ver = m.group(1)
        bins = sorted(ext_dir.glob("bin/*/codex"))
        bin_path = str(bins[0]) if bins and bins[0].is_file() else ""
        candidates.append((ext_dir, ver, bin_path))

    if not candidates:
        return {"installed": False, "version": "", "path": "", "binary": "", "dirs": []}

    best = candidates[0]
    for item in candidates[1:]:
        if item[1] and (not best[1] or compare_versions(item[1], best[1]) > 0):
            best = item
    return {
        "installed": True,
        "version": best[1],
        "path": str(best[0]),
        "binary": best[2],
        "dirs": [str(c[0]) for c in candidates],
    }


def get_installed_antigravity_version(home: Path | None = None) -> str:
    app_target, ide_cli = find_antigravity_cli(home)
    search_roots = []
    if app_target:
        search_roots.extend([app_target / "Contents/Resources/app/product.json", app_target / "resources/app/product.json"])
    if ide_cli:
        search_roots.extend([
            ide_cli.resolve().parent.parent / "resources/app/product.json",
            ide_cli.resolve().parent.parent / "Resources/app/product.json",
        ])
    for prod in search_roots:
        if prod.is_file():
            try:
                data = json.loads(prod.read_text(encoding="utf-8"))
                return str(data.get("ideVersion") or data.get("version") or "").strip()
            except Exception:
                pass
    return ""


def install_codex_cli_first(
    values: dict,
    home: Path,
    node: Path,
    npm: Path,
    progress=lambda _m: None,
    check_latest: bool = False,
) -> dict:
    """Always configure and install Codex CLI first so it can auto-heal subsequent steps."""
    progress("Bước 2 · Đang cài đặt và cấu hình ưu tiên Codex CLI trước tiên...")
    c_home = write_codex_home(
        home,
        values.get("ai_api_key", ""),
        values.get("model", "gpt-6.2-sol"),
        values.get("base_url", "https://codex.anhlaptrinh.vn/v1"),
    )

    existing = find_codex_binary(home, isolated_only=True)
    if existing:
        if not check_latest:
            shim = register_codex_shim(home, existing, c_home, extra_bin_dir=node.parent)
            return {"installed": True, "skipped": True, "up_to_date": True, "executable": str(existing), "codex_home": str(c_home), "shim": shim}
        cli_info = get_installed_codex_cli_info(home)
        installed_ver = cli_info.get("version", "")
        progress("Đang kiểm tra phiên bản mới nhất của Codex CLI...")
        latest_ver = fetch_latest_npm_codex_version()
        if installed_ver and (not latest_ver or compare_versions(installed_ver, latest_ver) >= 0):
            shim = register_codex_shim(home, existing, c_home, extra_bin_dir=node.parent)
            progress(f"✓ Codex CLI đã ở phiên bản mới nhất (v{installed_ver}) — không cần tải lại.")
            return {
                "installed": True,
                "skipped": True,
                "up_to_date": True,
                "version": installed_ver,
                "target_version": latest_ver or installed_ver,
                "executable": str(existing),
                "codex_home": str(c_home),
                "shim": shim,
            }

    base_url = (values.get("base_url") or "").strip().rstrip("/")
    should_install_npm = (
        base_url == "https://codex.anhlaptrinh.vn/v1"
        or os.environ.get("EMTROLY_FORCE_CODEX_INSTALL") == "1"
    )
    if should_install_npm and npm.is_file() and node.is_file():
        cli_prefix = data_root(home) / "codex-cli"
        cli_prefix.mkdir(parents=True, exist_ok=True, mode=0o700)
        pkg_json = cli_prefix / "package.json"
        if not pkg_json.is_file():
            _write_private_file(pkg_json, '{"name":"emtroly-codex-cli","private":true}\n', 0o600)
        env = dict(os.environ, NO_COLOR="1")
        env["PATH"] = str(node.parent) + os.pathsep + env.get("PATH", "")
        try:
            subprocess.run(
                [str(npm), "install", "--prefix", str(cli_prefix), "@openai/codex", "--no-audit", "--no-fund"],
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=300,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            pass

    final_bin = find_codex_binary(home, isolated_only=not should_install_npm)
    if final_bin:
        net_utils.clear_macos_quarantine(final_bin)
        shim = register_codex_shim(home, final_bin, c_home, extra_bin_dir=node.parent)
        final_ver = get_installed_codex_cli_info(home).get("version", "")
        return {"installed": True, "skipped": False, "up_to_date": True, "version": final_ver, "executable": str(final_bin), "codex_home": str(c_home), "shim": shim}
    return {"installed": False, "skipped": False, "up_to_date": False, "version": "", "executable": "", "codex_home": str(c_home), "shim": None}


def find_antigravity_cli(home: Path | None = None) -> tuple[Path | None, Path | None]:
    """Locate Antigravity IDE binary & CLI on macOS or Linux if present."""
    resolved_home = Path(home) if home is not None else Path.home()
    sys_name = platform.system()
    candidates: list[tuple[Path, Path]] = []

    env_cli = os.environ.get("EMTROLY_ANTIGRAVITY_CLI", "").strip()
    if env_cli:
        p = Path(env_cli)
        if p.is_file() and os.access(p, os.X_OK):
            return p, p

    if sys_name == "Darwin":
        for app_root in (
            Path("/Applications/Antigravity.app"),
            Path("/Applications/Antigravity IDE.app"),
            resolved_home / "Applications/Antigravity.app",
            resolved_home / "Applications/Antigravity IDE.app",
        ):
            for cli_rel in ("Contents/Resources/app/bin/antigravity", "Contents/Resources/app/bin/antigravity-ide"):
                cli_path = app_root / cli_rel
                if cli_path.is_file() and os.access(cli_path, os.X_OK):
                    candidates.append((app_root, cli_path))
    elif sys_name == "Linux":
        for bin_path in (
            Path("/usr/bin/antigravity"),
            Path("/usr/bin/antigravity-ide"),
            Path("/opt/Antigravity/bin/antigravity"),
            Path("/opt/antigravity-ide/bin/antigravity-ide"),
            resolved_home / ".local/bin/antigravity",
        ):
            if bin_path.is_file() and os.access(bin_path, os.X_OK):
                candidates.append((bin_path, bin_path))

    if candidates:
        return candidates[0]

    for name in ("antigravity", "antigravity-ide"):
        which_cli = shutil.which(name)
        if which_cli:
            p = Path(which_cli)
            return p, p
    return None, None


def install_antigravity_and_extension(values: dict, home: Path, progress=lambda _m: None, check_latest: bool = True) -> dict:
    """Configure isolated Antigravity profile & install Codex Extension (`openai.chatgpt`) before OpenClaw."""
    if values.get("skip_editor"):
        return {"configured": False, "skipped": True, "reason": "skip-editor"}

    app_target, ide_cli = find_antigravity_cli(home)
    if not ide_cli:
        return {"configured": False, "skipped": True, "reason": "antigravity-not-installed"}

    progress("Bước 2 · Đang cấu hình Antigravity IDE và kiểm tra Codex Extension...")
    ag_root = data_root(home) / "antigravity"
    user_data = ag_root / "UserData"
    ext_dir = ag_root / "Extensions"
    settings_dir = user_data / "User"
    for folder in (ag_root, user_data, ext_dir, settings_dir):
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)

    editor_settings = {
        "extensions.autoUpdate": False,
        "extensions.autoCheckUpdates": False,
        "extensions.ignoreRecommendations": True,
        "update.mode": "none",
    }
    _write_private_file(settings_dir / "settings.json", json.dumps(editor_settings, indent=2) + "\n", 0o600)

    c_home = codex_home_dir(home)
    if (values.get("ai_api_key") or "").strip():
        c_home = write_codex_home(
            home,
            values.get("ai_api_key", ""),
            values.get("model", "gpt-6.2-sol"),
            values.get("base_url", "https://codex.anhlaptrinh.vn/v1"),
        )
    ext_info = get_installed_codex_extension_info(home)
    skipped_download = False
    resolved_ver = ext_info.get("version", "")
    latest_ver = ""
    if check_latest and ext_info["installed"] and ext_info["version"]:
        progress("Đang kiểm tra phiên bản mới nhất của Codex Extension...")
        latest_ver = fetch_latest_codex_extension_version()
        if not latest_ver or compare_versions(ext_info["version"], latest_ver) >= 0:
            skipped_download = True
            progress(f"✓ Codex Extension đã ở phiên bản mới nhất (v{ext_info['version']}) — không cần tải lại.")

    if not skipped_download:
        env = dict(os.environ, CODEX_HOME=str(c_home), NO_COLOR="1")
        for k in ("OPENAI_API_KEY", "VSCODE_IPC_HOOK_CLI", "ELECTRON_RUN_AS_NODE", "NODE_OPTIONS", "VSCODE_DEV"):
            env.pop(k, None)

        progress("Đang cài đặt Codex Extension vào thư mục riêng...")
        res = subprocess.run(
            [
                str(ide_cli),
                "--user-data-dir",
                str(user_data),
                "--extensions-dir",
                str(ext_dir),
                "--install-extension",
                "openai.chatgpt",
                "--force",
            ],
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=600,
            check=False,
        )
        if res.returncode != 0:
            raise RuntimeError("editor-extension-install-failed: " + (res.stderr or res.stdout)[-400:].strip())

        after_info = get_installed_codex_extension_info(home)
        resolved_ver = after_info.get("version", "") or resolved_ver
        keep_path = after_info.get("path", "")
        if keep_path and len(after_info.get("dirs", [])) > 1:
            for old_dir in after_info["dirs"]:
                if old_dir != keep_path:
                    shutil.rmtree(old_dir, ignore_errors=True)

    # Create isolated desktop / Applications launcher
    if platform.system() == "Darwin":
        apps_dir = home / "Applications"
        apps_dir.mkdir(parents=True, exist_ok=True)
        launcher = apps_dir / "EmTroLy - Antigravity.command"
        launcher_body = (
            "#!/usr/bin/env bash\n"
            "unset OPENAI_API_KEY ELECTRON_RUN_AS_NODE VSCODE_IPC_HOOK_CLI NODE_OPTIONS VSCODE_DEV\n"
            f"export CODEX_HOME={shlex.quote(str(c_home))}\n"
            f"exec {shlex.quote(str(ide_cli))} --user-data-dir {shlex.quote(str(user_data))} "
            f"--extensions-dir {shlex.quote(str(ext_dir))} --new-window\n"
        )
        _write_private_file(launcher, launcher_body, 0o755)
        net_utils.clear_macos_quarantine(launcher)
        net_utils.clear_macos_quarantine(ext_dir)
    elif platform.system() == "Linux":
        apps_dir = home / ".local/share/applications"
        apps_dir.mkdir(parents=True, exist_ok=True)
        wrapper = data_root(home) / "launch-antigravity.sh"
        wrapper_body = (
            "#!/usr/bin/env bash\n"
            "unset OPENAI_API_KEY ELECTRON_RUN_AS_NODE VSCODE_IPC_HOOK_CLI NODE_OPTIONS VSCODE_DEV\n"
            f"export CODEX_HOME={shlex.quote(str(c_home))}\n"
            f"exec {shlex.quote(str(ide_cli))} --user-data-dir {shlex.quote(str(user_data))} "
            f"--extensions-dir {shlex.quote(str(ext_dir))} --new-window \"$@\"\n"
        )
        _write_private_file(wrapper, wrapper_body, 0o755)
        desktop_entry = (
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=Em Trợ Lý - Antigravity IDE\n"
            "Comment=Antigravity IDE và Codex riêng của Em Trợ Lý\n"
            f"Exec={shlex.quote(str(wrapper))}\n"
            "Terminal=false\n"
            "Categories=Development;Utility;\n"
        )
        _write_private_file(apps_dir / "emtroly-antigravity.desktop", desktop_entry, 0o755)

    return {
        "configured": True,
        "installed": True,
        "skipped": skipped_download,
        "up_to_date": True,
        "version": resolved_ver,
        "target_version": latest_ver or resolved_ver,
        "cli": str(ide_cli),
    }


def _create_isolated_antigravity_launcher(home: Path, ide_cli: Path, user_data: Path, ext_dir: Path, c_home: Path) -> str:
    if platform.system() == "Darwin":
        apps_dir = home / "Applications"
        apps_dir.mkdir(parents=True, exist_ok=True)
        launcher = apps_dir / "EmTroLy - Antigravity.command"
        launcher_body = (
            "#!/usr/bin/env bash\n"
            "unset OPENAI_API_KEY ELECTRON_RUN_AS_NODE VSCODE_IPC_HOOK_CLI NODE_OPTIONS VSCODE_DEV\n"
            f"export CODEX_HOME={shlex.quote(str(c_home))}\n"
            f"exec {shlex.quote(str(ide_cli))} --user-data-dir {shlex.quote(str(user_data))} "
            f"--extensions-dir {shlex.quote(str(ext_dir))} --new-window\n"
        )
        _write_private_file(launcher, launcher_body, 0o755)
        net_utils.clear_macos_quarantine(launcher)
        return str(launcher)
    if platform.system() == "Linux":
        apps_dir = home / ".local/share/applications"
        apps_dir.mkdir(parents=True, exist_ok=True)
        wrapper = data_root(home) / "launch-antigravity.sh"
        wrapper_body = (
            "#!/usr/bin/env bash\n"
            "unset OPENAI_API_KEY ELECTRON_RUN_AS_NODE VSCODE_IPC_HOOK_CLI NODE_OPTIONS VSCODE_DEV\n"
            f"export CODEX_HOME={shlex.quote(str(c_home))}\n"
            f"exec {shlex.quote(str(ide_cli))} --user-data-dir {shlex.quote(str(user_data))} "
            f"--extensions-dir {shlex.quote(str(ext_dir))} --new-window \"$@\"\n"
        )
        _write_private_file(wrapper, wrapper_body, 0o755)
        desktop_entry = (
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=Em Trợ Lý - Antigravity IDE\n"
            "Comment=Antigravity IDE và Codex riêng của Em Trợ Lý\n"
            f"Exec={shlex.quote(str(wrapper))}\n"
            "Terminal=false\n"
            "Categories=Development;Utility;\n"
        )
        dst_desktop = apps_dir / "emtroly-antigravity.desktop"
        _write_private_file(dst_desktop, desktop_entry, 0o755)
        return str(dst_desktop)
    return ""


def install_antigravity_ide_only(values: dict, home: Path, progress=lambda _m: None) -> dict:
    """Modular Step 2: Verify/prepare Antigravity IDE & isolated profile without installing VSIX yet."""
    progress("Đang kiểm tra và chuẩn bị Antigravity IDE riêng...")
    app_target, ide_cli = find_antigravity_cli(home)
    if not ide_cli:
        raise RuntimeError(
            "antigravity-ide-missing: Chưa tìm thấy Antigravity IDE trên máy "
            "(macOS: /Applications/Antigravity.app, Linux: /usr/bin/antigravity). "
            "Hãy cài đặt Antigravity IDE trước rồi chạy lại phần này."
        )
    if app_target:
        net_utils.clear_macos_quarantine(app_target)
    ag_root = data_root(home) / "antigravity"
    user_data = ag_root / "UserData"
    ext_dir = ag_root / "Extensions"
    settings_dir = user_data / "User"
    already_configured = (settings_dir / "settings.json").is_file()
    for folder in (ag_root, user_data, ext_dir, settings_dir):
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    editor_settings = {
        "extensions.autoUpdate": False,
        "extensions.autoCheckUpdates": False,
        "extensions.ignoreRecommendations": True,
        "update.mode": "none",
    }
    _write_private_file(settings_dir / "settings.json", json.dumps(editor_settings, indent=2) + "\n", 0o600)
    c_home = write_codex_home(
        home,
        values.get("ai_api_key", ""),
        values.get("model", "gpt-6.2-sol"),
        values.get("base_url", "https://codex.anhlaptrinh.vn/v1"),
    )
    launcher = _create_isolated_antigravity_launcher(home, ide_cli, user_data, ext_dir, c_home)
    ide_ver = get_installed_antigravity_version(home)
    if already_configured:
        ver_note = f" (v{ide_ver})" if ide_ver else ""
        progress(f"✓ Antigravity IDE đã sẵn sàng{ver_note} — không cần tải lại.")
    return {"installed": True, "skipped": bool(already_configured), "up_to_date": True, "version": ide_ver, "cli": str(ide_cli), "launcher": launcher}


def install_codex_extension_only(values: dict, home: Path, progress=lambda _m: None) -> dict:
    """Modular Step 3: Install Codex Extension (`openai.chatgpt`) into Antigravity IDE."""
    _, ide_cli = find_antigravity_cli(home)
    if not ide_cli:
        raise RuntimeError(
            "antigravity-ide-missing: Máy chưa có Antigravity IDE. "
            "Hãy cài Phần 2 (Antigravity IDE) trước khi cài Codex Extension."
        )
    write_codex_home(
        home,
        values.get("ai_api_key", ""),
        values.get("model", "gpt-6.2-sol"),
        values.get("base_url", "https://codex.anhlaptrinh.vn/v1"),
    )
    merged = dict(values, skip_editor=False)
    return install_antigravity_and_extension(merged, home, progress=progress, check_latest=True)


def get_modular_status(home: Path | None = None, preferred_member: str = "emtroly") -> dict:
    resolved_home = Path(home) if home is not None else Path.home()
    c_home = codex_home_dir(resolved_home)
    codex_bin = find_codex_binary(resolved_home, isolated_only=False)
    codex_ready = bool(codex_bin and (c_home / "config.toml").is_file())
    codex_info = get_installed_codex_cli_info(resolved_home)
    codex_ver = codex_info.get("version", "") or codex_info.get("extension_version", "")

    app_target, ide_cli = find_antigravity_cli(resolved_home)
    ide_ready = bool(ide_cli)
    ide_ver = get_installed_antigravity_version(resolved_home) if ide_ready else ""

    ext_info = get_installed_codex_extension_info(resolved_home)
    ext_ready = bool(ext_info["installed"])
    ext_ver = ext_info.get("version", "")

    oc_root = resolved_home / f".openclaw-member-{preferred_member}"
    if not (oc_root / "openclaw.json").is_file():
        found_oc = [p for p in sorted(resolved_home.glob(".openclaw-member-*")) if (p / "openclaw.json").is_file()]
        oc_root = found_oc[0] if found_oc else oc_root
    oc_ready = (oc_root / "openclaw.json").is_file()

    return {
        "codex_cli": {
            "installed": codex_ready,
            "version": codex_ver,
            "path": str(codex_bin) if codex_bin else "",
            "detail": f"Đã cài ({'v' + codex_ver + ' · ' if codex_ver else ''}{codex_bin.name})" if codex_ready and codex_bin else "Chưa cài đặt",
        },
        "antigravity_ide": {
            "installed": ide_ready,
            "version": ide_ver,
            "path": str(app_target or ide_cli or ""),
            "detail": f"Đã sẵn sàng ({'v' + ide_ver + ' · ' if ide_ver else ''}{(app_target or ide_cli).name})" if ide_ready else "Chưa tìm thấy trên máy",
        },
        "codex_extension": {
            "installed": ext_ready,
            "version": ext_ver,
            "path": ext_info.get("path", ""),
            "detail": f"Đã cài ({'v' + ext_ver if ext_ver else Path(ext_info.get('path', '')).name})" if ext_ready else "Chưa cài vào Antigravity",
        },
        "openclaw": {
            "installed": oc_ready,
            "path": str(oc_root) if oc_ready else "",
            "detail": f"Đã cài ({oc_root.name})" if oc_ready else "Chưa cài đặt",
        },
    }


def is_auto_healable(stage: str, error: Exception) -> bool:
    if stage in {"input", "preflight", "provider", "telegram"}:
        return False
    if isinstance(error, FileExistsError):
        return False
    msg = str(error).strip()
    if not msg or msg in NON_HEALABLE_CODES:
        return False
    return True


def build_auto_heal_prompt(
    stage: str,
    error_text: str,
    values: dict,
    home: Path,
    root: Path | None,
    source: Path,
    attempt: int,
) -> str:
    secrets = [values.get("telegram_token", ""), values.get("ai_api_key", "")]
    safe_err = scrub_secrets(error_text, secrets)
    sys_label = "macOS (launchd)" if platform.system() == "Darwin" else "Linux (systemd --user)"
    owners_val = values.get("owner_ids", "")
    owners_str = ",".join(owners_val) if isinstance(owners_val, list) else str(owners_val)
    return (
        f"Bạn là hệ thống tự động chẩn đoán và sửa lỗi cài đặt của bộ cài 'Anh Lập Trình - Em Trợ Lý' trên {sys_label} "
        f"(Lần tự sửa thứ {attempt}/2).\n"
        "Một bước cài đặt vừa gặp sự cố. Hãy kiểm tra nguyên nhân thực tế trên máy và SỬA TRỰC TIẾP để bước kiểm tra tiếp theo thành công.\n\n"
        "THÔNG TIN SỰ CỐ:\n"
        f"- Bước gặp lỗi (stage): {stage}\n"
        f"- Chi tiết lỗi (đã ẩn mã bí mật): {safe_err}\n\n"
        "THÔNG SỐ CÀI ĐẶT:\n"
        f"- Hệ điều hành: {sys_label}\n"
        f"- Thư mục người dùng: {home}\n"
        f"- Thư mục trợ lý OpenClaw: {root or (home / ('.openclaw-member-' + str(values.get('member', 'emtroly'))))}\n"
        f"- Thư mục bộ nguồn (source): {source}\n"
        f"- Thư mục môi trường riêng: {data_root(home)}\n"
        f"- Tên tài khoản Telegram: {values.get('member', 'emtroly')}\n"
        f"- Telegram Owner IDs: {owners_str}\n"
        f"- Model AI: {values.get('model', 'gpt-6.2-sol')}\n\n"
        "NGUYÊN TẮC BẮT BUỘC:\n"
        f"1. Chỉ thao tác trong phạm vi thư mục của user hiện tại ({home}). Không dùng sudo, không xóa dữ liệu cá nhân.\n"
        "2. Tuyệt đối KHÔNG in nội dung telegram.token, member-provider.secret hoặc auth.json ra màn hình.\n"
        "3. Nếu lỗi ở bước `editor`: kiểm tra cài đặt tiện ích `openai.chatgpt` trong thư mục Extensions riêng.\n"
        "4. Nếu lỗi ở bước `gateway` / `zalo`: kiểm tra tiến trình cổng bị kẹt, trạng thái `systemctl --user` (Linux) hoặc `launchctl` (macOS), "
        "và kiểm tra `openclaw plugins list` / `openclaw gateway health --json`.\n"
        "5. Cuối cùng, tóm tắt ngắn gọn 1–2 câu tiếng Việt bạn đã sửa gì.\n"
    )


def invoke_codex_auto_heal(
    stage: str,
    error_text: str,
    values: dict,
    home: Path,
    root: Path | None,
    source: Path,
    *,
    node: Path | None = None,
    progress=lambda _m: None,
    attempt: int = 1,
    timeout: int = 240,
) -> dict:
    api_key = (values.get("ai_api_key") or "").strip()
    if not api_key:
        return {"invoked": False, "reason": "missing-api-key", "exit_code": 2, "summary": ""}

    base_url = (values.get("base_url") or "").strip().rstrip("/")
    allow_global_codex = base_url == "https://codex.anhlaptrinh.vn/v1"
    codex_bin = find_codex_binary(home, isolated_only=not allow_global_codex)
    if not codex_bin:
        return {"invoked": False, "reason": "codex-unavailable", "exit_code": 2, "summary": ""}

    progress(f"Phát hiện sự cố tại bước {stage} — Codex CLI đang tự động chẩn đoán và sửa lỗi (lần {attempt}/2)...")
    secrets = [values.get("telegram_token", ""), api_key]

    with tempfile.TemporaryDirectory(prefix="emtroly-unix-heal-") as tmp_str:
        tmp_dir = Path(tmp_str)
        os.chmod(tmp_dir, 0o700)
        c_home = write_codex_home(
            home,
            api_key,
            values.get("model", "gpt-6.2-sol"),
            base_url or "https://codex.anhlaptrinh.vn/v1",
        )
        summary_file = tmp_dir / "last-message.txt"
        work_dir = root if (root and root.is_dir()) else (data_root(home) if data_root(home).is_dir() else home)
        prompt = build_auto_heal_prompt(stage, error_text, values, home, root, source, attempt)

        env = dict(os.environ, CODEX_HOME=str(c_home), NO_COLOR="1", PYTHONUTF8="1")
        if node and node.parent.is_dir():
            env["PATH"] = str(node.parent) + os.pathsep + env.get("PATH", "")
        for rm_key in ("OPENAI_API_KEY", "ELECTRON_RUN_AS_NODE", "VSCODE_IPC_HOOK_CLI", "NODE_OPTIONS", "VSCODE_DEV"):
            env.pop(rm_key, None)

        model = values.get("model", "gpt-6.2-sol")
        cmd = [
            str(codex_bin),
            "exec",
            "--skip-git-repo-check",
            "--color",
            "never",
            "--sandbox",
            "danger-full-access",
            "-m",
            str(model),
            "-C",
            str(work_dir),
            "-o",
            str(summary_file),
            "-",
        ]
        try:
            proc = subprocess.run(
                cmd,
                input=prompt,
                cwd=str(work_dir),
                env=env,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
                check=False,
            )
            exit_code = proc.returncode
            raw_out = (proc.stdout or "") + "\n" + (proc.stderr or "")
        except subprocess.TimeoutExpired:
            exit_code = 124
            raw_out = "Hết thời gian chờ Codex CLI tự sửa lỗi."

        summary = summary_file.read_text(encoding="utf-8").strip() if summary_file.is_file() else ""
        if not summary:
            tail = [ln.strip() for ln in raw_out.splitlines() if ln.strip()][-3:]
            summary = " ".join(tail)
        safe_summary = scrub_secrets(summary, secrets)[:320]

        stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        audit_line = f"[{stamp}] stage={stage} attempt={attempt} exit={exit_code} summary={safe_summary}\n"
        audit_dirs = [data_root(home) / "logs"]
        if root and root.is_dir():
            audit_dirs.append(root / "logs")
        for a_dir in audit_dirs:
            try:
                a_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
                with (a_dir / "codex-autoheal.log").open("a", encoding="utf-8") as fh:
                    fh.write(audit_line)
            except OSError:
                pass

        return {"invoked": True, "exit_code": exit_code, "summary": safe_summary}


def run_step_with_auto_heal(
    stage: str,
    action,
    *,
    values: dict,
    home: Path,
    root_getter=lambda: None,
    source: Path,
    node: Path | None = None,
    progress=lambda _m: None,
    on_before_retry=None,
):
    last_summary = ""
    try:
        return action()
    except Exception as first_err:
        if not is_auto_healable(stage, first_err):
            raise
        current_err = first_err
        for attempt in (1, 2):
            heal = invoke_codex_auto_heal(
                stage,
                str(current_err),
                values,
                home,
                root_getter(),
                source,
                node=node,
                progress=progress,
                attempt=attempt,
            )
            if not heal.get("invoked"):
                break
            if heal.get("summary"):
                last_summary = heal["summary"]
            progress(f"Codex CLI đã xử lý sự cố bước {stage} (lần {attempt}/2). Đang kiểm tra nghiệm thu lại...")
            if on_before_retry is not None:
                on_before_retry()
            try:
                return action()
            except Exception as retry_err:
                current_err = retry_err
                if not is_auto_healable(stage, current_err):
                    raise
        if last_summary:
            raise RuntimeError(f"{current_err} (Ghi chú từ Codex tự sửa lỗi: {last_summary})") from None
        raise current_err
