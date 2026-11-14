#!/usr/bin/env python3
"""Actual old worker -> fresh new worker -> persistent review -> protected MCP.

Only the frozen synthetic tilted image is accepted. No production vault is used.
"""
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
    for name in ['baseline_local', 'local', 'server', 'image']:
        parser.add_argument(name, type=lambda v: Path(v).resolve())
    args = parser.parse_args()
    manifest = json.loads((Path(__file__).resolve().parents[2] /
        'Tests/VauldyMCPRuntimeTests/Fixtures/faint-line-corpus.json').read_text())
    assert args.image.name == 'tilted-9-right.png'
    original = args.image.read_bytes()
    assert hashlib.sha256(original).hexdigest() == manifest['sha256'][args.image.name]
    with tempfile.TemporaryDirectory(prefix='vauldy-repair-wire-') as temporary:
        root = Path(temporary); store = root / 'vault'; profile = root / 'profile.json'; client = None
        try:
            outcome, = command(args.baseline_local, 'import', '--store', store, args.image, accepted=(0, 2))
            def document():
                result, = json.loads((store / 'documents.json').read_text()); return result
            before = document(); identifier = before['id']
            assert any(word in before['ocrText'] for word in ['Zahnriemerwechsel', 'Zahnriemenwechsel'])
            assert '82.47 EUR' in before['ocrText']
            old_instance = command(args.baseline_local, 'worker-status', '--store', store)['instance']
            stop_worker(args.baseline_local, store)
            grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                         connectionName='Synthetic OCR repair', enabled=True, vaultPath=str(store / 'documents.json'),
                         allowedDocumentIDs=[identifier], acknowledgedCloudDisclosure=True)
            profile.write_text(json.dumps(grant)); profile_bytes = profile.read_bytes()
            for _ in range(2):
                command(args.local, 'retry', '--store', store, '--document', identifier, '--fresh', accepted=(0, 2))
                after = document(); info, = after['localImport']['pages']
                assert after['id'] == identifier and after['localImport']['contentHash'] == before['localImport']['contentHash']
                assert 'Leistung: Zahnriemenwechsel am Aggregat' in after['ocrText']
                assert 'Geltungsbereich: Fahrradzubehoer und Kleingeraete' in after['ocrText']
                assert 'Beitrag: 82,47 EUR' in after['ocrText'] and '82.47 EUR' not in after['ocrText']
                assert info['needsReview'] and not info['metrics']['cacheHit']
                history = [s for line in info['layout']['geometry']['lines'] for s in line.get('priorReadings', [])]
                if 'Zahnriemerwechsel' in before['ocrText']:
                    assert 'Leistung: Zahnriemerwechsel am Aggregat' in history
                assert 'Beitrag: 82.47 EUR' in history
                assert any(line.get('sourceRepair') == 'decimalSeparator' for line in info['layout']['geometry']['lines'])
                assert profile.read_bytes() == profile_bytes and args.image.read_bytes() == original
            assert command(args.local, 'worker-status', '--store', store)['instance'] != old_instance
            stop_worker(args.local, store)
            assert document()['localImport']['pages'][0]['layout'] == info['layout']
            client = Client(args.server, profile)
            listed = payload(client.call('list_documents', includeExcerpts=False))
            assert listed['totalCount'] == 1
            handle = listed['items'][0]['document']
            read = payload(client.call('read_document', document=handle))
            text = '\n'.join(segment['text'] for segment in read['segments'])
            assert 'Zahnriemenwechsel' in text and '82,47 EUR' in text
            wire = json.dumps(read)
            assert 'Zahnriemerwechsel' not in wire and '82.47 EUR' not in wire and 'priorReadings' not in wire
            assert 'sourceRepair' not in wire
            assert str(root) not in wire and identifier not in wire
            assert all(segment['page'] == 1 for segment in read['segments'])
            assert payload(client.call('get_vault_status'))['coverage']['reviewDocumentCount'] == 1
            grant['enabled'] = False; grant['revision'] = str(uuid.uuid4()); profile.write_text(json.dumps(grant))
            assert client.call('read_document', document=handle)['isError']
            print(json.dumps(dict(passed=True, realBaselineWorker=True, freshRetries=2,
                                  correctedWord=True, correctedDecimalSeparator=True, unchangedDigits=True, priorReadingPersisted=True,
                                  originalAndIdentityPreserved=True, grantsPreserved=True,
                                  localHistoryNotExposed=True, reviewVisible=True, revocation=True)))
        finally:
            if client: client.close()
            if (store / 'store.json').exists(): stop_worker(args.local, store)


if __name__ == '__main__': main()
