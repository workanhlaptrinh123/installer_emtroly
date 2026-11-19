import unittest
from unittest.mock import patch

import python_exec


class PythonExecTests(unittest.TestCase):
    def test_frozen_library_path_is_restored_for_external_programs(self):
        with patch.object(python_exec.sys, "frozen", True, create=True):
            environment = {"LD_LIBRARY_PATH": "/temporary/bundle", "LD_LIBRARY_PATH_ORIG": "/user/lib"}
            self.assertEqual(python_exec.restore_library_path(environment)["LD_LIBRARY_PATH"], "/user/lib")
            environment = {"LD_LIBRARY_PATH": "/temporary/bundle"}
            self.assertNotIn("LD_LIBRARY_PATH", python_exec.restore_library_path(environment))

    def test_unfrozen_library_path_is_not_changed(self):
        with patch.object(python_exec.sys, "frozen", False, create=True):
            environment = {"LD_LIBRARY_PATH": "/user/lib"}
            self.assertEqual(python_exec.restore_library_path(environment)["LD_LIBRARY_PATH"], "/user/lib")


if __name__ == "__main__":
    unittest.main()
