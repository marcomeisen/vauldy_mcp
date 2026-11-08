#!/usr/bin/env python3
"""Verify marked-region recovery, retained evidence and protected MCP output with synthetic originals."""
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
    parser.add_argument('local_binary', type=lambda value: Path(value).resolve())
    parser.add_argument('mcp_binary', type=lambda value: Path(value).resolve())
    parser.add_argument('fixtures', type=lambda value: Path(value).resolve(),
                        help='Synthetic originals from OCRMarkedRegionRecoveryTests')
    args = parser.parse_args()
    cases = [
        ('recovered-0.pdf', ['Beitrag: 49,99 EUR', 'Beginn: 27.01.2026', 'Versicherungsart: Hausrat'], 'Selbstbehalt: 110,00 EUR', 'completed'),
        ('recovered-1.pdf', ['Rechnungsbetrag: 82,47 EUR', 'Zahlbar bis: 19.08.2027', 'Leistung: Wartung'], 'Selbstbehalt: 110,00 EUR', 'completed'),
        ('conflict.pdf', ['Beginn: 27.01.2026'], 'Beitrag: 49,99 EUR', 'partial'),
    ]
    with tempfile.TemporaryDirectory(prefix='vauldy-region-wire-') as temporary:
        root = Path(temporary)
        store, profile = root / 'vault', root / 'profile.json'
        client = None
        identifiers = []
        try:
            for name, fields, preserved, state in cases:
                file = args.fixtures / name
                digest = hashlib.sha256(file.read_bytes()).hexdigest()
                result, = command(args.local_binary, 'import', '--store', store, file, accepted=(0, 2))
                assert result['state'] == state, result
                document, = [item for item in json.loads((store / 'documents.json').read_text())
                             if item['id'].lower() == result['documentID'].lower()]
                assert all(field in document['ocrText'] for field in fields)
                assert document['ocrText'].count(preserved) == 1
                page, = document['localImport']['pages']
                assert page['method'] == 'embeddedTextAndVision'
                assert 0 < page['metrics']['regionRetries'] <= 4
                assert page['metrics']['regionRetryPixels'] <= 8_000_000
                layout = page['layout']
                assert layout['sourceHash'] == digest and layout['page'] == 1
                body = document['ocrText'].split('\n', 1)[1]
                assert layout['textHash'] == hashlib.sha256(body.encode()).hexdigest()
                assert layout['geometry']['coverage']['status'] == 'checked'
                if state == 'completed':
                    assert not page['needsReview'] and page['metrics']['recoveredRegionLines'] == 3
                else:
                    assert page['needsReview'] and page['metrics']['regionRecoveryConflicts'] >= 1
                    assert '82,47' not in document['ocrText']
                assert hashlib.sha256(file.read_bytes()).hexdigest() == digest
                identifiers.append(document['id'])
            grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                         connectionName='Synthetic marked region recovery', enabled=True,
                         vaultPath=str(store / 'documents.json'), allowedDocumentIDs=[identifiers[0]],
                         acknowledgedCloudDisclosure=True)
            profile.write_text(json.dumps(grant))
            profile_bytes = profile.read_bytes()
            store_bytes = (store / 'documents.json').read_bytes()
            client = Client(args.mcp_binary, profile)
            assert payload(client.call('list_documents', query='Wartung', includeExcerpts=False))['totalCount'] == 0
            listed = payload(client.call('list_documents', query='Hausrat', includeExcerpts=False))
            assert listed['totalCount'] == 1
            handle = listed['items'][0]['document']
            read = payload(client.call('read_document', document=handle))
            assert read['sourceCoverage'] == 'all-declared-pages-processed'
            assert not read['pageStatus'][0]['needsReview']
            assert read['segments'] and all(segment['page'] == 1 and
                segment['source'] == f'[Quelle:{handle}:S.1]' for segment in read['segments'])
            wire = json.dumps(read, ensure_ascii=False)
            assert all(value in wire for value in ('49,99 EUR', '110,00 EUR', '27.01.2026', 'Hausrat'))
            assert all(value not in wire for value in ('sourceHash', 'textHash', 'geometry', 'layout', str(root), *identifiers, '82,47 EUR'))
            assert (store / 'documents.json').read_bytes() == store_bytes
            # The explicit maintenance path preserves prior literal evidence and
            # leaves the real profile unchanged, through the normal import commit.
            refined = command(args.local_binary, 'refine', '--store', store, '--document', identifiers[0])
            assert refined['state'] == 'completed'
            updated, = [item for item in json.loads((store / 'documents.json').read_text()) if item['id'] == identifiers[0]]
            assert updated['ocrText'].count(cases[0][2]) == 1
            assert all(field in updated['ocrText'] for field in cases[0][1])
            assert profile.read_bytes() == profile_bytes
            for fresh in (False, True):
                command(args.local_binary, 'retry', '--store', store, '--document', identifiers[0], *(['--fresh'] if fresh else []))
                document, = [item for item in json.loads((store / 'documents.json').read_text()) if item['id'] == identifiers[0]]
                assert document['localImport']['pages'][0]['metrics']['cacheHit'] == (not fresh)
                assert document['ocrText'].count(cases[0][2]) == 1
                assert all(field in document['ocrText'] for field in cases[0][1])
                assert profile.read_bytes() == profile_bytes
            grant['allowedDocumentIDs'] = [identifiers[2]]
            grant['revision'] = str(uuid.uuid4())
            profile.write_text(json.dumps(grant))
            listed = payload(client.call('list_documents', query='Beitrag', includeExcerpts=False))
            conflict_handle = listed['items'][0]['document']
            conflict_read = payload(client.call('read_document', document=conflict_handle))
            assert conflict_read['sourceCoverage'] == 'incomplete-or-unknown' and conflict_read['pageStatus'][0]['needsReview']
            conflict_wire = json.dumps(conflict_read, ensure_ascii=False)
            assert '49,99 EUR' in conflict_wire and '82,47' not in conflict_wire
            grant['enabled'] = False
            grant['revision'] = str(uuid.uuid4())
            profile.write_text(json.dumps(grant))
            assert client.call('read_document', document=conflict_handle)['isError']
            print(json.dumps(dict(passed=True, syntheticPDFs=3, recoveredFields=6, preservedValues=3,
                                  numericConflictPreserved=True, physicalPage=1, metadataRemainsLocal=True,
                                  evidencePreservingRefinement=True, cacheAndFreshRetry=True, revocation=True)))
        finally:
            if client:
                client.close()
            if (store / 'store.json').exists():
                stop_worker(args.local_binary, store)


if __name__ == '__main__':
    main()
