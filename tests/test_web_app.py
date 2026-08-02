import base64
import json
import time
import unittest

from src.web.app import create_app


ENVIRON = {
    "FOUNDRY_PROJECT_ENDPOINT": "https://example.services.ai.azure.com/api/projects/profile",
    "FOUNDRY_AGENT_NAME": "profile-agent",
    "GRAPH_CONSENT_URL": "https://profile-function.example/api/consent",
}


class WebAppTests(unittest.TestCase):
    def setUp(self) -> None:
        self.calls = []
        self.auth_events = []

        def invoker(**kwargs):
            self.calls.append(kwargs)
            return {
                "status": "completed",
                "responseId": "resp_result",
                "message": "プロフィールを要約しました。",
            }

        def auth_event_sink(event, **fields):
            self.auth_events.append({"event": event, **fields})

        self.app = create_app(
            invoker=invoker,
            environ=ENVIRON,
            auth_event_sink=auth_event_sink,
        )
        self.app.testing = True
        self.client = self.app.test_client()

    def headers(self, **overrides):
        headers = {
            "Origin": "https://chat.example.test",
            "X-MS-CLIENT-PRINCIPAL": "validated-principal",
            "X-MS-TOKEN-AAD-ACCESS-TOKEN": "sensitive-user-token",
            "X-MS-TOKEN-AAD-EXPIRES-ON": str(int(time.time()) + 600),
        }
        headers.update(overrides)
        return headers

    def post(self, payload, headers=None):
        return self.client.post(
            "/api/chat",
            json=payload,
            headers=headers or self.headers(),
            base_url="https://chat.example.test",
        )

    def test_index_has_security_headers(self) -> None:
        response = self.client.get("/", base_url="https://chat.example.test")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["X-Frame-Options"], "DENY")
        self.assertIn("script-src 'self'", response.headers["Content-Security-Policy"])

    def test_index_shows_easy_auth_user_name(self) -> None:
        response = self.client.get(
            "/",
            headers={
                "X-MS-CLIENT-PRINCIPAL": "validated-principal",
                "X-MS-CLIENT-PRINCIPAL-NAME": "sample-user",
            },
            base_url="https://chat.example.test",
        )

        self.assertEqual(response.status_code, 200)
        self.assertIn("sample-user", response.get_data(as_text=True))

    def test_index_escapes_user_name_and_requires_principal(self) -> None:
        escaped_response = self.client.get(
            "/",
            headers={
                "X-MS-CLIENT-PRINCIPAL": "validated-principal",
                "X-MS-CLIENT-PRINCIPAL-NAME": "<script>alert(1)</script>",
            },
            base_url="https://chat.example.test",
        )
        missing_principal_response = self.client.get(
            "/",
            headers={"X-MS-CLIENT-PRINCIPAL-NAME": "untrusted-user"},
            base_url="https://chat.example.test",
        )

        escaped_html = escaped_response.get_data(as_text=True)
        self.assertNotIn("<script>alert(1)</script>", escaped_html)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt;", escaped_html)
        self.assertNotIn(
            "untrusted-user",
            missing_principal_response.get_data(as_text=True),
        )

    def test_missing_easy_auth_principal_is_rejected(self) -> None:
        response = self.post(
            {"message": "プロフィールを教えて"},
            self.headers(**{"X-MS-CLIENT-PRINCIPAL": ""}),
        )

        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.get_json()["error"]["code"], "missing_client_principal")
        self.assertEqual(self.calls, [])

    def test_jwt_expiry_is_used_when_header_format_is_unavailable(self) -> None:
        expires_on = int(time.time()) + 600
        payload = base64.urlsafe_b64encode(
            json.dumps({"exp": expires_on}).encode("utf-8")
        ).decode("ascii").rstrip("=")
        access_token = f"header.{payload}.signature"

        response = self.post(
            {"message": "プロフィールを教えて"},
            self.headers(
                **{
                    "X-MS-TOKEN-AAD-ACCESS-TOKEN": access_token,
                    "X-MS-TOKEN-AAD-EXPIRES-ON": "undocumented-format",
                }
            ),
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.calls[0]["expires_on"], expires_on)

    def test_cross_origin_request_is_rejected(self) -> None:
        response = self.post(
            {"message": "プロフィールを教えて"},
            self.headers(Origin="https://other.example.test"),
        )

        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.get_json()["error"]["code"], "invalid_origin")

    def test_chat_forwards_only_server_selected_configuration(self) -> None:
        response = self.post(
            {
                "message": "  プロフィールを教えて  ",
                "previousResponseId": "resp_previous",
            }
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["responseId"], "resp_result")
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0]["message"], "プロフィールを教えて")
        self.assertEqual(self.calls[0]["previous_response_id"], "resp_previous")
        self.assertEqual(self.calls[0]["settings"].agent_name, "profile-agent")
        self.assertNotIn("sensitive-user-token", str(response.get_json()))
        self.assertEqual(
            [event["event"] for event in self.auth_events],
            ["web_chat_started", "web_chat_completed"],
        )

    def test_consent_event_has_safe_diagnostic_context(self) -> None:
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

        def consent_invoker(**_kwargs):
            return {
                "status": "consent_required",
                "responseId": "resp_secret_state",
                "message": "アクセス許可が必要です。",
                "action": {
                    "purpose": "foundry_oauth_consent",
                    "url": (
                        "https://region.consent.azure-apihub.net/"
                        "login?data=sensitive-consent-state"
                    ),
                },
            }

        events = []
        app = create_app(
            invoker=consent_invoker,
            environ=ENVIRON,
            auth_event_sink=lambda event, **fields: events.append(
                {"event": event, **fields}
            ),
        )
        app.testing = True
        client = app.test_client()

        response = client.post(
            "/api/chat",
            json={"message": "プロフィールを教えて"},
            headers=self.headers(
                **{
                    "X-MS-CLIENT-PRINCIPAL": principal,
                    "X-MS-CLIENT-PRINCIPAL-NAME": "sample-user",
                }
            ),
            base_url="https://chat.example.test",
        )

        payload = response.get_json()
        consent_event = events[-1]
        serialized = json.dumps(consent_event)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(consent_event["event"], "foundry_mcp_consent_required")
        self.assertEqual(consent_event["consent_host"], "region.consent.azure-apihub.net")
        self.assertEqual(payload["diagnosticId"], consent_event["diagnostic_id"])
        self.assertEqual(len(consent_event["user_fingerprint"]), 24)
        for sensitive_value in (
            tenant_id,
            object_id,
            "sample-user",
            "sensitive-user-token",
            "resp_secret_state",
            "sensitive-consent-state",
        ):
            self.assertNotIn(sensitive_value, serialized)

    def test_unknown_client_configuration_is_rejected(self) -> None:
        response = self.post(
            {
                "message": "プロフィールを教えて",
                "agentName": "attacker-selected-agent",
            }
        )

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.get_json()["error"]["code"], "invalid_request")
        self.assertEqual(self.calls, [])

    def test_consent_open_event_accepts_only_canonical_diagnostic_id(self) -> None:
        diagnostic_id = "00000000-0000-4000-8000-000000000003"
        response = self.client.post(
            "/api/diagnostics/consent-opened",
            json={"diagnosticId": diagnostic_id},
            headers=self.headers(),
            base_url="https://chat.example.test",
        )
        invalid_response = self.client.post(
            "/api/diagnostics/consent-opened",
            json={"diagnosticId": "not-a-diagnostic-id"},
            headers=self.headers(),
            base_url="https://chat.example.test",
        )

        self.assertEqual(response.status_code, 204)
        self.assertEqual(invalid_response.status_code, 400)
        self.assertEqual(self.auth_events[-1]["event"], "foundry_mcp_consent_opened")
        self.assertEqual(self.auth_events[-1]["diagnostic_id"], diagnostic_id)

    def test_invalid_response_id_is_rejected(self) -> None:
        response = self.post(
            {
                "message": "プロフィールを教えて",
                "previousResponseId": "../../unexpected",
            }
        )

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.get_json()["error"]["code"], "invalid_response_id")

    def test_message_length_is_bounded(self) -> None:
        response = self.post({"message": "a" * 2001})

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.get_json()["error"]["code"], "message_too_long")


if __name__ == "__main__":
    unittest.main()