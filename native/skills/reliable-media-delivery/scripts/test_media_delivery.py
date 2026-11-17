import hashlib
from pathlib import Path
import tempfile
import unittest
import zipfile

from media_delivery import END, START, persist_policy, prepare_file


class MediaDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / 'instance'
        self.workspace = self.state / 'workspace'
        self.workspace.mkdir(parents=True)

    def artifact(self, name='Hồ sơ thanh toán.docx'):
        target = self.workspace / 'output' / name
        target.parent.mkdir(exist_ok=True)
        with zipfile.ZipFile(target, 'w') as archive:
            archive.writestr('[Content_Types].xml', '<Types/>')
            archive.writestr('word/document.xml', '<document/>')
        return target

    def test_stages_unicode_docx_without_sending(self):
        source = self.artifact()
        result = prepare_file(source, self.workspace, self.state)
        staged = Path(result['media'])
        self.assertEqual(result['status'], 'staged_not_sent')
        self.assertTrue(staged.is_relative_to(self.state / 'media/outbound'))
        self.assertEqual(staged.read_bytes(), source.read_bytes())
        self.assertEqual(result['sha256'], hashlib.sha256(source.read_bytes()).hexdigest())
        self.assertEqual(result['filename'], source.name)

    def test_rejects_cross_instance(self):
        other = self.root / 'other.txt'
        other.write_text('fixture')
        with self.assertRaises(ValueError):
            prepare_file(other, self.workspace, self.state)

    def test_rejects_empty_and_oversized(self):
        empty = self.workspace / 'empty.txt'
        empty.touch()
        with self.assertRaises(ValueError):
            prepare_file(empty, self.workspace, self.state)
        with self.assertRaises(ValueError):
            prepare_file(self.artifact(), self.workspace, self.state, max_bytes=1)

    def test_rejects_invalid_docx(self):
        target = self.workspace / 'invalid.docx'
        with zipfile.ZipFile(target, 'w') as archive:
            archive.writestr('wrong.xml', '<data/>')
        with self.assertRaises(ValueError):
            prepare_file(target, self.workspace, self.state)

    def test_policy_preserves_existing_and_is_idempotent(self):
        agents = self.workspace / 'AGENTS.md'
        agents.write_text('# Customer instructions\n')
        persist_policy(self.workspace, self.state)
        original = agents.read_text()
        persist_policy(self.workspace, self.state)
        self.assertEqual(original, agents.read_text())
        self.assertTrue(original.startswith('# Customer instructions'))
        self.assertEqual(original.count(START), 1)
        self.assertEqual(original.count(END), 1)

    def test_rejects_ambiguous_policy(self):
        (self.workspace / 'AGENTS.md').write_text(START)
        with self.assertRaises(ValueError):
            persist_policy(self.workspace, self.state)

    @unittest.skipUnless(hasattr(Path, 'symlink_to'), 'symlinks unavailable')
    def test_rejects_symlink_escape(self):
        outside = self.root / 'outside'
        outside.mkdir()
        file = outside / 'secret.txt'
        file.write_text('fixture')
        try:
            (self.workspace / 'link').symlink_to(outside, target_is_directory=True)
        except OSError:
            self.skipTest('symlink creation not permitted')
        with self.assertRaises(ValueError):
            prepare_file(self.workspace / 'link/secret.txt', self.workspace, self.state)


if __name__ == '__main__':
    unittest.main()
