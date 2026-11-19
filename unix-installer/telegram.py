"""Safely validate a Telegram bot and preserve its existing command menu."""

import json
import re
import time
import urllib.request


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api(token, method, body=None):
    if not re.fullmatch(r"[0-9]{5,}:[A-Za-z0-9_-]{20,}", token):
        raise ValueError("Invalid Telegram token")
    if method not in {"getMe", "getMyCommands", "setMyCommands"}:
        raise ValueError("Unsupported Telegram operation")
    payload = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request("https://api.telegram.org/bot" + token + "/" + method, data=payload,
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.build_opener(_NoRedirect()).open(request, timeout=45) as response:
            result = json.loads(response.read(1024 * 1024))
    except Exception:
        raise RuntimeError("Telegram request failed; check the connection and bot token") from None
    if not isinstance(result, dict) or result.get("ok") is not True:
        raise RuntimeError("Telegram did not accept the request")
    return result.get("result")


def verify_bot(token):
    result = api(token, "getMe")
    if not isinstance(result, dict) or result.get("is_bot") is not True:
        raise RuntimeError("Telegram did not confirm a bot")


def ensure_menu(token):
    current = api(token, "getMyCommands")
    if not isinstance(current, list):
        raise RuntimeError("Telegram command menu has an unexpected format")
    required = [{"command": "zaloqr", "description": "Tao QR dang nhap Zalo"},
                {"command": "zalostatus", "description": "Kiem tra trang thai Zalo"}]
    names = {item["command"] for item in required}
    for item in current:
        if not isinstance(item, dict) or not isinstance(item.get("command"), str) or not isinstance(item.get("description"), str):
            raise RuntimeError("Telegram command menu has an unexpected entry")
        if item["command"] not in names:
            required.append({"command": item["command"], "description": item["description"]})
            names.add(item["command"])
    if len(required) > 100:
        raise RuntimeError("Telegram command menu is full; existing commands were not changed")
    if api(token, "setMyCommands", {"commands": required}) is not True:
        raise RuntimeError("Telegram command menu was not updated")
    for attempt in range(8):
        result = api(token, "getMyCommands")
        if isinstance(result, list) and {"zaloqr", "zalostatus"}.issubset(
                {item.get("command") for item in result if isinstance(item, dict)}):
            return
        if attempt < 7:
            time.sleep(2)
    raise RuntimeError("Telegram command menu could not be verified")
