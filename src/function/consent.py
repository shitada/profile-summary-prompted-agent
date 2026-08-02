from __future__ import annotations

import os
from collections.abc import Mapping
from urllib.parse import urlencode

_CONSENT_COMPLETE_PATH = "/api/consent-complete"


def build_graph_consent_url(environ: Mapping[str, str] | None = None) -> str:
    settings = os.environ if environ is None else environ
    base_url = _resolve_base_url(settings)
    query = urlencode({"post_login_redirect_uri": _CONSENT_COMPLETE_PATH})
    return f"{base_url}/.auth/login/aad?{query}"


def _resolve_base_url(environ: Mapping[str, str]) -> str:
    configured = environ.get("PUBLIC_BASE_URL", "").strip().rstrip("/")
    if configured:
        if not configured.startswith(("https://", "http://localhost:")):
            raise ValueError("PUBLIC_BASE_URL must use HTTPS outside localhost.")
        return configured

    hostname = environ.get("WEBSITE_HOSTNAME", "").strip()
    if hostname:
        return f"https://{hostname}"

    return "http://localhost:7071"