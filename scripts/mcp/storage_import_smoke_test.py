#!/usr/bin/env python3
"""R3: real worker import alongside MCP reads of a large synthetic JSON store."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

from smoke_test import Client, payload
from import_smoke_test import command, stop_worker
from architecture_review_probe import grant
from topic_overview_smoke_test import write_json
from storage_boundary_benchmark import stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('local_binary', type=lambda x: Path(x).resolve())
    parser.add_argument('mcp_binary', type=lambda x: Path(x).resolve())
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='vauldy-r3-import-') as temporary:
        root = Path(temporary); store, pdf, image = root/'vault', root/'mixed.pdf', root/'image.png'
        client, process = None, None
        try:
            command(args.local_binary, 'example', '--output', pdf)
            command(args.local_binary, 'import', '--store', store, pdf)
            stop_worker(args.local_binary, store)
            seed = json.loads((store/'documents.json').read_text())[0]
            text = 'Versicherung. Dieser synthetische Vertrag beschreibt Leistungen und monatliche Zahlungen. '
            records = []
            for index in range(500):
                record = json.loads(json.dumps(seed))
                record['id'] = str(uuid.uuid4())
                record['ocrText'] = '--- Seite 1 ---\n' + text * 1600
                record['pageCount'] = 1
                record.pop('baseAnalysis', None); record.pop('baseAnalysisSourceHash', None)
                # These generated OCR records are synthetic fixtures, not user imports.
                record['localImport']['contentHash'] = hashlib.sha256(str(index).encode()).hexdigest()
                records.append(record)
            write_json(store/'documents.json', records)
            original_snapshot_bytes = (store/'documents.json').stat().st_size
            assert original_snapshot_bytes > 64 * 1024 * 1024
            profile = root/'profile.json'; original_profile = grant(store/'documents.json', [records[0]['id']])
            write_json(profile, original_profile); profile_bytes = profile.read_bytes()
            client = Client(args.mcp_binary, profile)
            assert payload(client.call('get_vault_status'))['grantedDocumentCount'] == 1
            command(args.local_binary, 'example', '--output', image)
            original_bytes = image.read_bytes()
            started = time.perf_counter()
            process = subprocess.Popen([str(args.local_binary), 'import', '--store', str(store), str(image)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            durations, transient_errors, successes_during_import = [], 0, 0
            deadline = time.monotonic() + 180
            while process.poll() is None:
                assert time.monotonic() < deadline, 'Import timed out'
                start = time.perf_counter()
                response = client.call('list_documents', query='Versicherung', includeExcerpts=False)
                durations.append((time.perf_counter() - start) * 1000)
                if response.get('isError'):
                    text = response['content'][0]['text']
                    assert text in [
                        'Die Freigabe oder das Dokument hat sich geändert. Bitte erneut suchen.',
                        'Der freigegebene lokale Bestand ist nicht lesbar. Original und Bestand bleiben unverändert.',
                    ], 'Unexpected concurrent-read failure'
                    transient_errors += 1  # A concurrent source rotation must fail closed, never leak.
                else:
                    data = payload(response)
                    assert data['totalCount'] == 1 and data['retrievalComplete']
                    successes_during_import += 1
                time.sleep(.02)
            stdout, stderr = process.communicate(timeout=10)
            assert process.returncode == 0, stderr
            assert json.loads(stdout)[0]['state'] in ['completed', 'partial']
            import_ms = (time.perf_counter() - started) * 1000
            assert successes_during_import > 0
            after = json.loads((store/'documents.json').read_text())
            assert len(after) == 501
            expected = {record['id']: record['ocrText'] for record in records}
            assert all(record['ocrText'] == expected[record['id']] for record in after if record['id'] in expected)
            assert payload(client.call('get_vault_status'))['grantedDocumentCount'] == 1
            assert payload(client.call('list_documents', query='Versicherung', includeExcerpts=False))['totalCount'] == 1
            assert profile.read_bytes() == profile_bytes and image.read_bytes() == original_bytes
            client.close(); client = Client(args.mcp_binary, profile)
            assert payload(client.call('get_vault_status'))['grantedDocumentCount'] == 1
            revoked = dict(original_profile, enabled=False, revision=str(uuid.uuid4()))
            write_json(profile, revoked)
            assert client.call('list_documents', includeExcerpts=False)['isError']
            report = dict(snapshotBytes=original_snapshot_bytes, initialRecords=500, finalRecords=501,
                          grantedBeforeAndAfter=1, realWorkerImportMS=round(import_ms, 3),
                          concurrentList=stats(durations), transientSourceRotationErrors=transient_errors,
                          successfulReadsWhileImporting=successes_during_import, restart=True, revocation=True,
                          existingOCRUnchanged=True, sourceAndGrantUnchanged=True,
                          localSHA256=hashlib.sha256(args.local_binary.read_bytes()).hexdigest(),
                          mcpSHA256=hashlib.sha256(args.mcp_binary.read_bytes()).hexdigest())
            args.output.write_text(json.dumps(report, indent=2)+'\n'); print(json.dumps(report))
        finally:
            if process and process.poll() is None:
                process.kill(); process.communicate()
            if client: client.close()
            if store.exists(): stop_worker(args.local_binary, store)


if __name__ == '__main__':
    main()
