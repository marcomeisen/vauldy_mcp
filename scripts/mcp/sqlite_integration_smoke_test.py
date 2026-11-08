#!/usr/bin/env python3
"""R3b: synthetic SQLite -> actual native worker -> offline stdio, including SIGKILL recovery."""
import argparse
import hashlib
import json
import sqlite3
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

from smoke_test import Client, payload
from import_smoke_test import command, stop_worker
from architecture_review_probe import grant
from topic_overview_smoke_test import write_json
from storage_boundary_benchmark import stats


def records(db):
    with sqlite3.connect(db) as connection:
        return [json.loads(row[0]) for row in connection.execute('SELECT payload FROM records ORDER BY id')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('local_binary', type=lambda x: Path(x).resolve())
    parser.add_argument('mcp_binary', type=lambda x: Path(x).resolve())
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='vauldy-r3b-wire-') as temporary:
        root = Path(temporary); store = root/'vault'; pdf = root/'synthetic.pdf'; png = root/'synthetic.png'
        client = worker = importer = None
        try:
            created = command(args.local_binary, 'create-sqlite', '--store', store)
            db = Path(created['vaultPath']); assert created['storage'] == 'sqlite'
            command(args.local_binary, 'example', '--output', pdf)
            command(args.local_binary, 'import', '--store', store, pdf)
            stop_worker(args.local_binary, store)
            print('Native SQLite seed import completed.', flush=True)
            inventory = command(args.local_binary, 'inventory-quality', '--store', store)
            assert inventory['total'] == 1 and inventory['sourceAvailable'] == 1
            assert len(inventory['snapshotDigest']) == 64
            seed = records(db)[0]
            assert '49,99 EUR' in seed['ocrText']
            originals = {p.name: p.read_bytes() for p in (store/'originals').iterdir()}
            expected = {}
            # Long records are explicitly synthetic; all writes use SQLite transactions and generation triggers.
            with sqlite3.connect(db) as connection:
                for i in range(40):
                    row = json.loads(json.dumps(seed)); row['id'] = str(uuid.uuid4()).upper()
                    row['ocrText'] = '--- Seite 1 ---\n' + 'Versicherung mit monatlicher Zahlung. ' * 2000
                    row['pageCount'] = 1
                    row.pop('baseAnalysis', None); row.pop('baseAnalysisSourceHash', None)
                    row['localImport']['contentHash'] = hashlib.sha256(str(i).encode()).hexdigest()
                    data = json.dumps(row, ensure_ascii=False).encode(); expected[row['id']] = data
                    connection.execute('INSERT INTO records VALUES(?,?,?,?,?,?,?)',
                        (row['id'], data, hashlib.sha256(data).digest(), row['localImport']['contentHash'], '', '', 'completed'))
            profile = root/'profile.json'; value = grant(db, list(expected)[:2]); write_json(profile, value)
            before_profile = profile.read_bytes()
            client = Client(args.mcp_binary, profile, server_options=('--persistent-sqlite-index',))
            first = payload(client.call('list_documents', query='Versicherung', includeExcerpts=False, pageSize=1))
            assert first['totalCount'] == 2
            handle, cursor = first['items'][0]['document'], first['nextCursor']
            command(args.local_binary, 'example', '--output', png)
            original_png = png.read_bytes()
            (store/'worker/stop').unlink(missing_ok=True)  # Explicit restart of this synthetic worker only.
            worker = subprocess.Popen([str(args.local_binary), 'worker', '--store', str(store), '--no-watch'],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 15
            while not command(args.local_binary, 'worker-status', '--store', store)['running']:
                assert worker.poll() is None and time.monotonic() < deadline
                time.sleep(.02)
            started = time.perf_counter()
            importer = subprocess.Popen([str(args.local_binary), 'import', '--store', str(store), str(png)],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            durations, transient, successes, killed = [], 0, 0, False
            deadline = time.monotonic() + 180
            while importer.poll() is None:
                assert time.monotonic() < deadline, 'worker/import timeout'
                if not killed:
                    with sqlite3.connect(db) as connection:
                        recognizing = connection.execute("SELECT count(*) FROM records WHERE import_state='recognizing'").fetchone()[0]
                    if recognizing:
                        assert worker.poll() is None
                        worker.kill(); worker.wait(timeout=10); killed = True
                        print("Synthetic OCR worker killed while recognizing; waiting for automatic restart.", flush=True)
                start = time.perf_counter()
                response = client.call('list_documents', query='Versicherung', includeExcerpts=False)
                durations.append((time.perf_counter()-start)*1000)
                if response.get('isError'):
                    assert response['content'][0]['text'] in [
                        'Die Freigabe oder das Dokument hat sich geändert. Bitte erneut suchen.',
                        'Der freigegebene lokale Bestand ist nicht lesbar. Original und Bestand bleiben unverändert.']
                    transient += 1
                else:
                    assert payload(response)['totalCount'] == 2; successes += 1
                time.sleep(.015)
            stdout, stderr = importer.communicate(timeout=10)
            assert importer.returncode == 0, stderr
            outcome = json.loads(stdout)[0]; assert outcome['state'] == 'completed'
            assert killed and successes, 'SIGKILL during OCR and concurrent successful reads must actually occur'
            import_ms = (time.perf_counter()-started)*1000
            assert client.call('read_document', document=handle)['isError']
            assert client.call('list_documents', cursor=cursor)['isError']
            after = records(db); assert len(after) == 42
            assert all(r['localImport']['state'] != 'recognizing' for r in after)
            assert all(r['localImport'].get('attempt') is None for r in after)
            with sqlite3.connect(db) as connection:
                assert connection.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
                for identity, data in connection.execute('SELECT id,payload FROM records'):
                    if identity in expected: assert data == expected[identity]
            jobs = [json.loads(p.read_text()) for p in (store/'worker').glob('*.json')]
            assert jobs and all(j['state'] == 'finished' and not j.get('borrowedAccess') for j in jobs)
            assert png.read_bytes() == original_png and profile.read_bytes() == before_profile
            for name, data in originals.items(): assert (store/'originals'/name).read_bytes() == data
            assert not (store/'documents.json').exists() and not (store/'documents.backup.json').exists()
            client.close(); client = Client(args.mcp_binary, profile)
            assert payload(client.call('list_documents', query='Versicherung', includeExcerpts=False))['totalCount'] == 2
            write_json(profile, dict(value, allowedDocumentIDs=list(expected)[1:2], revision=str(uuid.uuid4())))
            assert payload(client.call('list_documents', includeExcerpts=False))['totalCount'] == 1
            write_json(profile, dict(value, enabled=False, revision=str(uuid.uuid4())))
            assert client.call('search_documents', query='Versicherung')['isError']
            report = dict(initialRecords=41, finalRecords=42, grantedBeforeAndAfterImport=2,
                actualNativeWorker=True, nativeInventoryQuality=True, killedWhileRecognizing=killed, automaticWorkerRestart=True,
                queueFinishedAndBorrowedAccessCleared=True, staleHandleAndCursorRejected=True,
                restart=True, revocation=True, originalBytesAndGrantUnchanged=True, unchangedRowsByteIdentical=True,
                integrityCheck='ok', noJSONSnapshot=True, importIncludingCrashMS=round(import_ms,3),
                concurrentList=stats(durations), successes=successes, transientErrors=transient,
                transport='local stdio; no relay/network service configured; not a network-disconnected Mac acceptance',
                localSHA256=hashlib.sha256(args.local_binary.read_bytes()).hexdigest(),
                mcpSHA256=hashlib.sha256(args.mcp_binary.read_bytes()).hexdigest())
            args.output.write_text(json.dumps(report,indent=2)+'\n'); print(json.dumps(report))
        finally:
            if importer and importer.poll() is None: importer.kill(); importer.communicate()
            if client: client.close()
            if worker and worker.poll() is None: worker.kill(); worker.wait(timeout=10)
            if store.exists(): stop_worker(args.local_binary, store)


if __name__ == '__main__': main()
