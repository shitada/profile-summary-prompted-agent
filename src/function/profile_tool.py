from __future__ import annotations

import base64
import json
import re
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

EASY_AUTH_ACCESS_TOKEN_HEADER = "x-ms-token-aad-access-token"
EASY_AUTH_PRINCIPAL_HEADER = "x-ms-client-principal"

TENANT_CLAIM_TYPES = frozenset(
    {
        "tid",
        "http://schemas.microsoft.com/identity/claims/tenantid",
    }
)
OBJECT_CLAIM_TYPES = frozenset(
    {
        "oid",
        "http://schemas.microsoft.com/identity/claims/objectidentifier",
    }
)

PROFILE_FIELDS = (
    "displayName",
    "givenName",
    "surname",
    "jobTitle",
    "department",
    "mail",
    "userPrincipalName",
    "officeLocation",
    "preferredLanguage",
)

_MAX_PROFILE_VALUE_LENGTH = 512
_WHITESPACE = re.compile(r"\s+")


class AuthContextError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class UserIdentity:
    tenant_id: str
    object_id: str


def get_transport_headers(context: Mapping[str, Any]) -> dict[str, str]:
    transport = context.get("transport")
    if not isinstance(transport, Mapping):
        raise AuthContextError("missing_transport", "MCP transport metadata is missing.")

    properties = transport.get("properties")
    if not isinstance(properties, Mapping):
        raise AuthContextError(
            "missing_transport_properties",
            "MCP transport properties are missing.",
        )

    headers = properties.get("headers")
    if not isinstance(headers, Mapping):
        raise AuthContextError("missing_headers", "MCP transport headers are missing.")

    return {
        str(name).casefold(): str(value).strip()
        for name, value in headers.items()
        if value is not None
    }


def extract_user_access_token(context: Mapping[str, Any]) -> str:
    headers = get_transport_headers(context)
    easy_auth_token = headers.get(EASY_AUTH_ACCESS_TOKEN_HEADER, "")
    if easy_auth_token:
        return easy_auth_token

    authorization = headers.get("authorization", "")
    scheme, separator, credentials = authorization.partition(" ")
    if separator and scheme.casefold() == "bearer" and credentials.strip():
        return credentials.strip()

    raise AuthContextError(
        "missing_user_token",
        "A delegated user access token was not provided.",
    )


def extract_user_identity(context: Mapping[str, Any]) -> UserIdentity:
    headers = get_transport_headers(context)
    encoded_principal = headers.get(EASY_AUTH_PRINCIPAL_HEADER, "")
    if not encoded_principal:
        raise AuthContextError(
            "missing_client_principal",
            "The validated Easy Auth client principal is missing.",
        )

    principal = _decode_client_principal(encoded_principal)
    claims = principal.get("claims")
    if not isinstance(claims, list):
        raise AuthContextError(
            "invalid_client_principal",
            "The Easy Auth client principal has no claims collection.",
        )

    tenant_id = _find_claim(claims, TENANT_CLAIM_TYPES)
    object_id = _find_claim(claims, OBJECT_CLAIM_TYPES)
    if not tenant_id:
        raise AuthContextError(
            "missing_tenant_claim",
            "The validated principal has no tenant identifier.",
        )
    if not object_id:
        raise AuthContextError(
            "missing_object_claim",
            "The validated principal has no user object identifier.",
        )

    return UserIdentity(tenant_id=tenant_id, object_id=object_id)


def normalize_profile(payload: Mapping[str, Any]) -> dict[str, str | None]:
    return {field: _normalize_profile_value(payload.get(field)) for field in PROFILE_FIELDS}


def build_success_response(payload: Mapping[str, Any]) -> dict[str, Any]:
    return {"status": "ok", "profile": normalize_profile(payload)}


def _decode_client_principal(encoded_principal: str) -> Mapping[str, Any]:
    try:
        padded = encoded_principal + ("=" * (-len(encoded_principal) % 4))
        decoded = base64.b64decode(padded, validate=True)
        principal = json.loads(decoded.decode("utf-8"))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AuthContextError(
            "invalid_client_principal",
            "The Easy Auth client principal is invalid.",
        ) from error

    if not isinstance(principal, Mapping):
        raise AuthContextError(
            "invalid_client_principal",
            "The Easy Auth client principal must be a JSON object.",
        )
    return principal


def _find_claim(claims: list[Any], accepted_types: frozenset[str]) -> str | None:
    for claim in claims:
        if not isinstance(claim, Mapping):
            continue
        claim_type = claim.get("typ")
        claim_value = claim.get("val")
        if claim_type in accepted_types and isinstance(claim_value, str):
            normalized = claim_value.strip()
            if normalized:
                return normalized
    return None


def _normalize_profile_value(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = _WHITESPACE.sub(" ", value).strip()
    if not normalized:
        return None
    return normalized[:_MAX_PROFILE_VALUE_LENGTH]