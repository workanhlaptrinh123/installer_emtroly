import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("ubuntu_deb", Path(__file__).with_name("build-ubuntu-deb.py"))
ubuntu_deb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ubuntu_deb)


@unittest.skipUnless(shutil.which("dpkg-deb"), "dpkg-deb is required")
class UbuntuDebTests(unittest.TestCase):
    def test_package_contains_desktop_launcher_and_no_maintainer_scripts(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            executable = directory / "source"
            executable.write_bytes(b"fake-binary")
            package = directory / "preview.deb"
            ubuntu_deb.build(executable, package, "0.20261119~preview1", "amd64", "2.35")
            output = subprocess.check_output(["dpkg-deb", "--contents", str(package)], text=True)
            self.assertIn("usr/lib/installer-emtroly/caidattroly", output)
            self.assertIn("usr/share/applications/installer-emtroly-preview.desktop", output)
            self.assertNotIn("/home/", output)
            control = directory / "control"
            subprocess.run(["dpkg-deb", "--control", str(package), str(control)], check=True)
            self.assertEqual({item.name for item in control.iterdir()}, {"control"})
            metadata = (control / "control").read_text()
            self.assertIn("libc6 (>= 2.35)", metadata)
            self.assertIn("libsqlite3-0", metadata)
            self.assertIn("ca-certificates", metadata)
            self.assertTrue(package.with_suffix(".deb.sha256").is_file())
            with self.assertRaises(ValueError):
                ubuntu_deb.build(executable, package, "0.20261119~preview1", "amd64", "2.35")

    def test_invalid_version_and_architecture_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "source"
            executable.touch()
            with self.assertRaises(ValueError):
                ubuntu_deb.build(executable, Path(temporary) / "out.deb", "1\nInjected: yes", "amd64", "2.35")
            with self.assertRaises(ValueError):
                ubuntu_deb.build(executable, Path(temporary) / "out.deb", "1", "all", "2.35")
            with self.assertRaises(ValueError):
                ubuntu_deb.build(executable, Path(temporary) / "out.deb", "1", "amd64", "2.34")


if __name__ == "__main__":
    unittest.main()
