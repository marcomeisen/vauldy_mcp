#!/usr/bin/env python3
"""Real packaged stdio diagnosis, per-profile presence and exact grant preservation; synthetic only."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
from smoke_test import Client, payload


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('resources', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='vauldy-management-wire-') as temp:
        root = Path(temp).resolve()
        # No GUI companion needed: a diagnostic must not auto-launch a menu.
        binary_dir = root/'bin'; binary_dir.mkdir()
        for name in ['vauldy-local', 'vauldy-mcp']:
            shutil.copy2(args.resources.resolve()/name, binary_dir/name)
        local, server = binary_dir/'vauldy-local', binary_dir/'vauldy-mcp'
        connection = str(uuid.uuid4()); document = str(uuid.uuid4())
        profile = root/'connections'/connection/'profile.json'; profile.parent.mkdir(parents=True)
        vault = root/'documents.json'
        vault.write_text(json.dumps([dict(id=document, title='Synthetic probe fixture', status='indexed', pageCount=1, ocrText='--- Seite 1 ---\nNur Testinhalt')]))
        grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=connection, connectionName='Synthetic local probe', desktopClient='claude', enabled=False, vaultPath=str(vault), allowedDocumentIDs=[document], acknowledgedCloudDisclosure=True)
        original = vault.read_bytes()
        for enabled in [False, True]:
            grant['enabled'] = enabled; grant['revision'] = str(uuid.uuid4())
            profile.write_text(json.dumps(grant)); before = profile.read_bytes()
            result = json.loads(subprocess.check_output([str(local), 'check-connection', '--profile', str(profile)], timeout=20))
            assert result['serverVersion'] == '0.12.1'
            assert set(result['discoveredTools']) == {'get_vault_status', 'list_documents', 'search_documents', 'read_document'}
            assert result['accessEnabled'] == enabled
            assert result['grantedDocuments'] == int(enabled)
            assert vault.read_bytes() == original and profile.read_bytes() == before
            status = json.loads(subprocess.check_output([str(local), 'mcp-status', '--root', str(root)]))
            assert status == dict(runningServerCount=0, statusMenuRunning=False), 'Diagnostic must exit and must not become host/menu activity'
            assert not list((root/'runtime-status').glob('*.json')), 'Diagnostic metadata must be removed'
            records = [json.loads(line)['record'] for line in (profile.parent/'logs/audit.jsonl').read_text().splitlines()]
            assert all(record.get('operation') in [None, 'status'] for record in records), 'Probe must not query document contents'
        # Real software-only repair: preserve paused/active grants, vault and foreign client configuration.
        client_config = root/'test-client-config.toml'; client_config.write_text('# Foreign client settings\n')
        saved_profile, saved_config = profile.read_bytes(), client_config.read_bytes()
        app = args.resources.resolve().parent.parent
        updated = json.loads(subprocess.check_output([str(args.resources.resolve()/'vauldy-local'), 'update-software', '--root', str(root), '--from-app', str(app)], timeout=30))
        assert updated == dict(updated=True, version='0.12.1', clientRestartRequired=True)
        assert profile.read_bytes() == saved_profile and vault.read_bytes() == original and client_config.read_bytes() == saved_config
        for name in ['vauldy-mcp', 'vauldy-local', 'vauldy-mcp-http']:
            assert (binary_dir/name).read_bytes() == (args.resources.resolve()/name).read_bytes()
        import plistlib
        wrong_app = root/'Wrong Version.app'; (wrong_app/'Contents').mkdir(parents=True)
        (wrong_app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='com.marcomeisen.vauldy.mcp-setup', CFBundleShortVersionString='0.1.0')))
        bad = subprocess.run([str(local), 'update-software', '--root', str(root), '--from-app', str(wrong_app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assert bad.returncode != 0 and profile.read_bytes() == saved_profile and vault.read_bytes() == original
        host = Client(server, profile)
        try:
            assert payload(host.call('get_vault_status'))['grantedDocumentCount'] == 1
            entries = [json.loads(p.read_text()) for p in (root/'runtime-status').glob('*.json')]
            assert len(entries) == 1
            entry = entries[0]
            assert entry['connectionID'].lower() == connection.lower() and entry['diagnostic'] is False
            assert entry['version'] == '0.12.1' and entry.get('lastRequestAt') is not None
            assert set(entry) <= {'connectionID', 'version', 'diagnostic', 'lastRequestAt'}
            assert document not in json.dumps(entry) and str(root) not in json.dumps(entry)
        finally:
            host.close()
        print('PASS: real local diagnosis for paused/active grants, no content query, unchanged profile/vault, no host/menu false positive, per-connection request metadata and cleanup.')


if __name__ == '__main__':
    main()
