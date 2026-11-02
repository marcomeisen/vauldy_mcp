#!/usr/bin/env python3
"""Real native folder references, restart and verified migration. Synthetic data only."""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
from import_smoke_test import command, stop_worker


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local_binary', type=Path)
    parser.add_argument('mcp_binary', type=Path)
    args = parser.parse_args()
    local = args.local_binary.resolve()
    with tempfile.TemporaryDirectory(prefix='vauldy-original-wire-') as temp:
        root = Path(temp).resolve()
        source = root/'source'; source.mkdir()
        file = source/'example.pdf'
        command(local, 'example', '--output', file)
        before = file.read_bytes(), file.stat().st_mtime_ns, file.stat().st_mode
        store = root/'references'; copies = root/'legacy'
        try:
            outcome = command(local, 'import-folder', '--store', store, source)[0]
            assert outcome['state'] == 'completed'
            document = json.loads((store/'documents.json').read_text())[0]
            assert document['localImport']['originalReference']['bookmark']
            assert not (store/'originals').exists()
            stop_worker(local, store)
            retried = command(local, 'retry', '--store', store, '--document', document['id'], '--fresh')
            assert retried['state'] == 'completed' and retried['documentID'] == document['id']
            assert command(local, 'check-originals', '--store', store)[0]['state'] == 'available'
            old = command(local, 'import', '--store', copies, file)[0]
            managed = next((copies/'originals').iterdir())
            preview = command(local, 'originals-preview', '--store', copies, source)
            assert preview['items'][0]['status'] == 'eligible' and managed.exists()
            report = command(local, 'originals-migrate', '--store', copies, source)
            assert report['items'][0]['copyRemoved'] and not managed.exists()
            for name in ['documents.json', 'documents.backup.json']:
                persisted = json.loads((copies/name).read_text())[0]
                assert persisted['id'] == old['documentID'] and persisted['localImport']['originalReference']
            stop_worker(local, copies)
            assert command(local, 'retry', '--store', copies, '--document', old['documentID'], '--fresh')['state'] == 'completed'
            assert (file.read_bytes(), file.stat().st_mtime_ns, file.stat().st_mode) == before
            digest = hashlib.sha256(file.read_bytes()).hexdigest()
            file.write_bytes(file.read_bytes() + b'\n% synthetic changed version\n')
            assert command(local, 'check-originals', '--store', store)[0]['state'] == 'changed'
            changed = json.loads((store/'documents.json').read_text())[0]
            assert changed['localImport']['contentHash'] == digest and changed['ocrText'] == document['ocrText']
            file.unlink()
            assert command(local, 'check-originals', '--store', store)[0]['state'] == 'unavailable'
            print('PASS: native folder reference without copy, worker restart/fresh OCR, verified legacy migration, both snapshots, unchanged source bytes/mtime/mode, historical OCR and missing-source state.')
        finally:
            for vault in [store, copies]:
                if (vault/'store.json').exists():
                    stop_worker(local, vault)


if __name__ == '__main__':
    main()
