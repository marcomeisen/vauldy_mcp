#!/usr/bin/env python3
"""Exercise index revocation and process death through real local MCP processes."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import signal
import tempfile
import time
import uuid

from smoke_test import Client, payload


def stop_during_write(client, directory, pending, pattern):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and not pending.done():
        if any(directory.glob(pattern)):
            client.process.send_signal(signal.SIGSTOP)
            _, status = os.waitpid(client.process.pid, os.WUNTRACED)
            assert os.WIFSTOPPED(status), 'Builder did not stop'
            assert any(directory.glob(pattern)), 'Write completed before stop'
            return
        time.sleep(0.001)
    raise AssertionError('No in-progress SQLite build observed')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=lambda value: Path(value).resolve())
    binary = parser.parse_args().binary
    with tempfile.TemporaryDirectory(prefix='vauldy-index-recovery-') as temp:
        root = Path(temp)
        vault, profile_path = root / 'documents.json', root / 'profile.json'
        records = [dict(id=str(uuid.uuid4()), title='Synthetischer Beleg', status='indexed',
                        pageCount=1, ocrText='--- Seite 1 ---\nSynthetischer Beleg ' + str(index))
                   for index in range(4000)]
        vault.write_text(json.dumps(records))
        archive = vault.read_bytes()
        profile = dict(version=1, connectionID=str(uuid.uuid4()), connectionName='Index recovery test',
                       vaultPath=str(vault), allowedDocumentIDs=[record['id'] for record in records],
                       acknowledgedCloudDisclosure=True)

        def save_grant(enabled):
            profile.update(enabled=enabled, revision=str(uuid.uuid4()))
            staging = root / 'profile.tmp'
            staging.write_text(json.dumps(profile))
            staging.replace(profile_path)

        def list_all(client):
            return client.call('list_documents', query='Beleg', includeExcerpts=False, pageSize=100)

        scratch = '.vauldy-index-*/.build-*'
        journal = '.vauldy-index-*/index-v1.sqlite-journal'
        for revoke in (True, False):
            save_grant(True)
            builder = Client(binary, profile_path, server_options=('--persistent-sqlite-index',))
            with ThreadPoolExecutor(max_workers=1) as executor:
                pending = executor.submit(list_all, builder)
                try:
                    stop_during_write(builder, root, pending, scratch)
                    if revoke:
                        save_grant(False)
                        observer = Client(binary, profile_path)
                        try:
                            assert payload(observer.call('get_vault_status'))['grantedDocumentCount'] == 0
                            assert list_all(observer)['isError']
                            assert not any(path.is_dir() for path in root.glob('.vauldy-index-*'))
                        finally:
                            observer.close()
                        builder.process.send_signal(signal.SIGCONT)
                        assert pending.result(timeout=15)['isError']
                        assert not any(path.is_dir() for path in root.glob('.vauldy-index-*'))
                    else:
                        builder.process.kill()
                        assert builder.process.wait(timeout=5) == -signal.SIGKILL
                        assert any(root.glob(scratch))
                finally:
                    # A failed assertion must also release a stopped process and unblock the reader.
                    if not pending.done() and builder.process.poll() is None:
                        builder.process.kill()
                        builder.process.wait(timeout=5)
                    builder.close()

        grant = profile_path.read_bytes()
        restarted = Client(binary, profile_path, server_options=('--persistent-sqlite-index',))
        try:
            assert payload(list_all(restarted))['totalCount'] == len(records)
            database, = root.glob('.vauldy-index-*/index-v1.sqlite')
            assert not any(root.glob(scratch))
            assert vault.read_bytes() == archive and profile_path.read_bytes() == grant
        finally:
            restarted.close()

        # Force an incremental update of a published database and kill it with its journal open.
        for record in records:
            record['ocrText'] += ' Korrektur'
        vault.write_text(json.dumps(records))
        archive = vault.read_bytes()
        builder = Client(binary, profile_path, server_options=('--persistent-sqlite-index',))
        with ThreadPoolExecutor(max_workers=1) as executor:
            pending = executor.submit(list_all, builder)
            try:
                stop_during_write(builder, root, pending, journal)
            finally:
                if builder.process.poll() is None:
                    builder.process.kill()
                assert builder.process.wait(timeout=5) == -signal.SIGKILL
                builder.close()
            assert any(root.glob(journal))

        restarted = Client(binary, profile_path, server_options=('--persistent-sqlite-index',))
        try:
            result = restarted.call('list_documents', query='Korrektur', includeExcerpts=False)
            assert payload(result)['totalCount'] == len(records)
            assert not any(root.glob(journal))
        finally:
            restarted.close()

        # Simulate a revoker that died after detaching its directory but before unlinking it.
        retired = database.parent.with_name(database.parent.name + '.retired-' + str(uuid.uuid4()))
        database.parent.rename(retired)
        restarted = Client(binary, profile_path, server_options=('--persistent-sqlite-index',))
        try:
            assert payload(list_all(restarted))['totalCount'] == len(records)
            assert database.is_file() and not retired.exists()
            assert vault.read_bytes() == archive and profile_path.read_bytes() == grant
        finally:
            restarted.close()
    print('PASS: stopped builder denied after revocation; SIGKILL scratch and journal recovered; detached cache cleaned; JSON and grant unchanged by recovery.')


if __name__ == '__main__':
    main()
