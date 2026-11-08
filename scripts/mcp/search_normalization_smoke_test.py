#!/usr/bin/env python3
"""Exercise search aliases, literal evidence and index rebuilding with synthetic sources."""
import argparse
import json
from pathlib import Path
import sqlite3
import tempfile
import time
import uuid

from smoke_test import Client, payload, assert_v1_discovery
from topic_overview_smoke_test import document, write_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=lambda value: Path(value).resolve())
    args = parser.parse_args()
    variants = ['Versicherung', 'Versiche-\nrung', 'Versiche-\r\n  rung',
                'Versiche\u00adrung', 'Versiche\u200brung', 'Versiche\u2060rung', 'Versiche\ufeffrung']
    modes = [(), ('--memory-sqlite-index',), ('--persistent-sqlite-index',)]
    results = []
    for mode in modes:
        with tempfile.TemporaryDirectory(prefix='vauldy-normalization-wire-') as temporary:
            root = Path(temporary)
            vault, profile = root / 'documents.json', root / 'profile.json'
            items = [document('Name: Erika Musterfrau\nE-Mail: erika@example.com',
                              'Neutraler Vorlauf. ' * 90 + '\n' + spelling + '\nBeitrag: 49,99 EUR')
                     for spelling in variants]
            controls = [document(text) for text in ['Kfz-Haftpflicht', 'AB12-\ncd34', '49,\n99 EUR',
                         'Vertragsnummer: abc-\ndef', 'Versiche-\n\nrung']]
            private = document('Versiche-\nrung NICHTFREIGEGEBEN')
            write_json(vault, items + controls + [private])
            grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                         connectionName='Synthetic normalized search', enabled=True, vaultPath=str(vault),
                         allowedDocumentIDs=[item['id'] for item in items + controls], acknowledgedCloudDisclosure=True)
            write_json(profile, grant)
            original = vault.read_bytes(), profile.read_bytes()
            client = Client(args.binary, profile, server_options=mode)
            try:
                assert_v1_discovery(client.request('tools/list', {})['tools'])
                start = time.perf_counter()
                page = payload(client.call('list_documents', query='Versicherung', includeExcerpts=False, pageSize=2))
                count = page['totalCount']
                handles = [row['document'] for row in page['items']]
                while page.get('nextCursor'):
                    page = payload(client.call('list_documents', cursor=page['nextCursor']))
                    handles.extend(row['document'] for row in page['items'])
                ms = round((time.perf_counter() - start) * 1000, 1)
                assert count == len(set(handles)) == len(variants), (mode, count, handles)
                assert page['retrievalComplete']
                for query in ['Versiche\u00adrung', 'Versiche-\nrung']:
                    assert payload(client.call('list_documents', query=query, includeExcerpts=False))['totalCount'] == len(variants)
                search = payload(client.call('search_documents', query='Versicherung', limit=10))
                assert {hit['document'] for hit in search['hits']} == set(handles)
                seen = set()
                for handle in handles:
                    passages = payload(client.call('read_document', document=handle, view='passages', query='Versicherung'))
                    assert passages['retrievalComplete'] and len(passages['segments']) == 1
                    segment = passages['segments'][0]
                    assert segment['page'] == 2 and segment['source'] == f'[Quelle:{handle}:S.2]'
                    spelling, = [value for value in variants if value in segment['text']]
                    seen.add(spelling)
                    full = payload(client.call('read_document', document=handle))
                    text = ''.join(row['text'] for row in full['segments'] if row['page'] == 2)
                    assert segment['text'] in text
                    wire = json.dumps(passages)
                    for secret in ['Erika Musterfrau', 'erika@example.com', str(root), private['id']]:
                        assert secret not in wire
                assert seen == set(variants)
                overview = payload(client.call('get_topic_overview', query='versicherung'))
                assert len(overview['rows']) == len(variants)
                assert all(row['evidence']['page'] == 2 for row in overview['rows'])
                for query in ['KfzHaftpflicht', 'AB12cd34', 'abcdef']:
                    assert payload(client.call('list_documents', query=query, includeExcerpts=False))['totalCount'] == 0
                assert payload(client.call('list_documents', query='Kfz-Haftpflicht', includeExcerpts=False))['totalCount'] == 1
                assert (vault.read_bytes(), profile.read_bytes()) == original
            finally:
                client.close()
            if mode == ('--persistent-sqlite-index',):
                database, = root.glob('.vauldy-index-*/index-v1.sqlite')
                with sqlite3.connect(database) as connection:
                    assert connection.execute('PRAGMA user_version').fetchone()[0] == 3
                    connection.execute('PRAGMA user_version=2')
                previous_inode = database.stat().st_ino
            client = Client(args.binary, profile, server_options=mode)
            try:
                page = payload(client.call('list_documents', query='Versicherung', includeExcerpts=False))
                assert page['totalCount'] == len(variants)
                if mode == ('--persistent-sqlite-index',):
                    assert database.stat().st_ino != previous_inode
                    with sqlite3.connect(database) as connection:
                        assert connection.execute('PRAGMA user_version').fetchone()[0] == 3
                handle = page['items'][0]['document']
                changed = [item | {'ocrText': item['ocrText'] + '\nAktualisierte Quelle.'} for item in items]
                write_json(vault, [*changed, *controls, private])
                assert client.call('read_document', document=handle, view='passages', query='Versicherung')['isError']
                page = payload(client.call('list_documents', query='Versicherung', includeExcerpts=False))
                handle = page['items'][0]['document']
                write_json(profile, grant | {'enabled': False, 'revision': str(uuid.uuid4())})
                assert client.call('read_document', document=handle, view='passages', query='Versicherung')['isError']
                assert client.call('search_documents', query='Versicherung')['isError']
            finally:
                client.close()
            results.append(dict(mode=list(mode) or ['default'], matchingDocuments=count, enumerationMS=ms,
                                literalPageEvidence=True, changedSourceAndRevocation=True))
    print(json.dumps(dict(passed=True, variants=len(variants), controls=5, privateDocuments=1, modes=results)))


if __name__ == '__main__':
    main()
