#!/usr/bin/env python3
"""Frozen PDFs: old worker -> two fresh new reads -> persisted evidence -> MCP.

Uses only the three bundled synthetic PDFs, checked against their frozen hashes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import uuid

from import_smoke_test import command, stop_worker
from smoke_test import Client, payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['baseline_local', 'local', 'server']:
        parser.add_argument(name, type=lambda v: Path(v).resolve())
    args = parser.parse_args()
    fixtures = Path(__file__).resolve().parents[2] / 'Tests/VauldyMCPRuntimeTests/Fixtures'
    corpus = json.loads((fixtures / 'ocr-field-recovery-corpus.json').read_text())
    with tempfile.TemporaryDirectory(prefix='vauldy-field-recovery-wire-') as temporary:
        root = Path(temporary); store = root / 'vault'; profile = root / 'profile.json'; client = None
        try:
            originals = {}
            for case in corpus['cases']:
                file = fixtures / case['file']; original = file.read_bytes()
                assert hashlib.sha256(original).hexdigest() == case['sha256']
                outcome, = command(args.baseline_local, 'import', '--store', store, file, accepted=(0, 2))
                originals[outcome['documentID']] = (case, file, original)
            def documents():
                return {d['id']: d for d in json.loads((store / 'documents.json').read_text())}
            before = documents()
            assert any('TESTWWZZZ26K08417' in d['ocrText'] for d in before.values())
            assert any('10/u1' in d['ocrText'] for d in before.values())
            stop_worker(args.baseline_local, store)
            grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                         connectionName='Synthetic field recovery', enabled=True,
                         vaultPath=str(store / 'documents.json'), allowedDocumentIDs=list(before),
                         acknowledgedCloudDisclosure=True)
            profile.write_text(json.dumps(grant)); profile_bytes = profile.read_bytes()
            for _ in range(2):
                for identifier, (case, file, original) in originals.items():
                    command(args.local, 'retry', '--store', store, '--document', identifier, '--fresh', accepted=(0, 2))
                    after = documents()[identifier]
                    assert after['localImport']['contentHash'] == before[identifier]['localImport']['contentHash']
                    assert all(not p['metrics']['cacheHit'] for p in after['localImport']['pages'])
                    for page in case['pages']:
                        for field in page['fields']:
                            if field['text'] in before[identifier]['ocrText']:
                                assert field['text'] in after['ocrText'], field
                    history = [s for p in after['localImport']['pages']
                               for line in p['layout']['geometry']['lines'] for s in line.get('priorReadings', [])]
                    if case['id'] == 'doc-001':
                        assert 'Fahrgestellnummer: TESTWVWZZZ26K08417' in after['ocrText']
                        assert 'Fahrgestellnummer: TESTWWZZZ26K08417' in history
                    elif case['id'] == 'doc-004':
                        for row in ['Wohnung 3 beide Schließzylinder', 'Keller 1 gekennzeichnet', 'Briefkasten 0 Nachlieferung vereinbart']:
                            assert row in after['ocrText'], row
                    else:
                        for unit in ['g/dl', '10³/µl', 'mg/l']:
                            assert unit in after['ocrText'].splitlines(), unit
                        assert all(unit in history for unit in ['g/dI', '10/u1', 'mg/1'])
                        assert after['ocrText'].splitlines().count('mg/dl') == 2
                    assert file.read_bytes() == original and profile.read_bytes() == profile_bytes
            persisted = documents(); stop_worker(args.local, store)
            assert documents() == persisted
            client = Client(args.server, profile)
            listed = payload(client.call('list_documents', includeExcerpts=False))
            assert listed['totalCount'] == 3
            texts = []
            for item in listed['items']:
                read = payload(client.call('read_document', document=item['document']))
                # Repairs deliberately remain reviewable; coverage must not
                # advertise an unqualified completeness guarantee over MCP.
                assert read['sourceCoverage'] == 'incomplete-or-unknown'
                assert any(page['needsReview'] for page in read['pageStatus'])
                assert read['availablePages'] == list(range(1, read['expectedPageCount'] + 1))
                assert read['containsEntireAvailableText'] and not read.get('nextCursor')
                text = '\n'.join(s['text'] for s in read['segments']); texts.append(text)
                wire = json.dumps(read)
                assert 'priorReadings' not in wire and 'TESTWWZZZ26K08417' not in wire
                assert str(root) not in wire and all(identifier not in wire for identifier in before)
            assert any('Keller 1 gekennzeichnet' in t and 'Briefkasten 0 Nachlieferung vereinbart' in t for t in texts)
            assert any('10³/µl' in t and 'mg/l' in t for t in texts)
            grant['enabled'] = False; grant['revision'] = str(uuid.uuid4()); profile.write_text(json.dumps(grant))
            assert client.call('read_document', document=listed['items'][0]['document'])['isError']
            print(json.dumps(dict(passed=True, frozenPDFs=3, pages=7, freshRetriesPerPDF=2,
                targetedCases=7, priorCorrectFieldsPreserved=True, priorReadingsPersisted=True,
                originalIdentityAndGrantPreserved=True, sanitizedMCP=True, revocation=True)))
        finally:
            if client: client.close()
            if (store / 'store.json').exists(): stop_worker(args.local, store)


if __name__ == '__main__': main()
