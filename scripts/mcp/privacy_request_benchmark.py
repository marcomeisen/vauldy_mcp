#!/usr/bin/env python3
"""Synthetic privacy/request-path micro benchmark. JSON fixtures in a temp dir only."""
import subprocess
import json, statistics, sys, tempfile, time, uuid, random
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_test import Client, payload
import stdio_client
# Cold privacy preparation can exceed the default 15 s request timeout.
stdio_client.Client.call = lambda self, name, **a: self.request('tools/call', {'name': name, 'arguments': a}, timeout=180)

binary = Path(sys.argv[1]).resolve(); out = Path(sys.argv[2])
random.seed(7)
FIRST = ['Erika', 'Max', 'Anna', 'Jonas', 'Lea', 'Paul', 'Mia', 'Felix', 'Sophie', 'Lukas']
LAST = ['Musterfrau', 'Beispiel', 'Probst', 'Lindner', 'Hartmann', 'Vogel', 'Krause', 'Brandt']
FILL = 'Der synthetische Vertrag beschreibt Leistungen, Laufzeit und die monatliche Zahlung der Versicherung. '

def iban(i): return f'DE{10 + i % 89:02d}3704004405{i:010d}'

def text(kb, identifiers):
    lines, size, i = [], 0, 0
    while size < kb * 1024:
        if identifiers and i < identifiers:
            n = f'{FIRST[i % 10]} {LAST[i % 8]}{i}'
            line = f'Kontoinhaber {n}, IBAN {iban(i)}, E-Mail kunde{i}@example.com, Vertragsnummer VN-{100000 + i}. '
            i += 1
        else:
            line = FILL
        lines.append(line); size += len(line)
        if len(lines) % 40 == 0: lines.append(f'\n--- Seite {len(lines)//40 + 1} ---\n')
    return '--- Seite 1 ---\n' + ''.join(lines)

def doc(title, body, day=1):
    return dict(id=str(uuid.uuid4()), title=title, sourceName=title + '.pdf',
                importedAt=f'2026-01-{day:02d}T00:00:00Z', status='indexed', pageCount=1, ocrText=body)

def fixture(root, docs):
    root.mkdir(parents=True)
    vault = root / 'documents.json'; vault.write_text(json.dumps(docs))
    profile = root / 'profile.json'
    profile.write_text(json.dumps(dict(version=1, revision=str(uuid.uuid4()), connectionID=str(uuid.uuid4()),
        connectionName='Synthetic perf', enabled=True, acknowledgedCloudDisclosure=True,
        vaultPath=str(vault), allowedDocumentIDs=[d['id'] for d in docs])))
    return Client(binary, profile)

def timed(fn):
    t = time.perf_counter(); r = fn(); return (time.perf_counter() - t) * 1000, r

def handle_for(c, title):
    items = payload(c.call('list_documents', query=title, includeExcerpts=False, pageSize=5))['items']
    return items[0]['document']

results = dict(privacyScaling=[], cacheThrash={}, corpusLoad=[])
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    # 1) Cold read_document cost vs. text size and identifier density (fresh process each).
    for kb in (32, 128, 512):
        for ids in (0, 50, 200, 800):
            c = fixture(tmp / f's{kb}-{ids}', [doc('Zielvertrag', text(kb, ids))])
            try:
                payload(c.call('get_vault_status'))
                h = handle_for(c, 'Zielvertrag')
                cold, _ = timed(lambda: payload(c.call('read_document', document=h)))
                warm = [timed(lambda: payload(c.call('read_document', document=h)))[0] for _ in range(5)]
                psg, _ = timed(lambda: payload(c.call('read_document', document=h, view='passages', query='Laufzeit')))
                results['privacyScaling'].append(dict(textKiB=kb, identifiers=ids, coldReadMS=round(cold, 1),
                    warmReadMedianMS=round(statistics.median(warm), 1), passagesAfterWarmMS=round(psg, 1)))
                print(results['privacyScaling'][-1], flush=True)
            finally:
                rss_kb = int(subprocess.run(['ps','-o','rss=','-p',str(c.process.pid)],capture_output=True,text=True).stdout.strip() or 0)
                print('  rssMiB', round(rss_kb/1024,1), flush=True)
                c.close()
    # 2) Privacy cache thrash: cycling through 8 vs 12 documents.
    for n in (8, 12):
        docs = [doc(f'Rundvertrag{k:02d}', text(64, 100), day=k + 1) for k in range(n)]
        c = fixture(tmp / f'thrash{n}', docs)
        try:
            hs = [handle_for(c, f'Rundvertrag{k:02d}') for k in range(n)]
            for h in hs: payload(c.call('read_document', document=h))
            times = []
            for _ in range(2):
                for h in hs: times.append(timed(lambda: payload(c.call('read_document', document=h)))[0])
            results['cacheThrash'][str(n)] = dict(documents=n, secondRoundMedianMS=round(statistics.median(times), 1))
            print(n, results['cacheThrash'][str(n)], flush=True)
        finally:
            rss_kb = int(subprocess.run(['ps','-o','rss=','-p',str(c.process.pid)],capture_output=True,text=True).stdout.strip() or 0)
            print('  rssMiB', round(rss_kb/1024,1), flush=True)
            c.close()
    # 3) extract_document_fields / read for ONE doc while the grant size grows.
    for total in (10, 1000, 5000):
        docs = [doc('Zielvertrag', text(32, 20))] + [doc(f'Fueller{k}', text(16, 0), day=(k % 27) + 1) for k in range(total - 1)]
        c = fixture(tmp / f'corpus{total}', docs)
        try:
            payload(c.call('get_vault_status'))
            h = handle_for(c, 'Zielvertrag')
            payload(c.call('read_document', document=h))
            reads = [timed(lambda: payload(c.call('read_document', document=h)))[0] for _ in range(5)]
            ext = []
            for _ in range(5):
                ms, r = timed(lambda: c.call('extract_document_fields', documents=[h]))
                assert not r.get('isError'), r
                ext.append(ms)
            results['corpusLoad'].append(dict(grantedDocuments=total, vaultBytes=(tmp / f'corpus{total}' / 'documents.json').stat().st_size,
                readMedianMS=round(statistics.median(reads), 1), extractFieldsMedianMS=round(statistics.median(ext), 1)))
            print(results['corpusLoad'][-1], flush=True)
        finally:
            rss_kb = int(subprocess.run(['ps','-o','rss=','-p',str(c.process.pid)],capture_output=True,text=True).stdout.strip() or 0)
            print('  rssMiB', round(rss_kb/1024,1), flush=True)
            c.close()
out.write_text(json.dumps(results, indent=1))
