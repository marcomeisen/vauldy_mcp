#!/usr/bin/env python3
"""Test packaged client registration with isolated homes and synthetic grants; no cloud."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import uuid

from smoke_test import Client, payload


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local_cli', type=Path)
    args = parser.parse_args()
    executable = args.local_cli.resolve()
    binary = executable.with_name('vauldy-mcp')
    assert binary.is_file()
    with tempfile.TemporaryDirectory(prefix='vauldy-client-wire-') as directory:
        root = Path(directory)
        doc_id = str(uuid.uuid4())
        vault = root / 'documents.json'
        vault.write_text(json.dumps([dict(id=doc_id, title='Fahrradwartung', status='indexed', pageCount=1,
                                             ocrText='--- Seite 1 ---\nFahrradwartung 49,99 EUR.')]))
        home = root / 'Client home with spaces'
        for target in ['chatgpt', 'claude']:
            profile = root / f'{target}-profile.json'
            profile.write_text(json.dumps(dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                connectionName=target, enabled=True, vaultPath=str(vault), allowedDocumentIDs=[doc_id], acknowledgedCloudDisclosure=True)))
            grant = profile.read_bytes()
            config = home / ('.codex/config.toml' if target == 'chatgpt' else 'Library/Application Support/Claude/claude_desktop_config.json')
            config.parent.mkdir(parents=True, exist_ok=True)
            original = '# Keep this comment\n[mcp_servers.other]\ncommand = "/unchanged"\n' if target == 'chatgpt' else '{"preferences":{"theme":"dark"},"mcpServers":{"other":{"command":"/unchanged"}}}'
            config.write_text(original)
            command = [str(executable), 'connect', '--client', target, '--profile', str(profile), '--client-home', str(home)]
            subprocess.run(command, check=True, timeout=40, capture_output=True)
            fresh_home = root / f'fresh-{target}'
            subprocess.run(command[:-1] + [str(fresh_home)], check=True, timeout=40, capture_output=True)
            assert (fresh_home / config.relative_to(home)).is_file()
            saved = config.read_bytes()
            subprocess.run(command, check=True, timeout=40, capture_output=True)
            assert config.read_bytes() == saved and profile.read_bytes() == grant
            if target == 'chatgpt':
                assert saved.startswith(original.encode())
                entry = tomllib.loads(saved.decode())['mcp_servers']['vauldy']
            else:
                decoded = json.loads(saved)
                assert decoded['preferences'] == {'theme': 'dark'}
                assert decoded['mcpServers']['other'] == {'command': '/unchanged'}
                entry = decoded['mcpServers']['vauldy']
            assert Path(entry['command']).resolve() == binary.resolve()
            assert entry['args'][0] == '--profile'
            assert Path(entry['args'][1]).resolve() == profile.resolve()
            assert os.stat(config).st_mode & 0o777 == 0o600
            client = Client(entry['command'], entry['args'][1])
            try:
                assert payload(client.call('get_vault_status'))['grantedDocumentCount'] == 1
                result = payload(client.call('search_documents', query='Fahrradwartung'))
                assert len(result['hits']) == 1
            finally:
                client.close()
            print(f'PASS {target}: packaged connect, preservation, idempotence and real MCP start/search.')


if __name__ == '__main__':
    main()
