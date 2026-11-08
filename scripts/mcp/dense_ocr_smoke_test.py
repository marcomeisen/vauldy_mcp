#!/usr/bin/env python3
"""Fresh dense synthetic PDF -> protected MCP -> evidence-preserving worker retry."""
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
    parser.add_argument('local', type=lambda p: Path(p).resolve())
    parser.add_argument('server', type=lambda p: Path(p).resolve())
    parser.add_argument('fixtures', type=lambda p: Path(p).resolve())
    args = parser.parse_args()
    original = args.fixtures / 'dense.pdf'
    digest = hashlib.sha256(original.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix='vauldy-dense-wire-') as temporary:
        root = Path(temporary); store = root / 'vault'; client = None
        try:
            result, = command(args.local, 'import', '--store', store, original)
            assert result['state'] == 'completed'
            doc_id = result['documentID']
            document, = json.loads((store / 'documents.json').read_text())
            coverage = document['localImport']['pages'][0]['layout']['geometry']['coverage']
            assert coverage['status'] == 'checked' and coverage['comparedRegions'] > 128
            assert len(coverage['regions']) <= 128
            assert coverage['totalDetectedCharacters'] == coverage['totalCoveredCharacters']
            expected = ['11,10 EUR', '22,20 EUR', '33,30 EUR', '44,40 EUR', '55,50 EUR', '110,00 EUR']
            assert all(value in document['ocrText'] for value in expected)
            profile = root / 'profile.json'
            grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                         connectionName='Synthetic dense page', enabled=True,
                         vaultPath=str(store / 'documents.json'), allowedDocumentIDs=[doc_id],
                         acknowledgedCloudDisclosure=True)
            profile.write_text(json.dumps(grant)); before_profile = profile.read_bytes()
            client = Client(args.server, profile)
            listed = payload(client.call('list_documents', includeExcerpts=False))
            assert listed['totalCount'] == 1
            handle = listed['items'][0]['document']
            read = payload(client.call('read_document', document=handle))
            assert read['containsEntireAvailableText'] and read['sourceCoverage'] == 'all-declared-pages-processed'
            assert all(segment['page'] == 1 and segment['source'] == f'[Quelle:{handle}:S.1]' for segment in read['segments'])
            text = '\n'.join(segment['text'] for segment in read['segments'])
            assert all(value in text for value in expected)
            assert all(secret not in json.dumps(read) for secret in [doc_id, str(root), 'geometry', 'totalDetectedCharacters', 'lineReview'])
            instance = command(args.local, 'worker-status', '--store', store)['instance']
            command(args.local, 'retry', '--store', store, '--document', doc_id, '--fresh')
            after, = json.loads((store / 'documents.json').read_text())
            assert after['ocrText'] == document['ocrText'] and after['id'] == document['id']
            assert not after['localImport']['pages'][0]['metrics']['cacheHit']
            assert command(args.local, 'worker-status', '--store', store)['instance'] == instance
            assert profile.read_bytes() == before_profile and hashlib.sha256(original.read_bytes()).hexdigest() == digest
            grant.update(enabled=False, revision=str(uuid.uuid4())); profile.write_text(json.dumps(grant))
            assert client.call('read_document', document=handle)['isError']
            print(json.dumps(dict(passed=True,syntheticPDFs=1,embeddedRows=140,exactRecoveredFields=5,
                                  comparedRegions=coverage['comparedRegions'],storedRegions=len(coverage['regions']),
                                  preservedDeductible=True,sourcePage=1,metadataRemainsLocal=True,
                                  sameWorkerFreshRetry=True,originalUnchanged=True,grantUnchanged=True,revocation=True)))
        finally:
            if client: client.close()
            if (store / 'store.json').exists(): stop_worker(args.local, store)


if __name__ == '__main__':
    main()
