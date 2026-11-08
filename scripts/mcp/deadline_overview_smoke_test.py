#!/usr/bin/env python3
"""Exercise the deadline overview using only synthetic sources through local stdio."""
import argparse
import json
from pathlib import Path
import tempfile
import time
import uuid

from smoke_test import Client, assert_v1_discovery, payload
from topic_overview_smoke_test import document, write_json


def contract(marker, fields, *other_pages, **overrides):
    return document(f'Leasingvertrag\n{marker}\n\n{fields}', *other_pages, **overrides)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=lambda path: Path(path).resolve())
    args = parser.parse_args()
    rule = 'Kündigungsfrist: 1 Monat vor Vertragsende'
    end = 'Vertragsende: 15.04.2027'
    fixtures = {
        'MONATTEST': contract('MONATTEST', f'{end}\n{rule}'),
        'FESTTEST': contract('FESTTEST', f'{end}\n{rule}\nKündigung bis: 2027-03-11\n'
                             'Zahlbar bis: 2.1.2027\nTermin am: 18.02.2027'),
        'MONATSENDETEST': contract('MONATSENDETEST', f'Vertragsende: 31.03.2027\n{rule}'),
        'SCHALTTEST': contract('SCHALTTEST', 'Vertragsende: 2.3.2028\n'
                              'Kündigungsfrist: 1 Woche vor dem Vertragsende'),
        'TAGESTEST': contract('TAGESTEST', 'Vertragsende: 2027-01-03\n'
                             'Kündigungsfrist: 3 Kalendertage vor Vertragsende'),
        'KONFLIKTTEST': contract('KONFLIKTTEST', f'{end}\nVertragsende: 16.04.2027\n{rule}'),
        'STICHTAGKONFLIKTTEST': contract('STICHTAGKONFLIKTTEST', f'{end}\n{rule}\n'
                                       'Kündigung bis: 12.03.2027\nKündigung bis: 15.03.2027'),
        'VERLAENGERUNGTEST': contract('VERLAENGERUNGTEST', f'{end}\n{rule}\n\n'
                                     'Eine Vertragsverlängerung erfolgt automatisch.'),
        'BEDINGUNGTEST': contract('BEDINGUNGTEST', f'{end}\n{rule}\n\n'
                                  'Diese Regel gilt nur bei schriftlicher Bestätigung.'),
        'RECHNUNGTEST': document('Rechnung\nRECHNUNGTEST\n\nZahlung fällig am: 09.03.2027'),
        'WERKTAGTEST': contract('WERKTAGTEST', f'{end}\nKündigungsfrist: 3 Werktage vor Vertragsende'),
        'FORMATTEST': contract('FORMATTEST', f'{end}\nKündigungsfrist: 3 Tage vor Vertragsende'),
        'UNGÜLTIGTEST': contract('UNGÜLTIGTEST', f'Vertragsende: 29.02.2027\n{rule}'),
        'ANKERFEHLTTEST': contract('ANKERFEHLTTEST', rule),
        'GRENZTEST': contract('GRENZTEST', end, rule),
        'MEHRKOPFTEST': contract('MEHRKOPFTEST', f'{end}\n\nMietvertrag\n{rule}'),
        'OCRLUECKENTEST': contract('OCRLUECKENTEST', f'{end}\n{rule}') | {'pageCount': 2},
        'OCRFEHLERTEST': contract('OCRFEHLERTEST', f'{end}\n{rule}', status='failed'),
        'MASKIERTEST': contract('MASKIERTEST', f'{end}\nKündigungsfrist: erika@example.com'),
        'LAENGENTEST': contract('LAENGENTEST', f'{end}\nKündigungsfrist: ' + 'Text ' * 40),
        'WEITERTEST': contract('WEITERTEST', f'{end}\n{rule}\nFortgesetzte Angabe'),
    }
    private = contract('PRIVATTEST', f'{end}\n{rule}')
    with tempfile.TemporaryDirectory(prefix='vauldy-deadline-wire-') as temporary:
        root = Path(temporary)
        vault, profile = root / 'documents.json', root / 'profile.json'
        items = list(fixtures.values())
        write_json(vault, [*items, private])
        grant = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
                     connectionName='Synthetic deadlines', enabled=True, vaultPath=str(vault),
                     allowedDocumentIDs=[item['id'] for item in items], acknowledgedCloudDisclosure=True)
        write_json(profile, grant)
        original = vault.read_bytes(), profile.read_bytes()
        client = Client(args.binary, profile)
        try:
            tools = client.request('tools/list', {})['tools']
            assert_v1_discovery(tools)
            tool = next(tool for tool in tools if tool['name'] == 'get_deadline_overview')
            handles = {}
            for marker, item in fixtures.items():
                candidate, = payload(client.call('list_documents', query=marker, includeExcerpts=False))['items']
                handles[marker] = candidate['document']
                assert candidate['document'] != item['id']

            def overview(*markers):
                selected = [handles[marker] for marker in markers]
                data = payload(client.call('get_deadline_overview', documents=selected), tool['outputSchema'])
                assert data['contractVersion'] == 1 and data['scope'] == 'selected-documents-explicit-deadlines', data
                assert [row['document'] for row in data['rows']] == selected, data
                wire = json.dumps(data)
                for secret in [str(root), 'erika@example.com', private['id'], *(item['id'] for item in items)]:
                    assert secret not in wire
                for row in data['rows']:
                    assert [entry['role'] for entry in row['entries']] == [
                        'endDate', 'noticePeriod', 'cancellationDue', 'paymentDue', 'appointment']
                    for entry in row['entries']:
                        assert len(entry['evidence']) <= 2
                        for evidence in entry['evidence']:
                            assert evidence['source'] == f"[Quelle:{row['document']}:S.{evidence['page']}]"
                return data['rows']

            calls = client.counter
            start = time.perf_counter()
            month, fixed, boundary, week, days = overview(*list(fixtures)[:5])
            ms = round((time.perf_counter() - start) * 1000, 1)
            assert client.counter == calls + 1
            source = f"[Quelle:{month['document']}:S.1]"
            assert month['calculationStatus'] == 'calculated'
            assert month['calculation'] == dict(date='2027-03-15', method='subtract-calendar-months-same-day',
                                                ruleSource=source, endDateSource=source), month
            assert month['entries'][1]['status'] == 'stated-rule' and month['entries'][1]['evidence'][0]['quote'] == rule
            assert fixed['calculationStatus'] == 'stated-date' and 'calculation' not in fixed
            assert [entry['date'] for entry in fixed['entries'][2:]] == ['2027-03-11', '2027-01-02', '2027-02-18']
            assert boundary['calculationStatus'] == 'unresolved' and 'CALENDAR_DATE_UNRESOLVED' in boundary['warnings']
            assert week['calculation']['date'] == '2028-02-24' and week['calculation']['method'] == 'subtract-calendar-weeks'
            assert days['calculation']['date'] == '2026-12-31' and days['calculation']['method'] == 'subtract-calendar-days'

            for marker, warning, index, field_warning in [
                ('KONFLIKTTEST', 'RULE_OR_END_DATE_UNRESOLVED', 0, 'MULTIPLE_FIELD_VALUES'),
                ('STICHTAGKONFLIKTTEST', 'CANCELLATION_DATE_UNRESOLVED', 2, 'MULTIPLE_FIELD_VALUES'),
                ('VERLAENGERUNGTEST', 'CONDITIONAL_CONTEXT', None, None),
                ('BEDINGUNGTEST', 'CONDITIONAL_CONTEXT', None, None),
                ('WERKTAGTEST', 'CONDITIONAL_CONTEXT', None, None),
                ('FORMATTEST', 'RULE_NOT_SUPPORTED', None, None),
                ('UNGÜLTIGTEST', 'RULE_OR_END_DATE_UNRESOLVED', 0, 'DATE_NOT_SUPPORTED'),
                ('ANKERFEHLTTEST', 'RULE_OR_END_DATE_UNRESOLVED', None, None),
                ('GRENZTEST', 'RULE_AND_END_DATE_SCOPE_UNRESOLVED', None, None),
                ('MEHRKOPFTEST', 'RULE_AND_END_DATE_SCOPE_UNRESOLVED', None, None),
                ('OCRLUECKENTEST', 'SOURCE_NOT_READY', 0, 'SOURCE_NOT_READY'),
                ('OCRFEHLERTEST', 'SOURCE_NOT_READY', 0, 'SOURCE_NOT_READY'),
                ('MASKIERTEST', 'RULE_OR_END_DATE_UNRESOLVED', 1, 'REDACTED_VALUE'),
                ('LAENGENTEST', 'RULE_OR_END_DATE_UNRESOLVED', 1, 'EVIDENCE_WITHHELD'),
                ('WEITERTEST', 'RULE_OR_END_DATE_UNRESOLVED', 1, 'FIELD_EXTRACTION_INCOMPLETE'),
            ]:
                row, = overview(marker)
                assert row['calculationStatus'] == 'unresolved' and 'calculation' not in row and warning in row['warnings'], row
                if index is not None:
                    entry = row['entries'][index]
                    assert entry['status'] == 'unresolved' and field_warning in entry['warnings'], entry
                    assert 'date' not in entry
            invoice, = overview('RECHNUNGTEST')
            assert invoice['entries'][3]['date'] == '2027-03-09' and invoice['calculationStatus'] == 'unresolved'
            assert not payload(client.call('list_documents', query='PRIVATTEST'))['items']
            first = handles['MONATTEST']
            for invalid in [{}, {'documents': []}, {'documents': [first, first]}, {'documents': first},
                            {'documents': [1]}, {'documents': ['']}, {'documents': [first], 'cursor': 'invalid'},
                            {'documents': list(handles.values())[:6]}, {'documents': [first, private['id']]}]:
                assert client.call('get_deadline_overview', **invalid)['isError'], invalid
            for field in ['cancellationDue', 'paymentDue', 'appointment']:
                assert client.call('extract_document_fields', documents=[first], fields=[field])['isError']
            assert (vault.read_bytes(), profile.read_bytes()) == original
            write_json(vault, [items[0] | {'ocrText': items[0]['ocrText'] + '\nKorrektur.'}, *items[1:], private])
            assert client.call('get_deadline_overview', documents=[first])['isError']
            write_json(profile, grant | {'enabled': False, 'revision': str(uuid.uuid4())})
            assert client.call('get_deadline_overview', documents=[handles['FESTTEST']])['isError']
        finally:
            client.close()
    print(json.dumps(dict(passed=True, fixtures=len(fixtures) + 1, documentsPerMeasuredCall=5, deadlineCalls=1, deadlineMS=ms)))


if __name__ == '__main__':
    main()
