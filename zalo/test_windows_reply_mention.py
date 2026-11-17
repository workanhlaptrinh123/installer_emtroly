import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("install-windows-reply-mention.py")
SPEC = importlib.util.spec_from_file_location("mention_installer", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MentionPatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mention-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.setup = self.root / "setup"
        self.setup.mkdir()
        self.names = ("monitor.mjs", "send.mjs", "low.mjs", "channel.mjs")
        self.original = "const before = true;\nconst untouched = 1;\n"
        self.expected = {}
        patches = []
        for name in self.names:
            (self.setup / name).write_text(self.original, encoding="utf-8")
            self.expected[name] = hashlib.sha256(self.original.encode()).hexdigest()
            patches.append(f"--- a/{name}\n+++ b/{name}\n@@ -1,2 +1,2 @@\n-const before = true;\n+const after = true;\n const untouched = 1;\n")
        self.patch = self.root / "reviewed.patch"
        self.patch.write_text("".join(patches), encoding="utf-8")

    def test_prepares_reviewed_files_without_modifying_originals(self):
        with patch.object(MODULE, "EXPECTED", self.expected):
            output = MODULE.prepare(self.setup, self.patch)
        self.assertEqual(set(output), set(self.names))
        self.assertTrue(all("const after = true;" in value for value in output.values()))
        self.assertEqual((self.setup / self.names[0]).read_text(), self.original)

    def test_changed_or_guarded_bundle_is_rejected_before_writes(self):
        target = self.setup / self.names[1]
        target.write_text(self.original + "zalo-text-delivery-guard/guard.mjs\n")
        with patch.object(MODULE, "EXPECTED", self.expected), self.assertRaisesRegex(ValueError, "differs"):
            MODULE.prepare(self.setup, self.patch)
        self.assertEqual((self.setup / self.names[0]).read_text(), self.original)

    def test_unreviewed_patch_context_and_incomplete_files_are_rejected(self):
        source = {name: self.original for name in self.names}
        bad_context = self.patch.read_text().replace("-const before", "-const different", 1)
        with self.assertRaisesRegex(ValueError, "context differs"):
            MODULE.apply_diff(source, bad_context)
        with self.assertRaisesRegex(ValueError, "file set differs"):
            MODULE.apply_diff(source, bad_context.split("--- a/send.mjs")[0].replace("-const different", "-const before"))


if __name__ == "__main__":
    unittest.main()
