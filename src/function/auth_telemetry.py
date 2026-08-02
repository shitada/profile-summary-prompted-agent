from __future__ import annotations

import hashlib
import json
import logging
from typing import Any

LOGGER_NAME = "profile_chat.auth"
EVENT_PREFIX = "profile_auth "

_LOGGER = logging.getLogger(LOGGER_NAME)
_LOGGER.setLevel(logging.INFO)
_ALLOWED_EVENTS = frozenset(
    {
        "function_mcp_started",
        "function_graph_completed",
        "function_mcp_failed",
    }
)
_ALLOWED_FIELDS = frozenset(
    {
        "correlation_id",
        "user_fingerprint",
        "duration_ms",
        "error_code",
    }
)


def emit_auth_event(event: str, **fields: Any) -> None:
    record = build_auth_event(event, **fields)
    _LOGGER.info("%s%s", EVENT_PREFIX, json.dumps(record, separators=(",", ":")))


def build_auth_event(event: str, **fields: Any) -> dict[str, Any]:
    if event not in _ALLOWED_EVENTS:
        raise ValueError("Unsupported authentication telemetry event.")
    if set(fields) - _ALLOWED_FIELDS:
        raise ValueError("Unsupported authentication telemetry field.")
    record: dict[str, Any] = {
        "schema": "profile-auth-v1",
        "component": "function",
        "event": event,
    }
    for name, value in fields.items():
        if value is None:
            continue
        if isinstance(value, int):
            record[name] = value
        elif isinstance(value, str):
            record[name] = value[:160]
        else:
            raise TypeError("Authentication telemetry values must be scalar.")
    return record


def fingerprint_identity(tenant_id: str, object_id: str) -> str:
    value = (
        "profile-auth-v1|"
        f"{tenant_id.strip().casefold()}|{object_id.strip().casefold()}"
    )
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:24]