"""Validate user-supplied settings for isolated Unix installations."""

import re
from urllib.parse import urlsplit


MODELS = {"gpt-6.2-sol", "gpt-6.1-terra", "gpt-6.2-astra"}
INVISIBLE_CHARS_RE = re.compile(r"[\u200b\u200c\u200d\u2060\ufeff\u00a0]")
LEADING_DASH_RE = re.compile(r"^[\u2010\u2011\u2012\u2013\u2014\u2212]+")
MARKDOWN_LINK_RE = re.compile(r"^\[[^\]]*\]\((https?://[^)\s]+)\)$")


def clean_text(value) -> str:
    if not isinstance(value, str):
        return ""
    return INVISIBLE_CHARS_RE.sub("", value).strip()


def normalize(raw_settings: dict) -> dict:
    """Sanitize real-world customer copy-paste quirks before validation."""
    if not isinstance(raw_settings, dict):
        return {}
    out = dict(raw_settings)
    for key in (
        "member",
        "assistant_name",
        "owner_ids",
        "group_id",
        "telegram_token",
        "ai_api_key",
        "model",
        "base_url",
        "gateway_port",
        "qr_owner_id",
        "audience",
        "addressing",
        "style",
    ):
        if key in out and isinstance(out[key], str):
            out[key] = clean_text(out[key])

    if isinstance(out.get("member"), str):
        out["member"] = out["member"].lower()

    tok = out.get("telegram_token", "")
    if isinstance(tok, str) and tok:
        tok_no_space = re.sub(r"\s+", "", tok)
        bot_match = re.fullmatch(r"(?i)bot([0-9]{5,}:[A-Za-z0-9_-]{20,})", tok_no_space)
        out["telegram_token"] = bot_match.group(1) if bot_match else tok_no_space

    if isinstance(out.get("ai_api_key"), str):
        out["ai_api_key"] = re.sub(r"\s+", "", out["ai_api_key"])

    raw_owners = out.get("owner_ids", "")
    if isinstance(raw_owners, str) and raw_owners:
        parts = [p.strip() for p in re.split(r"[,;\s]+", raw_owners) if p.strip()]
        deduped = list(dict.fromkeys(parts))
        out["owner_ids"] = ",".join(deduped)

    raw_group = out.get("group_id", "")
    if isinstance(raw_group, str) and raw_group:
        compact_group = re.sub(r"\s+", "", raw_group)
        compact_group = LEADING_DASH_RE.sub("-", compact_group)
        out["group_id"] = compact_group

    raw_url = out.get("base_url", "")
    if isinstance(raw_url, str) and raw_url:
        md = MARKDOWN_LINK_RE.fullmatch(raw_url)
        if md:
            raw_url = md.group(1).strip()
        out["base_url"] = raw_url.rstrip("/")

    if isinstance(out.get("gateway_port"), str):
        port_compact = re.sub(r"\s+", "", out["gateway_port"])
        out["gateway_port"] = port_compact if port_compact else "0"

    configure_zalo = out.get("configure_zalo", True) is not False
    qr_owner = out.get("qr_owner_id", "")
    if isinstance(qr_owner, str):
        qr_owner = re.sub(r"\s+", "", qr_owner)
        out["qr_owner_id"] = qr_owner
    if configure_zalo and not out.get("qr_owner_id"):
        first_owner = (out.get("owner_ids", "").split(",", 1)[0] or "").strip()
        if re.fullmatch(r"[1-9][0-9]*", first_owner):
            out["qr_owner_id"] = first_owner

    return out


def validate(settings):
    if not isinstance(settings, dict):
        raise ValueError("invalid-settings")

    def text(key):
        value = settings.get(key, "")
        return value.strip() if isinstance(value, str) else ""

    member = text("member")
    if not re.fullmatch(r"[a-z][a-z0-9_-]{0,56}", member):
        raise ValueError("invalid-member")
    assistant_name = text("assistant_name")
    if not assistant_name:
        raise ValueError("missing-assistant-name")
    owners = text("owner_ids")
    if not re.fullmatch(r"[1-9][0-9]*(,[1-9][0-9]*)*", owners):
        raise ValueError("invalid-owners")
    owners = owners.split(",")
    if len(owners) != len(set(owners)):
        raise ValueError("duplicate-owners")
    group = text("group_id")
    if group and not re.fullmatch(r"-[1-9][0-9]*", group):
        raise ValueError("invalid-group")
    telegram = text("telegram_token")
    if not re.fullmatch(r"[0-9]{5,}:[A-Za-z0-9_-]{20,}", telegram):
        raise ValueError("invalid-telegram-token")
    api_key = text("ai_api_key")
    if not api_key:
        raise ValueError("missing-api-key")
    model = text("model")
    if model.lower() not in MODELS:
        raise ValueError("invalid-model")
    base_url = text("base_url")
    try:
        if any(character.isspace() or ord(character) < 32 for character in base_url):
            raise ValueError("invalid-base-url")
        url = urlsplit(base_url)
        if (url.scheme != "https" or not url.hostname or url.username is not None or
                url.password is not None or url.query or url.fragment):
            raise ValueError("invalid-base-url")
        _ = url.port
    except ValueError:
        raise ValueError("invalid-base-url") from None
    raw_port = text("gateway_port")
    if not re.fullmatch(r"[0-9]+", raw_port) or not (int(raw_port) == 0 or 1024 <= int(raw_port) <= 65000):
        raise ValueError("invalid-port")
    if settings.get("accept_full_access") is not True:
        raise ValueError("full-access-consent-required")
    configure_zalo = settings.get("configure_zalo", True) is not False
    qr_owner = text("qr_owner_id")
    if configure_zalo:
        if not qr_owner and settings.get("configure_zalo") is True:
            qr_owner = owners[0]
        if qr_owner not in owners:
            raise ValueError("invalid-qr-owner")
    return {
        "member": member, "assistant_name": assistant_name, "owner_ids": owners,
        "group_id": group, "telegram_token": telegram, "ai_api_key": api_key,
        "model": model, "base_url": base_url.rstrip("/"), "gateway_port": int(raw_port),
        "qr_owner_id": qr_owner if configure_zalo else "", "configure_zalo": configure_zalo,
        "skip_editor": bool(settings.get("skip_editor", False)),
        "audience": text("audience"),
        "addressing": text("addressing"), "style": text("style"),
    }
