#!/usr/bin/env python3
"""Import synthetic difficult rasters through the real worker and verify stored/MCP text."""
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
    parser.add_argument('fixtures', type=lambda value: Path(value).resolve(), help='Synthetic PDFs from OCRTargetedRetryTests only')
    args = parser.parse_args()
    expected = {
        'raster-pdf': ['Vertragsnummer: ZO-481017', 'Beitrag: 49,99 EUR', 'Beginn: 27.01.2026', 'Versicherungsart: Hausrat'],
        'raster-other-values': ['Vertragsnummer: VX-739245', 'Beitrag: 82,47 EUR', 'Beginn: 19.08.2027', 'Versicherungsart: Hausrat'],
        'raster-light': ['Vertragsnummer: ZO-481017', 'Beitrag: 49,99 EUR', 'Beginn: 27.01.2026', 'Versicherungsart: Hausrat'],
    }
    with tempfile.TemporaryDirectory(prefix='vauldy-raster-quality-wire-') as temporary:
        root = Path(temporary)
        store, profile = root / 'vault', root / 'profile.json'
        client = None
        imported = []
        try:
            for name, fields in expected.items():
                file = args.fixtures / (name + '.pdf')
                original = hashlib.sha256(file.read_bytes()).hexdigest()
                outcome, = command(args.local_binary, 'import', '--store', store, file, accepted=(0, 2))
                assert outcome['state'] in ('completed', 'partial')
                document, = [item for item in json.loads((store / 'documents.json').read_text())
                             if item['id'].lower() == outcome['documentID'].lower()]
                normalized = ' '.join(document['ocrText'].split())
                assert all(field in normalized for field in fields), name
                assert document['localImport']['pages'][0]['metrics']['pdfScaleRetries'] == 1
                assert hashlib.sha256(file.read_bytes()).hexdigest() == original
                imported.append(dict(name=name, id=document['id'], state=outcome['state'],
                                     review=document['localImport']['pages'][0]['needsReview']))
            selected = imported[0]['id']
            grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                         connectionName='Synthetic raster quality', enabled=True, vaultPath=str(store / 'documents.json'),
                         allowedDocumentIDs=[selected], acknowledgedCloudDisclosure=True)
            profile.write_text(json.dumps(grant))
            original_profile = profile.read_bytes()
            before = (store / 'documents.json').read_bytes()
            client = Client(args.mcp_binary, profile)
            listed = payload(client.call('list_documents', query='Hausrat', includeExcerpts=False))
            assert listed['totalCount'] == 1
            handle = listed['items'][0]['document']
            read = payload(client.call('read_document', document=handle))
            assert read['sourceCoverage'] == 'all-declared-pages-processed'
            wire = json.dumps(read, ensure_ascii=False)
            assert '49,99 EUR' in wire and '27.01.2026' in wire and 'Hausrat' in wire
            assert '43,99' not in wire and '27.01.2009' not in wire
            assert 'ZO-481017' not in wire and selected not in wire and str(root) not in wire
            assert all(segment['page'] == 1 and segment['source'] == f'[Quelle:{handle}:S.1]'
                       for segment in read['segments'])
            assert (store / 'documents.json').read_bytes() == before
            for fresh in [False, True]:
                command(args.local_binary, 'retry', '--store', store, '--document', selected,
                        *(['--fresh'] if fresh else []))
                current, = [item for item in json.loads((store / 'documents.json').read_text()) if item['id'] == selected]
                assert current['localImport']['pages'][0]['metrics']['cacheHit'] == (not fresh)
                assert all(field in ' '.join(current['ocrText'].split()) for field in expected['raster-pdf'])
                assert profile.read_bytes() == original_profile
            grant['enabled'] = False
            grant['revision'] = str(uuid.uuid4())
            profile.write_text(json.dumps(grant))
            assert client.call('read_document', document=handle)['isError']
            print(json.dumps(dict(passed=True, syntheticPDFs=3, exactStoredFields=12,
                                  cases=[{k: v for k, v in item.items() if k != 'id'} for item in imported],
                                  grants=True, privacy=True, physicalPage=1, cacheAndFreshRetry=True, revocation=True)))
        finally:
            if client:
                client.close()
            if (store / 'store.json').exists():
                stop_worker(args.local_binary, store)


if __name__ == '__main__':
    main()
