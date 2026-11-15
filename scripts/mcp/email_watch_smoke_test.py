#!/usr/bin/env python3
"""Drop a synthetic MIME message into a running watched folder and verify the MCP boundary."""
from argparse import ArgumentParser
from email.message import EmailMessage
from email.policy import SMTP
import hashlib
import json
from pathlib import Path
import tempfile
import uuid

from import_smoke_test import command, stop_worker
from smoke_test import Client, payload
from watch_smoke_test import wait_for


def profile(path, store, selected):
    path.write_text(json.dumps(dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
        connectionName='Synthetic email test', enabled=True, vaultPath=str(store/'documents.json'),
        allowedDocumentIDs=selected, acknowledgedCloudDisclosure=True)))


def main():
    parser = ArgumentParser()
    parser.add_argument('local_binary', type=Path)
    parser.add_argument('mcp_binary', type=Path)
    args = parser.parse_args()
    local, server = args.local_binary.resolve(), args.mcp_binary.resolve()
    clients = []
    with tempfile.TemporaryDirectory(prefix='vauldy-email-wire-') as tmp:
        root = Path(tmp).resolve()
        watched, store = root/'watch', root/'vault'
        watched.mkdir()
        def documents():
            return json.loads((store/'documents.json').read_text())
        try:
            baseline = root/'baseline.pdf'
            pdf, png = root/'rechnung.pdf', root/'foto.png'
            command(local, 'example', '--output', baseline)
            pdf.write_bytes(baseline.read_bytes() + b'\n% synthetic email attachment\n')
            command(local, 'example', '--output', png)
            old_id = command(local, 'direct-import', '--store', store, baseline)['documentID']
            old_row = documents()[0]
            original_profile = root/'profile.json'
            profile(original_profile, store, [old_id])
            grant_before = original_profile.read_bytes()
            original_client = Client(server, original_profile)
            clients.append(original_client)

            msg = EmailMessage(policy=SMTP)
            msg['From'] = 'Musterverein <absender@example.invalid>'
            msg['To'] = 'Leser <empfaenger@example.invalid>'
            msg['Subject'] = 'Grüße zum Technikpaket'
            msg['Date'] = 'Sun, 15 Nov 2026 09:42:00 +0100'
            msg.set_content('Das Testpostfach enthält ein Technikpaket mit Unterlagen.')
            msg.add_alternative('<p>Diese alternative HTML-Darstellung wird nicht doppelt übernommen.</p>', subtype='html')
            msg.add_attachment(pdf.read_bytes(), maintype='application', subtype='pdf', filename='Rechnung.pdf')
            msg.add_attachment(png.read_bytes(), maintype='image', subtype='png', filename='Foto.png')
            msg.add_attachment(b'unsupported-content', maintype='application', subtype='zip', filename='nicht-importieren.zip')
            source_bytes = msg.as_bytes()

            command(local, 'watch-add', '--store', store, watched)
            wait_for(lambda: command(local, 'watch-list', '--store', store)['scans'])
            source = watched/'Brief.eml'
            source.write_bytes(source_bytes)
            wait_for(lambda: len(documents()) == 4 and all(
                d['localImport']['state'] in ('completed', 'partial') for d in documents()), timeout=200)
            by_name = {d['sourceName']: d for d in documents()}
            mail = by_name['Brief.eml']
            assert mail['title'] == 'Grüße zum Technikpaket'
            assert mail['localImport']['pages'][0]['method'] == 'embeddedText'
            assert 'Absender: Musterverein <absender@example.invalid>' in mail['ocrText']
            assert '09:42:00 +0100' in mail['ocrText'] and 'Dokumentdatum: 2026-11-15' in mail['ocrText']
            assert 'Das Testpostfach' in mail['ocrText'] and 'alternative HTML' not in mail['ocrText']
            for name, file in [('Rechnung.pdf', pdf), ('Foto.png', png)]:
                d = by_name[name]
                digest = hashlib.sha256(file.read_bytes()).hexdigest()
                assert d['id'] in mail['localImport']['emailAttachmentIDs']
                assert d['localImport']['contentHash'] == digest
                assert '@example.invalid' not in d['ocrText']
                assert d['ocrText'].strip()
                assert (store/'originals'/f'{digest}.{file.suffix[1:]}').read_bytes() == file.read_bytes()

            # New mail and attachment records are absent from an existing grant.
            assert original_profile.read_bytes() == grant_before
            assert by_name[baseline.name] == old_row
            assert payload(original_client.call('list_documents'))['totalCount'] == 1
            assert not payload(original_client.call('search_documents', query='Technikpaket'))['hits']
            authorized = root/'authorized.json'
            profile(authorized, store, [mail['id']])
            client = Client(server, authorized)
            clients.append(client)
            hit = payload(client.call('search_documents', query='Technikpaket'))['hits'][0]
            read = payload(client.call('read_document', document=hit['document']))
            assert 'Technikpaket' in json.dumps(read)
            assert 'absender@example.invalid' not in json.dumps(read)
            assert 'empfaenger@example.invalid' not in json.dumps(read)
            assert payload(client.call('list_documents'))['totalCount'] == 1

            stop_worker(local, store)
            (watched/'Kopie.eml').write_bytes(source_bytes)
            command(local, 'watch-start', '--store', store)
            wait_for(lambda: any(s['submitted'] >= 2 for s in
                command(local, 'watch-list', '--store', store)['scans']), timeout=50)
            assert len(documents()) == 4
            assert original_profile.read_bytes() == grant_before and source.read_bytes() == source_bytes
            print('PASS: new EML watched import, decoded headers/body/date, separate native PDF/image processing, MIME variants, originals, restart deduplication and unchanged MCP grants.')
        finally:
            for client in clients: client.close()
            if (store/'store.json').exists(): stop_worker(local, store)


if __name__ == '__main__':
    main()
