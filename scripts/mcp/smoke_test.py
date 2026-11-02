#!/usr/bin/env python3
"""Real stdio JSON-RPC smoke test. Synthetic inputs only, no app launch or cloud."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time
import uuid

class Client:
    def __init__(self, binary, profile, stderr=subprocess.DEVNULL, capabilities=None):
        self.process = subprocess.Popen([str(binary), '--profile', str(profile)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=stderr)
        self.counter = 0
        self.pending = b''
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.request('initialize', {'protocolVersion': '2025-11-25', 'capabilities': capabilities or {},
                                   'clientInfo': {'name': 'independent-wire-test', 'version': '1'}})
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
    def send(self, obj):
        self.process.stdin.write(json.dumps(obj).encode() + b'\n'); self.process.stdin.flush()
    def request(self, method, params):
        self.counter += 1
        self.send({'jsonrpc': '2.0', 'id': self.counter, 'method': method, 'params': params})
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if b'\n' not in self.pending:
                if not self.selector.select(max(0, deadline - time.monotonic())): break
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk: raise AssertionError('Server exited before response')
                self.pending += chunk
                continue
            line, self.pending = self.pending.split(b'\n', 1)
            response = json.loads(line)
            if response.get('id') == self.counter:
                assert 'error' not in response, response
                return response['result']
        raise AssertionError('MCP request timed out')
    def call(self, name, **arguments):
        return self.request('tools/call', {'name': name, 'arguments': arguments})
    def close(self):
        self.selector.close()
        self.process.stdin.close()
        try: self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try: self.process.wait(timeout=3)
            except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()

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
        vault.write_text(json.dumps([document]))
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
            assert len(compatibility_client.request('tools/list', {})['tools']) == 4
            assert payload(compatibility_client.call('get_vault_status'))['grantedDocumentCount'] == 0
        finally: compatibility_client.close()
        client = Client(args.binary.resolve(), profile_file)
        try:
            tools = client.request('tools/list', {})['tools']
            assert {t['name'] for t in tools} == {'get_vault_status', 'search_documents', 'list_documents', 'read_document'}
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
            assert result['containsEntireAvailableText']
            assert client.call('search_documents', query='Fahrradwartung', vaultPath='/arbitrary')['isError']
            assert client.call('read_document', document=doc_id)['isError']
            assert client.call('delete_document', document=handle)['isError']
            profile['enabled'] = False; profile['revision'] = str(uuid.uuid4()); profile_file.write_text(json.dumps(profile))
            assert client.call('read_document', document=handle)['isError']
            assert payload(client.call('get_vault_status'))['grantedDocumentCount'] == 0
            assert hashlib.sha256(vault.read_bytes()).hexdigest() == before
            print('PASS: real MCP initialize/list/call; both response channels; allowlist; pseudonymization; revocation; read-only archive.')
        finally: client.close()

if __name__ == '__main__': main()
