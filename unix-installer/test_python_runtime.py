from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import python_runtime


class PythonRuntimeTests(unittest.TestCase):
    def test_all_platforms_have_valid_pinned_digests(self):
        self.assertEqual(len(python_runtime.ARCHIVES), 4)
        for _, digest in python_runtime.ARCHIVES.values():
            self.assertRegex(digest, r"^[a-f0-9]{64}$")

    def test_unknown_platform_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(python_runtime.shutil, "which", return_value=None), \
                patch.object(python_runtime.platform, "system", return_value="Other"), self.assertRaises(ValueError):
            python_runtime.install(Path(temporary))

    def test_existing_symlinked_directory_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(python_runtime.shutil, "which", return_value=None), \
                patch.object(python_runtime.platform, "system", return_value="Linux"), \
                patch.object(python_runtime.platform, "machine", return_value="x86_64"):
            root = Path(temporary).resolve()
            target = root / "python-3.12.16-20261110-linux-x64"
            target.symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError):
                python_runtime.install(root)


if __name__ == "__main__":
    unittest.main()
