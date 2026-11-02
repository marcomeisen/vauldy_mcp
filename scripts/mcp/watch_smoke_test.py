#!/usr/bin/env python3
"""Real watched-folder worker/OCR/MCP check; synthetic files and isolated local grants only."""
import argparse
import json
from pathlib import Path
import shutil
import tempfile
import time
import uuid
from import_smoke_test import command, stop_worker
from smoke_test import Client, payload


def wait_for(check, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.2)
    raise AssertionError('Timed out waiting for watched-folder processing')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local_binary', type=Path)
    parser.add_argument('mcp_binary', type=Path)
    args = parser.parse_args()
    local = args.local_binary.resolve()
    with tempfile.TemporaryDirectory(prefix='vauldy-watch-wire-') as temp:
        root = Path(temp).resolve(); store = root/'vault'
        first = root/'first'; second = root/'second'
        first.mkdir(); second.mkdir()
        client = None
        try:
            # An existing PDF and a later image in a second folder, with real native OCR.
            command(local, 'example', '--output', first/'existing.pdf')
            folders = command(local, 'watch-add', '--store', store, first, second)
            assert len(folders) == 2
            def documents():
                return json.loads((store/'documents.json').read_text())
            wait_for(lambda: len(documents()) == 1 and documents()[0]['localImport']['state'] == 'completed')
            initial = documents()[0]
            assert initial['pageCount'] == 2 and '49,99' in initial['ocrText']
            profile_path = root/'profile.json'
            profile_path.write_text(json.dumps(dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                connectionName='Isolated watch test', enabled=True, vaultPath=str(store/'documents.json'),
                allowedDocumentIDs=[initial['id']], acknowledgedCloudDisclosure=True)))
            grant_before = profile_path.read_bytes()
            client = Client(args.mcp_binary.resolve(), profile_path)
            assert payload(client.call('get_vault_status'))['grantedDocumentCount'] == 1
            command(local, 'example', '--output', second/'new.png')
            wait_for(lambda: len(documents()) == 2 and all(d['localImport']['state'] == 'completed' for d in documents()))
            # Copies across watched folders do not create another record.
            shutil.copyfile(first/'existing.pdf', second/'duplicate.pdf')
            time.sleep(12)
            assert len(documents()) == 2
            assert profile_path.read_bytes() == grant_before
            assert payload(client.call('get_vault_status'))['grantedDocumentCount'] == 1
            second_id = next(f['id'] for f in folders if f['path'] == str(second))
            command(local, 'watch-pause', '--store', store, '--folder', second_id)
            # Wait for a scan that has applied the pause before adding a file.
            wait_for(lambda: all(s['folderID'] != second_id for s in command(local, 'watch-list', '--store', store)['scans']))
            nested = second/'nested'; nested.mkdir()
            command(local, 'example', '--output', nested/'later.pdf')
            time.sleep(6)
            assert len(documents()) == 2
            # Restart rereads configuration and deduplicates unchanged bytes.
            stop_worker(local, store)
            command(local, 'watch-add', '--store', store, second, '--recursive')
            # Use different bytes so this represents a new original, not a dedupe of the first PDF.
            with (nested/'later.pdf').open('ab') as stream:
                stream.write(b'\n% synthetic watch restart fixture\n')
            wait_for(lambda: len(documents()) == 3 and all(d['localImport']['state'] == 'completed' for d in documents()))
            assert profile_path.read_bytes() == grant_before
            assert payload(client.call('get_vault_status'))['grantedDocumentCount'] == 1
            for folder in command(local, 'watch-list', '--store', store)['folders']:
                command(local, 'watch-remove', '--store', store, '--folder', folder['id'])
            assert len(documents()) == 3
            print('PASS: multiple folders, existing/new PDF and image OCR, dedupe, pause, recursion, restart, retained originals and unchanged MCP grants.')
        finally:
            if client:
                client.close()
            if (store/'store.json').exists():
                stop_worker(local, store)


if __name__ == '__main__':
    main()
