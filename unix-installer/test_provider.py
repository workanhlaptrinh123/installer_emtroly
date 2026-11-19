import io
import json
import unittest
from unittest.mock import patch

import provider


class ProviderTests(unittest.TestCase):
    def test_matches_provider_case(self):
        response = io.BytesIO(json.dumps({"data": [{"id": "GPT-6.1-sol"}]}).encode())
        with patch("provider.urllib.request.build_opener") as factory:
            factory.return_value.open.return_value = response
            self.assertEqual(provider.verify("https://example.com/v1", "private", "gpt-6.1-sol"), "GPT-6.1-sol")

    def test_error_does_not_reveal_api_key(self):
        with patch("provider.urllib.request.build_opener", side_effect=RuntimeError("sensitive key")):
            with self.assertRaises(RuntimeError) as error:
                provider.verify("https://example.com/v1", "sensitive key", "gpt-6.1-sol")
        self.assertNotIn("sensitive key", str(error.exception))


if __name__ == "__main__":
    unittest.main()
