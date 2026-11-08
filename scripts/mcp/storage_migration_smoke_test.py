#!/usr/bin/env python3
"""R3c: native import, explicit migration/backup/restore, live stdio and rollback on synthetic data."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid
import signal

from smoke_test import Client, payload
from import_smoke_test import command, stop_worker
from architecture_review_probe import grant
from topic_overview_smoke_test import write_json


def snapshot(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def denied(binary, *args):
    result = subprocess.run([str(binary), *map(str, args)], capture_output=True, text=True, timeout=60)
    assert result.returncode != 0
    return result.stderr.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('local_binary', type=lambda p: Path(p).resolve())
    parser.add_argument('mcp_binary', type=lambda p: Path(p).resolve())
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='vauldy-r3c-wire-') as temporary:
        root = Path(temporary); source = root/'source'; pdf = root/'synthetic.pdf'
        clients = []; migration_process = None
        try:
            command(args.local_binary, 'example', '--output', pdf)
            original = pdf.read_bytes()
            command(args.local_binary, 'import', '--store', source, pdf)
            # A live worker is a mandatory maintenance barrier, even when it is idle.
            denied(args.local_binary, 'storage-preview', '--store', source, '--format', 'sqlite')
            stop_worker(args.local_binary, source)
            records = json.loads((source/'documents.json').read_text()); identity = records[0]['id']
            profile = root/'source-profile.json'; write_json(profile, grant(source/'documents.json', [identity]))
            profile_bytes = profile.read_bytes(); source_before = snapshot(source)
            source_client = Client(args.mcp_binary, profile); clients.append(source_client)
            handle = payload(source_client.call('list_documents', includeExcerpts=False))['items'][0]['document']
            plan = command(args.local_binary, 'storage-preview', '--store', source, '--format', 'sqlite')
            assert snapshot(source) == source_before
            denied(args.local_binary, 'storage-migrate', '--store', source, '--format', 'sqlite', '--to', root/'wrong', '--expected', '0'*64)
            assert not (root/'wrong').exists()
            started = time.perf_counter()
            result = command(args.local_binary, 'storage-migrate', '--store', source, '--format', 'sqlite', '--to', root/'migration', '--expected', plan['fingerprint'])
            duration = (time.perf_counter()-started)*1000
            assert result['verified'] and not result['profilesChanged']
            assert snapshot(source) == source_before and profile.read_bytes() == profile_bytes
            assert not (root/'migration/INCOMPLETE').exists()
            payload(source_client.call('read_document', document=handle))  # Existing grant/source remain valid.
            sqlite_profile = root/'sqlite-profile.json'; write_json(sqlite_profile, grant(Path(result['vaultPath']), [identity]))
            client = Client(args.mcp_binary, sqlite_profile); clients.append(client)
            hit = payload(client.call('search_documents', query='Fahrradwartung'))['hits'][0]
            read = payload(client.call('read_document', document=hit['document']))
            assert 'Erika Musterfrau' not in json.dumps(read) and 'erika@example.com' not in json.dumps(read)
            backup = Path(result['backupPath']); backup_bytes = snapshot(backup)
            restore_plan = command(args.local_binary, 'storage-preview', '--store', backup, '--format', 'same')
            restored = command(args.local_binary, 'storage-restore', '--store', backup, '--to', root/'restored', '--expected', restore_plan['fingerprint'])
            assert Path(restored['vaultPath']).read_bytes() == (source/'documents.json').read_bytes()
            assert snapshot(backup) == backup_bytes
            rollback_plan = command(args.local_binary, 'storage-preview', '--store', root/'migration/vault', '--format', 'json')
            rollback = command(args.local_binary, 'storage-migrate', '--store', root/'migration/vault', '--format', 'json', '--to', root/'rollback', '--expected', rollback_plan['fingerprint'])
            assert json.loads(Path(rollback['vaultPath']).read_text()) == records
            rollback_profile = root/'rollback-profile.json'; write_json(rollback_profile, grant(Path(rollback['vaultPath']), [identity]))
            returned = Client(args.mcp_binary, rollback_profile); clients.append(returned)
            assert payload(returned.call('search_documents', query='Fahrradwartung'))['hits']
            denied(args.local_binary, 'storage-migrate', '--store', source, '--format', 'sqlite', '--to', root/'migration', '--expected', plan['fingerprint'])
            # Restore never accepts a changed backup, including when the caller has its old preview.
            (backup/'documents.json').write_bytes(b'corrupt synthetic backup')
            denied(args.local_binary, 'storage-restore', '--store', backup, '--to', root/'bad-restore', '--expected', restore_plan['fingerprint'])
            assert not (root/'bad-restore').exists()
            assert pdf.read_bytes() == original and snapshot(source) == source_before and profile.read_bytes() == profile_bytes
            # Real process loss before publication. Extra content-addressed copies represent retained
            # synthetic historical originals; they are never OCR'd or granted.
            for index in range(32):
                data = b'SYNTHETIC R3C CRASH COPY\n' + bytes([index]) * (4 * 1024 * 1024)
                path = source/'originals'/(hashlib.sha256(data).hexdigest()+'.pdf')
                path.write_bytes(data); path.chmod(0o600)
            crash_before = snapshot(source)
            crash_plan = command(args.local_binary, 'storage-preview', '--store', source, '--format', 'sqlite')
            migration_process = subprocess.Popen([str(args.local_binary), 'storage-migrate', '--store', str(source),
                '--format', 'sqlite', '--to', str(root/'crash-result'), '--expected', crash_plan['fingerprint']],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 120; interrupted = None
            while migration_process.poll() is None:
                pending = list(root.glob('.vauldy-transfer-*/INCOMPLETE'))
                if pending:
                    interrupted = pending[0].parent
                    migration_process.kill(); migration_process.communicate(timeout=10); break
                assert time.monotonic() < deadline, 'migration staging timeout'
                time.sleep(.002)
            assert interrupted is not None and migration_process.returncode == -signal.SIGKILL
            assert not (root/'crash-result').exists() and (interrupted/'INCOMPLETE').exists()
            assert snapshot(source) == crash_before and profile.read_bytes() == profile_bytes
            denied(args.local_binary, 'status', '--store', interrupted/'vault')
            payload(source_client.call('read_document', document=handle))
            report = dict(documents=len(records), realNativeImport=True, activeWorkerRefused=True,
                previewReadOnly=True, stalePreviewRefused=True, originalSourceAndProfileByteUnchanged=True,
                previousMCPHandleStillValid=True, sqliteMCPSearchAndPrivacy=True, verifiedBackupRestore=True,
                jsonRollbackAndMCPSearch=True, existingDestinationRefused=True, corruptBackupRefused=True,
                noAutomaticProfileSwitch=True, sigkillBeforePublication=True, incompleteTargetRejected=True,
                sourceUsableAfterCrash=True, migrationMS=round(duration,3),
                localSHA256=hashlib.sha256(args.local_binary.read_bytes()).hexdigest(),
                mcpSHA256=hashlib.sha256(args.mcp_binary.read_bytes()).hexdigest())
            args.output.write_text(json.dumps(report,indent=2)+'\n'); print(json.dumps(report))
        finally:
            if migration_process and migration_process.poll() is None: migration_process.kill(); migration_process.communicate()
            for client in clients: client.close()
            if source.exists(): stop_worker(args.local_binary, source)


if __name__ == '__main__': main()
