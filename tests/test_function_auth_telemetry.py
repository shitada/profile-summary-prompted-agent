import unittest

from src.function.auth_telemetry import build_auth_event, fingerprint_identity
from src.web.auth_telemetry import fingerprint_identity as web_fingerprint_identity


class FunctionAuthTelemetryTests(unittest.TestCase):
    def test_function_and_web_use_same_fingerprint_algorithm(self) -> None:
        fingerprint = fingerprint_identity(
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000002",
        )
        web_fingerprint = web_fingerprint_identity(
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000002",
        )

        self.assertEqual(len(fingerprint), 24)
        self.assertEqual(fingerprint, web_fingerprint)

    def test_event_schema_rejects_token_fields(self) -> None:
        with self.assertRaises(ValueError):
            build_auth_event("function_mcp_started", access_token="secret")


if __name__ == "__main__":
    unittest.main()