#!/usr/bin/env python3
"""R3d.3 local SQLite acceptance with a real overlapping native OCR workload."""
import argparse
import contextlib
import json
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time

from sqlite_load_acceptance import (
    GATES, MeasuredClient, case, command, digest, fill, grant, payload, stats,
    stop_worker, write_json,
)

SEARCH_LIMIT_MS = 5000
REQUEST_SECONDS = 15
SAFE_ERRORS = {
    'Die Freigabe oder das Dokument hat sich geändert. Bitte erneut suchen.',
    'Der freigegebene lokale Bestand ist nicht lesbar. Original und Bestand bleiben unverändert.',
}
QUERIES = {
    'commonFilter': ('list_documents', dict(query='Versicherung', includeExcerpts=False, pageSize=100)),
    'rareRanked': ('search_documents', dict(query='Pruefmarker000000', limit=1)),
    'commonRanked': ('search_documents', dict(query='Versicherung', limit=1)),
}


def rebuild(local, store):
    start = time.monotonic()
    subprocess.run([str(local), 'storage-rebuild-projections', '--store', str(store)],
                   capture_output=True, check=True, timeout=600)
    return round((time.monotonic() - start) * 1000, 3)


def raster_fixture(local, root, pages):
    png, jpeg, pdf = (root / name for name in ('raster.png', 'raster.jpg', 'raster.pdf'))
    command(local, 'example', '--output', png)
    subprocess.run(['/usr/bin/sips', '-s', 'format', 'jpeg', str(png), '--out', str(jpeg)],
                   capture_output=True, check=True, timeout=15)
    info = subprocess.check_output(['/usr/bin/sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(jpeg)], text=True)
    width, height = (int(re.search(key + r': (\d+)', info)[1]) for key in ('pixelWidth', 'pixelHeight'))
    image = jpeg.read_bytes()

    def stream(dictionary, data):
        return f'<< {dictionary} /Length {len(data)} >>\nstream\n'.encode() + data + b'\nendstream'

    page_refs = ' '.join(f'{i + 5} 0 R' for i in range(pages))
    objects = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        f'<< /Type /Pages /Kids [{page_refs}] /Count {pages} >>'.encode(),
        stream(f'/Type /XObject /Subtype /Image /Width {width} /Height {height} '
               '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode', image),
        stream('', f'q {width} 0 0 {height} 0 0 cm /Im Do Q\n'.encode()),
    ]
    objects.extend([f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] '
                    '/Resources << /XObject << /Im 3 0 R >> >> /Contents 4 0 R >>'.encode()] * pages)
    with pdf.open('wb') as output:
        output.write(b'%PDF-1.4\n%\xff\xff\xff\xff\n')
        offsets = []
        for index, obj in enumerate(objects, 1):
            offsets.append(output.tell())
            output.write(f'{index} 0 obj\n'.encode() + obj + b'\nendobj\n')
        start = output.tell()
        output.write(f'xref\n0 {len(objects) + 1}\n0000000000 65535 f \n'.encode())
        for offset in offsets:
            output.write(f'{offset:010} 00000 n \n'.encode())
        output.write(f'trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode())
    return pdf


def record_hashes(db):
    with contextlib.closing(sqlite3.connect(db)) as sql:
        return dict(sql.execute('SELECT id,digest FROM records'))


def query(client, label, granted, common_count, allow_change=False):
    method, args = QUERIES[label]
    started = time.monotonic()
    try:
        response, elapsed = client.call(method, **args)
    except TimeoutError:
        return dict(outcome='timeout', started=started, ended=time.monotonic())
    ended = time.monotonic()
    if response.get('isError'):
        assert allow_change and not response.get('structuredContent'), 'Unexpected MCP error or data in error'
        assert response['content'][0]['text'] in SAFE_ERRORS, 'Unexpected MCP error type'
        return dict(outcome='sourceChanged', started=started, ended=ended)
    data = payload(response)
    assert data['coverage']['authorizedDocumentCount'] == granted, 'Grant count changed'
    expected = 1 if label == 'rareRanked' else common_count
    assert data['totalCount'] == expected, 'Search count differs from independent expectation'
    if method == 'search_documents':
        assert len(data['hits']) == 1 and data['hits'][0]['page'] is not None, 'Missing ranked evidence'
    return dict(outcome='ok', elapsedMS=round(elapsed, 3), started=started, ended=ended)


def summarize(samples, requested, min_ok):
    timings = [s['elapsedMS'] for s in samples if s['outcome'] == 'ok']
    result = dict(**stats(timings), requested=requested, attempted=len(samples),
                  sourceChanges=sum(s['outcome'] == 'sourceChanged' for s in samples),
                  timeouts=sum(s['outcome'] == 'timeout' for s in samples))
    result['go'] = len(timings) >= min_ok and not result['timeouts'] and result.get('p95MS', float('inf')) <= SEARCH_LIMIT_MS
    return result


def steady(binary, profile, root, granted, common_count, repeats, broad_repeats):
    result = {}
    for label in QUERIES:
        requested = broad_repeats if label == 'commonRanked' else repeats
        client = MeasuredClient(binary, profile, root, 'steady-' + label, request_seconds=REQUEST_SECONDS)
        samples = []
        try:
            assert payload(client.call('get_vault_status')[0])['grantedDocumentCount'] == granted
            for _ in range(requested):
                sample = query(client, label, granted, common_count)
                samples.append(sample)
                if sample['outcome'] == 'timeout':
                    break
        finally:
            client.close()
        summary = summarize(samples, requested, requested)
        summary.update(client.metrics)
        summary['go'] &= summary.get('peakRSSBytes', float('inf')) <= GATES['peakRSSBytes']
        result[label] = summary
    return result


def parallel(local, binary, store, db, profile, root, label, operation, granted, common_count,
             queries, min_overlap):
    started = time.monotonic()
    profile_before = profile.read_bytes()
    client = MeasuredClient(binary, profile, root, label, request_seconds=REQUEST_SECONDS)
    proc = None
    monitor = None
    active = []
    finished = []
    stop = threading.Event()
    seen = threading.Event()
    samples = {key: [] for key in queries}
    outcome = None

    def observe():
        with contextlib.closing(sqlite3.connect(db, timeout=.15)) as sql:
            while not stop.is_set():
                if proc.poll() is not None:
                    finished.append(time.monotonic())
                    return
                try:
                    if sql.execute("SELECT 1 FROM records WHERE import_state='recognizing' LIMIT 1").fetchone():
                        active.append(time.monotonic())
                        seen.set()
                except sqlite3.OperationalError:
                    pass
                stop.wait(.02)

    try:
        first = payload(client.call('list_documents', includeExcerpts=False, pageSize=1)[0])
        assert first['totalCount'] == granted
        handle, cursor = first['items'][0]['document'], first['nextCursor']
        with (root / f'{label}.worker-stderr').open('wb') as errors:
            proc = subprocess.Popen([str(local), *map(str, operation)], stdout=subprocess.PIPE, stderr=errors)
            started = time.monotonic()
            monitor = threading.Thread(target=observe, daemon=True)
            monitor.start()
            while not seen.wait(.02):
                assert proc.poll() is None and time.monotonic() - started < 15, 'Native OCR state was not observed'
            timed_out = False
            while proc.poll() is None and not timed_out:
                assert time.monotonic() - started < 120, 'Parallel OCR workload exceeded 120 seconds'
                for key in queries:
                    sample = query(client, key, granted, common_count, allow_change=True)
                    samples[key].append(sample)
                    if sample['outcome'] == 'timeout':
                        timed_out = True
                        break
                    if proc.poll() is not None:
                        break
                if queries == ('commonRanked',) and min_overlap == 1:
                    break
            stdout, _ = proc.communicate(timeout=120)
            native_elapsed = (time.monotonic() - started) * 1000
            assert proc.returncode == 0, 'Native import or fresh OCR failed'
        decoded = json.loads(stdout)
        outcome = decoded[0] if isinstance(decoded, list) else decoded
        assert outcome['state'] == 'completed' and outcome['pageCount'] > 1, 'Multi-page OCR did not complete'
        assert profile.read_bytes() == profile_before, 'Importer changed the grant profile'
        if not timed_out:
            assert client.call('read_document', document=handle)[0]['isError'], 'Old handle survived source commit'
            assert client.call('list_documents', cursor=cursor)[0]['isError'], 'Old cursor survived source commit'
            assert payload(client.call('get_vault_status')[0])['grantedDocumentCount'] == granted
    finally:
        stop.set()
        if monitor:
            monitor.join(timeout=2)
        if proc and proc.poll() is None:
            proc.kill()
            proc.communicate(timeout=5)
        client.close()
    assert active and outcome, 'No verified native OCR overlap'
    if finished:
        native_elapsed = (finished[0] - started) * 1000
    result = dict(grants=granted, ocrObservations=len(active), ocrObservedMS=round((active[-1]-active[0])*1000, 3),
                  nativeMS=round(native_elapsed, 3), pageCount=outcome['pageCount'],
                  staleHandleAndCursorChecked=not timed_out, requests={}, **client.metrics)
    for key, data in samples.items():
        overlapping = [s for s in data if s['started'] <= active[-1] and s['ended'] >= active[0]]
        result['requests'][key] = dict(**summarize(overlapping, min_overlap, min_overlap),
                                       allAttempts=len(data),
                                       allTimeouts=sum(s['outcome'] == 'timeout' for s in data),
                                       allSourceChanges=sum(s['outcome'] == 'sourceChanged' for s in data))
    result['go'] = all(s['go'] for s in result['requests'].values()) and (
        result.get('peakRSSBytes', float('inf')) <= GATES['peakRSSBytes'])
    return result, outcome['documentID'].upper()


def crash_recovery(local, binary, store, db, profile, root, count, common_count):
    with contextlib.closing(sqlite3.connect(db)) as sql:
        has_rank_projection = bool(sql.execute(
            "SELECT 1 FROM sqlite_schema WHERE type='table' AND name='rank_projection_v1'"
        ).fetchone())

    def state():
        statements = [
            'SELECT token FROM generation', 'SELECT count(*) FROM records',
            'SELECT count(*) FROM search_indexed_v1', 'SELECT count(*) FROM search_terms_v1',
        ]
        if has_rank_projection:
            statements.append('SELECT count(*) FROM rank_projection_v1')
        with contextlib.closing(sqlite3.connect(db)) as sql:
            return tuple(sql.execute(statement).fetchone()[0] for statement in statements)

    before = state()
    originals = record_hashes(db)
    journal = Path(str(db) + '-journal')
    assert not journal.exists()
    process = subprocess.Popen([str(local), 'storage-rebuild-projections', '--store', str(store)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 30
        while True:
            try:
                size = journal.stat().st_size
                if size > 512:
                    break
            except FileNotFoundError:
                pass
            assert process.poll() is None and time.monotonic() < deadline, 'No populated index-builder journal'
            time.sleep(.002)
        process.kill()
        assert process.wait(timeout=5) == -signal.SIGKILL
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
    assert state() == before, 'Committed generation or index counts changed after SIGKILL'
    assert record_hashes(db) == originals, 'Record digests changed after SIGKILL'
    with contextlib.closing(sqlite3.connect(db)) as sql:
        assert sql.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    for label in ('after-rollback', 'after-rebuild'):
        if label == 'after-rebuild':
            rebuild_ms = rebuild(local, store)
            assert state()[1:] == before[1:] and state()[0] != before[0]
            assert record_hashes(db) == originals and not journal.exists(), 'Restart altered records or left journal'
        client = MeasuredClient(binary, profile, root, label, request_seconds=REQUEST_SECONDS)
        try:
            keys = ('commonFilter', 'rareRanked', 'commonRanked') if has_rank_projection else ('commonFilter', 'rareRanked')
            for key in keys:
                assert query(client, key, count, common_count)['outcome'] == 'ok', 'Full-grant query failed after crash'
        finally:
            client.close()
    return dict(grants=count, journalBytesAtKill=size, rolledBack=True, recordDigestsPreserved=True,
                integrityCheck='ok', rebuildMS=rebuild_ms, journalRemoved=True, fullGrantQueriesPassed=True,
                rankProjectionRows=before[-1] if has_rank_projection else None)


def run_size(local, binary, count, args, row, checkpoint):
    with tempfile.TemporaryDirectory(prefix=f'vauldy-r3d3-{count}-') as temporary:
        root = Path(temporary)
        store, seed_pdf, profile = root/'vault', root/'seed.pdf', root/'profile.json'
        db = Path(command(local, 'create-sqlite', '--store', store)['vaultPath'])
        try:
            command(local, 'example', '--output', seed_pdf)
            seed_digest = digest(seed_pdf)
            command(local, 'import', '--store', store, seed_pdf)
            stop_worker(local, store)
            with contextlib.closing(sqlite3.connect(db)) as sql:
                seed = json.loads(sql.execute('SELECT payload FROM records').fetchone()[0])
            _, expected, _ = fill(db, seed, count - 2, args.text_bytes)
            print(json.dumps(dict(stage='building-index', documents=count)), flush=True)
            row['initialRebuildMS'] = rebuild(local, store)
            checkpoint()
            before_import = record_hashes(db)
            old_ids = sorted(before_import)
            assert len(old_ids) == count - 1
            common_count = sum(k == 'Versicherung' for k in expected.values())
            raster = raster_fixture(local, root, args.ocr_pages)
            image_digest = digest(raster)
            write_json(profile, grant(db, old_ids))
            row['newImport'], imported = parallel(local, binary, store, db, profile, root, 'new-import',
                ('import', '--store', store, raster), count - 1, common_count, ('commonFilter', 'rareRanked'), 1)
            after_import = record_hashes(db)
            assert len(after_import) == count and imported not in before_import and imported in after_import
            assert all(after_import[k] == v for k, v in before_import.items()), 'Native import altered another record'
            assert set(json.loads(profile.read_text())['allowedDocumentIDs']) == set(old_ids)
            row['noImplicitGrant'] = True
            all_ids = sorted(after_import)
            write_json(profile, grant(db, all_ids))
            checkpoint()

            for label, labels, minimum in (
                ('fullGrantOCR', ('commonFilter', 'rareRanked'), 2),
                ('fullGrantBroadOCR', ('commonRanked',), args.broad_ocr_min),
            ):
                row[label], seen = parallel(local, binary, store, db, profile, root, label,
                    ('retry', '--store', store, '--document', imported, '--fresh'), count, common_count, labels, minimum)
                assert seen == imported
                checkpoint()
            assert digest(raster) == image_digest and digest(seed_pdf) == seed_digest
            after_ocr = record_hashes(db)
            assert set(after_ocr) == set(all_ids)
            assert all(after_ocr[k] == v for k, v in before_import.items()), 'Fresh OCR altered another record'
            stop_worker(local, store)
            row['databaseBytes'] = db.stat().st_size
            before_reads = digest(db)
            row['steady'] = steady(binary, profile, root, count, common_count, args.repeats, args.broad_repeats)
            checkpoint()
            row['baseline'] = case(binary, profile, root, 'all', all_ids, expected, count, args.samples, search_gates=True)
            assert digest(db) == before_reads, 'Read workload modified the source database'
            row['readOnlySourceUnchanged'] = True
            checkpoint()
            if count == 20000:
                print(json.dumps(dict(stage='index-abort-recovery', documents=count)), flush=True)
                row['recovery'] = crash_recovery(local, binary, store, db, profile, root, count, common_count)
            row['go'] = (row['baseline']['go'] and all(r['go'] for r in row['steady'].values())
                         and all(row[key]['go'] for key in ('newImport', 'fullGrantOCR', 'fullGrantBroadOCR')))
        finally:
            stop_worker(local, store)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('local', type=lambda s: Path(s).resolve())
    parser.add_argument('binary', type=lambda s: Path(s).resolve())
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--counts', default='1000,2000,5000,10000,20000')
    parser.add_argument('--text-bytes', type=int, default=32768)
    parser.add_argument('--ocr-pages', type=int, default=24)
    parser.add_argument('--samples', type=int, default=25)
    parser.add_argument('--repeats', type=int, default=10)
    parser.add_argument('--broad-repeats', type=int, default=3)
    parser.add_argument('--broad-ocr-min', type=int, default=1,
                        help='Required successful overlapping broad ranked requests during fresh OCR.')
    args = parser.parse_args()
    counts = [int(x) for x in args.counts.split(',')]
    assert all(100 <= n <= 20000 for n in counts) and min(args.samples, args.repeats, args.broad_repeats, args.broad_ocr_min) > 0
    report = dict(scope='R3d.3 local stdio, synthetic long text and native concurrent raster OCR',
                  localSHA256=digest(args.local), mcpSHA256=digest(args.binary), cases=[],
                  limits=dict(**GATES, repeatedSearchP95MS=SEARCH_LIMIT_MS, searchRequestSeconds=REQUEST_SECONDS),
                  textBytes=args.text_bytes, ocrPages=args.ocr_pages, baselineSamples=args.samples,
                  searchRepeats=args.repeats, broadRepeats=args.broad_repeats, broadOCRMin=args.broad_ocr_min)

    def checkpoint():
        stage = args.output.with_suffix('.tmp')
        stage.write_text(json.dumps(report, indent=2) + '\n')
        stage.replace(args.output)

    checkpoint()
    for count in counts:
        row = dict(documents=count)
        report['cases'].append(row)
        try:
            run_size(args.local, args.binary, count, args, row, checkpoint)
        except Exception as error:
            row['go'] = False
            row['failureType'] = type(error).__name__
            if isinstance(error, AssertionError) and error.args:
                row['check'] = str(error)
        checkpoint()
        print(json.dumps(dict(stage='finished-size', documents=count, go=row['go'],
                              failureType=row.get('failureType'), check=row.get('check'))), flush=True)
    report['go'] = all(c['go'] for c in report['cases'])
    checkpoint()


if __name__ == '__main__':
    main()
