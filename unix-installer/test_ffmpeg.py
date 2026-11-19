from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import ffmpeg


class FfmpegTests(unittest.TestCase):
    def test_unknown_platform_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(ffmpeg.shutil, "which", return_value=None), \
                patch.object(ffmpeg.platform, "system", return_value="Other"), self.assertRaises(ValueError):
            ffmpeg.install(Path(temporary))

    def test_symlinked_cache_is_not_used(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(ffmpeg.shutil, "which", return_value=None), \
                patch.object(ffmpeg.platform, "system", return_value="Linux"), \
                patch.object(ffmpeg.platform, "machine", return_value="x86_64"):
            root = Path(temporary).resolve()
            target = root / "ffmpeg-imageio-0.6.0-linux-x64"
            target.symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError):
                ffmpeg.install(root)

    def test_binary_checksum_failure_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "ffmpeg"
            executable.write_text("not ffmpeg")
            executable.chmod(0o700)
            with self.assertRaises(ValueError):
                ffmpeg._verify(executable, "0" * 64)


if __name__ == "__main__":
    unittest.main()
