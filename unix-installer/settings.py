"""Validate user-supplied settings for isolated Unix installations."""

import re
from urllib.parse import urlsplit


MODELS = {"gpt-6.2-sol", "gpt-6.1-terra", "gpt-6.2-astra"}


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
    if not re.fullmatch(r"-[1-9][0-9]*", group):
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
