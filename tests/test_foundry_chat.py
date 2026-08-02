import time
import unittest
from types import SimpleNamespace

from src.web.foundry_chat import (
    FOUNDRY_SCOPE,
    EasyAuthTokenCredential,
    FoundryChatError,
    FoundryChatSettings,
    classify_foundry_error,
    invoke_agent,
    normalize_foundry_response,
)


SETTINGS = FoundryChatSettings(
    project_endpoint="https://example.services.ai.azure.com/api/projects/profile",
    agent_name="profile-agent",
    graph_consent_url="https://profile-function.example/api/consent",
)


class FakeOpenAIClient:
    def __init__(self, response=None, error=None):
        self.responses = self
        self.response = response
        self.error = error
        self.requests = []

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return None

    def create(self, **kwargs):
        self.requests.append(kwargs)
        if self.error:
            raise self.error
        return self.response


class FakeProjectClient:
    def __init__(self, *, endpoint, credential, openai_client):
        self.endpoint = endpoint
        self.credential = credential
        self.openai_client = openai_client

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return None

    def get_openai_client(self):
        self.credential.get_token(FOUNDRY_SCOPE)
        return self.openai_client


class FoundryChatTests(unittest.TestCase):
    def test_oauth_consent_host_allowlist_cannot_be_overridden(self) -> None:
        settings = FoundryChatSettings.from_environ(
            {
                "FOUNDRY_PROJECT_ENDPOINT": SETTINGS.project_endpoint,
                "FOUNDRY_AGENT_NAME": SETTINGS.agent_name,
                "OAUTH_CONSENT_HOST_SUFFIX": ".attacker.test",
            }
        )

        self.assertNotIn(".attacker.test", settings.oauth_consent_host_suffixes)

    def test_easy_auth_credential_allows_only_foundry_scope(self) -> None:
        credential = EasyAuthTokenCredential("sensitive-token", int(time.time()) + 600)

        token = credential.get_token(FOUNDRY_SCOPE)

        self.assertEqual(token.token, "sensitive-token")
        with self.assertRaises(FoundryChatError) as captured:
            credential.get_token("https://graph.microsoft.com/.default")
        self.assertEqual(captured.exception.code, "unexpected_token_scope")

    def test_expired_token_is_rejected(self) -> None:
        credential = EasyAuthTokenCredential("sensitive-token", int(time.time()))

        with self.assertRaises(FoundryChatError) as captured:
            credential.get_token(FOUNDRY_SCOPE)

        self.assertEqual(captured.exception.code, "user_token_expired")

    def test_agent_invocation_chains_previous_response(self) -> None:
        response = SimpleNamespace(id="resp_next", output_text="回答", output=[])
        openai_client = FakeOpenAIClient(response=response)

        def factory(*, endpoint, credential):
            return FakeProjectClient(
                endpoint=endpoint,
                credential=credential,
                openai_client=openai_client,
            )

        result = invoke_agent(
            settings=SETTINGS,
            access_token="sensitive-token",
            expires_on=int(time.time()) + 600,
            message="続けてください",
            previous_response_id="resp_previous",
            project_client_factory=factory,
        )

        self.assertEqual(result["message"], "回答")
        self.assertEqual(
            openai_client.requests,
            [
                {
                    "input": "続けてください",
                    "extra_body": {
                        "agent_reference": {
                            "name": "profile-agent",
                            "type": "agent_reference",
                        }
                    },
                    "previous_response_id": "resp_previous",
                }
            ],
        )
        self.assertNotIn("sensitive-token", str(result))

    def test_oauth_consent_request_is_allowlisted(self) -> None:
        response = SimpleNamespace(
            id="resp_consent",
            output_text="",
            output=[
                {
                    "type": "oauth_consent_request",
                    "consent_link": "https://region.consent.azure-apihub.net/login?data=redacted",
                    "raw_secret": "must-not-return",
                }
            ],
        )

        result = normalize_foundry_response(response, SETTINGS)

        self.assertEqual(result["status"], "consent_required")
        self.assertEqual(result["action"]["purpose"], "foundry_oauth_consent")
        self.assertNotIn("raw_secret", str(result))
        self.assertNotIn("must-not-return", str(result))

    def test_regional_azure_apim_consent_host_is_allowlisted(self) -> None:
        response = SimpleNamespace(
            id="resp_consent",
            output_text="",
            output=[
                {
                    "type": "oauth_consent_request",
                    "consent_link": (
                        "https://region.consent.azure-apim.net/"
                        "login?data=redacted"
                    ),
                }
            ],
        )

        result = normalize_foundry_response(response, SETTINGS)

        self.assertEqual(result["status"], "consent_required")
        self.assertEqual(result["action"]["purpose"], "foundry_oauth_consent")

    def test_oauth_consent_url_with_userinfo_is_rejected(self) -> None:
        response = SimpleNamespace(
            id="resp_consent",
            output_text="",
            output=[
                {
                    "type": "oauth_consent_request",
                    "consent_link": (
                        "https://u:@example.consent.azure-apim.net/login"
                    ),
                }
            ],
        )

        with self.assertRaises(FoundryChatError) as captured:
            normalize_foundry_response(response, SETTINGS)

        self.assertEqual(captured.exception.code, "invalid_consent_url")

    def test_oauth_consent_url_with_non_default_port_is_rejected(self) -> None:
        response = SimpleNamespace(
            id="resp_consent",
            output_text="",
            output=[
                {
                    "type": "oauth_consent_request",
                    "consent_link": (
                        "https://example.consent.azure-apim.net:8443/login"
                    ),
                }
            ],
        )

        with self.assertRaises(FoundryChatError) as captured:
            normalize_foundry_response(response, SETTINGS)

        self.assertEqual(captured.exception.code, "invalid_consent_url")

    def test_untrusted_oauth_consent_host_is_rejected(self) -> None:
        response = SimpleNamespace(
            id="resp_consent",
            output_text="",
            output=[
                {
                    "type": "oauth_consent_request",
                    "consent_link": (
                        "https://example.consent.azure-apim.net.attacker.test/consent"
                    ),
                }
            ],
        )

        with self.assertRaises(FoundryChatError) as captured:
            normalize_foundry_response(response, SETTINGS)

        self.assertEqual(captured.exception.code, "invalid_consent_url")

    def test_only_known_graph_consent_url_becomes_action(self) -> None:
        response = SimpleNamespace(
            id="resp_graph",
            output_text=(
                "許可後に再試行してください。 "
                "https://profile-function.example/api/consent "
                "https://untrusted.example/"
            ),
            output=[],
        )

        result = normalize_foundry_response(response, SETTINGS)

        self.assertEqual(result["action"]["purpose"], "graph_consent")
        self.assertEqual(result["action"]["url"], SETTINGS.graph_consent_url)

    def test_service_errors_are_mapped_without_upstream_body(self) -> None:
        error = RuntimeError("upstream body with sensitive content")
        error.status_code = 429

        classified = classify_foundry_error(error)

        self.assertEqual(classified.code, "foundry_throttled")
        self.assertNotIn("sensitive content", str(classified))

    def test_mcp_tool_auth_error_prompts_safe_retry(self) -> None:
        error = RuntimeError("upstream body with expired token details")
        error.status_code = 400
        error.code = "tool_user_error"

        classified = classify_foundry_error(error)

        self.assertEqual(classified.code, "foundry_mcp_connection_failed")
        self.assertEqual(classified.status_code, 409)
        self.assertIn("Retry the request", str(classified))
        self.assertNotIn("expired token details", str(classified))


if __name__ == "__main__":
    unittest.main()