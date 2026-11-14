#!/usr/bin/env python3
"""Re-read the frozen policy scan in an isolated vault created by v18."""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import uuid

from import_smoke_test import command, stop_worker
from smoke_test import Client, payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('baseline', 'local', 'server', 'image'):
        parser.add_argument(name, type=lambda value: Path(value).resolve())
    args = parser.parse_args()
    manifest = Path(__file__).resolve().parents[2] / 'Tests/VauldyMCPRuntimeTests/Fixtures/faint-line-corpus.json'
    original = args.image.read_bytes()
    assert hashlib.sha256(original).hexdigest() == json.loads(manifest.read_text())['sha256']['ambiguous.png']
    wrong, correct = 'Policennummer: 1000-171', 'Policennummer: IO0O-171'
    with tempfile.TemporaryDirectory(prefix='vauldy-policy-repair-') as temporary:
        root = Path(temporary)
        store = root / 'vault'
        profile = root / 'profile.json'

        def document():
            result, = json.loads((store / 'documents.json').read_text())
            return result

        active = args.baseline
        client = None
        try:
            command(active, 'import', '--store', store, args.image, accepted=(0, 2))
            before = document()
            identifier = before['id']
            assert wrong in before['ocrText'] and correct not in before['ocrText']
            stop_worker(active, store)
            active = args.local
            grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                         connectionName='Synthetic policy repair', enabled=True,
                         vaultPath=str(store / 'documents.json'), allowedDocumentIDs=[identifier],
                         acknowledgedCloudDisclosure=True)
            profile.write_text(json.dumps(grant))
            original_grant = profile.read_bytes()

            for _ in range(2):
                command(active, 'retry', '--store', store, '--document', identifier, '--fresh', accepted=(0, 2))
                after = document()
                info, = after['localImport']['pages']
                assert after['ocrText'] == before['ocrText'].replace(wrong, correct)
                assert after['id'] == identifier
                assert after['localImport']['contentHash'] == before['localImport']['contentHash']
                assert info['needsReview'] and not info['metrics']['cacheHit']
                assert any(line.get('policyIdentifierRepair') and wrong in line.get('priorReadings', [])
                           for line in info['layout']['geometry']['lines'])
                assert profile.read_bytes() == original_grant and args.image.read_bytes() == original

            stop_worker(active, store)
            assert document()['localImport']['pages'][0]['layout'] == info['layout']
            client = Client(args.server, profile)
            listed = payload(client.call('list_documents', includeExcerpts=False))
            assert listed['totalCount'] == 1
            handle = listed['items'][0]['document']
            read = payload(client.call('read_document', document=handle))
            fields = payload(client.call('extract_document_fields', documents=[handle], fields=['contractNumber']))
            assert any(segment['page'] == 1 and 'Beitrag: 81,19 EUR' in segment['text'] for segment in read['segments'])
            wire = json.dumps([read, fields])
            assert all(item not in wire for item in ('IO0O-171', '1000-171', 'priorReadings',
                                                     'policyIdentifierRepair', str(root), identifier))
            grant.update(enabled=False, revision=str(uuid.uuid4()))
            profile.write_text(json.dumps(grant))
            assert client.call('read_document', document=handle)['isError']
            print(json.dumps(dict(passed=True, freshRetries=2, policyCorrected=True, priorReadingPreserved=True,
                                  otherTextUnchanged=True, originalAndGrantPreserved=True,
                                  textAndFieldProtected=True, revocation=True)))
        finally:
            if client:
                client.close()
            if (store / 'store.json').exists():
                stop_worker(active, store)


if __name__ == '__main__':
    main()
