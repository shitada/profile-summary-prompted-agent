from __future__ import annotations

import asyncio
import logging
import os
import time
import uuid
from collections.abc import Awaitable, Callable, Mapping
from typing import Any

try:
    from .auth_telemetry import emit_auth_event, fingerprint_identity
    from .consent import build_graph_consent_url
    from .profile_tool import (
        AuthContextError,
        build_success_response,
        extract_user_access_token,
        extract_user_identity,
    )
except ImportError:
    from auth_telemetry import emit_auth_event, fingerprint_identity
    from consent import build_graph_consent_url
    from profile_tool import (
        AuthContextError,
        build_success_response,
        extract_user_access_token,
        extract_user_identity,
    )

GRAPH_SCOPE = "https://graph.microsoft.com/.default"
GRAPH_ME_URL = "https://graph.microsoft.com/v1.0/me"
GRAPH_PROFILE_SELECT = (
    "displayName,givenName,surname,jobTitle,department,mail,"
    "userPrincipalName,officeLocation,preferredLanguage"
)

TokenProvider = Callable[[Mapping[str, Any]], Awaitable[str]]
ProfileFetcher = Callable[[str], Awaitable[Mapping[str, Any]]]


class OboFlowError(RuntimeError):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class GraphServiceError(RuntimeError):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


async def get_profile_response(
    context: Mapping[str, Any],
    *,
    token_provider: TokenProvider | None = None,
    profile_fetcher: ProfileFetcher | None = None,
    consent_url_builder: Callable[[], str] = build_graph_consent_url,
    auth_event_sink: Callable[..., None] = emit_auth_event,
) -> dict[str, Any]:
    correlation_id = str(uuid.uuid4())
    started = time.monotonic()
    fingerprint = _safe_user_fingerprint(context)
    provide_token = token_provider or acquire_graph_access_token
    fetch_profile = profile_fetcher or fetch_graph_profile

    try:
        auth_event_sink(
            "function_mcp_started",
            correlation_id=correlation_id,
            user_fingerprint=fingerprint,
        )
        access_token = await provide_token(context)
        profile = await fetch_profile(access_token)
        auth_event_sink(
            "function_graph_completed",
            correlation_id=correlation_id,
            user_fingerprint=fingerprint,
            duration_ms=int((time.monotonic() - started) * 1_000),
        )
        return build_success_response(profile)
    except AuthContextError as error:
        auth_event_sink(
            "function_mcp_failed",
            correlation_id=correlation_id,
            user_fingerprint=fingerprint,
            error_code=error.code,
            duration_ms=int((time.monotonic() - started) * 1_000),
        )
        logging.warning("Profile auth context rejected: %s (%s)", error.code, correlation_id)
        return _error_response(
            code=error.code,
            message="A signed-in user context is required.",
            correlation_id=correlation_id,
        )
    except OboFlowError as error:
        auth_event_sink(
            "function_mcp_failed",
            correlation_id=correlation_id,
            user_fingerprint=fingerprint,
            error_code=error.code,
            duration_ms=int((time.monotonic() - started) * 1_000),
        )
        logging.warning("Profile OBO flow failed: %s (%s)", error.code, correlation_id)
        if error.code == "graph_consent_required":
            return _error_response(
                code=error.code,
                message="Microsoft Graph profile permission is required.",
                correlation_id=correlation_id,
                action_url=consent_url_builder(),
            )
        if error.code == "conditional_access_required":
            return _error_response(
                code=error.code,
                message="Additional sign-in requirements prevented profile access.",
                correlation_id=correlation_id,
            )
        return _error_response(
            code=error.code,
            message="The delegated Graph token could not be acquired.",
            correlation_id=correlation_id,
        )
    except GraphServiceError as error:
        auth_event_sink(
            "function_mcp_failed",
            correlation_id=correlation_id,
            user_fingerprint=fingerprint,
            error_code=error.code,
            duration_ms=int((time.monotonic() - started) * 1_000),
        )
        logging.warning("Graph profile request failed: %s (%s)", error.code, correlation_id)
        return _error_response(
            code=error.code,
            message="Microsoft Graph could not return the profile.",
            correlation_id=correlation_id,
        )
    except Exception:
        auth_event_sink(
            "function_mcp_failed",
            correlation_id=correlation_id,
            user_fingerprint=fingerprint,
            error_code="internal_error",
            duration_ms=int((time.monotonic() - started) * 1_000),
        )
        logging.error("Unexpected profile tool failure (%s)", correlation_id)
        return _error_response(
            code="internal_error",
            message="The profile request could not be completed.",
            correlation_id=correlation_id,
        )


def _safe_user_fingerprint(context: Mapping[str, Any]) -> str:
    try:
        identity = extract_user_identity(context)
        return fingerprint_identity(identity.tenant_id, identity.object_id)
    except AuthContextError:
        return "unavailable"


async def acquire_graph_access_token(context: Mapping[str, Any]) -> str:
    credential = build_obo_credential(context)
    try:
        token = await asyncio.to_thread(credential.get_token, GRAPH_SCOPE)
        return token.token
    except Exception as error:
        raise OboFlowError(classify_obo_failure(error)) from error
    finally:
        await asyncio.to_thread(credential.close)


def build_obo_credential(context: Mapping[str, Any]):
    from azure.identity import ManagedIdentityCredential, OnBehalfOfCredential

    user_token = extract_user_access_token(context)
    identity = extract_user_identity(context)

    managed_identity_client_id = os.environ.get(
        "OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID", ""
    ).strip()
    application_client_id = os.environ.get("ENTRA_APPLICATION_CLIENT_ID", "").strip()
    if not managed_identity_client_id:
        raise AuthContextError(
            "missing_managed_identity_client_id",
            "The managed identity assertion client is not configured.",
        )
    if not application_client_id:
        raise AuthContextError(
            "missing_application_client_id",
            "The Function application client is not configured.",
        )

    token_exchange_audience = os.environ.get(
        "TOKEN_EXCHANGE_AUDIENCE", "api://AzureADTokenExchange"
    ).rstrip("/")
    managed_identity = ManagedIdentityCredential(client_id=managed_identity_client_id)

    def get_client_assertion() -> str:
        assertion = managed_identity.get_token(
            f"{token_exchange_audience}/.default"
        )
        return assertion.token

    return OnBehalfOfCredential(
        tenant_id=identity.tenant_id,
        client_id=application_client_id,
        client_assertion_func=get_client_assertion,
        user_assertion=user_token,
    )


def classify_obo_failure(error: BaseException) -> str:
    message = str(error).casefold()
    if any(
        marker in message
        for marker in (
            "aadsts65001",
            "consent_required",
            "has not consented",
        )
    ):
        return "graph_consent_required"
    if any(
        marker in message
        for marker in (
            "aadsts50076",
            "aadsts50079",
            "interaction_required",
            "claims challenge",
        )
    ):
        return "conditional_access_required"
    return "graph_token_exchange_failed"


async def fetch_graph_profile(access_token: str) -> Mapping[str, Any]:
    import aiohttp

    timeout = aiohttp.ClientTimeout(total=15, connect=5)
    headers = {"Authorization": f"Bearer {access_token}"}
    params = {"$select": GRAPH_PROFILE_SELECT}

    async with aiohttp.ClientSession(timeout=timeout) as session:
        for attempt in range(2):
            async with session.get(
                GRAPH_ME_URL,
                headers=headers,
                params=params,
            ) as response:
                if response.status == 200:
                    payload = await response.json(content_type=None)
                    if not isinstance(payload, Mapping):
                        raise GraphServiceError("graph_invalid_response")
                    return payload

                retryable = response.status == 429 or response.status >= 500
                if retryable and attempt == 0:
                    await asyncio.sleep(_retry_delay(response.headers))
                    continue
                raise GraphServiceError(_graph_error_code(response.status))

    raise GraphServiceError("graph_unavailable")


def _retry_delay(headers: Mapping[str, str]) -> float:
    try:
        return min(max(float(headers.get("Retry-After", "0.25")), 0.0), 2.0)
    except ValueError:
        return 0.25


def _graph_error_code(status: int) -> str:
    if status in (401, 403):
        return "graph_access_denied"
    if status == 429:
        return "graph_throttled"
    if status >= 500:
        return "graph_unavailable"
    return "graph_request_failed"


def _error_response(
    *,
    code: str,
    message: str,
    correlation_id: str,
    action_url: str | None = None,
) -> dict[str, Any]:
    response: dict[str, Any] = {
        "status": "error",
        "error": {
            "code": code,
            "message": message,
            "correlationId": correlation_id,
        },
    }
    if action_url:
        response["error"]["action"] = {
            "type": "open_url",
            "url": action_url,
        }
    return response