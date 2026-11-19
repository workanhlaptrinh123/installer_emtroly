import unittest
from unittest.mock import patch

import frozen_systemd_integration


class SystemdIntegrationSafetyTests(unittest.TestCase):
    def test_refuses_to_run_outside_disposable_github_runner(self):
        with patch.dict("os.environ", {"GITHUB_ACTIONS": "false"}), \
                patch.object(frozen_systemd_integration.tempfile, "TemporaryDirectory") as temporary:
            with self.assertRaisesRegex(RuntimeError, "disposable Linux GitHub runner"):
                frozen_systemd_integration.main()
            temporary.assert_not_called()


if __name__ == "__main__":
    unittest.main()
