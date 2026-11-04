#!/usr/bin/env python3
"""Verify two release ZIPs and exercise A -> B -> A on an isolated macOS installation."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import subprocess
import tempfile
import uuid
from zipfile import ZipFile

from smoke_test import Client, payload

APP = 'Vauldy MCP Einrichtung.app'
PRODUCTS = ('vauldy-mcp', 'vauldy-local', 'vauldy-mcp-http', 'vauldy-relay')
TOOLS = {'get_vault_status', 'list_documents', 'search_documents', 'read_document'}


def require(condition, reason):
    if not condition:
        raise SystemExit(reason)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as data:
        for block in iter(lambda: data.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def run(*args, timeout=45):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    require(result.returncode == 0, f'{Path(args[0]).name} failed: {result.stderr.strip() or result.stdout.strip()}')
    return result.stdout


def require_offline():
    # Fail closed when the OS query is restricted or unavailable, even if stdout looks offline.
    result = subprocess.run(['/usr/sbin/scutil', '--nwi'], capture_output=True, text=True, timeout=10)
    require(result.returncode == 0 and not result.stderr.strip()
            and result.stdout.strip() == 'No network information',
            'macOS could not confirm a disconnected network. Use the isolated test Mac with networking disconnected.')


def extract_release(archive, expected, destination, team):
    require(re.fullmatch(r'[0-9a-fA-F]{64}', expected) and sha256(archive) == expected.lower(),
            'Release ZIP SHA-256 does not match the independently supplied value.')
    with ZipFile(archive) as zipped:
        entries = zipped.infolist()
        require(0 < len(entries) <= 2048 and sum(entry.file_size for entry in entries) <= 320 * 1024 * 1024,
                'Unexpected ZIP size or entry count.')
        for entry in entries:
            path = PurePosixPath(entry.filename)
            require(path.parts and path.parts[0] in (APP, '__MACOSX')
                    and '..' not in path.parts
                    and stat.S_IFMT(entry.external_attr >> 16) in (0, stat.S_IFREG, stat.S_IFDIR),
                    'Unexpected or unsafe entry in release ZIP.')
    destination.mkdir()
    run('/usr/bin/ditto', '-x', '-k', str(archive), str(destination))
    app = destination / APP
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', str(app))
    if team:
        requirement = (
            'anchor apple generic and identifier "com.marcomeisen.vauldy.mcp-setup" '
            'and certificate 1[field.1.2.840.113635.100.6.2.6] exists '
            'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists '
            f'and certificate leaf[subject.OU] = "{team}"'
        )
        run('/usr/bin/codesign', '--verify', '--strict', '-R=' + requirement, str(app))
        run('/usr/bin/syspolicy_check', 'distribution', str(app))
    resources = app / 'Contents/Resources'
    manifest = json.loads((resources / 'release.json').read_text())
    require(manifest['manifestVersion'] == 1 and platform.machine() in manifest['architectures'],
            'Unexpected release manifest or unsupported test Mac architecture.')
    require(re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', manifest['productVersion']),
            'Release version must be a numeric major.minor.patch.')
    if team:
        require(manifest.get('buildMode') == 'release'
                and re.fullmatch(r'[0-9a-f]{40}', manifest.get('sourceCommit') or ''),
                'Customer release requires a fresh build from an identified clean commit.')
    return app, manifest


def seed(root):
    connection = str(uuid.uuid4())
    profile = root / 'connections' / connection / 'profile.json'
    profile.parent.mkdir(parents=True)
    vault = root / 'synthetic-vault.json'
    records = [
        dict(id=str(uuid.uuid4()), title='Fiktiver Beleg', status='indexed', pageCount=1,
             ocrText=f'--- Seite 1 ---\n{topic} dokumentiert.')
        for topic in ('Fahrradwartung', 'Heizungswartung')
    ]
    vault.write_text(json.dumps(records))
    profile.write_text(json.dumps(dict(version=1, revision=str(uuid.uuid4()), connectionID=connection,
                                       connectionName='Synthetic release acceptance', enabled=True,
                                       allowedDocumentIDs=[record['id'] for record in records],
                                       acknowledgedCloudDisclosure=True, vaultPath=str(vault))))
    for name in ('synthetic-original.txt', 'synthetic-snapshot.backup', 'synthetic-client.toml',
                 'synthetic-device.json'):
        (root / name).write_text('Synthetic acceptance fixture: ' + name)
    return profile


def fixture_fingerprints(root):
    # Includes audit files already written by the preceding stdio verification.
    paths = list(root.glob('synthetic-*')) + list((root / 'connections').rglob('*'))
    return {path.relative_to(root): sha256(path) for path in paths if path.is_file()}


def verify_active(root, profile, app, version):
    binary = root / 'bin/vauldy-mcp'
    bundled = app / 'Contents/Resources'
    for product in PRODUCTS:
        require(sha256(root / 'bin' / product) == sha256(bundled / product), 'Active program bytes differ from the release.')
    installed_manifest = root / 'bin' / APP / 'Contents/Resources/release.json'
    require(sha256(installed_manifest) == sha256(bundled / 'release.json'), 'Active setup bundle differs from the release.')
    client = Client(binary, profile)
    try:
        require(client.initialization['serverInfo']['version'] == version, 'Unexpected active MCP version.')
        tools = client.request('tools/list', {})['tools']
        require(len(tools) == 4 and {tool['name'] for tool in tools} == TOOLS, 'Unexpected MCP tool contract.')
        require(payload(client.call('get_vault_status'))['grantedDocumentCount'] == 2, 'Unexpected synthetic grant count.')
        first = payload(client.call('list_documents', pageSize=1, includeExcerpts=False))
        require(first.get('nextCursor') and len(first['items']) == 1, 'Expected a continuation cursor.')
        second = payload(client.call('list_documents', cursor=first['nextCursor']))
        require(second['retrievalComplete'] and not second.get('nextCursor') and len(second['items']) == 1,
                'Continuation did not complete the inventory.')
        items = first['items'] + second['items']
        require(len({item['document'] for item in items}) == 2, 'Duplicate handle in the inventory.')
        texts = [payload(client.call('read_document', document=item['document'])) for item in items]
        segments = [segment for result in texts for segment in result['segments']]
        require({segment['text'].strip() for segment in segments} == {'Fahrradwartung dokumentiert.', 'Heizungswartung dokumentiert.'}
                and all(segment['page'] == 1 for segment in segments),
                'Unexpected text or physical source page after software change.')
    finally:
        client.close()


def exercise(root, baseline, candidate, version_a, version_b, customer):
    profile = seed(root)
    local = root / 'bin/vauldy-local'
    opt_in = [] if customer else ['--allow-ad-hoc']
    steps = [
        (baseline / 'Contents/Resources/vauldy-local', 'update-software', baseline, version_a, 'updated'),
        (local, 'update-software', candidate, version_b, 'updated'),
        (local, 'rollback-software', baseline, version_a, 'rolledBack'),
    ]
    for executable, command, release, version, result in steps:
        if customer:
            require_offline()
        before = fixture_fingerprints(root)
        source = ['--from-app', str(release)] if command == 'update-software' else []
        outcome = json.loads(run(str(executable), command, '--root', str(root), *source, *opt_in))
        require(outcome == {result: True, 'version': version, 'clientRestartRequired': True},
                'Unexpected updater response.')
        require(fixture_fingerprints(root) == before, 'Software operation modified a synthetic fixture or its audit.')
        verify_active(root, profile, release, version)
    if customer:
        require_offline()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--sha-a', required=True)
    parser.add_argument('--sha-b', required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--team-id', help='Expected Developer ID Apple Team ID')
    mode.add_argument('--local-ad-hoc', action='store_true', help='Internal rehearsal only, without customer gates')
    parser.add_argument('--fresh-test-mac', action='store_true', help='Operator attests a clean dedicated Mac with network disconnected')
    args = parser.parse_args()

    require(__debug__, 'Run the smoke test with Python assertions enabled.')
    customer = args.team_id is not None
    if customer:
        require(re.fullmatch(r'[A-Z0-9]{10}', args.team_id) and args.fresh_test_mac,
                'Customer mode requires an Apple Team ID and confirmation of a fresh offline test Mac.')
        require_offline()
    elif args.fresh_test_mac:
        parser.error('--fresh-test-mac applies only to Developer ID customer mode.')

    with tempfile.TemporaryDirectory(prefix='vauldy-customer-acceptance-') as temporary:
        root = Path(temporary)
        baseline, first = extract_release(args.baseline, args.sha_a, root / 'baseline', args.team_id)
        candidate, second = extract_release(args.candidate, args.sha_b, root / 'candidate', args.team_id)
        version_a, version_b = first['productVersion'], second['productVersion']
        require(tuple(map(int, version_a.split('.'))) < tuple(map(int, version_b.split('.')))
                and first['softwareCompatibilityEpoch'] == second['softwareCompatibilityEpoch'],
                'Use an ascending version pair with the same software compatibility epoch.')
        if customer:
            require(first['sourceCommit'] != second['sourceCommit'], 'Use two distinct release commits.')
        exercise(root / 'install', baseline, candidate, version_a, version_b, customer)

    print(json.dumps(dict(
        mode='offline-developer-id' if customer else 'local-ad-hoc-rehearsal',
        versions=[version_a, version_b, version_a],
        macOS=platform.mac_ver()[0], architecture=platform.machine(),
        stdio=True, syntheticFixturesUnchangedBySoftwareOperations=True,
    ), sort_keys=True))


if __name__ == '__main__':
    main()
