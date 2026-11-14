#!/usr/bin/env python3
"""Synthetic native lines through worker, persisted reasons, protected MCP and revocation."""
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
    parser.add_argument('local', type=lambda v: Path(v).resolve())
    parser.add_argument('server', type=lambda v: Path(v).resolve())
    parser.add_argument('fixtures', type=lambda v: Path(v).resolve())
    args = parser.parse_args()
    configuration = json.loads((args.fixtures / 'clean.json').read_text())['geometry']['configuration']
    expected = {
        'clean': ['Vertragsnummer: VX-739245', 'Beitrag: 82,47 EUR', 'Versicherungsart: Hausrat'],
        'faint-words': ['Schutz fuer Fahrrad und Hausrat', 'Beitrag: 49,99 EUR'],
        'ambiguous': ['Policennummer: IO0O-171', 'Beitrag: 81,19 EUR'],
    }
    with tempfile.TemporaryDirectory(prefix='vauldy-line-wire-') as temporary:
        root = Path(temporary); store = root / 'vault'; client = None; instance = None
        try:
            for name, fields in expected.items():
                source = args.fixtures / (name + '.png')
                original = hashlib.sha256(source.read_bytes()).hexdigest()
                result, = command(args.local, 'import', '--store', store, source, accepted=(0, 2))
                doc_id = result['documentID']
                document = next(d for d in json.loads((store / 'documents.json').read_text()) if d['id'] == doc_id)
                info = document['localImport']['pages'][0]
                assessment = info['metrics']['lineReview']
                assert all(field in document['ocrText'] for field in fields)
                assert info['layout']['geometry']['configuration'] == configuration
                if name == 'ambiguous':
                    assert result['state'] == 'partial' and info['needsReview']
                    assert assessment['ambiguousIdentifiers'] > 0 and assessment['unconfirmedLines'] > 0
                    lines = info['layout']['geometry']['lines']
                    assert any(line.get('policyIdentifierRepair') and
                               'Policennummer: 1000-171' in line.get('priorReadings', []) for line in lines)
                current = command(args.local, 'worker-status', '--store', store)['instance']
                if instance is None: instance = current
                assert current == instance
                profile = root / (name + '-profile.json')
                grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                             connectionName='Synthetic line review', enabled=True,
                             vaultPath=str(store / 'documents.json'), allowedDocumentIDs=[doc_id],
                             acknowledgedCloudDisclosure=True)
                profile.write_text(json.dumps(grant)); before_profile = profile.read_bytes()
                client = Client(args.server, profile)
                status = payload(client.call('get_vault_status'))
                assert status['grantedDocumentCount'] == status['searchableDocumentCount'] == 1
                assert status['coverage']['reviewDocumentCount'] == int(name == 'ambiguous')
                listed = payload(client.call('list_documents', includeExcerpts=False))
                assert listed['totalCount'] == 1
                handle = listed['items'][0]['document']
                read = payload(client.call('read_document', document=handle))
                text = '\n'.join(segment['text'] for segment in read['segments'])
                public_fields = fields[1:] if name in ('clean', 'ambiguous') else fields
                if name == 'faint-words':
                    # Existing local NER can protect "Schutz" as a place name.
                    # Assert full native text above and the unmasked source suffix here.
                    public_fields = ['fuer Fahrrad und Hausrat', 'Beitrag: 49,99 EUR']
                assert all(field in text for field in public_fields)
                assert 'VX-739245' not in text
                assert 'IO0O-171' not in text and '1000-171' not in text
                assert all(segment['page'] == 1 for segment in read['segments'])
                assert all(value not in json.dumps(read) for value in
                           ['lineReview', 'unconfirmedLines', 'normalizedCrops', 'policyIdentifierRepair', 'priorReadings', str(root), doc_id])
                command(args.local, 'retry', '--store', store, '--document', doc_id, '--fresh', accepted=(0, 2))
                repeated = next(d for d in json.loads((store / 'documents.json').read_text()) if d['id'] == doc_id)
                assert repeated['ocrText'] == document['ocrText']
                assert repeated['localImport']['pages'][0]['needsReview'] == info['needsReview']
                assert repeated['localImport']['pages'][0]['metrics']['lineReview'] == assessment
                assert hashlib.sha256(source.read_bytes()).hexdigest() == original
                assert profile.read_bytes() == before_profile
                grant.update(enabled=False, revision=str(uuid.uuid4())); profile.write_text(json.dumps(grant))
                assert client.call('read_document', document=handle)['isError']
                client.close(); client = None
            print(json.dumps(dict(passed=True, syntheticImages=3, nativeExactFields=7,
                                  protectedVerifiedExcerpts=5, contractIdentifierRedacted=True,
                                  policyIdentifierCorrectedAndRedacted=True,
                                  ambiguousIdentifierRemainsReview=True, persistedReasons=True,
                                  sameWorker=True, freshRetryPreservesEvidence=True, repeatReasonsStable=True,
                                  originalAndGrantUnchanged=True, sourcePage=1,
                                  diagnosticsRemainLocal=True, revocations=3)))
        finally:
            if client: client.close()
            if (store / 'store.json').exists(): stop_worker(args.local, store)


if __name__ == '__main__':
    main()
