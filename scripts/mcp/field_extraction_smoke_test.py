#!/usr/bin/env python3
"""Contract fields over real stdio, isolated synthetic records, optional measured comparison."""
import argparse
import json
from pathlib import Path
import tempfile
import time
import uuid

from smoke_test import Client, assert_v1_discovery, payload
from topic_overview_smoke_test import document, stats, write_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=lambda value: Path(value).resolve())
    parser.add_argument('--benchmark', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='vauldy-fields-wire-') as temp:
        root = Path(temp)
        pages = ['VWTEST Vertragsunterlagen\nLeasingvertrag']
        pages += ['Allgemeine Erläuterungen ohne vereinbarte Vertragsfelder. ' * 24 for _ in range(17)]
        pages[4] += '\nMonatliche Rate: 249,99 EUR'
        pages[6] += '\nLaufzeit: 36 Monate'
        pages[17] += '\nKündigungsfrist: 3 Monate vor Vertragsende.'
        records = [document(*pages), document(
            'CONFLICTTEST\nVertragsart: Mietvertrag\nMonatsrate: 650 EUR\nGesamtkosten: 7800 EUR\n'
            'Laufzeit: 12 Monate\nKündigungsfrist: Ein Monat.',
            'Kündigungsfrist: Drei Monate.\nName: Erika Musterfrau\nE-Mail: erika@example.com\n'
            'Aussteller: erika@example.com\nVertragspartner: Falscher Aussteller'),
            document('PAGINGTEST\nLeasingvertrag\n' + '\n'.join(f'Kündigungsfrist: {i} Wochen.' for i in range(19))),
            document('FAILEDTEST\nLeasingvertrag\nMonatsrate: 1 EUR', status='failed'),
            document('UNLOCATEDTEST\nKosten: 7 EUR', ocrText='UNLOCATEDTEST\nKosten: 7 EUR'),
            document('LONGTEST\nKosten: ' + '€' * 1300),
            document('PRIVATEMARKER\nLeasingvertrag\nMonatsrate: 999 EUR')]
        vault = root / 'documents.json'
        write_json(vault, records)
        vault_bytes = vault.read_bytes()
        grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                     connectionName='Synthetic field extraction', enabled=True, vaultPath=str(vault),
                     allowedDocumentIDs=[r['id'] for r in records[:-1]], acknowledgedCloudDisclosure=True)

        def make_profile(name):
            path = root / name / 'profile.json'
            path.parent.mkdir()
            write_json(path, grant)
            return path

        def select(client, query):
            items = payload(client.call('list_documents', query=query, includeExcerpts=False))['items']
            assert len(items) == 1, (query, items)
            return items[0]['document']

        profile = make_profile('wire')
        profile_bytes = profile.read_bytes()
        client = Client(args.binary, profile)
        try:
            tools = client.request('tools/list', {})['tools']
            assert_v1_discovery(tools)
            schema = next(t['outputSchema'] for t in tools if t['name'] == 'extract_document_fields')

            def extract(**kwargs):
                return payload(client.call('extract_document_fields', **kwargs), schema)

            handle = select(client, 'VWTEST')
            before = client.counter
            result = extract(documents=[handle])
            assert client.counter == before + 1 and result['retrievalComplete']
            rows = {r['field']: r for r in result['results']}
            expected = dict(contractType=('Leasingvertrag', 1), cost=('249,99 EUR', 5),
                            term=('36 Monate', 7), noticePeriod=('3 Monate vor Vertragsende.', 18))
            for field, (value, page) in expected.items():
                row = rows[field]
                assert row['status'] == 'evidenced' and row['sourceCoverage'] == 'all-declared-pages-have-ocr-text', (field, row)
                evidence, = row['evidence']
                assert evidence['value'] == value and evidence['page'] == page
                assert evidence['quote'] in pages[page - 1]
                assert evidence['source'] == f'[Quelle:{handle}:S.{page}]'
            conflict = extract(documents=[select(client, 'CONFLICTTEST')],
                               fields=['cost', 'noticePeriod', 'issuer', 'endDate'])
            rows = {r['field']: r for r in conflict['results']}
            assert rows['cost']['status'] == 'multiple-values' and rows['cost']['evidenceCount'] == 2
            assert rows['noticePeriod']['status'] == 'conflicting'
            assert {e['page'] for e in rows['noticePeriod']['evidence']} == {1, 2}
            assert rows['endDate']['status'] == 'not-evidenced'
            assert rows['issuer']['status'] == 'redacted'
            combined = extract(documents=[handle, conflict['results'][0]['document']])
            assert combined['retrievalComplete'] and len(combined['results']) == 8
            assert {r['document'] for r in combined['results']} == {handle, conflict['results'][0]['document']}
            wire = json.dumps(conflict)
            for secret in ['Erika Musterfrau', 'erika@example.com', 'Falscher Aussteller',
                           'PRIVATEMARKER', str(root), *(r['id'] for r in records)]:
                assert secret not in wire, secret
            failed = extract(documents=[select(client, 'FAILEDTEST')])
            assert all(r['status'] == 'source-unavailable' for r in failed['results'])
            unlocated = extract(documents=[select(client, 'UNLOCATEDTEST')], fields=['cost'])['results'][0]
            assert unlocated['status'] == 'not-evidenced' and not unlocated['evidence']
            assert 'UNLOCATED_SOURCE_TEXT' in unlocated['warnings']
            long = extract(documents=[select(client, 'LONGTEST')], fields=['cost'])['results'][0]
            assert 'FIELD_EXTRACTION_INCOMPLETE' in long['warnings']

            for invalid in [{}, {'documents': []}, {'documents': [handle, handle]},
                            {'documents': [handle], 'fields': []}, {'documents': [handle], 'fields': ['unknown']},
                            {'documents': [handle], 'fields': ['cost', 'cost']}, {'documents': [handle] * 11},
                            {'documents': [True]}, {'documents': handle}, {'fields': 'cost'},
                            {'documents': [records[-1]['id']]}, {'documents': [handle], 'query': 'VW'},
                            {'documents': [handle], 'cursor': 3}]:
                assert client.call('extract_document_fields', **invalid)['isError'], invalid

            paged_handle = select(client, 'PAGINGTEST')
            first = extract(documents=[paged_handle], fields=['noticePeriod'])
            assert len(first['results']) == 8 and not first['retrievalComplete']
            assert first['results'][0]['status'] == 'conflicting' and first['results'][0]['evidenceCount'] == 19
            cursor = first['nextCursor']
            assert client.call('read_document', document=paged_handle, cursor=cursor)['isError']
            assert client.call('extract_document_fields', cursor=cursor, fields=['cost'])['isError']
            assert client.call('extract_document_fields', cursor=cursor.rsplit(':', 1)[0] + ':9')['isError']
            second = extract(cursor=cursor)
            assert second['retrievalComplete'] and 'nextCursor' not in second
            parts = first['results'] + second['results']
            assert [r['evidenceOffset'] for r in parts] == list(range(0, 19, 2))
            assert parts[-1]['evidenceComplete'] and not parts[0]['evidenceComplete']
            assert len({e['value'] for row in parts for e in row['evidence']}) == 19
            other = Client(args.binary, make_profile('other'))
            try:
                assert other.call('extract_document_fields', cursor=cursor)['isError']
                assert other.call('extract_document_fields', documents=[handle])['isError']
            finally:
                other.close()
            assert vault.read_bytes() == vault_bytes and profile.read_bytes() == profile_bytes
            changed = records.copy()
            changed[2] = changed[2] | {'ocrText': changed[2]['ocrText'] + '\nKündigungsfrist: 99 Wochen.'}
            write_json(vault, changed)
            assert client.call('extract_document_fields', cursor=cursor)['isError']
            assert client.call('extract_document_fields', documents=[paged_handle])['isError']
            handle = select(client, 'VWTEST')
            write_json(profile, grant | {'enabled': False, 'revision': str(uuid.uuid4())})
            assert client.call('extract_document_fields', documents=[handle])['isError']
        finally:
            client.close()

        report = dict(passed=['single-call-four-fields', 'physical-last-page', 'conflicts', 'cost-roles',
                              'missing-fields', 'whole-document-privacy', 'grants', 'failed-source',
                              'unlocated-source', 'bounded-evidence', 'input-validation', 'pagination',
                              'cursor-scope', 'changed-source', 'revocation', 'read-only-fixtures', 'v1-contract'],
                      documents=len(records), selectedPages=18, extractionCalls=1)
        if args.benchmark:
            vault.write_bytes(vault_bytes)

            def timed(client, selected, mode):
                start = time.perf_counter()
                before = client.counter
                responses = []
                if mode == 'fields':
                    data = payload(client.call('extract_document_fields', documents=[selected]))
                    assert data['retrievalComplete'] and all(r['status'] == 'evidenced' for r in data['results'])
                    responses.append(data)
                else:
                    cursor = None
                    while True:
                        data = payload(client.call('read_document', document=selected, **({'cursor': cursor} if cursor else {})))
                        responses.append(data)
                        cursor = data.get('nextCursor')
                        if not cursor:
                            break
                    assert [s['page'] for r in responses for s in r['segments']] == list(range(1, 19))
                return ((time.perf_counter() - start) * 1000, client.counter - before,
                        sum(len(json.dumps(r, ensure_ascii=False).encode()) for r in responses))

            benchmark = {}
            for mode in ['read', 'fields']:
                cold = []
                for i in range(10):
                    client = Client(args.binary, make_profile(f'{mode}-cold-{i}'))
                    try:
                        selected = select(client, 'VWTEST')
                        elapsed, calls, size = timed(client, selected, mode)
                        cold.append(elapsed)
                    finally:
                        client.close()
                client = Client(args.binary, make_profile(f'{mode}-warm'))
                try:
                    selected = select(client, 'VWTEST')
                    timed(client, selected, mode)
                    warm = [timed(client, selected, mode)[0] for _ in range(20)]
                finally:
                    client.close()
                benchmark[mode] = dict(cold=stats(cold), warm=stats(warm), toolCalls=calls,
                                       structuredBytes=size)
            report['benchmark'] = benchmark
        print(json.dumps(report))


if __name__ == '__main__':
    main()
