#!/usr/bin/env python3
"""R4: compare a real legacy package and current build, entirely in synthetic local roots."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
import zipfile

from smoke_test import Client, payload


def output(command):
    return json.loads(subprocess.check_output(list(map(str, command)), timeout=30))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mcp', type=lambda x: Path(x).resolve())
    parser.add_argument('local', type=lambda x: Path(x).resolve())
    parser.add_argument('--legacy-zip', required=True, type=lambda x: Path(x).resolve())
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='vauldy-r4-wire-') as temporary:
        root = Path(temporary); old_dir = root/'legacy'; old_dir.mkdir(mode=0o700)
        with zipfile.ZipFile(args.legacy_zip) as archive:
            candidates = [name for name in archive.namelist() if name.endswith('/Contents/Resources/vauldy-mcp') and not name.startswith('__MACOSX/')]
            assert len(candidates) == 1
            old_binary = old_dir/'vauldy-mcp'
            old_binary.write_bytes(archive.read(candidates[0])); old_binary.chmod(0o700)
        # New diagnostic CLI, explicitly next to the old server. No installed files touched.
        shutil.copy2(args.local, old_dir/'vauldy-local')
        vault, profile = root/'documents.json', root/'profile.json'
        document = str(uuid.uuid4())
        vault.write_text(json.dumps([dict(id=document, title='Synthetic R4', status='indexed', pageCount=1, ocrText='--- Seite 1 ---\nSynthetische Versicherung')]))
        grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()), connectionName='Synthetic R4',
                     enabled=True, acknowledgedCloudDisclosure=True, vaultPath=str(vault), allowedDocumentIDs=[document])
        profile.write_text(json.dumps(grant)); original = vault.read_bytes(), profile.read_bytes()
        info = output([args.mcp, '--build-info'])
        assert len(info['tools']) == 9 and info['documentStorage'] == 'json-or-sqlite'
        assert subprocess.check_output([args.mcp, '--version'], text=True).strip() == 'vauldy-mcp ' + info['productVersion']
        old_client, current_client = None, None
        try:
            old_client = Client(old_binary, profile)
            old_tools = [item['name'] for item in old_client.request('tools/list', {})['tools']]
            assert old_client.initialization['serverInfo']['version'] == '0.13.0'
            assert len(old_tools) == 6, f'Expected actual six-tool package, found {len(old_tools)}'
            old_probe = output([old_dir/'vauldy-local', 'check-connection', '--profile', profile])
            assert old_probe['serverVersion'] == '0.13.0' and not old_probe['compatible'] and not old_probe['buildVerified']
            assert old_probe['missingTools'] == ['compare_contract_versions', 'get_deadline_overview', 'get_document_inventory']
            current_client = Client(args.mcp, profile)
            assert current_client.initialization['serverInfo']['version'] == info['productVersion'] + '+' + info['buildID']
            actual_tools = sorted(item['name'] for item in current_client.request('tools/list', {})['tools'])
            assert actual_tools == info['tools']
            current_probe = output([args.local, 'check-connection', '--profile', profile])
            assert current_probe['compatible'] and current_probe['buildVerified']
            assert current_probe['serverBuildID'] == info['buildID'] and current_probe['missingTools'] == []
            assert current_probe['accessEnabled'] and current_probe['grantedDocuments'] == 1
            records = [json.loads(p.read_text()) for p in (root/'runtime-status').glob('*.json')]
            hosts = [record for record in records if not record['diagnostic']]
            assert len(hosts) == 2
            assert any(record.get('buildID') == info['buildID'] for record in hosts)
            assert any(record.get('buildID') is None and record['version'] == '0.13.0' for record in hosts)
            assert all(record['connectionID'].lower() == grant['connectionID'].lower() for record in hosts)
            assert (vault.read_bytes(), profile.read_bytes()) == original
            grant['enabled'] = False; grant['revision'] = str(uuid.uuid4()); profile.write_text(json.dumps(grant))
            paused = output([args.local, 'check-connection', '--profile', profile])
            assert paused['compatible'] and not paused['accessEnabled'] and paused['grantedDocuments'] == 0
            assert current_client.call('list_documents', includeExcerpts=False)['isError']
            assert old_client.call('list_documents', includeExcerpts=False)['isError']
            assert vault.read_bytes() == original[0]
            report = dict(passed=True, productVersion=info['productVersion'], currentBuild=info, actualLegacyTools=old_tools,
                          legacyProbe=old_probe, currentProbe=current_probe, pausedProbe=paused,
                          simultaneousOldAndNewProcesses=True, noDiagnosticHostConfusion=True,
                          originalAndGrantUnchangedByProbe=True, revocationBothBuilds=True,
                          mcpSHA256=hashlib.sha256(args.mcp.read_bytes()).hexdigest(),
                          legacyZIP_SHA256=hashlib.sha256(args.legacy_zip.read_bytes()).hexdigest(),
                          scope='Local synthetic stdio. No real ChatGPT connection or installed user archive used.')
            args.output.write_text(json.dumps(report, indent=2)+'\n')
            print(json.dumps(report))
        finally:
            if current_client: current_client.close()
            if old_client: old_client.close()


if __name__ == '__main__':
    main()
