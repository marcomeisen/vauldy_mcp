#!/usr/bin/env python3
"""Real packaged updater and rollback, with signed synthetic crash fixtures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

from smoke_test import Client, payload


def sign(path, identifier=None):
    command = ['codesign', '--force', '--sign', '-']
    if identifier:
        command += ['--identifier', identifier]
    subprocess.run(command + [str(path)], check=True, capture_output=True)


def resources(app):
    return app / 'Contents/Resources'


def copy_release(source, parent, label):
    app = parent / f'{label}.app'
    shutil.copytree(source, app)
    (resources(app) / 'update-test-label.txt').write_text(label)
    return app


def adjust_release(app, **fields):
    manifest = resources(app) / 'release.json'
    value = json.loads(manifest.read_text())
    value.update(fields)
    manifest.write_text(json.dumps(value))
    if 'productVersion' in fields:
        status = resources(app) / 'Vauldy MCP Status.app'
        for bundle in (app, status):
            info = bundle / 'Contents/Info.plist'
            metadata = plistlib.loads(info.read_bytes())
            metadata['CFBundleShortVersionString'] = fields['productVersion']
            info.write_bytes(plistlib.dumps(metadata))
        sign(status)
    sign(app)


def probe_fixture(app, real_server, root):
    # Executable fixture starts real MCP except at an explicitly selected fault point.
    c_file = root / 'probe-fixture.c'
    c_file.write_text(r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *mode = getenv("VAULDY_TEST_UPDATE_MODE");
    const int active = strstr(argv[0], "/bin/vauldy-mcp") != NULL;
    if (mode && active && strcmp(mode, "fail-after") == 0) return 64;
    if (mode && ((!active && strcmp(mode, "crash-before") == 0)
                 || (active && strcmp(mode, "crash-after") == 0))) {
        FILE *ready = fopen(getenv("VAULDY_TEST_UPDATE_MARKER"), "w");
        if (!ready) return 65;
        fclose(ready);
        for (int n = 0; n < 120 && getppid() != 1; n++) usleep(100000);
        return 66;
    }
    execv(REAL_SERVER, argv);
    return 67;
}
''')
    server = resources(app) / 'vauldy-mcp'
    server.unlink()
    subprocess.run(['xcrun', 'clang', '-mmacosx-version-min=14.0',
                    '-DREAL_SERVER=' + json.dumps(str(real_server)), str(c_file), '-o', str(server)], check=True)
    sign(server)
    # Fault-injection launcher execs a different image. It deliberately models a legacy
    # manifest without a build declaration, not a new self-identifying package.
    manifest = resources(app) / 'release.json'
    metadata = json.loads(manifest.read_text())
    metadata.pop('serverBuildID', None); metadata.pop('tools', None)
    manifest.write_text(json.dumps(metadata))
    sign(app)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=lambda value: Path(value).resolve())
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix='vauldy-update-wire-') as temporary:
        temp = Path(temporary).resolve()
        root = temp / 'install'
        installed = root / 'bin'
        installed.mkdir(parents=True)
        app = installed / 'Vauldy MCP Einrichtung.app'
        original = args.app
        local = resources(original) / 'vauldy-local'
        server = installed / 'vauldy-mcp'
        original_server = resources(original) / 'vauldy-mcp'
        shutil.copy2(original_server, server)
        shutil.copy2(local, installed / 'vauldy-local')
        tunnel = installed / 'tunnel-client'
        tunnel.write_bytes(b'synthetic adjacent helper')
        tunnel.chmod(0o700)
        legacy_backup = installed / 'vauldy-mcp.before-init-compatibility-20261101'
        legacy_backup.write_bytes(b'synthetic legacy server backup')
        legacy_backup.chmod(0o700)
        (installed / '.DS_Store').write_bytes(b'synthetic Finder metadata')
        original_bin_inode = installed.stat().st_ino
        version = json.loads((resources(original) / 'release.json').read_text())['productVersion']
        (root / 'software.json').write_text(json.dumps(dict(
            version=version, serverHash=hashlib.sha256(server.read_bytes()).hexdigest())))

        connection, document = str(uuid.uuid4()), str(uuid.uuid4())
        profile = root / 'connections' / connection / 'profile.json'
        profile.parent.mkdir(parents=True)
        vault = root / 'documents.json'
        vault.write_text(json.dumps([dict(id=document, title='Fixture', status='indexed', pageCount=1,
                                          ocrText='--- Seite 1 ---\nNur synthetischer Bestand')]))
        profile.write_text(json.dumps(dict(version=1, revision=str(uuid.uuid4()), connectionID=connection,
                                          connectionName='Synthetic update profile', enabled=True,
                                          allowedDocumentIDs=[document], acknowledgedCloudDisclosure=True,
                                          vaultPath=str(vault))))
        untouched = [profile, vault, root / 'software.json', legacy_backup]
        for name in ['client.toml', 'original.pdf', 'snapshot.backup', 'synthetic-device.json',
                     'connections/' + connection + '/logs/audit.jsonl']:
            fixture = root / name
            fixture.parent.mkdir(parents=True, exist_ok=True)
            fixture.write_bytes(('untouched fixture ' + name).encode())
            untouched.append(fixture)
        expected = {path: path.read_bytes() for path in untouched}

        def command(candidate=None, *, ad_hoc=True):
            action = 'update-software' if candidate else 'rollback-software'
            argv = [str(local), action, '--root', str(root)]
            if candidate:
                argv += ['--from-app', str(candidate)]
            if ad_hoc:
                argv += ['--allow-ad-hoc']
            return argv

        def run(candidate=None, *, failure=None, ad_hoc=True, env=None):
            result = subprocess.run(command(candidate, ad_hoc=ad_hoc), capture_output=True, text=True,
                                    timeout=40, env=env)
            if failure:
                assert result.returncode != 0 and failure in result.stderr, result
                return None
            assert result.returncode == 0, result.stderr
            response = json.loads(result.stdout)
            assert response == {('updated' if candidate else 'rolledBack'): True,
                                'version': version, 'clientRestartRequired': True}, response
            return response

        def interrupt(candidate, phase):
            marker = temp / phase
            mode = dict(os.environ, VAULDY_TEST_UPDATE_MODE=phase, VAULDY_TEST_UPDATE_MARKER=str(marker))
            with subprocess.Popen(command(candidate), env=mode, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL) as process:
                try:
                    deadline = time.monotonic() + 20
                    while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.03)
                    assert marker.exists(), f'Candidate never reached {phase}'
                finally:
                    if process.poll() is None:
                        process.send_signal(signal.SIGKILL)
                assert process.wait(timeout=5) == -signal.SIGKILL

        def slots():
            return list(root.glob('.software-slot-*'))

        def assert_preserved():
            assert all(path.read_bytes() == value for path, value in expected.items())
            assert tunnel.read_bytes() == b'synthetic adjacent helper' and tunnel.stat().st_mode & 0o777 == 0o700

        run(original, ad_hoc=False, failure='Signatur')
        assert installed.stat().st_ino == original_bin_inode
        run(original)
        assert legacy_backup.read_bytes() == expected[legacy_backup]
        assert legacy_backup.stat().st_mode & 0o777 == 0o700
        metadata = installed / '.DS_Store'
        assert not metadata.exists()
        unknown = installed / 'unexpected-program'
        unknown.write_bytes(b'synthetic unknown entry')
        run(original, failure='fremde oder unsichere Einträge')
        assert unknown.read_bytes() == b'synthetic unknown entry'
        unknown.unlink()
        metadata.symlink_to(legacy_backup)
        run(original, failure='fremde oder unsichere Einträge')
        assert metadata.is_symlink()
        metadata.unlink()
        metadata.write_bytes(b'synthetic Finder metadata')
        state_file = installed / '.vauldy-generation.json'
        baseline_state = state_file.read_bytes()
        baseline_inode = installed.stat().st_ino
        assert baseline_inode != original_bin_inode and app.is_dir()
        run(original)
        assert installed.stat().st_ino == baseline_inode and not slots()
        run(failure='keine geprüfte Vorversion')

        tampered = copy_release(original, temp, 'tampered')
        sign(tampered)
        (resources(tampered) / 'update-test-label.txt').write_text('tampered after signing')
        run(tampered, failure='Signatur')
        incompatible = copy_release(original, temp, 'incompatible')
        adjust_release(incompatible, softwareCompatibilityEpoch=999)
        run(incompatible, failure='passt nicht')
        wrong_build = copy_release(original, temp, 'wrong-build')
        adjust_release(wrong_build, serverBuildID='macho.' + '0' * 32)
        run(wrong_build, failure='passt nicht')
        wrong_tools = copy_release(original, temp, 'wrong-tools')
        adjust_release(wrong_tools, tools=['get_vault_status', 'list_documents', 'read_document', 'search_documents'])
        run(wrong_tools, failure='Startprüfung')
        assert state_file.read_bytes() == baseline_state
        assert_preserved()
        older = copy_release(original, temp, 'older')
        adjust_release(older, productVersion='0.0.1')
        run(older, failure='ältere Version')

        fault = copy_release(original, temp, 'fault')
        probe_fixture(fault, original_server, temp)
        mode = dict(os.environ, VAULDY_TEST_UPDATE_MODE='fail-after')
        run(fault, failure='Startprüfung', env=mode)
        assert installed.stat().st_ino == baseline_inode and state_file.read_bytes() == baseline_state and not slots()
        assert server.read_bytes() == original_server.read_bytes()
        assert_preserved()

        interrupt(fault, 'crash-before')
        assert slots() and state_file.read_bytes() == baseline_state
        assert installed.stat().st_ino == baseline_inode
        run(failure='keine geprüfte Vorversion')
        run(original)
        assert not slots()

        interrupt(fault, 'crash-after')
        assert installed.stat().st_ino != baseline_inode
        assert (resources(app) / 'update-test-label.txt').read_text() == 'fault'
        assert len(slots()) == 1
        assert_preserved()
        run()
        assert installed.stat().st_ino == baseline_inode and not slots()
        assert state_file.read_bytes() == baseline_state

        updated = copy_release(original, temp, 'updated')
        new_server = resources(updated) / 'vauldy-mcp'
        sign(new_server, 'com.marcomeisen.vauldy.mcp-fixture-update')
        sign(updated)
        assert new_server.read_bytes() != original_server.read_bytes()
        with subprocess.Popen(command(updated), stdout=subprocess.PIPE, stderr=subprocess.PIPE) as first:
            run(updated)
            stdout, stderr = first.communicate(timeout=40)
            assert first.returncode == 0 and json.loads(stdout)['updated'], stderr
        assert (resources(app) / 'update-test-label.txt').read_text() == 'updated'
        assert server.read_bytes() == new_server.read_bytes()
        assert len(slots()) == 1 and state_file.read_bytes() != baseline_state
        assert_preserved()

        tunnel.write_bytes(b'a changed adjacent helper')
        run(failure='Begleitdateien')
        assert tunnel.read_bytes() == b'a changed adjacent helper'
        assert server.read_bytes() == new_server.read_bytes()
        tunnel.write_bytes(b'synthetic adjacent helper')

        legacy_backup.write_bytes(b'changed legacy server backup')
        run(failure='Begleitdateien')
        assert legacy_backup.read_bytes() == b'changed legacy server backup'
        legacy_backup.write_bytes(expected[legacy_backup])

        retained_server = slots()[0] / 'vauldy-mcp'
        retained_server.write_bytes(b'broken retained executable')
        run(failure='Signatur')
        assert server.read_bytes() == new_server.read_bytes()
        retained_server.write_bytes(original_server.read_bytes())

        run()
        assert installed.stat().st_ino == baseline_inode
        assert state_file.read_bytes() == baseline_state and not slots()
        assert server.read_bytes() == original_server.read_bytes()
        run(failure='keine geprüfte Vorversion')
        assert_preserved()

        # Exercise the stable client path after rollback using a second synthetic profile
        # so the production-like audit sentinel is never opened by a server.
        live = temp / 'wire-profile.json'
        live.write_bytes(profile.read_bytes())
        client = Client(server, live)
        try:
            assert payload(client.call('get_vault_status'))['grantedDocumentCount'] == 1
            item = payload(client.call('list_documents'))['items'][0]
            assert 'synthetischer Bestand' in json.dumps(payload(client.call('read_document', document=item['document'])))
        finally:
            client.close()
        assert_preserved()
    print('PASS: signed update, authentication and compatibility gates, failed-start recovery, SIGKILL, concurrent update, verified rollback and real stdio.')


if __name__ == '__main__':
    main()
