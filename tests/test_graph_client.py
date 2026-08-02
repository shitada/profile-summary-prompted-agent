import unittest

from src.function.graph_client import (
    GraphServiceError,
    OboFlowError,
    classify_obo_failure,
    get_profile_response,
)
from src.function.profile_tool import AuthContextError


class GraphClientTests(unittest.IsolatedAsyncioTestCase):
    async def test_success_does_not_return_access_token(self) -> None:
        observed_tokens: list[str] = []

        async def provide_token(_):
            return "sensitive-token"

        async def fetch_profile(token: str):
            observed_tokens.append(token)
            return {
                "displayName": "Sample User",
                "department": "Sample Department",
                "id": "not-returned",
            }

        response = await get_profile_response(
            {},
            token_provider=provide_token,
            profile_fetcher=fetch_profile,
        )

        self.assertEqual(observed_tokens, ["sensitive-token"])
        self.assertEqual(response["status"], "ok")
        self.assertNotIn("sensitive-token", str(response))

    async def test_success_emits_safe_start_and_completion_events(self) -> None:
        events = []

        async def token_provider(_context):
            return "sensitive-token"

        async def profile_fetcher(_access_token):
            return {"displayName": "Sample User"}

        response = await get_profile_response(
            {},
            token_provider=token_provider,
            profile_fetcher=profile_fetcher,
            auth_event_sink=lambda event, **fields: events.append(
                {"event": event, **fields}
            ),
        )

        self.assertEqual(response["status"], "ok")
        self.assertEqual(
            [event["event"] for event in events],
            ["function_mcp_started", "function_graph_completed"],
        )
        serialized = str(events)
        self.assertNotIn("sensitive-token", serialized)
        self.assertNotIn("Sample User", serialized)

    async def test_consent_failure_returns_only_safe_action(self) -> None:
        async def require_consent(_):
            raise OboFlowError("graph_consent_required")

        async def unused_fetcher(_):
            self.fail("profile fetcher must not be called")

        response = await get_profile_response(
            {},
            token_provider=require_consent,
            profile_fetcher=unused_fetcher,
            consent_url_builder=lambda: "https://example.test/.auth/login/aad",
        )

        self.assertEqual(response["status"], "error")
        self.assertEqual(response["error"]["code"], "graph_consent_required")
        self.assertEqual(
            response["error"]["action"]["url"],
            "https://example.test/.auth/login/aad",
        )

    async def test_auth_context_error_keeps_stable_code(self) -> None:
        async def reject_context(_):
            raise AuthContextError("missing_user_token", "sensitive detail")

        async def unused_fetcher(_):
            self.fail("profile fetcher must not be called")

        response = await get_profile_response(
            {},
            token_provider=reject_context,
            profile_fetcher=unused_fetcher,
        )

        self.assertEqual(response["error"]["code"], "missing_user_token")
        self.assertNotIn("sensitive detail", str(response))

    async def test_graph_error_does_not_return_upstream_body(self) -> None:
        async def provide_token(_):
            return "token"

        async def fail_graph(_):
            raise GraphServiceError("graph_access_denied")

        response = await get_profile_response(
            {},
            token_provider=provide_token,
            profile_fetcher=fail_graph,
        )

        self.assertEqual(response["error"]["code"], "graph_access_denied")

    def test_obo_error_classification(self) -> None:
        cases = {
            "AADSTS65001: user has not consented": "graph_consent_required",
            "interaction_required due to claims challenge": "conditional_access_required",
            "AADSTS50079: MFA registration required": "conditional_access_required",
            "connection failed": "graph_token_exchange_failed",
        }

        for message, expected in cases.items():
            with self.subTest(message=message):
                self.assertEqual(classify_obo_failure(RuntimeError(message)), expected)


if __name__ == "__main__":
    unittest.main()