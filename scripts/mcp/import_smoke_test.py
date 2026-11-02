#!/usr/bin/env python3
"""Real standalone worker/OCR/MCP test. Synthetic originals, isolated vault, no cloud calls."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid
from smoke_test import Client, payload


def command(binary, *args, accepted=(0,)):
    result = subprocess.run([str(binary), *map(str, args)], capture_output=True, text=True, timeout=240)
    assert result.returncode in accepted, f'Local command failed ({result.returncode}): {result.stderr}'
    return json.loads(result.stdout) if result.stdout.strip() else None


def stop_worker(binary, store):
    command(binary, 'worker-stop', '--store', store)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if not command(binary, 'worker-status', '--store', store)['running']:
            return
        time.sleep(.1)
    raise AssertionError('Worker did not stop; retain fixture for diagnosis')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local_binary', type=Path)
    parser.add_argument('mcp_binary', type=Path)
    args = parser.parse_args()
    local = args.local_binary.resolve()
    with tempfile.TemporaryDirectory(prefix='vauldy-import-wire-') as temp:
        root = Path(temp); store = root/'vault'; pdf = root/'mixed.pdf'; image = root/'image.png'
        client = None
        try:
            command(local, 'example', '--output', pdf)
            original = hashlib.sha256(pdf.read_bytes()).hexdigest()
            start = time.monotonic()
            imported = command(local, 'import', '--store', store, pdf)[0]
            duration = time.monotonic() - start
            assert imported['state'] == 'completed' and imported['pageCount'] == 2
            doc_id = imported['documentID']
            documents = json.loads((store/'documents.json').read_text())
            assert [p['method'] for p in documents[0]['localImport']['pages']] == ['embeddedText', 'vision']
            first_worker = command(local, 'worker-status', '--store', store)['instance']
            duplicate = command(local, 'import', '--store', store, pdf)[0]
            assert duplicate['reusedOriginal'] and duplicate['documentID'] == doc_id
            assert command(local, 'status', '--store', store)[0]['state'] == 'completed'
            assert hashlib.sha256(pdf.read_bytes()).hexdigest() == original
            before = (store/'documents.json').read_bytes()
            profile_path = root/'profile.json'
            profile = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()), connectionName='Isolated import test',
                           enabled=False, vaultPath=str(store/'documents.json'), allowedDocumentIDs=[doc_id], acknowledgedCloudDisclosure=True)
            profile_path.write_text(json.dumps(profile))
            client = Client(args.mcp_binary.resolve(), profile_path)
            assert client.call('search_documents', query='Fahrradwartung')['isError']
            profile['enabled'] = True; profile['revision'] = str(uuid.uuid4()); profile_path.write_text(json.dumps(profile))
            search = payload(client.call('search_documents', query='Fahrradwartung'))
            handle = search['hits'][0]['document']
            listed = payload(client.call('list_documents', query='Fahrradwartung', pageSize=1))
            assert listed['totalCount'] == 1 and listed['retrievalComplete'] and listed['processingComplete']
            assert listed['items'][0]['document'] == handle
            read = payload(client.call('read_document', document=handle))
            assert read['sourceCoverage'] == 'all-declared-pages-processed'
            assert read['expectedPageCount'] == 2
            wire = json.dumps(read)
            assert '49,99' in wire and '8246' in wire
            assert 'erika@example.com' not in wire and 'Erika Musterfrau' not in wire and doc_id not in wire
            assert (store/'documents.json').read_bytes() == before
            command(local, 'example', '--output', image)
            # A concurrent direct OCR lock queues new work; a second CLI safely attaches to that job.
            with (store/'ocr.lock').open('r+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                pending = subprocess.Popen([str(local), 'import', '--store', str(store), str(image)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    states = command(local, 'status', '--store', store)
                    if any(item['state'] == 'queued' for item in states): break
                    time.sleep(.1)
                assert pending.poll() is None and any(item['state'] == 'queued' for item in states)
                follower = subprocess.Popen([str(local), 'import', '--store', str(store), str(image)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                time.sleep(.3)
                assert follower.poll() is None
                fcntl.flock(lock, fcntl.LOCK_UN)
            for process in [pending, follower]:
                output, error = process.communicate(timeout=240)
                assert process.returncode == 0, error
                assert json.loads(output)[0]['state'] == 'completed'
            assert command(local, 'worker-status', '--store', store)['instance'] == first_worker
            assert payload(client.call('get_vault_status'))['grantedDocumentCount'] == 1
            # Repeated OCR uses page checkpoints, not a duplicate-import shortcut.
            command(local, 'retry', '--store', store, '--document', doc_id)
            cached = next(d for d in json.loads((store/'documents.json').read_text()) if d['id'] == doc_id)
            assert all(p['metrics']['cacheHit'] for p in cached['localImport']['pages'])
            # Explicit fresh recognition bypasses checkpoints.
            command(local, 'retry', '--store', store, '--document', doc_id, '--fresh')
            fresh = next(d for d in json.loads((store/'documents.json').read_text()) if d['id'] == doc_id)
            assert all(not p['metrics']['cacheHit'] for p in fresh['localImport']['pages'])
            assert fresh['ocrText'] == documents[0]['ocrText']
            profile['enabled'] = False; profile['revision'] = str(uuid.uuid4()); profile_path.write_text(json.dumps(profile))
            assert client.call('read_document', document=handle)['isError']
            print(f'PASS: worker import → durable OCR → explicit grant → sanitized MCP read → revoke; process reuse, concurrent queue/reattach, cache and fresh retry. Cold mixed PDF: {duration:.2f}s; phases: {[p.get("metrics") for p in documents[0]["localImport"]["pages"]]}.')
        finally:
            if client: client.close()
            if (store/'store.json').exists(): stop_worker(local, store)

if __name__ == '__main__': main()
