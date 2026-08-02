import unittest

from src.function.consent import build_graph_consent_url


class ConsentTests(unittest.TestCase):
    def test_website_hostname_builds_same_origin_consent_url(self) -> None:
        url = build_graph_consent_url({"WEBSITE_HOSTNAME": "profile.example.test"})

        self.assertEqual(
            url,
            "https://profile.example.test/.auth/login/aad?"
            "post_login_redirect_uri=%2Fapi%2Fconsent-complete",
        )

    def test_insecure_public_base_url_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            build_graph_consent_url({"PUBLIC_BASE_URL": "http://profile.example.test"})

    def test_localhost_is_supported_for_local_validation(self) -> None:
        url = build_graph_consent_url({})

        self.assertTrue(url.startswith("http://localhost:7071/.auth/login/aad?"))


if __name__ == "__main__":
    unittest.main()