"""Verify the selected provider model before creating an instance."""

import json
import urllib.request

from telegram import _NoRedirect


def verify(base_url, api_key, model):
    request = urllib.request.Request(base_url.rstrip("/") + "/models",
                                     headers={"Authorization": "Bearer " + api_key})
    try:
        with urllib.request.build_opener(_NoRedirect()).open(request, timeout=45) as response:
            document = json.loads(response.read(4 * 1024 * 1024))
    except Exception:
        raise RuntimeError("Provider model check failed; verify URL, key and connection") from None
    models = document.get("data", []) if isinstance(document, dict) else []
    matches = [item.get("id") for item in models if isinstance(item, dict)
               and isinstance(item.get("id"), str) and item["id"].casefold() == model.casefold()]
    if not matches:
        raise RuntimeError("The selected model is not available from the provider")
    return matches[0]
