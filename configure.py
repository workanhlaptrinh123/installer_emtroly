import argparse
import json
import os
import pathlib
import re
import runpy
import secrets

parser = argparse.ArgumentParser()
parser.add_argument('--settings', required=True)
parser.add_argument('--root', required=True)
parser.add_argument('--workspace', default='/root/.openclaw/workspace')
parser.add_argument('--runtime-root', default='/root')
parser.add_argument('--workspace-dir')
parser.add_argument('--overwrite', action='store_true')
args = parser.parse_args()
settings = json.loads(pathlib.Path(args.settings).read_text())
root = pathlib.Path(args.root)
runtime_root = pathlib.Path(args.runtime_root) / '.openclaw'
workspace_dir = pathlib.Path(args.workspace_dir) if args.workspace_dir else root / 'workspace'
root.mkdir(parents=True, exist_ok=True)
config = root / 'openclaw.json'
if config.exists() and not args.overwrite:
    raise SystemExit('Refusing to overwrite an existing member configuration')
member = settings['member']
for key in ('telegram_token', 'api_key', 'base_url', 'model'):
    if not str(settings.get(key, '')).strip() or str(settings[key]).startswith(('ENTER_', 'REPLACE_')):
        raise SystemExit(f'Missing real customer setting: {key}')
if not re.fullmatch(r'[a-z][a-z0-9_-]{0,63}', member):
    raise SystemExit('Invalid member name')
owners = settings['owner_ids']
if not owners or any(not re.fullmatch(r'[1-9][0-9]*', str(owner)) for owner in owners):
    raise SystemExit('Explicit positive Telegram owner IDs required')
group_id = str(settings.get('group_id', '')).strip()
if not re.fullmatch(r'-[1-9][0-9]*', group_id):
    raise SystemExit('An explicit negative Telegram group ID is required for the group allowlist')
os.umask(0o077)
(root / 'telegram.token').write_text(settings['telegram_token'].strip() + '\n')
account = {
    'enabled': True, 'tokenFile': str(runtime_root / 'telegram.token'),
    'dmPolicy': 'allowlist', 'allowFrom': [str(x) for x in owners],
    'groupPolicy': 'allowlist', 'groupAllowFrom': ['*'],
}
account['groups'] = {group_id: {
    'groupPolicy': 'allowlist',
    'requireMention': False,
    'tools': {'allow': ['*']},
    'toolsBySender': {'*': {'alsoAllow': ['exec', 'process']}},
}}
document = {
    'gateway': {'mode': 'local', 'bind': 'loopback', 'auth': {'mode': 'token', 'token': secrets.token_hex(32)}},
    'secrets': {'providers': {'customer': {'source': 'file', 'path': str(runtime_root / 'member-provider.secret'), 'mode': 'singleValue'}}},
    'models': {'providers': {'customer': {
        'baseUrl': settings['base_url'], 'apiKey': {'source': 'file', 'provider': 'customer', 'id': 'value'},
        'api': settings.get('api', 'openai-completions'),
        'models': [{'id': settings['model'], 'name': settings['model']}],
    }, 'openai': {
        'baseUrl': settings['base_url'], 'apiKey': {'source': 'file', 'provider': 'customer', 'id': 'value'},
        'auth': 'api-key', 'api': 'openai-completions',
        'models': [{'id': 'cx/gpt-image-2', 'name': 'Member image API'}],
    }}},
    'agents': {'defaults': {'workspace': args.workspace, 'model': {'primary': 'customer/' + settings['model']},
                            'mediaModels': {'image': {'primary': 'openai/cx/gpt-image-2', 'timeoutMs': 240000}}},
               'entries': {'main': {'name': settings.get('assistant_name', member),
                                    'tools': {'profile': 'full', 'exec': {'host': 'gateway', 'mode': 'full', 'strictInlineEval': False},
                                              'toolsBySender': {'*': {'alsoAllow': ['exec', 'process', 'group:fs']}}}}}},
    'channels': {'telegram': {'enabled': True, 'groupPolicy': 'allowlist', 'defaultAccount': member, 'accounts': {member: account}}},
    'bindings': [{'agentId': 'main', 'match': {'channel': 'telegram', 'accountId': member}}],
    'commands': {'ownerAllowFrom': ['telegram:' + str(owner) for owner in owners]},
    'tools': {'profile': 'full', 'fs': {'workspaceOnly': False},
              'exec': {'host': 'gateway', 'mode': 'full', 'strictInlineEval': False}},
}
config.write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n')
config.chmod(0o600)
(root / 'telegram.token').chmod(0o600)
(workspace_dir).mkdir(parents=True, exist_ok=True)
media_helper = pathlib.Path(__file__).resolve().parent / 'native/skills/reliable-media-delivery/scripts/media_delivery.py'
runpy.run_path(str(media_helper))['persist_policy'](workspace_dir, root)
(root / 'member-provider.secret').write_text(settings['api_key'].strip() + '\n')
(root / 'member-provider.secret').chmod(0o600)

requested_modules = settings.get('modules', [])
if requested_modules is None:
    requested_modules = []
if not isinstance(requested_modules, list) or any(
    not isinstance(module, str) or not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,127}', module)
    for module in requested_modules
):
    raise SystemExit('modules must be a list of valid module IDs')
profile = settings.get('profile', 'basic-assistant-full')
if not isinstance(profile, str) or not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,127}', profile):
    raise SystemExit('Invalid module profile')
(root / 'modules.json').write_text(json.dumps({
    'profile': profile,
    'modules': requested_modules,
}, ensure_ascii=False, indent=2) + '\n')
(root / 'modules.json').chmod(0o600)
