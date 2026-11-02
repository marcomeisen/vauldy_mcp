#!/usr/bin/env python3
"""Corpus originals -> real CLI worker -> persisted store -> real stdio metadata.

Generate synthetic originals with VAULDY_BASE_ANALYSIS_DIAGNOSTICS while running
BaseAnalysisMCPTests first. No installed profiles or production data are accessed.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path
import subprocess
import tempfile
import uuid
from smoke_test import Client, payload

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local_binary', type=Path)
    parser.add_argument('mcp_binary', type=Path)
    parser.add_argument('originals', type=Path)
    parser.add_argument('--include-raster', action='store_true', help='Also gate all eight native raster originals')
    args = parser.parse_args()
    local, binary = args.local_binary.resolve(), args.mcp_binary.resolve()
    cases = [c for c in json.loads((ROOT / 'Tests/VauldyMCPRuntimeTests/Fixtures/overview-corpus.json').read_text())['cases'] if c['id'] != 'low_quality']
    entries = [(case, 'embedded') for case in cases]
    if args.include_raster:
        raster_ids = {'invoice', 'bank', 'authority', 'medical', 'housing', 'school', 'vehicle', 'insurance'}
        entries += [(case, 'raster') for case in cases if case['id'] in raster_ids]
    cases = [case for case, _ in entries]
    files = [args.originals.resolve() / (mode + '-' + case['id'] + '.pdf') for case, mode in entries]
    assert all(p.is_file() for p in files), 'Generate synthetic originals with the Swift corpus tests first.'
    originals = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    with tempfile.TemporaryDirectory(prefix='vauldy-base-wire-') as temp:
        root = Path(temp); store = root / 'vault'; profile_file = root / 'profile.json'; client = None
        try:
            imported = subprocess.run([str(local), 'import', '--store', str(store), *map(str, files)], capture_output=True, text=True, timeout=240)
            assert imported.returncode in (0, 2), imported.stderr
            outcomes = json.loads(imported.stdout)
            assert len(outcomes) == len(cases)
            # Local explicit reanalysis uses retained OCR and preserves original bytes.
            first = outcomes[0]['documentID']
            subprocess.run([str(local), 'analyze', '--store', str(store), '--document', first], check=True, capture_output=True, timeout=30)
            before = (store / 'documents.json').read_bytes()
            retained = json.loads(before)
            assert len(retained) == len(cases)
            grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()), connectionName='Synthetic corpus wire',
                         enabled=False, vaultPath=str(store / 'documents.json'), allowedDocumentIDs=[o['documentID'] for o in outcomes], acknowledgedCloudDisclosure=True)
            profile_file.write_text(json.dumps(grant))
            client = Client(binary, profile_file)
            assert client.call('list_documents')['isError']
            grant['enabled'] = True; grant['revision'] = str(uuid.uuid4()); profile_file.write_text(json.dumps(grant))
            schemas = {t['name']: t['outputSchema'] for t in client.request('tools/list', {})['tools']}
            listed = []; cursor = None
            while True:
                result = payload(client.call('list_documents', **({'cursor': cursor} if cursor else {'pageSize': 3})), schemas['list_documents'])
                listed.extend(result['items']); cursor = result.get('nextCursor')
                if not cursor:
                    assert result['retrievalComplete']; break
            assert len(listed) == len(cases)
            local_ids = [o['documentID'].upper() for o in outcomes]
            for case, outcome in zip(cases, outcomes):
                record = next(d for d in retained if d['id'].upper() == outcome['documentID'].upper())
                analysis = record['baseAnalysis']; gold = case['expected']
                assert analysis['status'] == gold['status'], case['id']
                assert len(analysis['documents']) == gold['logicalDocuments'], case['id']
                if analysis['documents']:
                    card = analysis['documents'][0]
                    assert card['kind'] == gold['kind'], case['id']
                    for name in ['issuer', 'issueDate', 'subject', 'titleYear']:
                        assert card.get(name, {}).get('value') == gold.get(name), (case['id'], name)
                    assert all(term in card.get('overview', {}).get('value', '') for term in gold['overviewContains']), case['id']
            expected_titles = sorted(card['title'] for record in retained for card in record['baseAnalysis']['documents'])
            observed_titles = []
            checks = 0
            for hit in listed:
                metadata = payload(client.call('read_document', document=hit['document'], view='metadata'), schemas['read_document'])
                # Handles deliberately do not expose local identifiers.
                cards = list(metadata['documents']); continuation = metadata.get('nextCursor')
                while continuation:
                    page = payload(client.call('read_document', document=hit['document'], view='metadata', cursor=continuation), schemas['read_document'])
                    cards += page['documents']; continuation = page.get('nextCursor')
                assert len(cards) == metadata['logicalDocumentCount']
                assert metadata['analysisStatus'] != 'not-analyzed'
                for card in cards:
                    observed_titles.append(card['title'])
                    assert card['pages'] and card['title']
                    for field in card['fields']:
                        assert field['page'] in card['pages']
                        assert field['source'].startswith('[Quelle:' + hit['document'])
                encoded = json.dumps(dict(metadata=metadata, allCards=cards), ensure_ascii=False)
                for secret in [str(root), 'Erika Beispiel', *local_ids]:
                    assert secret not in encoded
                checks += 1
            remaining = list(expected_titles)
            redacted_titles = 0
            for title in observed_titles:
                parts = re.split(r'(\[V_[A-F0-9]+_[A-Z]+_\d+\])', title)
                pattern = ''.join('.+?' if re.fullmatch(r'\[V_[A-F0-9]+_[A-Z]+_\d+\]', part) else re.escape(part) for part in parts)
                matched = next((raw for raw in remaining if re.fullmatch(pattern, raw)), None)
                assert matched is not None, 'Protected title must project from a stored title'
                remaining.remove(matched)
                redacted_titles += title != matched
            assert not remaining
            status = payload(client.call('get_vault_status'), schemas['get_vault_status'])
            coverage = status['analysisCoverage']
            assert sum(coverage[k] for k in ['completed', 'needsReview', 'unavailable', 'failed', 'notAnalyzed', 'stale']) == len(cases)
            assert (store / 'documents.json').read_bytes() == before
            grant['enabled'] = False; grant['revision'] = str(uuid.uuid4()); profile_file.write_text(json.dumps(grant))
            assert client.call('read_document', document=listed[0]['document'], view='metadata')['isError']
            assert all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in originals.items())
            print(json.dumps(dict(corpusOriginals=len(cases), metadataReads=checks, redactedMetadataTitles=redacted_titles, analysisCoverage=coverage, storeUnchanged=True, originalsUnchanged=True, revoked=True), ensure_ascii=False))
        finally:
            if client: client.close()
            if (store / 'store.json').exists():
                subprocess.run([str(local), 'worker-stop', '--store', str(store)], check=True, capture_output=True, timeout=20)


if __name__ == '__main__':
    main()
