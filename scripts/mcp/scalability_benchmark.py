#!/usr/bin/env python3
"""Synthetic 1k/2k real-MCP scaling benchmark; no user archives or installations."""
import sys,json,time,uuid,tempfile,hashlib,os,statistics,subprocess
from pathlib import Path
sys.dont_write_bytecode=True;sys.path.insert(0,str(Path(__file__).resolve().parent))
from smoke_test import Client,payload
binary=Path(sys.argv[1]);destination=Path(sys.argv[2]);results=[]
for count in [1000,2000]:
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
  start=time.perf_counter();client=Client(binary,profile);timings['initializeMS']=(time.perf_counter()-start)*1000
  def call(label,name,**arguments):
   start=time.perf_counter();result=payload(client.call(name,**arguments));timings[label]=(time.perf_counter()-start)*1000;return result
  try:
   status=call('statusColdMS','get_vault_status');assert status['grantedDocumentCount']==count
   search=call('searchColdMS','search_documents',query='Krankenversicherung',limit=5)
   call('searchWarmMS','search_documents',query='Krankenversicherung',limit=5)
   page=call('filteredListFirstMS','list_documents',query='Themenmarker',pageSize=25);assert page['totalCount']==count//50
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
    topic_count=topic['totalCount'];assert topic_count==count//50 and topic['retrievalComplete']
    assert all(not x['excerpt'] for x in topic['items'])
    start=time.perf_counter();compact=payload(client.call('list_documents',pageSize=100,includeExcerpts=False));seen={x['document'] for x in compact['items']};compact_calls=1
    while compact.get('nextCursor'):
     compact=payload(client.call('list_documents',cursor=compact['nextCursor']));seen.update(x['document'] for x in compact['items']);compact_calls+=1
    timings['completeCompactInventoryMS']=(time.perf_counter()-start)*1000
    assert len(seen)==count and compact['retrievalComplete'] and compact_calls==count//100
    assert timings['completeCompactInventoryMS'] < 15_000 and timings['topicCompactMS'] < 3_000, 'Synthetic scale budget exceeded'
   result=dict(documents=count,pagesPerDocument=4,snapshotBytes=vault.stat().st_size,initialAuditEntries=1000,filteredDocuments=len(hits),listCalls=list_calls,compactListCalls=compact_calls,topicCandidates=topic_count,timingsMS={k:round(v,2) for k,v in timings.items()},archiveUnchanged=True,profileUnchanged=True)
   results.append(result);print(json.dumps(result),flush=True)
  finally:client.close()
long_evidence=None
if supports_passages:
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
   client=Client(binary,profile)
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
destination.parent.mkdir(parents=True,exist_ok=True);destination.write_text(json.dumps(dict(binaryVersion=subprocess.check_output([str(binary),'--version'],text=True).strip(),syntheticOnly=True,cases=results,longEvidence=long_evidence),indent=2))
