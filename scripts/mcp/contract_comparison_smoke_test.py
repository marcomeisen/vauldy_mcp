#!/usr/bin/env python3
"""Compare only synthetic contract versions over the actual local stdio boundary."""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import time
import uuid

from smoke_test import Client, assert_v1_discovery, payload
from topic_overview_smoke_test import document, write_json


def version(marker, *, issuer='Nordstern Sachversicherung AG', number='MOCK-84R7',
            newer=False, label='Vertragsnummer', last=None, continuation='', line_break='\n'):
    pages = ['Versicherungsschein\nAussteller: ' + issuer + continuation + f'\n{label}: {number}'
             + '\n\nBetreff: Hausrat\n' + marker]
    pages += ['Hinweise zur Bearbeitung der Unterlagen. ' * 10 for _ in range(16)]
    pages += [last or ('Monatsrate: 65 EUR\nSchlussrate: 50 EUR\nLaufzeit: 24 Monate'
                       if newer else 'Monatsrate: 50 EUR\nGesamtkosten: 1200 EUR\nLaufzeit: 24 Monate')]
    item = document(*pages)
    item['ocrText'] = item['ocrText'].replace('\n', line_break)
    indices = list(range(1, len(pages) + 1))
    source = dict(text=item['ocrText'], count=len(pages), review=[False] * len(pages), unreadable=[False] * len(pages))
    digest = hashlib.sha256(json.dumps(source, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
    heading = dict(role='documentType', value='insuranceNotice', page=1, quote='Versicherungsschein', origin='documentHeading')
    item.update(baseAnalysisSourceHash=digest, baseAnalysis=dict(
        version=1, engine='local-rules-extractive-v1', status='completed', analyzedPages=indices, issues=[],
        documents=[dict(pages=indices, kind='insuranceNotice', kindEvidence=heading, title='Police', issues=[])]))
    return item


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=lambda p: Path(p).resolve())
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='vauldy-compare-wire-') as temporary:
        root = Path(temporary)
        before = version('ALTTEST')
        after = version('NEUTEST', newer=True, line_break='\r\n')
        another = version('FREMDTEST', number='MOCK-27R8')
        issuer = version('ANDERERAUSSTELLER', issuer='Anderes Testwerk GmbH')
        split = version('MEHRTEST')
        card = split['baseAnalysis']['documents'][0]
        split['baseAnalysis']['documents'] = [card | {'pages': list(range(1, 10))},
                                             card | {'pages': list(range(10, 19))}]
        partial = version('LUECKENTEST') | {'pageCount': 19}
        unscoped = version('UNZUGEORDNETTEST')
        del unscoped['baseAnalysis'], unscoped['baseAnalysisSourceHash']
        failed_scope = version('ANALYSEFEHLERTEST')
        failed_scope['baseAnalysis']['status'] = 'failed'
        conflict = version('KONFLIKTTEST', last='Monatsrate: 65 EUR\nMonatsrate: 70 EUR\n'
                           'Kündigungsbedingungen: E-Mail: erika@example.com\n'
                           'Laufzeit: 36 Monate\nUnvollständige Fortsetzung.')
        identity_conflict = version('NUMMERNKONFLIKT', last='Vertragsnummer: MOCK-27R8\nMonatsrate: 99 EUR')
        wrapped = version('ZEILENUMBRUCHTEST', continuation='\nAbweichender Zusatz')
        unmasked_left = version('POLICENALTT', number='PK-85HJ', label='Policennummer', last='Kosten: Referenz PK-85HJ')
        unmasked_right = version('POLICENNEUT', number='PK-85HJ', label='Policennummer', last='Kosten: 30 EUR')
        private = version('PRIVATTEST', newer=True)
        items = [before, after, another, issuer, split, partial, unscoped, failed_scope, conflict, identity_conflict,
                 wrapped, unmasked_left, unmasked_right, private]
        vault = root / 'documents.json'
        profile = root / 'profile.json'
        write_json(vault, items)
        grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                     connectionName='Synthetic comparison', enabled=True, vaultPath=str(vault),
                     allowedDocumentIDs=[i['id'] for i in items[:-1]], acknowledgedCloudDisclosure=True)
        write_json(profile, grant)
        original = vault.read_bytes(), profile.read_bytes()
        client = Client(args.binary, profile)
        try:
            tools = client.request('tools/list', {})['tools']
            assert_v1_discovery(tools)
            schema = next(t['outputSchema'] for t in tools if t['name'] == 'compare_contract_versions')

            def select(query):
                item, = payload(client.call('list_documents', query=query, includeExcerpts=False))['items']
                return item['document']

            def compare(left, right):
                value = payload(client.call('compare_contract_versions', before=left, after=right), schema)
                wire = json.dumps(value)
                for secret in ['MOCK-84R7', 'MOCK-27R8', 'PK-85HJ', 'erika@example.com', str(root),
                               *(item['id'] for item in items)]:
                    assert secret not in wire
                return value

            left, right = select('ALTTEST'), select('NEUTEST')
            calls = client.counter
            start = time.perf_counter()
            value = compare(left, right)
            ms = round(1000 * (time.perf_counter() - start), 1)
            assert client.counter == calls + 1 and value['status'] == 'compared' and value['contractVersion'] == 1, value
            assert value['before']['identitySource'] == f'[Quelle:{left}:S.1]'
            assert value['after']['identitySource'] == f'[Quelle:{right}:S.1]'
            rows = {r['aspect']: r for r in value['rows']}
            monthly = rows['monthly']
            assert monthly['status'] == 'different-text' and monthly['before']['value'] == '50 EUR' and monthly['after']['value'] == '65 EUR', monthly
            assert monthly['before']['quote'] == 'Monatsrate: 50 EUR'
            assert monthly['after']['quote'] == 'Monatsrate: 65 EUR'
            assert monthly['before']['source'] == f'[Quelle:{left}:S.18]'
            assert monthly['after']['source'] == f'[Quelle:{right}:S.18]'
            assert rows['total']['status'] == 'before-only' and 'after' not in rows['total']
            assert rows['final']['status'] == 'after-only' and 'before' not in rows['final']
            assert rows['duration']['status'] == 'same-text'
            assert compare(right, left)['before']['document'] == right

            for marker, warning in [
                ('FREMDTEST', 'IDENTITY_NOT_UNIQUE_OR_MATCHING'),
                ('ANDERERAUSSTELLER', 'IDENTITY_NOT_UNIQUE_OR_MATCHING'),
                ('MEHRTEST', 'DOCUMENT_SCOPE_UNRESOLVED'),
                ('LUECKENTEST', 'SOURCE_NOT_READY'),
                ('UNZUGEORDNETTEST', 'DOCUMENT_SCOPE_UNRESOLVED'),
                ('ANALYSEFEHLERTEST', 'DOCUMENT_SCOPE_UNRESOLVED'),
                ('NUMMERNKONFLIKT', 'IDENTITY_NOT_UNIQUE_OR_MATCHING'),
                ('ZEILENUMBRUCHTEST', 'IDENTITY_NOT_UNIQUE_OR_MATCHING'),
            ]:
                result = compare(left, select(marker))
                assert result['status'] == 'unresolved-pair' and not result['rows'] and warning in result['warnings'], result
                assert 'identitySource' not in result['before'] and 'identitySource' not in result['after']
            rows = {r['aspect']: r for r in compare(left, select('KONFLIKTTEST'))['rows']}
            assert rows['monthly']['status'] == 'unresolved' and rows['monthly']['afterEvidenceCount'] == 2
            assert rows['conditions']['status'] == 'unresolved' and 'REDACTED_VALUE' in rows['conditions']['warnings']
            assert rows['duration']['status'] == 'unresolved' and 'FIELD_EXTRACTION_INCOMPLETE' in rows['duration']['warnings']
            masked = compare(select('POLICENALTT'), select('POLICENNEUT'))
            assert masked['status'] == 'compared'
            assert next(r for r in masked['rows'] if r['field'] == 'cost')['status'] == 'unresolved'

            for invalid in [{}, {'before': left}, {'before': left, 'after': left}, {'before': [left], 'after': right},
                            {'before': left, 'after': right, 'cursor': 'fake'}, {'before': left, 'after': private['id']}]:
                assert client.call('compare_contract_versions', **invalid)['isError'], invalid
            assert (vault.read_bytes(), profile.read_bytes()) == original
            write_json(vault, [before, after | {'ocrText': after['ocrText'] + '\nKorrektur.'}, *items[2:]])
            assert client.call('compare_contract_versions', before=left, after=right)['isError']
            write_json(profile, grant | {'enabled': False, 'revision': str(uuid.uuid4())})
            assert client.call('compare_contract_versions', before=left, after=right)['isError']
        finally:
            client.close()
    print(json.dumps(dict(passed=True, fixtures=len(items), pagesPerVersion=18, comparisonCalls=1, comparisonMS=ms)))


if __name__ == '__main__':
    main()
