import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import dependencies


class DependencyTests(unittest.TestCase):
    def test_platform_names(self):
        self.assertEqual(dependencies.node_archive("Darwin", "arm64"), "node-v24.21.0-darwin-arm64")
        self.assertEqual(dependencies.node_archive("Darwin", "x86_64"), "node-v24.21.0-darwin-x64")
        self.assertEqual(dependencies.node_archive("Linux", "x86_64"), "node-v24.21.0-linux-x64")
        self.assertEqual(dependencies.node_archive("Linux", "aarch64"), "node-v24.21.0-linux-arm64")
        with self.assertRaises(ValueError):
            dependencies.node_archive("Windows", "x86_64")
        self.assertEqual(len(dependencies.NODE_DIGESTS), 4)
        self.assertTrue(all(len(digest) == 64 for digest in dependencies.NODE_DIGESTS.values()))

    def archive(self, name, link=None):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            entry = tarfile.TarInfo(name)
            if link is not None:
                entry.type = tarfile.SYMTYPE
                entry.linkname = link
            else:
                entry.size = 1
            archive.addfile(entry, None if link is not None else io.BytesIO(b"x"))
        stream.seek(0)
        return tarfile.open(fileobj=stream, mode="r:gz")

    def test_archive_rejects_traversal(self):
        for name in ("../outside", "/root/outside", "node/../../outside", "another/file"):
            with self.subTest(name=name), self.archive(name) as archive:
                with self.assertRaises(ValueError):
                    dependencies._safe_archive(archive, "node")

    def test_archive_rejects_escaping_symlinks(self):
        for link in ("/etc/passwd", "../../../outside"):
            with self.subTest(link=link), self.archive("node/bin/npm", link) as archive:
                with self.assertRaises(ValueError):
                    dependencies._safe_archive(archive, "node")

    def test_archive_allows_node_internal_symlinks(self):
        with self.archive("node/bin/npm", "../lib/node_modules/npm/bin/npm-cli.js") as archive:
            self.assertEqual(len(dependencies._safe_archive(archive, "node")), 1)

    def test_existing_incomplete_runtime_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            node = root / dependencies.node_archive()
            node.mkdir()
            marker = node / "keep"
            marker.write_text("keep")
            with self.assertRaises(ValueError):
                dependencies.install_node(root)
            self.assertEqual(marker.read_text(), "keep")

    def test_rejects_relative_dependency_directory(self):
        with self.assertRaises(ValueError):
            dependencies.install_node("relative-directory")


if __name__ == "__main__":
    unittest.main()
