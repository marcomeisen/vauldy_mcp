#!/usr/bin/env python3
"""Explicit primary activation through real packaged binaries; synthetic data only."""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import uuid

from architecture_review_probe import grant
from import_smoke_test import command, stop_worker
from smoke_test import Client, payload
from topic_overview_smoke_test import write_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=lambda p: Path(p).resolve())
    parser.add_argument('--legacy-zip', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    resources = args.app/'Contents/Resources'
    local, server = resources/'vauldy-local', resources/'vauldy-mcp'
    with tempfile.TemporaryDirectory(prefix='vauldy-primary-wire-') as temporary:
        root = Path(temporary).resolve(); store = root/'installation/vault'; pdf = root/'example.pdf'
        installation = store.parent; installation.mkdir(mode=0o700)
        old_app = root/'old-release'
        old_app.mkdir()
        subprocess.run(['ditto', '-x', '-k', str(args.legacy_zip.resolve()), str(old_app)], check=True)
        old_bundle = next(old_app.glob('*.app'))
        old_local = old_bundle/'Contents/Resources/vauldy-local'
        for executable in [old_local, old_bundle/'Contents/Resources/vauldy-mcp']:
            executable.chmod(0o700)
        # Install a signed epoch-1 software slot, then upgrade with the epoch-2 updater.
        command(old_local, 'update-software', '--root', installation, '--from-app', old_bundle, '--allow-ad-hoc')
        command(local, 'example', '--output', pdf)
        original = pdf.read_bytes()
        command(local, 'import', '--store', store, pdf)
        stop_worker(local, store)
        records = json.loads((store/'documents.json').read_text())
        assert records and records[0]['localImport']['state'] == 'completed'
        assert any(page['method'] == 'vision' for page in records[0]['localImport']['pages'])
        profile = root/'profile.json'
        write_json(profile, grant(store/'documents.json', [records[0]['id']]))
        profile_bytes = profile.read_bytes()
        client = Client(server, profile)
        try:
            old_handle = payload(client.call('list_documents', includeExcerpts=False))['items'][0]['document']
            plan = command(local, 'storage-preview', '--store', store, '--format', 'sqlite')
            prepared = root/'prepared'
            command(local, 'storage-migrate', '--store', store, '--format', 'sqlite', '--to', prepared, '--expected', plan['fingerprint'])
            updated = command(local, 'update-software', '--root', installation, '--from-app', args.app, '--allow-ad-hoc')
            assert updated['updated'] and updated['version'] == json.loads((resources/'release.json').read_text())['productVersion']
            denied = subprocess.run([str(local), 'rollback-software', '--root', str(installation), '--allow-ad-hoc'], capture_output=True, timeout=30)
            assert denied.returncode != 0  # No return to a JSON-only writer.
            activated = command(local, 'storage-activate-sqlite', '--store', store, '--prepared', prepared, '--expected', plan['fingerprint'])
            assert activated['verified'] and activated['storage'] == 'sqlite' and not activated['profilesChanged']
            assert json.loads((store/'store.json').read_text())['version'] == 4
            assert not (store/'documents.json').exists() and not (store/'documents.backup.json').exists()
            assert client.call('read_document', document=old_handle)['isError']
            hits = payload(client.call('search_documents', query='Fahrradwartung'))['hits']
            read = payload(client.call('read_document', document=hits[0]['document']))
            assert 'Erika Musterfrau' not in json.dumps(read) and 'erika@example.com' not in json.dumps(read)
            database = store/'sqlite/records.sqlite'
            with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as db:
                assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
                values = [json.loads(row[0]) for row in db.execute('SELECT payload FROM records')]
            assert {v['id']:v for v in values} == {v['id']:v for v in records}
            before = hashlib.sha256(database.read_bytes()).hexdigest()
            denied = subprocess.run([str(old_local), 'import', '--store', str(store), str(pdf)], capture_output=True, timeout=30)
            assert denied.returncode != 0 and hashlib.sha256(database.read_bytes()).hexdigest() == before
            assert not (store/'documents.json').exists()
            # A fresh real native worker commits a new image to SQLite only.
            image = root/'new.png'; command(local, 'example', '--output', image)
            command(local, 'import', '--store', store, image); stop_worker(local, store)
            assert not (store/'documents.json').exists()
            with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as db:
                assert db.execute('SELECT count(*) FROM records').fetchone()[0] == len(records)+1
            assert payload(client.call('list_documents', includeExcerpts=False))['totalCount'] == len(records)
            assert profile.read_bytes() == profile_bytes and pdf.read_bytes() == original
            changed = json.loads(profile_bytes); changed['enabled'] = False; changed['revision'] = str(uuid.uuid4())
            write_json(profile, changed)
            assert client.call('read_document', document=hits[0]['document'])['isError']
            report = dict(passed=True, nativeVisionImportBeforeAndAfter=True, losslessRecords=True,
                          epoch1Upgrade=True, incompatibleRollbackRefused=True, oldWriterRefused=True,
                          logicalProfileByteUnchanged=True, noGrantExpansion=True, privacyAndRevocation=True,
                          oldHandleInvalidated=True, noJSONFallback=True,
                          localSHA256=hashlib.sha256(local.read_bytes()).hexdigest(),
                          serverSHA256=hashlib.sha256(server.read_bytes()).hexdigest())
            args.output.write_text(json.dumps(report, indent=2)+'\n'); print(json.dumps(report))
        finally:
            client.close()
            stop_worker(local, store)


if __name__ == '__main__': main()
