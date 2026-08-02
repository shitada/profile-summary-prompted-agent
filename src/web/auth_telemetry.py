from __future__ import annotations

import base64
import hashlib
import json
import logging
from collections.abc import Mapping
from typing import Any

LOGGER_NAME = "profile_chat.auth"
EVENT_PREFIX = "profile_auth "
FINGERPRINT_VERSION = "v1"

_LOGGER = logging.getLogger(LOGGER_NAME)
_LOGGER.setLevel(logging.INFO)
_MONITORING_CONFIGURED = False

_TENANT_CLAIMS = frozenset(
    {
        "tid",
        "http://schemas.microsoft.com/identity/claims/tenantid",
    }
)
_OBJECT_CLAIMS = frozenset(
    {
        "oid",
        "http://schemas.microsoft.com/identity/claims/objectidentifier",
    }
)
_ALLOWED_EVENTS = frozenset(
    {
        "web_chat_started",
        "web_chat_completed",
        "web_chat_failed",
        "foundry_mcp_consent_required",
        "foundry_mcp_consent_opened",
    }
)
_ALLOWED_FIELDS = frozenset(
    {
        "diagnostic_id",
        "user_fingerprint",
        "token_ttl_seconds",
        "previous_response_present",
        "status",
        "error_code",
        "http_status",
        "consent_host",
        "duration_ms",
        "connection_name",
    }
)


def configure_auth_telemetry(environ: Mapping[str, str]) -> None:
    global _MONITORING_CONFIGURED
    if _MONITORING_CONFIGURED:
        return
    if not environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING", "").strip():
        return

    from azure.identity import ManagedIdentityCredential
    from azure.monitor.opentelemetry import configure_azure_monitor

    managed_identity_client_id = environ.get(
        "OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID", ""
    ).strip()
    if not managed_identity_client_id:
        raise RuntimeError("Web telemetry managed identity is not configured.")

    configure_azure_monitor(
        credential=ManagedIdentityCredential(client_id=managed_identity_client_id),
        logger_name=LOGGER_NAME,
        disable_tracing=True,
        disable_metrics=True,
        enable_live_metrics=False,
        enable_performance_counters=False,
    )
    _MONITORING_CONFIGURED = True


def emit_auth_event(event: str, **fields: Any) -> None:
    record = build_auth_event(event, **fields)
    _LOGGER.info("%s%s", EVENT_PREFIX, json.dumps(record, separators=(",", ":")))


def build_auth_event(event: str, **fields: Any) -> dict[str, Any]:
    if event not in _ALLOWED_EVENTS:
        raise ValueError("Unsupported authentication telemetry event.")
    unexpected = set(fields) - _ALLOWED_FIELDS
    if unexpected:
        raise ValueError("Unsupported authentication telemetry field.")

    record: dict[str, Any] = {
        "schema": "profile-auth-v1",
        "component": "web",
        "event": event,
    }
    for name, value in fields.items():
        if value is None:
            continue
        if isinstance(value, bool):
            record[name] = value
        elif isinstance(value, int):
            record[name] = value
        elif isinstance(value, str):
            record[name] = value[:160]
        else:
            raise TypeError("Authentication telemetry values must be scalar.")
    return record


def user_fingerprint(headers: Mapping[str, str]) -> str:
    encoded_principal = headers.get("X-MS-CLIENT-PRINCIPAL", "").strip()
    if not encoded_principal:
        return "unavailable"

    try:
        padded = encoded_principal + ("=" * (-len(encoded_principal) % 4))
        principal = json.loads(base64.b64decode(padded, validate=True).decode("utf-8"))
        claims = principal.get("claims")
        if not isinstance(claims, list):
            return "unavailable"
        tenant_id = _find_claim(claims, _TENANT_CLAIMS)
        object_id = _find_claim(claims, _OBJECT_CLAIMS)
        if not tenant_id or not object_id:
            return "unavailable"
        return fingerprint_identity(tenant_id, object_id)
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return "unavailable"


def fingerprint_identity(tenant_id: str, object_id: str) -> str:
    value = (
        f"profile-auth-{FINGERPRINT_VERSION}|"
        f"{tenant_id.strip().casefold()}|{object_id.strip().casefold()}"
    )
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:24]


def _find_claim(claims: list[Any], accepted_types: frozenset[str]) -> str:
    for claim in claims:
        if not isinstance(claim, Mapping):
            continue
        claim_type = str(claim.get("typ", "")).casefold()
        if claim_type in accepted_types:
            return str(claim.get("val", "")).strip()
    return ""