#!/usr/bin/env python3
"""Real CLI title maintenance and read-only MCP using an isolated synthetic archive."""
import argparse
import copy
import json
from pathlib import Path
import tempfile
import uuid
from import_smoke_test import command
from smoke_test import Client, payload


def without_titles(document):
    return {key: value for key, value in document.items() if key not in {'title', 'generatedTitle', 'manualTitle'}}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local_binary', type=Path)
    parser.add_argument('mcp_binary', type=Path)
    args = parser.parse_args()
    local = args.local_binary.resolve()
    with tempfile.TemporaryDirectory(prefix='vauldy-title-wire-') as temp:
        root = Path(temp)
        store = root / 'vault'
        pdf = root / 'Scan_001.pdf'
        command(local, 'example', '--output', pdf)
        original = pdf.read_bytes()
        outcome = command(local, 'direct-import', '--store', store, pdf)
        assert outcome['state'] == 'completed'
        snapshot = store / 'documents.json'
        imported = json.loads(snapshot.read_text())[0]
        doc_id = imported['id']
        expected = imported['generatedTitle']
        assert expected == imported['title'] and not imported.get('manualTitle')
        legacy = copy.deepcopy(imported)
        bad = 'abbuchen, sind Sie verpflichtet, diese Zahlungsinformation an diesen weiterzuleiten. Vertrag'
        legacy['title'] = bad
        legacy.pop('generatedTitle', None)
        legacy.pop('manualTitle', None)
        assert len(legacy['baseAnalysis']['documents']) == 1
        legacy['baseAnalysis']['documents'][0]['title'] = bad
        # Keep a second, unselected row to detect unintended bulk changes or disclosure.
        other = copy.deepcopy(imported)
        other['id'] = str(uuid.uuid4()).upper()  # Match Swift UUID's persisted representation.
        other['title'] = 'Eigene zweite Bezeichnung'
        other['manualTitle'] = other['title']
        snapshot.write_text(json.dumps([legacy, other]))
        profile_path = root / 'profile.json'
        profile = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()), connectionName='Isolated title test',
                       enabled=True, vaultPath=str(snapshot), allowedDocumentIDs=[doc_id], acknowledgedCloudDisclosure=True)
        profile_path.write_text(json.dumps(profile))
        grant_bytes = profile_path.read_bytes()
        preview_before = snapshot.read_bytes()
        proposals = {row['documentID']: row for row in command(local, 'title-preview', '--store', store)}
        assert proposals[doc_id]['before'] == bad and proposals[doc_id]['after'] == expected
        assert proposals[other['id']]['after'] == other['manualTitle']
        assert snapshot.read_bytes() == preview_before and profile_path.read_bytes() == grant_bytes
        result = command(local, 'retitle', '--store', store, '--document', doc_id)
        assert result['manualOverride'] is False
        refreshed, untouched = json.loads(snapshot.read_text())
        assert refreshed['title'] == refreshed['generatedTitle'] == expected
        assert without_titles(refreshed) == without_titles(legacy)
        assert untouched == other, [key for key in set(untouched) | set(other) if untouched.get(key) != other.get(key)]
        before_repeat = snapshot.read_bytes()
        command(local, 'retitle', '--store', store, '--document', doc_id)
        assert snapshot.read_bytes() == before_repeat
        command(local, 'set-title', '--store', store, '--document', doc_id, '--title', 'Meine Versicherung')
        result = command(local, 'retitle', '--store', store, '--document', doc_id)
        assert result['manualOverride'] is True
        manual = json.loads(snapshot.read_text())[0]
        assert manual['title'] == manual['manualTitle'] == 'Meine Versicherung'
        assert manual['generatedTitle'] == expected
        command(local, 'reset-title', '--store', store, '--document', doc_id)
        reset = json.loads(snapshot.read_text())[0]
        assert reset['title'] == expected and not reset.get('manualTitle')
        assert without_titles(reset) == without_titles(legacy)
        assert profile_path.read_bytes() == grant_bytes
        assert pdf.read_bytes() == original
        before_read = snapshot.read_bytes()
        client = Client(args.mcp_binary.resolve(), profile_path)
        try:
            listed = payload(client.call('list_documents', pageSize=10))
            assert listed['totalCount'] == 1
            result = payload(client.call('read_document', document=listed['items'][0]['document'], view='metadata'))
            assert 'abbuchen' not in json.dumps(result)
            assert snapshot.read_bytes() == before_read
            assert profile_path.read_bytes() == grant_bytes
        finally:
            client.close()
    print('PASS: preview/retitle/set-title/reset-title, retained evidence/original/other rows/grant, MCP scope and read-only metadata')


if __name__ == '__main__':
    main()
