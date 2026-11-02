#!/usr/bin/env python3
"""Real installed MCP processes + menu companion. Synthetic profile; never edit host configurations."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid
from import_smoke_test import command
from smoke_test import Client, payload


def wait_for(check):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.1)
    raise AssertionError('Process status did not reach expected state')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local_binary', type=Path)
    parser.add_argument('mcp_binary', type=Path)
    parser.add_argument('status_app', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='vauldy-status-wire-') as temp:
        root = Path(temp).resolve(); binary_dir = root/'bin'; binary_dir.mkdir()
        local = binary_dir/'vauldy-local'; server = binary_dir/'vauldy-mcp'
        shutil.copy2(args.local_binary.resolve(), local); shutil.copy2(args.mcp_binary.resolve(), server)
        companion = binary_dir/'Vauldy MCP Status.app'
        shutil.copytree(args.status_app.resolve(), companion)
        status_binary = companion/'Contents/MacOS/vauldy-mcp-status'
        connection_id = str(uuid.uuid4())
        profile_file = root/'connections'/connection_id/'profile.json'
        profile_file.parent.mkdir(parents=True)
        document_id = str(uuid.uuid4()); vault = root/'documents.json'
        vault.write_text(json.dumps([dict(id=document_id, title='Synthetic status fixture', status='indexed',
                                        pageCount=1, ocrText='--- Seite 1 ---\nFahrradwartung 49,99 EUR')]))
        profile_file.write_text(json.dumps(dict(version=1, revision=str(uuid.uuid4()), connectionID=connection_id,
            connectionName='Status test', enabled=True, vaultPath=str(vault), allowedDocumentIDs=[document_id],
            acknowledgedCloudDisclosure=True)))
        original = vault.read_bytes(); grant = profile_file.read_bytes()
        def status():
            return command(local, 'mcp-status', '--root', root)
        assert status() == dict(runningServerCount=0, statusMenuRunning=False)
        assert not (root/'runtime-status').exists(), 'Reading status must not create markers'
        first = None; second = None
        try:
            # The installed server automatically starts the menu observer.
            first = Client(server, profile_file)
            wait_for(lambda: status() == dict(runningServerCount=1, statusMenuRunning=True))
            assert payload(first.call('get_vault_status'))['grantedDocumentCount'] == 1
            assert command(local, 'status-menu', '--root', root)['launched'] is False
            # A direct duplicate companion exits without creating a second menu item.
            subprocess.run([str(status_binary), '--root', str(root)], check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            second = Client(server, profile_file)
            wait_for(lambda: status()['runningServerCount'] == 2)
            first.close(); first = None
            wait_for(lambda: status()['runningServerCount'] == 1)
            # A hard kill leaves a marker but releases the kernel lease immediately.
            second.process.kill(); second.process.wait(timeout=5); second.close(); second = None
            wait_for(lambda: status()['runningServerCount'] == 0)
            assert status()['statusMenuRunning'], 'Menu must remain after the final server exits'
            assert vault.read_bytes() == original and profile_file.read_bytes() == grant
            # Stop only this root's observer, without guessing a PID from a stale file.
            command(local, 'status-menu-stop', '--root', root)
            wait_for(lambda: not status()['statusMenuRunning'])
            print('PASS: automatic menu launch, singleton across clients, 0/1/2 process counts, normal exit, SIGKILL, retained offline menu and unchanged grants/stdout.')
        finally:
            if first: first.close()
            if second: second.close()
            if status()['statusMenuRunning']:
                command(local, 'status-menu-stop', '--root', root)
                wait_for(lambda: not status()['statusMenuRunning'])


if __name__ == '__main__':
    main()
