#!/usr/bin/env python3
"""Exercise and time one topic-overview MCP call using only synthetic documents."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import statistics
import tempfile
import time
import uuid

from smoke_test import Client, payload


def write_json(path, data):
    staging = path.with_suffix('.tmp')
    staging.write_text(json.dumps(data, ensure_ascii=False))
    staging.replace(path)


def document(*pages, **fields):
    return dict(id=str(uuid.uuid4()), status='indexed', pageCount=len(pages),
                ocrText='\n'.join(f'--- Seite {index} ---\n{page}' for index, page in enumerate(pages, 1))) | fields


def analyzed_policy():
    text = 'Versicherungsschein\nAussteller: Nordstern Sachversicherung AG\nBetreff: Hausrat'
    record = document(text)
    source = dict(text=record['ocrText'], count=1, review=[False], unreadable=[False])
    digest = hashlib.sha256(json.dumps(source, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    issuer = dict(role='issuer', value='Nordstern Sachversicherung AG', page=1,
                  quote='Aussteller: Nordstern Sachversicherung AG', origin='explicitLabel')
    subject = dict(role='subject', value='Hausrat', page=1, quote='Betreff: Hausrat', origin='explicitLabel')
    heading = dict(role='documentType', value='insuranceNotice', page=1, quote='Versicherungsschein',
                   origin='documentHeading')
    return record | dict(baseAnalysisSourceHash=digest, baseAnalysis=dict(
        version=1, engine='local-rules-extractive-v1', status='completed', analyzedPages=[1], issues=[],
        documents=[dict(pages=[1], kind='insuranceNotice', kindEvidence=heading, issuer=issuer, subject=subject,
                        title='Versicherungsschein', issues=[])]))


def fixtures():
    filler = 'Allgemeine Erläuterung zu Ablage, Fristen und Ansprechstelle. ' * 14
    records = [analyzed_policy()]
    records += [document('Anschreiben zum Vorgang.', 'Versicherungsschein\n' + filler, filler) for _ in range(11)]
    records += [document('Werbung zur Versicherung.\nName: Erika Musterfrau\nE-Mail: erika@example.com')
                for _ in range(5)]
    private = document('Versicherungsschein\nNICHT-FREIGEGEBENE-MARKE')
    records += [
        document('Unklarer Bestand.', sourceName='private-versicherung.pdf'),
        document('Versicherung ohne lesbare Quelle.', status='failed'),
        document('Rechnung für Fahrradwartung.', filler),
        private,
    ]
    records += [document('Archivbeleg zum Vorgang.', filler, filler) for _ in range(150 - len(records))]
    return records, private


def overview(client, schema=None, **arguments):
    return payload(client.call('get_topic_overview', **arguments), schema)


def measure(client, expected_count):
    started = time.perf_counter()
    result = client.call('get_topic_overview', topic='insurance')
    elapsed = (time.perf_counter() - started) * 1000
    data = payload(result)
    assert data['retrievalComplete'] and data['candidateCount'] == expected_count
    return elapsed


def stats(samples):
    ordered = sorted(samples)
    return dict(runs=len(ordered), medianMS=round(statistics.median(ordered), 1),
                p95MS=round(ordered[math.ceil(0.95 * len(ordered)) - 1], 1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=lambda value: Path(value).resolve())
    parser.add_argument('--benchmark', action='store_true')
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix='vauldy-topic-wire-') as temp:
        root = Path(temp)
        records, private = fixtures()
        vault = root / 'documents.json'
        write_json(vault, records)
        original_vault = vault.read_bytes()
        grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                     connectionName='Synthetic topic overview', enabled=True, vaultPath=str(vault),
                     allowedDocumentIDs=[item['id'] for item in records if item['id'] != private['id']],
                     acknowledgedCloudDisclosure=True)

        def make_profile(name):
            path = root / name / 'profile.json'
            path.parent.mkdir()
            write_json(path, grant)
            return path

        profile = make_profile('wire')
        original_grant = profile.read_bytes()
        client = Client(args.binary, profile)
        try:
            tools = client.request('tools/list', {})['tools']
            schema = next(tool['outputSchema'] for tool in tools if tool['name'] == 'get_topic_overview')
            before = client.counter
            data = overview(client, schema, topic='insurance')
            assert client.counter == before + 1
            assert data['contractVersion'] == 1 and data['candidateCount'] == 19 and data['retrievalComplete']
            assert not data['processingComplete'] and data['coverage']['failedDocumentCount'] == 1
            rows = data['rows']
            assert Counter(row['status'] for row in rows) == {
                'policy-heading': 12, 'topic-mention': 5, 'no-physical-page-evidence': 1,
                'no-current-searchable-source': 1
            }
            assert Counter(row['evidence']['page'] for row in rows if row['status'] == 'policy-heading') == {1: 1, 2: 11}
            assert all(row['evidence']['quote'] == 'Versicherungsschein' for row in rows if row['status'] == 'policy-heading')
            analyzed, = [row for row in rows if 'issuer' in row]
            assert analyzed['issuer']['value'] == 'Nordstern Sachversicherung AG'
            assert analyzed['subject']['value'] == 'Hausrat' and analyzed['issuer']['page'] == 1
            wire = json.dumps(data)
            for secret in ['Erika Musterfrau', 'erika@example.com', 'private-versicherung.pdf',
                           'NICHT-FREIGEGEBENE-MARKE', str(root), *(item['id'] for item in records)]:
                assert secret not in wire, secret
            assert all(row['evidence']['source'] == f"[Quelle:{row['document']}:S.{row['evidence']['page']}]"
                       for row in rows if 'evidence' in row)
            assert '[V_' in wire
            assert payload(client.call('read_document', document=analyzed['document']))['document'] == analyzed['document']
            generic = overview(client, schema, query='fahrradwart')
            assert generic['candidateCount'] == 1 and generic['rows'][0]['status'] == 'topic-mention'
            for invalid in [{}, {'topic': 'unknown'}, {'query': '!!'}, {'topic': 'insurance', 'query': 'versicher'}]:
                assert client.call('get_topic_overview', **invalid)['isError']
            assert vault.read_bytes() == original_vault and profile.read_bytes() == original_grant

            extra = [document('Mitteilung zur Versicherung.') for _ in range(11)]
            write_json(vault, records + extra)
            grant_more = grant | {'revision': str(uuid.uuid4()),
                                  'allowedDocumentIDs': grant['allowedDocumentIDs'] + [item['id'] for item in extra]}
            write_json(profile, grant_more)
            first = overview(client, schema, topic='insurance')
            assert first['candidateCount'] == 30 and not first['retrievalComplete'] and len(first['rows']) == 25
            cursor = first['nextCursor']
            assert client.call('list_documents', cursor=cursor)['isError']
            assert client.call('get_topic_overview', query='versicher polic', cursor=cursor)['isError']
            second = overview(client, schema, topic='insurance', cursor=cursor)
            assert second['retrievalComplete'] and 'nextCursor' not in second and len(second['rows']) == 5
            assert len({row['document'] for row in first['rows'] + second['rows']}) == 30
            write_json(vault, records + extra[:-1] + [extra[-1] | {'ocrText': 'Korrektur der Quelle.'}])
            assert client.call('get_topic_overview', topic='insurance', cursor=cursor)['isError']
            write_json(profile, grant_more | {'enabled': False, 'revision': str(uuid.uuid4())})
            assert client.call('get_topic_overview', topic='insurance')['isError']
        finally:
            client.close()

        report = dict(passed=['single-call', 'physical-evidence', 'typed-fields', 'privacy', 'grants',
                              'ocr-coverage', 'generic-query', 'input-validation', 'pagination',
                              'cursor-scope', 'changed-source', 'revocation', 'read-only-fixtures'],
                      documents=len(records), granted=len(grant['allowedDocumentIDs']),
                      candidates=19, policyHeadings=12, toolCalls=1)
        if args.benchmark:
            vault.write_bytes(original_vault)
            cold = []
            for index in range(20):
                client = Client(args.binary, make_profile(f'cold-{index}'))
                try:
                    cold.append(measure(client, 19))
                finally:
                    client.close()
            client = Client(args.binary, make_profile('warm'))
            try:
                measure(client, 19)
                warm = [measure(client, 19) for _ in range(30)]
            finally:
                client.close()
            report |= dict(cold=stats(cold), warm=stats(warm))
        print(json.dumps(report))


if __name__ == '__main__':
    main()
