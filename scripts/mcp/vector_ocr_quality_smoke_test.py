#!/usr/bin/env python3
"""Verify synthetic Type 3 text from native worker import through protected MCP output."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tempfile
import uuid

from import_smoke_test import command, stop_worker
from smoke_test import Client, payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('local_binary', type=lambda value: Path(value).resolve())
    parser.add_argument('mcp_binary', type=lambda value: Path(value).resolve())
    parser.add_argument('fixtures', type=lambda value: Path(value).resolve(),
                        help='Synthetic PDFs from PDFVectorTextOCRTests only')
    args = parser.parse_args()
    cache_source = Path(__file__).resolve().parents[2] / 'Sources/VauldyCore/LocalOCRPageCache.swift'
    configuration_prefix = re.search(r'static let configuration = "(ocr-[^"]+-)"', cache_source.read_text())[1]
    expected = [
        ['Beitrag: 49,99 EUR', 'Beginn: 27.01.2026', 'Versicherungsart: Hausrat'],
        ['Rechnungsbetrag: 82,47 EUR', 'Zahlbar bis: 19.08.2027', 'Leistung: Wartung'],
    ]
    with tempfile.TemporaryDirectory(prefix='vauldy-vector-wire-') as temporary:
        root = Path(temporary)
        store, profile = root / 'vault', root / 'profile.json'
        client = None
        imported = []
        try:
            for index, fields in enumerate(expected):
                file = args.fixtures / f'vector-{index}.pdf'
                original_hash = hashlib.sha256(file.read_bytes()).hexdigest()
                outcome, = command(args.local_binary, 'import', '--store', store, file)
                assert outcome['state'] == 'completed', outcome
                document, = [item for item in json.loads((store / 'documents.json').read_text())
                             if item['id'].lower() == outcome['documentID'].lower()]
                assert all(field in ' '.join(document['ocrText'].split()) for field in fields)
                assert document['localImport']['pages'][0]['method'] == 'vision'
                layout = document['localImport']['pages'][0]['layout']
                body = document['ocrText'].split('\n', 1)[1]
                assert layout['version'] == 1 and layout['page'] == 1 and layout['sourceHash'] == original_hash
                assert layout['textHash'] == hashlib.sha256(body.encode()).hexdigest()
                assert layout['geometry']['configuration'].startswith(configuration_prefix)
                assert layout['geometry']['coordinateSpace'] == 'pdfCropBottomLeft'
                assert len(layout['geometry']['lines']) >= 4
                assert hashlib.sha256(file.read_bytes()).hexdigest() == original_hash
                imported.append(document['id'])
            selected = imported[0]
            grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                         connectionName='Synthetic vector coverage', enabled=True,
                         vaultPath=str(store / 'documents.json'), allowedDocumentIDs=[selected],
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
            assert read['expectedPageCount'] == 1
            wire = json.dumps(read, ensure_ascii=False)
            assert all(value in wire for value in ('49,99 EUR', '27.01.2026', 'Hausrat'))
            assert all(value not in wire for value in (str(root), *imported, '82,47 EUR', '19.08.2027'))
            assert all(value not in wire for value in ('sourceHash', 'textHash', 'geometry', 'layout', 'ocr-v'))
            assert read['segments'] and all(segment['page'] == 1 and
                segment['source'] == f'[Quelle:{handle}:S.1]' for segment in read['segments'])
            assert (store / 'documents.json').read_bytes() == store_bytes
            for fresh in (False, True):
                command(args.local_binary, 'retry', '--store', store, '--document', selected,
                        *(['--fresh'] if fresh else []))
                current, = [item for item in json.loads((store / 'documents.json').read_text()) if item['id'] == selected]
                assert current['localImport']['pages'][0]['metrics']['cacheHit'] == (not fresh)
                assert all(field in ' '.join(current['ocrText'].split()) for field in expected[0])
                assert current['localImport']['pages'][0]['layout']['sourceHash'] == current['localImport']['contentHash']
                assert profile.read_bytes() == profile_bytes
            grant['enabled'] = False
            grant['revision'] = str(uuid.uuid4())
            profile.write_text(json.dumps(grant))
            assert client.call('read_document', document=handle)['isError']
            print(json.dumps(dict(passed=True, syntheticPDFs=2, exactStoredFields=6,
                                  ungrantedExcluded=True, physicalPage=1, protectedOutput=True,
                                  sourceBoundLayout=True, layoutRemainsLocal=True,
                                  cacheAndFreshRetry=True, revocation=True)))
        finally:
            if client:
                client.close()
            if (store / 'store.json').exists():
                stop_worker(args.local_binary, store)


if __name__ == '__main__':
    main()
