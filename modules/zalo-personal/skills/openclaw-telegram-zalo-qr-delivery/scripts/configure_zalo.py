import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path


def update(document, open_groups):
    channels = document.setdefault('channels', {})
    channel = channels.setdefault('zalouser', {})
    accounts = channel.setdefault('accounts', {})
    if set(accounts) - {'default'}:
        raise ValueError('Multiple Zalo accounts require manual review')
    channel['enabled'] = True
    channel['defaultAccount'] = 'default'
    account = accounts.setdefault('default', {})
    account['enabled'] = True
    account.setdefault('profile', 'default')
    for policy in (channel, account):
        policy['dmPolicy'] = 'open'
        allowed = policy.setdefault('allowFrom', [])
        if '*' not in allowed:
            allowed.append('*')

    bindings = document.setdefault('bindings', [])
    zalo_bindings = [binding for binding in bindings if binding.get('match', {}).get('channel') == 'zalouser']
    if any(binding.get('agentId') != 'main' for binding in zalo_bindings):
        raise ValueError('Existing non-main Zalo binding requires manual review')
    desired = {'agentId': 'main', 'match': {'channel': 'zalouser', 'accountId': 'default'}}
    if desired not in bindings:
        bindings.append(desired)

    if open_groups:
        for policy in (channel, account):
            policy['groupPolicy'] = 'open'
            allowed = policy.setdefault('groupAllowFrom', [])
            if '*' not in allowed:
                allowed.append('*')
            groups = policy.setdefault('groups', {})
            groups.setdefault('*', {})
            for group in groups.values():
                group.update(enabled=True, requireMention=False)
                tools = group.setdefault('tools', {})
                tools.pop('alsoAllow', None)
                tools['allow'] = ['*']
    return document


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--open-groups', type=int, choices=(0, 1), default=0)
    args = parser.parse_args()
    config = args.root / 'openclaw.json'
    original = config.read_bytes()
    document = update(json.loads(original), bool(args.open_groups))
    fd, candidate = tempfile.mkstemp(prefix='zalo-candidate-', suffix='.json', dir=args.root)
    candidate_path = Path(candidate)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            json.dump(document, output, ensure_ascii=False, indent=2)
            output.write('\n')
        env = dict(os.environ, OPENCLAW_CONFIG_PATH=str(candidate_path))
        cli_entry = env.get('OPENCLAW_CLI_ENTRY')
        command = ['node', cli_entry] if os.name == 'nt' and cli_entry else ['openclaw']
        subprocess.run(command + ['config', 'validate'], env=env, check=True)
        if config.read_bytes() != original:
            raise RuntimeError('Config changed during validation')
        os.replace(candidate_path, config)
        config.chmod(0o600)
    finally:
        candidate_path.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
