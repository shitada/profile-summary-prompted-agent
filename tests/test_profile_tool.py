import base64
import json
import unittest

from src.function.profile_tool import (
    AuthContextError,
    build_success_response,
    extract_user_access_token,
    extract_user_identity,
    normalize_profile,
)


def build_context(headers: dict[str, str]) -> dict:
    return {"transport": {"properties": {"headers": headers}}}


def encode_principal(claims: list[dict[str, str]]) -> str:
    payload = json.dumps({"claims": claims}).encode("utf-8")
    return base64.b64encode(payload).decode("ascii").rstrip("=")


class ProfileToolTests(unittest.TestCase):
    def test_easy_auth_token_is_preferred_case_insensitively(self) -> None:
        context = build_context(
            {
                "X-MS-TOKEN-AAD-ACCESS-TOKEN": "easy-auth-token",
                "authorization": "Bearer fallback-token",
            }
        )

        self.assertEqual(extract_user_access_token(context), "easy-auth-token")

    def test_authorization_bearer_token_is_supported_as_fallback(self) -> None:
        context = build_context({"Authorization": "bearer fallback-token"})

        self.assertEqual(extract_user_access_token(context), "fallback-token")

    def test_missing_user_token_has_stable_error_code(self) -> None:
        with self.assertRaises(AuthContextError) as captured:
            extract_user_access_token(build_context({}))

        self.assertEqual(captured.exception.code, "missing_user_token")

    def test_identity_uses_validated_easy_auth_claims(self) -> None:
        context = build_context(
            {
                "x-ms-client-principal": encode_principal(
                    [
                        {"typ": "tid", "val": "tenant-id"},
                        {
                            "typ": "http://schemas.microsoft.com/identity/claims/objectidentifier",
                            "val": "object-id",
                        },
                    ]
                )
            }
        )

        identity = extract_user_identity(context)

        self.assertEqual(identity.tenant_id, "tenant-id")
        self.assertEqual(identity.object_id, "object-id")

    def test_invalid_principal_does_not_echo_header_value(self) -> None:
        with self.assertRaises(AuthContextError) as captured:
            extract_user_identity(
                build_context({"x-ms-client-principal": "sensitive-invalid-value"})
            )

        self.assertEqual(captured.exception.code, "invalid_client_principal")
        self.assertNotIn("sensitive-invalid-value", str(captured.exception))

    def test_profile_is_allowlisted_and_normalized(self) -> None:
        payload = {
            "displayName": "  Sample\nUser  ",
            "department": "Sample Department",
            "mail": None,
            "mobilePhone": "+00-0000-0000",
            "id": "must-not-be-returned",
        }

        profile = normalize_profile(payload)

        self.assertEqual(profile["displayName"], "Sample User")
        self.assertEqual(profile["department"], "Sample Department")
        self.assertIsNone(profile["mail"])
        self.assertNotIn("mobilePhone", profile)
        self.assertNotIn("id", profile)

    def test_success_response_has_fixed_schema(self) -> None:
        response = build_success_response({"displayName": "Sample User"})

        self.assertEqual(response["status"], "ok")
        self.assertEqual(response["profile"]["displayName"], "Sample User")
        self.assertEqual(len(response["profile"]), 9)


if __name__ == "__main__":
    unittest.main()