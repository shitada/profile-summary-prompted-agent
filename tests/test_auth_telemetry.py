import base64
import json
import unittest

from src.web.auth_telemetry import build_auth_event, user_fingerprint


class AuthTelemetryTests(unittest.TestCase):
    def test_fingerprint_is_stable_without_exposing_claims(self) -> None:
        tenant_id = "00000000-0000-4000-8000-000000000001"
        object_id = "00000000-0000-4000-8000-000000000002"
        principal = base64.b64encode(
            json.dumps(
                {
                    "claims": [
                        {"typ": "tid", "val": tenant_id},
                        {"typ": "oid", "val": object_id},
                    ]
                }
            ).encode("utf-8")
        ).decode("ascii")

        first = user_fingerprint({"X-MS-CLIENT-PRINCIPAL": principal})
        second = user_fingerprint({"X-MS-CLIENT-PRINCIPAL": principal})

        self.assertEqual(first, second)
        self.assertEqual(len(first), 24)
        self.assertNotIn(tenant_id, first)
        self.assertNotIn(object_id, first)

    def test_event_schema_rejects_unapproved_fields(self) -> None:
        with self.assertRaises(ValueError):
            build_auth_event(
                "foundry_mcp_consent_required",
                consent_url="https://example.test/?secret=value",
            )

    def test_invalid_principal_is_not_logged(self) -> None:
        self.assertEqual(
            user_fingerprint({"X-MS-CLIENT-PRINCIPAL": "not-base64"}),
            "unavailable",
        )


if __name__ == "__main__":
    unittest.main()