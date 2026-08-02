from __future__ import annotations

import base64
import json
import os
import time
import uuid
from collections.abc import Callable, Mapping
from datetime import datetime
from typing import Any
from urllib.parse import urlparse

from flask import Flask, jsonify, render_template, request

try:
    from .auth_telemetry import (
        configure_auth_telemetry,
        emit_auth_event,
        user_fingerprint,
    )
    from .foundry_chat import (
        RESPONSE_ID_PATTERN,
        FoundryChatError,
        FoundryChatSettings,
        invoke_agent,
    )
except ImportError:
    from auth_telemetry import configure_auth_telemetry, emit_auth_event, user_fingerprint
    from foundry_chat import (
        RESPONSE_ID_PATTERN,
        FoundryChatError,
        FoundryChatSettings,
        invoke_agent,
    )

MAX_MESSAGE_LENGTH = 2_000
MAX_REQUEST_BYTES = 16 * 1024
DEFAULT_CONNECTION_NAME = "profile-mcp-oauth"


def create_app(
    *,
    invoker: Callable[..., dict[str, Any]] = invoke_agent,
    environ: Mapping[str, str] | None = None,
    auth_event_sink: Callable[..., None] = emit_auth_event,
) -> Flask:
    settings_source = os.environ if environ is None else environ
    configure_auth_telemetry(settings_source)
    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = MAX_REQUEST_BYTES

    @app.after_request
    def add_security_headers(response):
        response.headers["Cache-Control"] = "no-store"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; base-uri 'none'; connect-src 'self'; "
            "font-src 'self'; form-action 'self'; frame-ancestors 'none'; "
            "img-src 'self'; object-src 'none'; script-src 'self'; style-src 'self'"
        )
        response.headers["Cross-Origin-Opener-Policy"] = "same-origin"
        response.headers["Permissions-Policy"] = (
            "camera=(), geolocation=(), microphone=(), payment=()"
        )
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        return response

    @app.get("/")
    def index():
        return render_template(
            "index.html",
            signed_in_user=_get_signed_in_user_name(request.headers),
        )

    @app.post("/api/chat")
    def chat():
        diagnostic_id = str(uuid.uuid4())
        started = time.monotonic()
        fingerprint = user_fingerprint(request.headers)
        token_ttl_seconds: int | None = None
        previous_response_present = False
        try:
            _require_same_origin()
            access_token, expires_on = _get_easy_auth_context(request.headers)
            token_ttl_seconds = expires_on - int(time.time())
            message, previous_response_id = _parse_chat_request(
                request.get_json(silent=True)
            )
            previous_response_present = previous_response_id is not None
            auth_event_sink(
                "web_chat_started",
                diagnostic_id=diagnostic_id,
                user_fingerprint=fingerprint,
                token_ttl_seconds=token_ttl_seconds,
                previous_response_present=previous_response_present,
                connection_name=settings_source.get(
                    "FOUNDRY_CONNECTION_NAME", DEFAULT_CONNECTION_NAME
                ),
            )
            settings = FoundryChatSettings.from_environ(settings_source)
            result = invoker(
                settings=settings,
                access_token=access_token,
                expires_on=expires_on,
                message=message,
                previous_response_id=previous_response_id,
            )
            result["diagnosticId"] = diagnostic_id
            duration_ms = int((time.monotonic() - started) * 1_000)
            if result.get("status") == "consent_required" and isinstance(
                result.get("action"), Mapping
            ) and result["action"].get("purpose") == "foundry_oauth_consent":
                consent_host = urlparse(str(result["action"].get("url", ""))).hostname
                auth_event_sink(
                    "foundry_mcp_consent_required",
                    diagnostic_id=diagnostic_id,
                    user_fingerprint=fingerprint,
                    token_ttl_seconds=token_ttl_seconds,
                    previous_response_present=previous_response_present,
                    consent_host=consent_host or "unavailable",
                    duration_ms=duration_ms,
                    connection_name=settings_source.get(
                        "FOUNDRY_CONNECTION_NAME", DEFAULT_CONNECTION_NAME
                    ),
                )
            else:
                auth_event_sink(
                    "web_chat_completed",
                    diagnostic_id=diagnostic_id,
                    user_fingerprint=fingerprint,
                    status=str(result.get("status", "unknown")),
                    duration_ms=duration_ms,
                )
            return jsonify(result)
        except FoundryChatError as error:
            auth_event_sink(
                "web_chat_failed",
                diagnostic_id=diagnostic_id,
                user_fingerprint=fingerprint,
                token_ttl_seconds=token_ttl_seconds,
                previous_response_present=previous_response_present,
                error_code=error.code,
                http_status=error.status_code,
                duration_ms=int((time.monotonic() - started) * 1_000),
            )
            return (
                jsonify(
                    {
                        "status": "error",
                        "diagnosticId": diagnostic_id,
                        "error": {
                            "code": error.code,
                            "message": str(error),
                            "correlationId": error.correlation_id,
                        },
                    }
                ),
                error.status_code,
            )

    @app.post("/api/diagnostics/consent-opened")
    def consent_opened():
        _require_same_origin()
        principal = request.headers.get("X-MS-CLIENT-PRINCIPAL", "").strip()
        if not principal:
            return ("", 401)
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict) or set(payload) != {"diagnosticId"}:
            return ("", 400)
        diagnostic_id = payload.get("diagnosticId")
        try:
            canonical_id = str(uuid.UUID(str(diagnostic_id)))
        except (ValueError, AttributeError):
            return ("", 400)
        if canonical_id != diagnostic_id:
            return ("", 400)
        auth_event_sink(
            "foundry_mcp_consent_opened",
            diagnostic_id=canonical_id,
            user_fingerprint=user_fingerprint(request.headers),
            connection_name=settings_source.get(
                "FOUNDRY_CONNECTION_NAME", DEFAULT_CONNECTION_NAME
            ),
        )
        return ("", 204)

    @app.errorhandler(413)
    def request_too_large(_):
        error = FoundryChatError(
            "request_too_large",
            "The request is too large.",
            413,
        )
        return (
            jsonify(
                {
                    "status": "error",
                    "error": {
                        "code": error.code,
                        "message": str(error),
                        "correlationId": error.correlation_id,
                    },
                }
            ),
            413,
        )

    return app


def _require_same_origin() -> None:
    origin = request.headers.get("Origin", "").strip()
    parsed = urlparse(origin)
    request_host = request.host.casefold()
    is_local = request_host.startswith(("localhost:", "127.0.0.1:"))
    allowed_scheme = parsed.scheme == "https" or (is_local and parsed.scheme == "http")
    if not origin or not allowed_scheme or parsed.netloc.casefold() != request_host:
        raise FoundryChatError(
            "invalid_origin",
            "The request origin is not allowed.",
            403,
        )


def _get_easy_auth_context(headers: Mapping[str, str]) -> tuple[str, int]:
    principal = headers.get("X-MS-CLIENT-PRINCIPAL", "").strip()
    access_token = headers.get("X-MS-TOKEN-AAD-ACCESS-TOKEN", "").strip()
    expires_header = headers.get("X-MS-TOKEN-AAD-EXPIRES-ON", "").strip()
    if not principal:
        raise FoundryChatError(
            "missing_client_principal",
            "A signed-in user is required.",
            401,
        )
    if not access_token:
        raise FoundryChatError(
            "missing_user_token",
            "A Foundry user token is required. Sign in again and retry.",
            401,
        )
    return access_token, _parse_expiry(expires_header, access_token)


def _get_signed_in_user_name(headers: Mapping[str, str]) -> str:
    principal = headers.get("X-MS-CLIENT-PRINCIPAL", "").strip()
    if not principal:
        return ""
    return headers.get("X-MS-CLIENT-PRINCIPAL-NAME", "").strip()


def _parse_expiry(value: str, access_token: str) -> int:
    if value:
        try:
            return int(float(value))
        except ValueError:
            pass
        try:
            return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
        except ValueError:
            pass
        for date_format in ("%m/%d/%Y %H:%M:%S %z", "%m/%d/%Y %I:%M:%S %p %z"):
            try:
                return int(datetime.strptime(value, date_format).timestamp())
            except ValueError:
                continue

    try:
        segments = access_token.split(".")
        if len(segments) != 3:
            raise ValueError("Access token is not a JWT.")
        payload_segment = segments[1] + ("=" * (-len(segments[1]) % 4))
        payload = json.loads(base64.urlsafe_b64decode(payload_segment).decode("utf-8"))
        expires_on = payload.get("exp")
        if not isinstance(expires_on, int):
            raise ValueError("Access token has no integer exp claim.")
        return expires_on
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise FoundryChatError(
            "invalid_token_expiry",
            "The sign-in session expiry is invalid.",
            401,
        ) from error


def _parse_chat_request(payload: Any) -> tuple[str, str | None]:
    if not isinstance(payload, dict):
        raise FoundryChatError(
            "invalid_request",
            "A JSON request body is required.",
            400,
        )
    if not set(payload).issubset({"message", "previousResponseId"}):
        raise FoundryChatError(
            "invalid_request",
            "The request contains unsupported fields.",
            400,
        )
    message = payload.get("message")
    if not isinstance(message, str) or not message.strip():
        raise FoundryChatError(
            "invalid_message",
            "Enter a message.",
            400,
        )
    normalized_message = message.strip()
    if len(normalized_message) > MAX_MESSAGE_LENGTH:
        raise FoundryChatError(
            "message_too_long",
            "The message is too long.",
            400,
        )

    previous_response_id = payload.get("previousResponseId")
    if previous_response_id is None:
        return normalized_message, None
    if not isinstance(previous_response_id, str) or not RESPONSE_ID_PATTERN.fullmatch(
        previous_response_id
    ):
        raise FoundryChatError(
            "invalid_response_id",
            "The conversation state is invalid. Reset the conversation and retry.",
            400,
        )
    return normalized_message, previous_response_id


app = create_app()