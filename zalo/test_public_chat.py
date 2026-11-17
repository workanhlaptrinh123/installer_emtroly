import copy
import importlib.util
from pathlib import Path
import runpy
import unittest


RELEASE = Path(__file__).resolve().parents[1]
CONFIGURATORS = (
    RELEASE / 'zalo/configure-zalo.py',
    RELEASE / 'native/skills/openclaw-telegram-zalo-qr-delivery/scripts/configure_zalo.py',
    RELEASE / 'modules/zalo-personal/skills/openclaw-telegram-zalo-qr-delivery/scripts/configure_zalo.py',
)


class PublicChatTests(unittest.TestCase):
    def test_windows_private_access_requires_explicit_ids(self):
        update = runpy.run_path(str(CONFIGURATORS[0]))['update']
        result = update({}, False, True)
        for policy in (result['channels']['zalouser'], result['channels']['zalouser']['accounts']['default']):
            self.assertEqual(policy['dmPolicy'], 'allowlist')
            self.assertEqual(policy['allowFrom'], [])
            self.assertEqual(policy['groupPolicy'], 'allowlist')
            self.assertEqual(policy['groupAllowFrom'], [])
        with self.assertRaises(ValueError):
            update({'channels': {'zalouser': {'dmPolicy': 'open'}}}, False, True)

    def test_local_prompt_public_zalo_and_private_telegram(self):
        source = RELEASE.parents[1] / 'installer-web/local_prompt.py'
        spec = importlib.util.spec_from_file_location('local_prompt', source)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for modules, expected in ((['zalo-personal'], 'open'), ([], 'not-selected')):
            guide = module.skill_install_guide({'name': 'fixture', 'modules': modules}, None, RELEASE, 'https://installer.example')
            self.assertEqual(guide['prompt_revision'], '20261023-telegram-group-allowlist')
            self.assertIn('"zalo_dm_policy": "' + expected + '"', guide['antigravity_prompt'])
            self.assertEqual(guide['skill_sources']['count'], 189)
            if modules:
                self.assertIn('dmPolicy=open', guide['antigravity_prompt'])
            else:
                self.assertNotIn('dmPolicy=open', guide['antigravity_prompt'])
            self.assertIn('Telegram DM allowFrom', guide['antigravity_prompt'])
            self.assertNotIn('không mở wildcard DM/pairing', guide['antigravity_prompt'])

    def fixture(self):
        return {'commands': {'ownerAllowFrom': ['telegram:123456789']},
                'tools': {'elevated': {'allowFrom': {'telegram': ['123456789']}}},
                'channels': {'telegram': {'dmPolicy': 'allowlist', 'allowFrom': ['123456789']},
                             'zalouser': {'dmPolicy': 'pairing', 'allowFrom': ['111111111'],
                                          'accounts': {'default': {'dmPolicy': 'allowlist', 'allowFrom': ['222222222']}}}},
                'bindings': [{'agentId': 'main', 'match': {'channel': 'telegram', 'accountId': 'fixture'}}]}

    def test_public_dm_account_overrides_and_preserved_owners(self):
        for source in CONFIGURATORS:
            with self.subTest(source=str(source)):
                update = runpy.run_path(str(source))['update']
                before = self.fixture()
                after = update(copy.deepcopy(before), True)
                for policy in (after['channels']['zalouser'], after['channels']['zalouser']['accounts']['default']):
                    self.assertEqual(policy['dmPolicy'], 'open')
                    self.assertIn('*', policy['allowFrom'])
                    self.assertEqual(policy['groupPolicy'], 'open')
                    self.assertFalse(policy['groups']['*']['requireMention'])
                self.assertIn('111111111', after['channels']['zalouser']['allowFrom'])
                self.assertIn('222222222', after['channels']['zalouser']['accounts']['default']['allowFrom'])
                for key in ('commands', 'tools'):
                    self.assertEqual(before[key], after[key])
                self.assertEqual(before['channels']['telegram'], after['channels']['telegram'])
                self.assertEqual(update(copy.deepcopy(after), True), after)

    def test_new_install_and_group_scope_preserved(self):
        for source in CONFIGURATORS:
            with self.subTest(source=str(source)):
                update = runpy.run_path(str(source))['update']
                after = update({}, False)
                self.assertEqual(after['channels']['zalouser']['dmPolicy'], 'open')
                self.assertEqual(after['channels']['zalouser']['accounts']['default']['allowFrom'], ['*'])
                self.assertNotIn('groupPolicy', after['channels']['zalouser'])

    def test_other_accounts_and_agent_bindings_fail_closed(self):
        for source in CONFIGURATORS:
            update = runpy.run_path(str(source))['update']
            for document in ({'channels': {'zalouser': {'accounts': {'other': {}}}}},
                             {'bindings': [{'agentId': 'other', 'match': {'channel': 'zalouser'}}]}):
                with self.subTest(source=str(source)), self.assertRaises(ValueError):
                    update(document, True)


if __name__ == '__main__':
    unittest.main()
