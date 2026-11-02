#!/usr/bin/env python3
"""Real MCP audit diagnostics: no source content in logs, safe errors, fail-closed write failure."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import uuid
from smoke_test import Client, payload


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('local_cli', type=Path)
    args = parser.parse_args(); local = args.local_cli.resolve(); binary = local.with_name('vauldy-mcp')
    with tempfile.TemporaryDirectory(prefix='vauldy-audit-wire-') as temp:
        root = Path(temp); profile = root / 'profile.json'; vault = root / 'documents.json'; doc_id = str(uuid.uuid4())
        private = 'PRIVATE-CONTENT-CANARY alice@example.com'
        vault.write_text(json.dumps([dict(id=doc_id, title='Geheimer Titel', sourceName='private-original.pdf', status='indexed', pageCount=1,
                                         ocrText='--- Seite 1 ---\nFahrradwartung 49,99 EUR.\n' + private)]))
        profile.write_text(json.dumps(dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()), connectionName='PRIVATE CONNECTION NAME',
            enabled=True, vaultPath=str(vault), allowedDocumentIDs=[doc_id], acknowledgedCloudDisclosure=True)))
        errors = root / 'stderr.txt'
        with errors.open('wb') as stderr:
            client = Client(binary, profile, stderr=stderr)
            try:
                client.request('tools/list', {})
                hit = payload(client.call('search_documents', query='Fahrradwartung'))['hits'][0]
                payload(client.call('read_document', document=hit['document']))
                assert client.call('get_vault_status', unexpected='SECRET-ARGUMENT')['isError']
                assert client.call('SECRET-TOOL-NAME')['isError']
                payload(client.call('search_documents', query='PRIVATE-QUERY-CANARY'))
                entries = [json.loads(line)['record'] for line in (root / 'logs/audit.jsonl').read_text().splitlines()]
                assert sum(e['event'] == 'requestStarted' for e in entries) == 5
                assert sum(e['event'] == 'responsePrepared' for e in entries) == 3
                assert sum(e['event'] == 'requestFailed' for e in entries) == 2
                assert any(e.get('code') == 'invalidArguments' for e in entries)
                subprocess.run([str(local), 'logs', '--profile', str(profile), '--verify'], check=True, capture_output=True)
                combined = (root / 'logs/audit.jsonl').read_text() + errors.read_text()
                for secret in ['PRIVATE-CONTENT-CANARY', 'alice@example.com', 'Geheimer Titel', 'private-original.pdf',
                               'PRIVATE CONNECTION NAME', doc_id, str(vault), 'PRIVATE-QUERY-CANARY', 'SECRET-ARGUMENT', 'SECRET-TOOL-NAME']:
                    assert secret not in combined, 'Private value leaked into diagnostics'
                # Corruption must prevent successful content output; it must not be silently repaired.
                with (root / 'logs/audit.jsonl').open('ab') as log: log.write(b'{truncated')
                response = client.call('search_documents', query='Fahrradwartung')
                assert response['isError'] and '49,99' not in json.dumps(response)
                assert (root / 'logs/audit.jsonl').read_bytes().endswith(b'{truncated')
            finally: client.close()
        assert 'auditUnavailable' in errors.read_text()
        print('PASS: actual MCP audit events, correlation, safe stderr, no private text, verification and fail-closed damaged log.')


if __name__ == '__main__': main()
