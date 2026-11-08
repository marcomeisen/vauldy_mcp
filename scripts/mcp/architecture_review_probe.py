#!/usr/bin/env python3
"""Measure storage boundaries and split-word retrieval with temporary synthetic data.

This reports current behavior; an expected limitation is not a passing quality gate.
No installed profile, original document, relay or external service is accessed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import time
import uuid

from smoke_test import Client, payload
from topic_overview_smoke_test import document, write_json


def grant(vault, ids):
    return dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                connectionName='Synthetic architecture review', enabled=True, vaultPath=str(vault),
                allowedDocumentIDs=ids, acknowledgedCloudDisclosure=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=lambda value: Path(value).resolve())
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    results = []
    for count, text_size in [(20000, 30), (20001, 30), (500, 120000), (500, 140000)]:
        with tempfile.TemporaryDirectory(prefix='vauldy-architecture-review-') as temporary:
            root = Path(temporary)
            vault, profile = root / 'documents.json', root / 'profile.json'
            items = [document('synthetisch ' * (text_size // 12)) for _ in range(count)]
            write_json(vault, items)
            write_json(profile, grant(vault, [items[0]['id']]))
            client = Client(args.binary, profile)
            durations, errors = [], []
            try:
                for _ in range(4):
                    start = time.perf_counter()
                    response = client.call('get_vault_status')
                    durations.append(round((time.perf_counter() - start) * 1000, 1))
                    errors.append(response.get('isError', False))
                    if not errors[-1]:
                        assert payload(response)['grantedDocumentCount'] == 1
                row = dict(documents=count, granted=1, snapshotBytes=vault.stat().st_size,
                           statusMS=durations, isError=errors)
                if any(errors):
                    row['lastResponseText'] = response['content'][0]['text']
                results.append(row)
            finally:
                client.close()

    with tempfile.TemporaryDirectory(prefix='vauldy-text-review-') as temporary:
        root = Path(temporary)
        vault, profile = root / 'documents.json', root / 'profile.json'
        variants = ['Versicherung', 'Versiche-\nrung', 'Versiche\u00adrung']
        items = [document(text) for text in variants]
        write_json(vault, items)
        write_json(profile, grant(vault, [item['id'] for item in items]))
        client = Client(args.binary, profile)
        try:
            all_items = payload(client.call('list_documents', includeExcerpts=False))
            filtered = payload(client.call('list_documents', query='Versicherung', includeExcerpts=False))
            search = payload(client.call('search_documents', query='Versicherung'))
            text_search = dict(variants=variants, allDocuments=all_items['totalCount'],
                               listMatched=filtered['totalCount'], searchHits=len(search['hits']))
        finally:
            client.close()

    report = dict(binarySHA256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  scope='Local stdio only; first call and three repeats; no P95, RSS or chat latency claim.',
                  storage=results, textSearch=text_search)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
