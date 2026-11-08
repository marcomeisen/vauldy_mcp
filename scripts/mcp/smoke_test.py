#!/usr/bin/env python3
"""Real stdio JSON-RPC smoke test. Synthetic inputs only, no app launch or cloud."""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import uuid

from stdio_client import Client

# Vauldy's published v1 tool contract. Independent of the relay's discovery mirror.
V1_DISCOVERY_SHA256 = '1c2d67d0bc94c20fb9efe2755d8bd67cf11a77eaeba769f775925371045fd9fa'
V1_TOOLS = {'get_vault_status', 'search_documents', 'list_documents', 'read_document'}


def assert_v1_discovery(tools):
    keys = ('name', 'inputSchema', 'outputSchema', 'annotations')
    contract = [{key: tool[key] for key in keys} for tool in sorted(tools, key=lambda tool: tool['name'])]
    canonical = json.dumps([tool for tool in contract if tool['name'] in V1_TOOLS],
                           sort_keys=True, separators=(',', ':')).encode()
    assert hashlib.sha256(canonical).hexdigest() == V1_DISCOVERY_SHA256, 'Vauldy v1 tool contract changed'


def validate_shape(value, schema):
    """Validate the JSON-Schema subset declared by these tools, without a dependency."""
    if 'anyOf' in schema:
        for candidate in schema['anyOf']:
            try:
                validate_shape(value, candidate)
                return
            except (AssertionError, KeyError): pass
        raise AssertionError('No declared result shape matched')
    kind = schema['type']
    expected = {'object': dict, 'array': list, 'string': str, 'boolean': bool, 'integer': int}[kind]
    assert type(value) is expected, (kind, type(value).__name__)
    if kind == 'object':
        assert set(schema.get('required', [])) <= value.keys()
        if schema.get('additionalProperties') is False:
            assert value.keys() <= schema['properties'].keys()
        for key, item in value.items():
            validate_shape(item, schema['properties'][key])
    elif kind == 'array':
        for item in value: validate_shape(item, schema['items'])
    elif kind == 'integer':
        assert value >= schema.get('minimum', value)
        assert value <= schema.get('maximum', value)

def payload(result, schema=None):
    assert not result.get('isError'), result
    # Text-only clients and structured clients see exactly the same sanitized value.
    text = json.loads(result['content'][0]['text'])
    assert text == result['structuredContent']
    if schema is not None: validate_shape(text, schema)
    return text

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('binary', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='vauldy-mcp-wire-') as temp:
        root = Path(temp); doc_id = str(uuid.uuid4())
        vault = root / 'documents.json'; profile_file = root / 'profile.json'
        document = dict(id=doc_id, title='Rechnung Erika Musterfrau', sourceName='secret-file.pdf', status='indexed',
                        pageCount=1, ocrText='--- Seite 1 ---\nFahrradwartung 49,99 EUR.\nName: Erika Musterfrau\nE-Mail: erika@example.com\nIBAN: DE89370400440532013000\n12345 Testort Dr: eine lange vertrauliche Zusatzangabe.\nName: Dr: eine lange vertrauliche Zusatzangabe.')
        second_id = str(uuid.uuid4())
        second = dict(id=second_id, title='Wartungsprotokoll', status='indexed', pageCount=1,
                      ocrText='--- Seite 1 ---\nSynthetisches Wartungsprotokoll.')
        vault.write_text(json.dumps([document, second]))
        before = hashlib.sha256(vault.read_bytes()).hexdigest()
        profile = dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()), connectionName='Wire test',
                       enabled=False, vaultPath=str(vault), allowedDocumentIDs=[doc_id], acknowledgedCloudDisclosure=True)
        profile_file.write_text(json.dumps(profile))
        # SDK 0.12.1 rejects object-valued experimental capabilities without the
        # server's compatibility transport. Keep standard capabilities intact.
        compatibility_client = Client(args.binary.resolve(), profile_file, capabilities={
            'elicitation': {'form': {}, 'url': {}},
            'experimental': {'example/extension': {'supported': True},
                             'example/array': [1, False], 'example/string': '1'}})
        try:
            assert compatibility_client.initialization['protocolVersion'] == '2025-11-25'
            assert compatibility_client.initialization['serverInfo']['name'] == 'vauldy'
            assert_v1_discovery(compatibility_client.request('tools/list', {})['tools'])
            assert payload(compatibility_client.call('get_vault_status'))['grantedDocumentCount'] == 0
        finally: compatibility_client.close()
        for version in ['2024-11-05', '2025-03-26', '2025-06-18']:
            legacy_client = Client(args.binary.resolve(), profile_file, protocol_version=version)
            try:
                assert legacy_client.initialization['protocolVersion'] == version
                assert_v1_discovery(legacy_client.request('tools/list', {})['tools'])
                assert payload(legacy_client.call('get_vault_status'))['grantedDocumentCount'] == 0
            finally:
                legacy_client.close()
        client = Client(args.binary.resolve(), profile_file)
        try:
            tools = client.request('tools/list', {})['tools']
            assert_v1_discovery(tools)
            assert {t['name'] for t in tools} == V1_TOOLS | {'get_topic_overview', 'extract_document_fields', 'compare_contract_versions', 'get_deadline_overview', 'get_document_inventory'}
            assert all(t['annotations']['readOnlyHint'] for t in tools)
            assert all('outputSchema' in t for t in tools)
            schemas = {t['name']: t['outputSchema'] for t in tools}
            assert client.call('search_documents', query='Fahrradwartung')['isError']
            assert client.call('list_documents')['isError']
            profile['enabled'] = True; profile['revision'] = str(uuid.uuid4()); profile_file.write_text(json.dumps(profile))
            payload(client.call('get_vault_status'), schemas['get_vault_status'])
            search = payload(client.call('search_documents', query='Fahrradwartung'), schemas['search_documents'])
            listed = payload(client.call('list_documents', query='Fahrradwartung', pageSize=1), schemas['list_documents'])
            assert listed['totalCount'] == 1 and listed['retrievalComplete'] and not listed['hasMore']
            assert listed['items'][0]['document'] == search['hits'][0]['document']
            assert client.call('list_documents', pageSize=0)['isError']
            assert client.call('list_documents', pageSize=26)['isError']
            assert client.call('list_documents', query='!!!')['isError']
            assert client.call('list_documents', vaultPath='/arbitrary')['isError']
            assert not search['retrievalComplete'] and not search['truncated']
            handle = search['hits'][0]['document']
            result = payload(client.call('read_document', document=handle), schemas['read_document'])
            for response in [search, result]:
                wire = json.dumps(response)
                for secret in ['erika@example.com', 'Erika Musterfrau', 'DE89370400440532013000', doc_id, str(root), 'secret-file.pdf']:
                    assert secret not in wire, 'Private value on actual transport'
                assert '49,99 EUR' in wire
            metadata = payload(client.call('read_document', document=handle, view='metadata'), schemas['read_document'])
            assert metadata['analysisStatus'] == 'not-analyzed' and not metadata['documents']
            passages = payload(client.call('read_document', document=handle, view='passages', query='Fahrrad'), schemas['read_document'])
            assert passages['mode'] == 'matching-passages' and passages['retrievalComplete']
            assert not passages['containsEntireAvailableText'] and passages['matchingPassageCount'] == 1
            assert '49,99 EUR' in passages['segments'][0]['text']
            for secret in ['erika@example.com', 'Erika Musterfrau', doc_id, str(root), 'secret-file.pdf']:
                assert secret not in json.dumps(passages)
            assert client.call('read_document', document=handle, view='metadata', query='Fahrrad')['isError']
            assert result['containsEntireAvailableText']

            # Exhaust the list using only continuation cursors, then revoke a live one.
            profile.update(revision=str(uuid.uuid4()), allowedDocumentIDs=[doc_id, second_id])
            profile_file.write_text(json.dumps(profile))
            legacy = payload(client.call('search_documents', query='Wartungsprotokoll'), schemas['search_documents'])
            legacy_handle = legacy['hits'][0]['document']
            assert legacy_handle.lower() != second_id.lower()
            legacy_content = payload(client.call('read_document', document=legacy_handle), schemas['read_document'])
            assert legacy_content['availablePages'] == [1] and legacy_content['segments'][0]['source'] == f'[Quelle:{legacy_handle}:S.1]'
            first_page = payload(client.call('list_documents', pageSize=1), schemas['list_documents'])
            cursor = first_page['nextCursor']
            assert first_page['totalCount'] == 2 and first_page['hasMore'] and not first_page['retrievalComplete']
            final_page = payload(client.call('list_documents', cursor=cursor), schemas['list_documents'])
            assert final_page['retrievalComplete'] and not final_page['hasMore'] and not final_page.get('nextCursor')
            assert len(first_page['items']) == len(final_page['items']) == 1
            assert first_page['items'][0]['document'] != final_page['items'][0]['document']
            handle = final_page['items'][0]['document']
            compact = payload(client.call('list_documents', pageSize=1, includeExcerpts=False), schemas['list_documents'])
            cursor = compact['nextCursor']
            compact_end = payload(client.call('list_documents', cursor=cursor), schemas['list_documents'])
            assert compact_end['retrievalComplete'] and compact_end['items'][0]['document'] == handle
            assert compact['items'][0]['excerpt'] == compact_end['items'][0]['excerpt'] == ''
            assert client.call('search_documents', query='Fahrradwartung', vaultPath='/arbitrary')['isError']
            assert client.call('read_document', document=doc_id)['isError']
            assert client.call('delete_document', document=handle)['isError']
            profile['enabled'] = False; profile['revision'] = str(uuid.uuid4()); profile_file.write_text(json.dumps(profile))
            for options in ({}, {'view': 'metadata'}, {'view': 'passages', 'query': 'Wartung'}):
                denied = client.call('read_document', document=handle, **options)
                assert denied['isError'] and 'structuredContent' not in denied
            assert client.call('list_documents', cursor=cursor)['isError']
            assert payload(client.call('get_vault_status'))['grantedDocumentCount'] == 0
            profile.update(enabled=True, revision=str(uuid.uuid4()))
            profile_file.write_text(json.dumps(profile))
            assert client.call('list_documents', cursor=cursor)['isError']
            assert client.call('read_document', document=handle)['isError']
            assert payload(client.call('list_documents'), schemas['list_documents'])['totalCount'] == 2
            assert hashlib.sha256(vault.read_bytes()).hexdigest() == before
            assert not any(root.glob('.vauldy-index-*')), 'Default pagination must not create a persistent index'
            print('PASS: real MCP initialize/list/call; both response channels; allowlist; pseudonymization; revocation; read-only archive.')
        finally: client.close()

if __name__ == '__main__': main()
