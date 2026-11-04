#!/usr/bin/env python3
"""Synthetic real-MCP scaling benchmark; no user archives or installations."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import shutil
import subprocess
import tempfile
import time
import uuid

from smoke_test import Client, payload

parser = argparse.ArgumentParser()
parser.add_argument('binary', type=lambda value: Path(value).resolve())
parser.add_argument('destination', type=Path)
parser.add_argument('--documents', type=int, nargs='+', choices=[1000, 2000, 5000, 10000, 20000],
                    default=[1000, 2000])
parser.add_argument('--experimental-sqlite-index', action='store_true',
                    help='Enable the process-local SQLite FTS5 pilot for exact list filters')
parser.add_argument('--compare-index-variants', action='store_true',
                    help='Isolate cache, compact projection and FTS5 on the same synthetic snapshot')
args = parser.parse_args()
server_options = ('--experimental-sqlite-index',) if args.experimental_sqlite_index else ()
binary, destination, results = args.binary, args.destination, []


def peak_resident_bytes(client):
    # Darwin wait4 gives this exact child process's high-water RSS in bytes.
    # Let it exit normally on EOF and leave forced cleanup to Client.close.
    process = client.process
    process.stdin.close()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        pid, status, usage = os.wait4(process.pid, os.WNOHANG)
        if pid:
            process.returncode = os.waitstatus_to_exitcode(status)
            assert process.returncode == 0
            return usage.ru_maxrss
        time.sleep(0.02)
    return None


def write_report(long_evidence=None):
    destination.parent.mkdir(parents=True, exist_ok=True)
    report = dict(
        binaryVersion=subprocess.check_output([str(binary), '--version'], text=True).strip(),
        platform=platform.platform(), syntheticOnly=True, requestedSizes=args.documents,
        experimentalSQLiteIndex=args.experimental_sqlite_index, compareIndexVariants=args.compare_index_variants,
        cases=results, longEvidence=long_evidence,
    )
    destination.write_text(json.dumps(report, indent=2) + '\n')


def compare_index_variants(root, profile, count):
    variants = {
        'jsonBaseline': ('--no-compact-list-projection',),
        'largerCacheOnly': ('--no-compact-list-projection', '--large-snapshot-cache'),
        'compactProjectionOnly': (),
        'memoryFTS5Only': ('--no-compact-list-projection', '--memory-sqlite-index'),
        'persistentFTS5AndProjection': ('--persistent-sqlite-index',),
    }
    result = {}

    for label, flags in variants.items():
        variant = root / label
        variant.mkdir(mode=0o700)
        (variant / 'logs').mkdir(mode=0o700)
        shutil.copyfile(root / 'logs/audit.jsonl', variant / 'logs/audit.jsonl')
        (variant / 'logs/audit.jsonl').chmod(0o600)
        local_profile = variant / 'profile.json'
        local_profile.write_bytes(profile.read_bytes())
        durable = '--persistent-sqlite-index' in flags
        client = Client(binary, local_profile, server_options=flags)
        try:
            def timed(**parameters):
                start = time.perf_counter()
                output = payload(client.call('list_documents', **parameters))
                return output, (time.perf_counter() - start) * 1000

            page, first_ms = timed(pageSize=100, includeExcerpts=False)
            assert page['totalCount'] == count
            handles = {item['document'] for item in page['items']}
            latencies = []
            pages = 1
            while page.get('nextCursor') and (durable or pages <= 10):
                page, elapsed = timed(cursor=page['nextCursor'])
                handles.update(item['document'] for item in page['items'])
                latencies.append(elapsed)
                pages += 1
            assert len(handles) == min(count, pages * 100)
            if durable:
                assert page['retrievalComplete'] and len(handles) == count
            exact, exact_cold = timed(query='Themenmarker', pageSize=100, includeExcerpts=False)
            assert exact['totalCount'] == count // 50
            warm = []
            for _ in range(5):
                exact, elapsed = timed(query='Themenmarker', pageSize=100, includeExcerpts=False)
                assert exact['totalCount'] == count // 50
                warm.append(elapsed)
            evidence = payload(client.call('read_document', document=exact['items'][0]['document']))
            assert any('Themenmarker' in item['text'] and item['page'] == 1 for item in evidence['segments'])
            continuation_p95 = statistics.quantiles(latencies, n=20, method='inclusive')[18] if len(latencies) > 1 else None
            result[label] = dict(firstCompactPageMS=round(first_ms, 2), compactPages=pages,
                                 continuationFirst10MedianMS=round(statistics.median(latencies[:10]), 2) if latencies else None,
                                 continuationP95MS=round(continuation_p95, 2) if continuation_p95 is not None else None,
                                 compactComplete=page['retrievalComplete'],
                                 completeCompactMS=round(first_ms + sum(latencies), 2) if page['retrievalComplete'] else None,
                                 exactColdMS=round(exact_cold, 2), exactWarmMedianMS=round(statistics.median(warm), 2),
                                 exactCandidates=exact['totalCount'], peakServerRSSBytes=peak_resident_bytes(client))
        finally:
            client.close()

        if durable:
            database, = variant.glob('.vauldy-index-*/index-v1.sqlite')
            saved = database.read_bytes()
            restarted = Client(binary, local_profile, server_options=flags)
            try:
                start = time.perf_counter()
                page = payload(restarted.call('list_documents', query='Themenmarker', pageSize=100, includeExcerpts=False))
                assert page['totalCount'] == count // 50 and database.read_bytes() == saved
                result[label]['restartExactMS'] = round((time.perf_counter() - start) * 1000, 2)
                result[label]['sqliteBytes'] = len(saved)
            finally:
                restarted.close()
        print(json.dumps(dict(variant=label, **result[label])), flush=True)
    return result


for count in args.documents:
 with tempfile.TemporaryDirectory(prefix='vauldy-architecture-scale-') as temp:
  root=Path(temp);vault=root/'documents.json';profile=root/'profile.json';records=[]
  for index in range(count):
   insurance=index%50==0
   title='Vertragsunterlage' if insurance else ['Rechnung','Befund','Steuerbescheid','Kontoauszug','Wartungsbericht'][index%5]
   subject='Private Krankenversicherung Policenübersicht Themenmarker' if insurance else title+' Dokumentation und Angaben zur Leistung'
   text='\n'.join(f'--- Seite {page} ---\n{subject}\nBeleg {index} Seite {page}.\n'+('Leistungsbeschreibung und dokumentierter Sachverhalt. '*14)+('\nName: Erika Musterfrau\nE-Mail: erika@example.com' if insurance else '') for page in range(1,5))
   records.append(dict(id=str(uuid.uuid5(uuid.NAMESPACE_URL,f'vauldy-scale-{index}')),title=title,sourceName=f'document-{index}.pdf',status='indexed',pageCount=4,ocrText=text))
  vault.write_text(json.dumps(records));ids=[x['id'] for x in records]
  profile.write_text(json.dumps(dict(version=1,revision=str(uuid.uuid4()),connectionID=str(uuid.uuid4()),connectionName='Synthetic scale test',enabled=True,vaultPath=str(vault),allowedDocumentIDs=ids,acknowledgedCloudDisclosure=True)))
  logs=root/'logs';logs.mkdir(mode=0o700);previous='0'*64
  with (logs/'audit.jsonl').open('w') as output:
   for seq in range(1,1001):
    record=dict(version=1,serviceVersion='0.10.0',sequence=seq,timestamp='2026-11-03T00:00:00.000Z',session='33333333-3333-3333-3333-333333333333',event='requestStarted',operation='status',documentHandles=[])
    digest=hashlib.sha256(json.dumps(dict(record=record,previousHash=previous),sort_keys=True,separators=(',',':')).encode()).hexdigest()
    output.write(json.dumps(dict(record=record,previousHash=previous,hash=digest),sort_keys=True,separators=(',',':'))+'\n');previous=digest
  os.chmod(logs/'audit.jsonl',0o600)
  before=hashlib.sha256(vault.read_bytes()).hexdigest();before_profile=profile.read_bytes();timings={}
  if args.compare_index_variants:
   measured = compare_index_variants(root, profile, count)
   assert hashlib.sha256(vault.read_bytes()).hexdigest() == before and profile.read_bytes() == before_profile
   results.append(dict(documents=count, snapshotBytes=vault.stat().st_size, variants=measured,
                       archiveUnchanged=True, profileUnchanged=True))
   write_report()
   continue
  start=time.perf_counter();client=Client(binary,profile,server_options=server_options);timings['initializeMS']=(time.perf_counter()-start)*1000
  def call(label,name,**arguments):
   start=time.perf_counter();result=payload(client.call(name,**arguments));timings[label]=(time.perf_counter()-start)*1000;return result
  try:
   status=call('statusColdMS','get_vault_status');assert status['grantedDocumentCount']==count
   search=call('searchColdMS','search_documents',query='Krankenversicherung',limit=5)
   assert search['totalCount']==count//50 and len(search['hits'])==5
   assert all('Krankenversicherung' in hit['excerpt'] for hit in search['hits'])
   warm_search=[]
   for _ in range(20):
    call('searchWarmMS','search_documents',query='Krankenversicherung',limit=5)
    warm_search.append(timings['searchWarmMS'])
   timings['searchWarmP95MS']=sorted(warm_search)[math.ceil(0.95*len(warm_search))-1]
   page=call('filteredListFirstMS','list_documents',query='Themenmarker',pageSize=25);assert page['totalCount']==count//50
   warm_first = call('filteredListWarmFirstMS', 'list_documents', query='Themenmarker', pageSize=25)
   assert warm_first['totalCount'] == page['totalCount']
   list_calls=1;hits=list(page['items']);t=time.perf_counter()
   while page.get('nextCursor'):
    page=payload(client.call('list_documents',cursor=page['nextCursor']));hits.extend(page['items']);list_calls+=1
   timings['filteredListRemainingMS']=(time.perf_counter()-t)*1000
   assert len(hits)==count//50
   call('unfilteredFirstPageMS','list_documents',pageSize=25)
   measurements=[]
   for _ in range(3):
    start=time.perf_counter();payload(client.call('get_vault_status'));measurements.append((time.perf_counter()-start)*1000)
   timings['statusWarmMedianMS']=statistics.median(measurements)
   assert hashlib.sha256(vault.read_bytes()).hexdigest()==before and profile.read_bytes()==before_profile
   definitions=client.request('tools/list',{})['tools']
   schema=next(x['inputSchema']['properties'] for x in definitions if x['name']=='list_documents')
   supports_passages='passages' in next(x['inputSchema']['properties']['view']['enum'] for x in definitions if x['name']=='read_document')
   compact_calls=None;topic_count=None
   if 'includeExcerpts' in schema:
    topic=call('topicCompactMS','list_documents',query='kranken polic',matchMode='any-term-substring',includeExcerpts=False,pageSize=100)
    topic_count = topic['totalCount']
    assert topic_count == count // 50
    topic_items=list(topic['items'])
    while topic.get('nextCursor'):
     topic=payload(client.call('list_documents',cursor=topic['nextCursor']))
     topic_items.extend(topic['items'])
    assert len({item['document'] for item in topic_items})==topic_count and topic['retrievalComplete']
    assert all(not x['excerpt'] for x in topic_items)
    start=time.perf_counter();compact=payload(client.call('list_documents',pageSize=100,includeExcerpts=False));seen={x['document'] for x in compact['items']};compact_calls=1
    while compact.get('nextCursor'):
     compact=payload(client.call('list_documents',cursor=compact['nextCursor']));seen.update(x['document'] for x in compact['items']);compact_calls+=1
    timings['completeCompactInventoryMS']=(time.perf_counter()-start)*1000
    assert len(seen)==count and compact['retrievalComplete'] and compact_calls==count//100
    if count <= 2000:
     assert timings['completeCompactInventoryMS'] < 15_000 and timings['topicCompactMS'] < 3_000, 'Synthetic scale budget exceeded'
   assert hashlib.sha256(vault.read_bytes()).hexdigest()==before and profile.read_bytes()==before_profile
   result = dict(
       documents=count, pagesPerDocument=4, snapshotBytes=vault.stat().st_size,
       initialAuditEntries=1000, filteredDocuments=len(hits), listCalls=list_calls,
       compactListCalls=compact_calls, topicCandidates=topic_count,
       timingsMS={name: round(duration, 2) for name, duration in timings.items()},
       warmSearchSamples=len(warm_search), peakServerRSSBytes=peak_resident_bytes(client),
       archiveUnchanged=True, profileUnchanged=True,
   )
   results.append(result)
   write_report()
   print(json.dumps(result), flush=True)
  finally:client.close()
long_evidence=None
if not args.compare_index_variants and supports_passages:
 with tempfile.TemporaryDirectory(prefix='vauldy-architecture-long-') as temp:
  root=Path(temp);vault=root/'documents.json';profile=root/'profile.json';identity=str(uuid.uuid4())
  sections=[]
  for page in range(1,101):
   content='Hausratversicherung dokumentierter Leistungsumfang.' if page==42 else 'Pflegepflicht dokumentierter Tarif.' if page==87 else 'Allgemeine Hinweise zum Dokument ohne gesuchte Belegstelle.'
   content += '\n' + ('Dokumentierter Sachverhalt mit neutralen allgemeinen Angaben. ' * 30)
   sections.append(f'--- Seite {page} ---\n'+content+('\nName: Erika Musterfrau\nE-Mail: erika@example.com' if page==1 else ''))
  assert len(sections)==100
  vault.write_text(json.dumps([dict(id=identity,title='Lange Akte',sourceName='private-long.pdf',status='indexed',pageCount=100,ocrText='\n'.join(sections))]))
  profile.write_text(json.dumps(dict(version=1,revision=str(uuid.uuid4()),connectionID=str(uuid.uuid4()),connectionName='Synthetic long evidence',enabled=True,vaultPath=str(vault),allowedDocumentIDs=[identity],acknowledgedCloudDisclosure=True)))
  before=vault.read_bytes(),profile.read_bytes()
  def open_client():
   client=Client(binary,profile,server_options=server_options)
   hit=payload(client.call('list_documents',includeExcerpts=False))['items'][0]
   return client,hit['document']
  client,handle=open_client()
  try:
   start=time.perf_counter();result=payload(client.call('read_document',document=handle));calls=1;pages={x['page'] for x in result['segments']}
   while result.get('nextCursor'):
    result=payload(client.call('read_document',document=handle,cursor=result['nextCursor']));calls+=1;pages.update(x['page'] for x in result['segments'])
   full_ms=(time.perf_counter()-start)*1000;assert pages==set(range(1,101)) and calls==34
  finally:client.close()
  client,handle=open_client()
  try:
   start=time.perf_counter();result=payload(client.call('read_document',document=handle,view='passages',query='hausrat pflege'));target_ms=(time.perf_counter()-start)*1000
   assert result['matchingPassageCount']==2 and result['retrievalComplete'] and not result['containsEntireAvailableText']
   assert [x['page'] for x in result['segments']]==[42,87]
   wire=json.dumps(result);assert 'Erika Musterfrau' not in wire and 'erika@example.com' not in wire
   assert (vault.read_bytes(),profile.read_bytes())==before
   long_evidence=dict(pages=100,fullTextCalls=calls,targetedCalls=1,fullTextColdMS=round(full_ms,2),targetedColdMS=round(target_ms,2),independentColdMCPProcesses=True,verifiedSourcePages=[42,87],archiveAndProfileUnchanged=True)
   print(json.dumps({'longEvidence':long_evidence}),flush=True)
  finally:client.close()
write_report(long_evidence)
