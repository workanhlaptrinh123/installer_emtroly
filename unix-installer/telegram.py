"""Safely validate a Telegram bot and preserve its existing command menu."""

import json
import re
import time
import urllib.request

import net_utils
import settings


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def normalize_token(token: str) -> str:
    cleaned = settings.clean_text(token)
    cleaned = re.sub(r"\s+", "", cleaned)
    m = re.fullmatch(r"(?i)bot([0-9]{5,}:[A-Za-z0-9_-]{20,})", cleaned)
    return m.group(1) if m else cleaned


def privacy_warning(bot_me) -> str:
    if isinstance(bot_me, dict) and bot_me.get("can_read_all_group_messages") is False:
        return (
            "Lưu ý: Bot đang bật Privacy Mode — hãy mở @BotFather gõ /setprivacy → chọn Bot → Disable "
            "(hoặc cấp quyền Admin nhóm cho Bot) để Bot đọc được mọi tin nhắn trong nhóm."
        )
    return ""


def api(token, method, body=None):
    token = normalize_token(token)
    if not re.fullmatch(r"[0-9]{5,}:[A-Za-z0-9_-]{20,}", token):
        raise ValueError("Invalid Telegram token")
    if method not in {"getMe", "getMyCommands", "setMyCommands", "getUpdates"}:
        raise ValueError("Unsupported Telegram operation")
    url = "https://api.telegram.org/bot" + token + "/" + method
    if method == "getUpdates":
        url += "?limit=50"
    payload = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    try:
        opener = urllib.request.build_opener(_NoRedirect())
        with net_utils.urlopen_with_retry(request, timeout=45, opener=opener) as response:
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
    return result


def fetch_ids_from_updates(token):
    me = verify_bot(token)
    bot_name = ("@" + me["username"]) if me.get("username") else str(me.get("first_name", "Bot"))
    updates = api(token, "getUpdates") or []
    owners = []
    groups = []
    seen_owners = set()
    seen_groups = set()
    for upd in updates if isinstance(updates, list) else []:
        if not isinstance(upd, dict):
            continue
        candidates = [
            upd.get(k)
            for k in ("message", "edited_message", "channel_post", "my_chat_member", "chat_member")
            if isinstance(upd.get(k), dict)
        ]
        cbq = upd.get("callback_query")
        if isinstance(cbq, dict):
            if isinstance(cbq.get("from"), dict):
                candidates.append({"from": cbq["from"]})
            if isinstance(cbq.get("message"), dict):
                candidates.append(cbq["message"])
        for item in candidates:
            frm = item.get("from")
            if isinstance(frm, dict) and not frm.get("is_bot"):
                uid = str(frm.get("id", ""))
                if re.fullmatch(r"[1-9][0-9]*", uid) and uid not in seen_owners:
                    seen_owners.add(uid)
                    owners.append(uid)
            chat = item.get("chat")
            if isinstance(chat, dict):
                cid = str(chat.get("id", ""))
                if re.fullmatch(r"-[1-9][0-9]*", cid) and cid not in seen_groups:
                    seen_groups.add(cid)
                    groups.append(cid)
                elif re.fullmatch(r"[1-9][0-9]*", cid) and chat.get("type") == "private" and cid not in seen_owners:
                    seen_owners.add(cid)
                    owners.append(cid)
    return {
        "bot_username": bot_name,
        "owner_id": owners[0] if owners else "",
        "group_id": groups[0] if groups else "",
        "owners": owners,
        "groups": groups,
        "can_read_all_group_messages": me.get("can_read_all_group_messages"),
        "privacy_warning": privacy_warning(me),
    }


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
