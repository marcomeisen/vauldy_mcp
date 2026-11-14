#!/usr/bin/env python3
"""Frozen numeric PDFs: v16 worker -> two fresh new reads -> persisted evidence -> MCP.

Uses only the bundled synthetic PDFs, checked against their frozen hashes.
"""
import argparse
import hashlib
import json
import re
from collections import Counter
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
    corpus = json.loads((fixtures / 'ocr-numeric-recovery-corpus.json').read_text())
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
            assert any('1,500,00€' in d['ocrText'] for d in before.values())
            assert any('1.635.3' in d['ocrText'] for d in before.values())
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
                    normalized = ' '.join(after['ocrText'].split())
                    expected_cells = Counter(' '.join(c['text'].split()) for p in case['pages'] for t in p['tables'] for c in t['cells'] if c['text'])
                    for cell, count in expected_cells.items():
                        assert len(re.findall(r'(?<!\w)' + re.escape(cell) + r'(?!\w)', normalized)) >= count, (case['id'], cell)
                    assert not (Counter(before[identifier]['ocrText'].splitlines()) - Counter(after['ocrText'].splitlines()) - Counter(history))
                    assert file.read_bytes() == original and profile.read_bytes() == profile_bytes
            persisted = documents(); stop_worker(args.local, store)
            assert documents() == persisted
            client = Client(args.server, profile)
            listed = payload(client.call('list_documents', includeExcerpts=False))
            assert listed['totalCount'] == len(corpus['cases'])
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
                assert 'priorReadings' not in wire and '1.635.3' not in wire and '1,500,00€' not in wire
                assert str(root) not in wire and all(identifier not in wire for identifier in before)
            assert any('1.635,3' in t and '86,240 m³' in t and '31,720 m³' in t for t in texts)
            assert any('1.500,00 €' in t for t in texts)
            assert any('10³/µl' in t and 'mg/l' in t for t in texts)
            grant['enabled'] = False; grant['revision'] = str(uuid.uuid4()); profile.write_text(json.dumps(grant))
            assert client.call('read_document', document=listed['items'][0]['document'])['isError']
            print(json.dumps(dict(passed=True, frozenPDFs=len(corpus['cases']), pages=sum(len(c['pages']) for c in corpus['cases']), freshRetriesPerPDF=2,
                previousAndNewRepairsPreserved=True, priorCorrectFieldsPreserved=True, priorReadingsPersisted=True,
                originalIdentityAndGrantPreserved=True, sanitizedMCP=True, revocation=True)))
        finally:
            if client: client.close()
            if (store / 'store.json').exists(): stop_worker(args.local, store)


if __name__ == '__main__': main()
