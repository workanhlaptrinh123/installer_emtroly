from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "native/skills/telegram-zalo-owner-login/scripts"


class NativeOwnerCompatibilityTests(unittest.TestCase):
    def test_native_module_import_does_not_require_unix_fcntl(self):
        program = """
import builtins, importlib.util, sys
real_import = builtins.__import__
def checked_import(name, *args, **kwargs):
    if name == 'fcntl':
        raise ModuleNotFoundError('fcntl')
    return real_import(name, *args, **kwargs)
builtins.__import__ = checked_import
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location('native_adapter', sys.argv[1] + '/deploy-native.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)
assert adapter.supported_core_version('OpenClaw 2026.11.4') == '2026.11.4'
"""
        result = subprocess.run([sys.executable, "-B", "-c", program, str(SCRIPTS)],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
