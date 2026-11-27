"""Native skill sync and bounded install timing; no credentials or service management."""

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request


def atomic_write(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError("Refusing symlinked destination")
    descriptor, temporary = tempfile.mkstemp(prefix=".local-install-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def safe_target(root, relative):
    if not isinstance(relative, str) or "\\" in relative:
        raise ValueError("Invalid manifest path")
    parts = PurePosixPath(relative).parts
    if not parts or relative.startswith("/") or any(part in {"", ".", ".."} or ":" in part or part.startswith(".") for part in relative.split("/")):
        raise ValueError("Unsafe manifest path")
    target = root.joinpath(*parts)
    if target.resolve() != target or root not in target.parents:
        raise ValueError("Refusing symlinked or escaping skill path")
    return target


def fetch(url, maximum, cancelled=None):
    parsed = urllib.parse.urlsplit(url)
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Skill URLs must not contain credentials or query data")
    if parsed.scheme != "https" and not (parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost"}):
        raise ValueError("HTTPS required")
    for attempt in range(3):
        if cancelled is not None and cancelled.is_set():
            raise RuntimeError("Skill sync cancelled after a failed file")
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                if urllib.parse.urlsplit(response.url).netloc != parsed.netloc:
                    raise ValueError("Cross-origin skill redirect refused")
                payload = response.read(maximum + 1)
            if len(payload) > maximum:
                raise ValueError("Skill response exceeds limit")
            return payload
        except (OSError, TimeoutError):
            if attempt == 2:
                raise RuntimeError("Skill download failed after three attempts") from None
            time.sleep(attempt + 1)


def has_reparse_point(path, stop_at=None):
    current = Path(path)
    stop_resolved = None
    if stop_at is not None and Path(stop_at).exists():
        try:
            stop_resolved = Path(stop_at).resolve()
        except OSError:
            stop_resolved = None
    while True:
        if current.is_symlink():
            return True
        if current.exists():
            try:
                if getattr(os.lstat(current), "st_file_attributes", 0) & 0x400:
                    return True
            except OSError:
                return True
        if stop_resolved is not None and current.exists():
            try:
                if current.resolve() == stop_resolved:
                    break
            except OSError:
                pass
        parent = current.parent
        if parent == current:
            break
        current = parent
    return False


def sync_skills(manifest_url, source_url, workspace, cache_dir, expected_count, workers=6, manifest_file=None):
    raw_workspace, raw_cache_dir = Path(workspace).absolute(), Path(cache_dir).absolute()
    if (has_reparse_point(raw_workspace, stop_at=raw_workspace.parent)
            or has_reparse_point(raw_cache_dir, stop_at=raw_cache_dir.parent)):
        raise ValueError("Workspace/cache must use real paths")
    workspace, cache_dir = raw_workspace.resolve(), raw_cache_dir.resolve()
    if has_reparse_point(workspace, stop_at=raw_workspace.parent) or has_reparse_point(cache_dir, stop_at=raw_cache_dir.parent):
        raise ValueError("Workspace/cache must use real paths")
    source = urllib.parse.urlsplit(source_url)
    if urllib.parse.urlsplit(manifest_url).netloc != source.netloc:
        raise ValueError("Manifest and files must share an origin")
    if manifest_file:
        manifest_path = Path(manifest_file)
        if manifest_path.is_symlink() or manifest_path.stat().st_size > 4 * 1024 * 1024:
            raise ValueError("Invalid local manifest")
        manifest_bytes = manifest_path.read_bytes()
    else:
        manifest_bytes = fetch(manifest_url, 4 * 1024 * 1024)
    manifest = json.loads(manifest_bytes)
    skills = manifest.get("skills", [])
    if not isinstance(skills, list) or len(skills) != expected_count or manifest.get("count") != expected_count:
        raise ValueError("Full manifest skill count mismatch")
    skill_root = workspace / "skills"
    entries, seen, skill_names = [], set(), set()
    for skill in skills:
        name = skill.get("name", "")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", name) or name in skill_names:
            raise ValueError("Invalid or duplicate skill name")
        skill_names.add(name)
        files = skill.get("files", [])
        if not isinstance(files, list) or not any(item.get("path") == "SKILL.md" for item in files):
            raise ValueError("Every skill must have a manifest SKILL.md")
        for item in files:
            relative = name + "/" + item["path"]
            digest = item.get("sha256", "")
            destination = safe_target(skill_root, relative)
            if relative.casefold() in seen or not re.fullmatch(r"[a-f0-9]{64}", digest):
                raise ValueError("Duplicate path or invalid SHA256")
            seen.add(relative.casefold())
            entries.append((relative, destination, digest))
    if len(entries) > 20000:
        raise ValueError("Unexpected manifest file count")
    started = time.monotonic()
    run_id = str(time.time_ns())
    cancelled = threading.Event()

    def install(entry):
        if cancelled.is_set():
            raise RuntimeError("Skill sync cancelled")
        relative, destination, digest = entry
        if destination.is_file() and hashlib.sha256(destination.read_bytes()).hexdigest() == digest:
            return "unchanged"
        cached = safe_target(cache_dir, digest)
        payload = cached.read_bytes() if cached.is_file() else None
        result = "cached"
        if payload is None or hashlib.sha256(payload).hexdigest() != digest:
            payload = fetch(source_url.rstrip("/") + "/" + urllib.parse.quote(relative, safe="/"), 32 * 1024 * 1024, cancelled)
            if hashlib.sha256(payload).hexdigest() != digest:
                raise ValueError("Downloaded skill SHA256 mismatch")
            atomic_write(cached, payload)
            result = "downloaded"
        if destination.exists():
            saved = safe_target(workspace / "skill-backups" / run_id, relative)
            atomic_write(saved, destination.read_bytes())
        atomic_write(destination, payload)
        return result

    summary = {"unchanged": 0, "cached": 0, "downloaded": 0}
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(workers, 6)))
    futures = [pool.submit(install, entry) for entry in entries]
    try:
        for future in concurrent.futures.as_completed(futures):
            summary[future.result()] += 1
    except Exception:
        cancelled.set()
        for future in futures:
            future.cancel()
        raise
    finally:
        pool.shutdown(wait=True, cancel_futures=True)
    for relative, destination, digest in entries:
        if hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
            raise ValueError("Final skill verification failed")
    atomic_write(workspace / "v6-skills-manifest.json", manifest_bytes)
    summary.update(skill_count=len(skills), file_count=len(entries), hashes_verified=True,
                   seconds=round(time.monotonic() - started, 3))
    return summary


def timed_step(state, name, command, timeout):
    if not re.fullmatch(r"[a-z][a-z0-9_-]{0,63}", name) or not command:
        raise ValueError("A safe step name and argv are required")
    started = time.monotonic()
    try:
        result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout, check=False)
        status, code = "passed" if result.returncode == 0 else "failed", result.returncode
    except subprocess.TimeoutExpired:
        status, code = "timeout", 124
    except OSError:
        status, code = "launch_failed", 127
    path = Path(state) / "install-timings.json"
    document = json.loads(path.read_text()) if path.exists() else {"steps": []}
    record = {"step": name, "status": status, "exit_code": code, "seconds": round(time.monotonic() - started, 3)}
    document["steps"].append(record)
    atomic_write(path, json.dumps(document, indent=2).encode())
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    sync = commands.add_parser("sync")
    for name in ("manifest-url", "source-url", "workspace", "cache-dir"):
        sync.add_argument("--" + name, required=True)
    sync.add_argument("--expected-count", type=int, required=True)
    sync.add_argument("--workers", type=int, default=6)
    sync.add_argument("--manifest-file")
    step = commands.add_parser("step")
    step.add_argument("--state", required=True)
    step.add_argument("--name", required=True)
    step.add_argument("--timeout", type=int, default=900)
    step.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == "sync":
        result = sync_skills(args.manifest_url, args.source_url, args.workspace, args.cache_dir, args.expected_count, args.workers, args.manifest_file)
    else:
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        result = timed_step(args.state, args.name, command, args.timeout)
    print(json.dumps(result))
    return result.get("exit_code", 0)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, RuntimeError, OSError, KeyError, TypeError):
        print(json.dumps({"status": "failed", "reason": "local_helper_validation_or_io"}))
        raise SystemExit(1)
