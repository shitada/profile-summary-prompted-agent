from __future__ import annotations

import logging
import re
import time
import uuid
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlparse

from azure.ai.projects import AIProjectClient
from azure.core.credentials import AccessToken

FOUNDRY_SCOPE = "https://ai.azure.com/.default"
RESPONSE_ID_PATTERN = re.compile(r"resp_[A-Za-z0-9_-]{1,240}")
MAX_ASSISTANT_TEXT_LENGTH = 12_000
MICROSOFT_OAUTH_CONSENT_HOST_SUFFIXES = (
    ".consent.azure-apihub.net",
    ".consent.azure-apim.net",
)


class FoundryChatError(RuntimeError):
    def __init__(self, code: str, message: str, status_code: int) -> None:
        super().__init__(message)
        self.code = code
        self.status_code = status_code
        self.correlation_id = str(uuid.uuid4())


@dataclass(frozen=True, slots=True)
class FoundryChatSettings:
    project_endpoint: str
    agent_name: str
    graph_consent_url: str = ""
    oauth_consent_host_suffixes: tuple[str, ...] = (
        MICROSOFT_OAUTH_CONSENT_HOST_SUFFIXES
    )

    @classmethod
    def from_environ(cls, environ: Mapping[str, str]) -> FoundryChatSettings:
        settings = cls(
            project_endpoint=environ.get("FOUNDRY_PROJECT_ENDPOINT", "").strip(),
            agent_name=environ.get("FOUNDRY_AGENT_NAME", "").strip(),
            graph_consent_url=environ.get("GRAPH_CONSENT_URL", "").strip(),
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        endpoint = urlparse(self.project_endpoint)
        if endpoint.scheme != "https" or not endpoint.hostname:
            raise FoundryChatError(
                "invalid_configuration",
                "The Foundry project endpoint is not configured.",
                500,
            )
        if "/api/projects/" not in endpoint.path:
            raise FoundryChatError(
                "invalid_configuration",
                "The Foundry project endpoint is invalid.",
                500,
            )
        if not self.agent_name:
            raise FoundryChatError(
                "invalid_configuration",
                "The Foundry agent name is not configured.",
                500,
            )
        if self.graph_consent_url:
            graph_url = urlparse(self.graph_consent_url)
            if graph_url.scheme != "https" or not graph_url.hostname:
                raise FoundryChatError(
                    "invalid_configuration",
                    "The Graph consent URL is invalid.",
                    500,
                )
        if not self.oauth_consent_host_suffixes or any(
            not suffix.startswith(".") for suffix in self.oauth_consent_host_suffixes
        ):
            raise FoundryChatError(
                "invalid_configuration",
                "The OAuth consent host allowlist is invalid.",
                500,
            )


class EasyAuthTokenCredential:
    def __init__(self, token: str, expires_on: int) -> None:
        self._token = token
        self._expires_on = expires_on

    def get_token(self, *scopes: str, **_: Any) -> AccessToken:
        if not scopes or any(scope != FOUNDRY_SCOPE for scope in scopes):
            raise FoundryChatError(
                "unexpected_token_scope",
                "The downstream token scope is not allowed.",
                500,
            )
        if self._expires_on <= int(time.time()) + 30:
            raise FoundryChatError(
                "user_token_expired",
                "Your sign-in session has expired. Sign in again and retry.",
                401,
            )
        return AccessToken(self._token, self._expires_on)

    def close(self) -> None:
        return None


def invoke_agent(
    *,
    settings: FoundryChatSettings,
    access_token: str,
    expires_on: int,
    message: str,
    previous_response_id: str | None = None,
    project_client_factory: Callable[..., Any] = AIProjectClient,
) -> dict[str, Any]:
    credential = EasyAuthTokenCredential(access_token, expires_on)
    request: dict[str, Any] = {
        "input": message,
        "extra_body": {
            "agent_reference": {
                "name": settings.agent_name,
                "type": "agent_reference",
            }
        },
    }
    if previous_response_id:
        request["previous_response_id"] = previous_response_id

    try:
        with project_client_factory(
            endpoint=settings.project_endpoint,
            credential=credential,
        ) as project_client:
            with project_client.get_openai_client() as openai_client:
                response = openai_client.responses.create(**request)
    except FoundryChatError:
        raise
    except Exception as error:
        classified = classify_foundry_error(error)
        logging.warning(
            "Foundry chat request failed: %s (%s)",
            classified.code,
            classified.correlation_id,
        )
        raise classified from error
    finally:
        credential.close()

    return normalize_foundry_response(response, settings)


def normalize_foundry_response(
    response: Any,
    settings: FoundryChatSettings,
) -> dict[str, Any]:
    response_id = str(getattr(response, "id", "")).strip()
    if not RESPONSE_ID_PATTERN.fullmatch(response_id):
        raise FoundryChatError(
            "invalid_foundry_response",
            "The agent returned an invalid response.",
            502,
        )

    assistant_text = str(getattr(response, "output_text", "") or "").strip()
    if len(assistant_text) > MAX_ASSISTANT_TEXT_LENGTH:
        assistant_text = assistant_text[:MAX_ASSISTANT_TEXT_LENGTH].rstrip()

    oauth_consent_url = _find_oauth_consent_url(
        getattr(response, "output", []),
        settings.oauth_consent_host_suffixes,
    )
    if oauth_consent_url:
        return {
            "status": "consent_required",
            "responseId": response_id,
            "message": assistant_text or "アクセス許可が必要です。",
            "action": {
                "type": "open_url",
                "purpose": "foundry_oauth_consent",
                "url": oauth_consent_url,
            },
        }

    if not assistant_text:
        raise FoundryChatError(
            "empty_foundry_response",
            "The agent did not return a message.",
            502,
        )

    result: dict[str, Any] = {
        "status": "completed",
        "responseId": response_id,
        "message": assistant_text,
    }
    if settings.graph_consent_url and settings.graph_consent_url in assistant_text:
        result["status"] = "consent_required"
        result["action"] = {
            "type": "open_url",
            "purpose": "graph_consent",
            "url": settings.graph_consent_url,
        }
    return result


def classify_foundry_error(error: BaseException) -> FoundryChatError:
    status_code = getattr(error, "status_code", None)
    error_code = str(getattr(error, "code", "") or "").casefold()
    nested_error = getattr(error, "error", None)
    if not error_code and nested_error is not None:
        error_code = str(getattr(nested_error, "code", "") or "").casefold()

    if status_code == 401:
        return FoundryChatError(
            "foundry_authentication_failed",
            "Your Foundry sign-in session is no longer valid.",
            401,
        )
    if status_code == 403:
        return FoundryChatError(
            "foundry_access_denied",
            "You do not have access to this agent.",
            403,
        )
    if status_code == 429:
        return FoundryChatError(
            "foundry_throttled",
            "The agent is busy. Wait briefly and retry.",
            429,
        )
    if status_code == 400 and error_code == "content_filter":
        return FoundryChatError(
            "content_blocked",
            "The message was blocked by the content policy.",
            400,
        )
    if status_code == 400 and error_code == "tool_user_error":
        return FoundryChatError(
            "foundry_mcp_connection_failed",
            (
                "The MCP connection could not be refreshed. Retry the request; "
                "if access is requested, authorize it again."
            ),
            409,
        )
    if isinstance(status_code, int) and status_code >= 500:
        return FoundryChatError(
            "foundry_unavailable",
            "The agent is temporarily unavailable.",
            503,
        )
    return FoundryChatError(
        "foundry_request_failed",
        "The agent request could not be completed.",
        502,
    )


def _find_oauth_consent_url(
    output: Any,
    allowed_host_suffixes: tuple[str, ...],
) -> str | None:
    for item in output or []:
        payload = _as_mapping(item)
        if payload.get("type") != "oauth_consent_request":
            continue
        consent_link = str(payload.get("consent_link", "")).strip()
        parsed = urlparse(consent_link)
        hostname = (parsed.hostname or "").casefold()
        try:
            port = parsed.port
        except ValueError:
            port = -1
        allowed_host = any(
            hostname.endswith(suffix.casefold()) for suffix in allowed_host_suffixes
        )
        if (
            parsed.scheme != "https"
            or not allowed_host
            or parsed.username is not None
            or parsed.password is not None
            or port not in (None, 443)
        ):
            raise FoundryChatError(
                "invalid_consent_url",
                "The agent returned an invalid consent URL.",
                502,
            )
        return consent_link
    return None


def _as_mapping(item: Any) -> Mapping[str, Any]:
    if isinstance(item, Mapping):
        return item
    model_dump = getattr(item, "model_dump", None)
    if callable(model_dump):
        dumped = model_dump()
        if isinstance(dumped, Mapping):
            return dumped
    return {
        "type": getattr(item, "type", None),
        "consent_link": getattr(item, "consent_link", None),
    }