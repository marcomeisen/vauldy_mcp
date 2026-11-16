#!/usr/bin/env python3
"""Synthetic SQLite benchmark for tools that operate on a few selected handles.

Builds an isolated SQLite store (never an installed vault/profile), grants all records and
measures read_document, extract_document_fields and compare_contract_versions for one or
two handles while the grant grows. Exit 0 means measurements completed, not a gate.
"""
import argparse
import contextlib
import json
import sqlite3
import statistics
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sqlite_load_acceptance import MeasuredClient, command, fill, grant, payload, stop_worker, write_json  # noqa: E402


def median(values):
    return round(statistics.median(values), 1)


def measure(local, binary, count, text_bytes, samples):
    with tempfile.TemporaryDirectory(prefix=f'vauldy-selected-{count}-') as temporary:
        root = Path(temporary)
        store, seed_pdf, profile = root / 'vault', root / 'seed.pdf', root / 'profile.json'
        db = Path(command(local, 'create-sqlite', '--store', store)['vaultPath'])
        try:
            command(local, 'example', '--output', seed_pdf)
            command(local, 'import', '--store', store, seed_pdf)
            stop_worker(local, store)
            with contextlib.closing(sqlite3.connect(db)) as sql:
                seed = json.loads(sql.execute('SELECT payload FROM records').fetchone()[0])
            ids, _, _ = fill(db, seed, count - 1, text_bytes)
            command(local, 'storage-rebuild-projections', '--store', store)
            with contextlib.closing(sqlite3.connect(db)) as sql:
                all_ids = [row[0] for row in sql.execute('SELECT id FROM records')]
            write_json(profile, grant(db, all_ids))
            client = MeasuredClient(binary, profile, root, f'selected-{count}', request_seconds=120)
            try:
                def handle(marker):
                    value, _ = client.call('list_documents', query=marker, includeExcerpts=False, pageSize=5)
                    items = payload(value)['items']
                    assert items, marker
                    return items[0]['document']
                first, second = handle('Pruefmarker000001'), handle('Pruefmarker000002')
                payload(client.call('read_document', document=first)[0])
                payload(client.call('read_document', document=second)[0])
                result = dict(documents=count, read=[], extract=[], compare=[])
                for _ in range(samples):
                    value, ms = client.call('read_document', document=first); payload(value); result['read'].append(ms)
                    value, ms = client.call('extract_document_fields', documents=[first, second]); payload(value); result['extract'].append(ms)
                    value, ms = client.call('compare_contract_versions', before=first, after=second); payload(value); result['compare'].append(ms)
                for key in ('read', 'extract', 'compare'):
                    result[key + 'MedianMS'] = median(result.pop(key))
            finally:
                client.close()
            result.update({k: v for k, v in client.metrics.items() if k == 'peakRSSBytes'})
            return result
        finally:
            stop_worker(local, store)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local', type=lambda p: Path(p).resolve())
    parser.add_argument('binary', type=lambda p: Path(p).resolve())
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--counts', default='100,1000,5000')
    parser.add_argument('--text-bytes', type=int, default=32768)
    parser.add_argument('--samples', type=int, default=5)
    args = parser.parse_args()
    rows = []
    for count in map(int, args.counts.split(',')):
        rows.append(measure(args.local, args.binary, count, args.text_bytes, args.samples))
        print(json.dumps(rows[-1]), flush=True)
    args.output.write_text(json.dumps(dict(binary=str(args.binary), rows=rows), indent=1) + '\n')


if __name__ == '__main__':
    main()
