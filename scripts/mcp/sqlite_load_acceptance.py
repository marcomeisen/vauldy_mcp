#!/usr/bin/env python3
"""R3d synthetic SQLite load acceptance. Never reads an installed vault/profile or uses a relay.
Native server peak RSS via /usr/bin/time -l; sampled RSS only enforces an emergency budget.
A failed/timeout gate is recorded, never replaced with a smaller fixture or a passing percentile.
"""
import argparse
import contextlib
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import signal
import sqlite3
import statistics
import subprocess
import tempfile
import threading
import time
import uuid

from stdio_client import Client
from smoke_test import payload
from import_smoke_test import command, stop_worker
from architecture_review_probe import grant
from topic_overview_smoke_test import write_json

MIB = 1024 * 1024
GATES = dict(coldStatusMS=5000, warmCompactP95MS=1000, warmStatusP95MS=1000,
             peakRSSBytes=512*MIB, filteredListMS=5000)


def stats(values):
    if not values: return dict(samples=0)
    return dict(samples=len(values), medianMS=round(statistics.median(values),3),
                p95MS=round(sorted(values)[math.ceil(len(values)*.95)-1],3))


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for part in iter(lambda: f.read(MIB), b''): h.update(part)
    return h.hexdigest()


class MeasuredClient:
    def __init__(self, binary, profile, root, label, options=(), request_seconds=30):
        self.log = root/(label+'.rss'); wrapper=root/(label+'.sh')
        wrapper.write_text('#!/bin/sh\nexec /usr/bin/time -l '+shlex.quote(str(binary))+' "$@"\n'); wrapper.chmod(0o700)
        self.stderr=self.log.open('wb'); self.metrics={}; self.stop=threading.Event(); self.timeout=request_seconds
        self.client=Client(wrapper,profile,stderr=self.stderr,server_options=options,timeout=request_seconds)
        self.server_pid=int(subprocess.check_output(['pgrep','-P',str(self.client.process.pid)],text=True).split()[0])
        self.watcher=threading.Thread(target=self.guard,daemon=True); self.watcher.start()
    def guard(self):
        while not self.stop.wait(.2):
            try:
                fields=subprocess.check_output(['ps','-o','ppid=,rss=','-p',str(self.server_pid)],text=True,stderr=subprocess.DEVNULL).split()
                if len(fields)==2 and int(fields[0])==self.client.process.pid:
                    rss=int(fields[1])*1024
                    self.metrics['sampledMaxRSSBytes']=max(rss,self.metrics.get('sampledMaxRSSBytes',0))
                    if rss>1536*MIB:
                        self.metrics['emergencyMemoryStop']=True; os.kill(self.server_pid,signal.SIGKILL); return
            except (subprocess.SubprocessError,ValueError,ProcessLookupError): return
    def call(self,name,**arguments):
        start=time.perf_counter()
        value=self.client.request('tools/call',dict(name=name,arguments=arguments),timeout=self.timeout)
        return value,(time.perf_counter()-start)*1000
    def close(self):
        self.stop.set(); self.watcher.join(timeout=2)
        # Kill only this owned server if a timed-out request is still running, so time -l reaps it.
        if self.client.process.poll() is None:
            with contextlib.suppress(BrokenPipeError,OSError): self.client.process.stdin.close()
            try: self.client.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError): os.kill(self.server_pid,signal.SIGKILL)
                self.client.process.wait(timeout=5)
        self.client.close(); self.stderr.close()
        text=self.log.read_text(); match=re.search(r'(\d+)\s+maximum resident set size',text)
        if match:self.metrics['peakRSSBytes']=int(match.group(1))
        else:self.metrics['nativePeakRSSMissing']=True


def fill(db,seed,count,text_bytes):
    ids=[]; expected={}; total_bytes=0; started=time.perf_counter()
    prose='Dieser synthetische Text beschreibt allgemeine Bedingungen und Beispiele zur lokalen Ablage. '
    with sqlite3.connect(db) as connection:
        connection.execute('PRAGMA max_page_count=262144')
        for index in range(count):
            value=copy.deepcopy(seed); value['id']=str(uuid.uuid5(uuid.NAMESPACE_URL,'vauldy-r3d/'+str(index))).upper()
            kind=['Versicherung','Rechnung','Steuerbescheid','Befund'][index%4]
            value['title']='Synthetischer '+kind; value['sourceName']='synthetic.pdf'; value['summary']=''; value['category']=''
            for key in ['baseAnalysis','baseAnalysisSourceHash']:value.pop(key,None)
            for key in ['entities','contentFacts','deadlines']:value[key]=[]
            pages=[]
            for page in range(8):
                header=(kind+'\n' if page==0 else '')+('Pruefmarker%06d\n'%index if page==7 else '')
                pages.append('--- Seite %d ---\n'%(page+1)+header+(prose*100)[:text_bytes//8-len(header)-24])
            value['ocrText']='\n\n'.join(pages); value['pageCount']=8
            metadata=value['localImport'];metadata.pop('metrics',None)
            metadata['contentHash']=hashlib.sha256(('fixture-'+str(index)).encode()).hexdigest()
            metadata['pages']=[dict(seed['localImport']['pages'][0],page=p+1) for p in range(8)]
            data=json.dumps(value,ensure_ascii=False,separators=(',',':')).encode();total_bytes+=len(data)
            connection.execute('INSERT INTO records VALUES(?,?,?,?,?,?,?)',
                (value['id'],data,hashlib.sha256(data).digest(),metadata['contentHash'],'','','completed'))
            ids.append(value['id']);expected[value['id']]=kind
    return ids,expected,dict(seedWriteMS=round((time.perf_counter()-started)*1000,3),payloadBytes=total_bytes)


def case(binary,profile,root,label,ids,expected,all_count,samples,options=(),projection_gates=False,search_gates=False):
    row=dict(granted=len(ids),options=list(options)); client=None
    try:
        client=MeasuredClient(binary,profile,root,label,options)
        response,row['coldStatusMS']=client.call('get_vault_status');assert payload(response)['grantedDocumentCount']==len(ids)
        for name,args,key in [('get_vault_status',{},'warmStatus'),('list_documents',dict(includeExcerpts=False,pageSize=100),'warmCompact')]:
            times=[]; started=time.monotonic()
            for _ in range(samples):
                response,elapsed=client.call(name,**args);data=payload(response)
                assert data['grantedDocumentCount' if name=='get_vault_status' else 'totalCount']==len(ids)
                times.append(elapsed)
                if time.monotonic()-started>120:break
            row[key]=stats(times);row[key]['completedRequestedSamples']=len(times)==samples
        # Complete compact pagination must enumerate all grants once, never trim to a cache budget.
        started=time.perf_counter(); response,_=client.call('list_documents',includeExcerpts=False,pageSize=100)
        page=payload(response); handles=set(); calls=0
        while True:
            calls+=1;items=page['items']; current={i['document'] for i in items}
            assert len(current)==len(items) and not handles.intersection(current)
            handles.update(current)
            if not page.get('nextCursor'):break
            page=payload(client.call('list_documents',cursor=page['nextCursor'])[0])
        assert len(handles)==len(ids) and page['retrievalComplete']
        row['pagination']=dict(documents=len(handles),calls=calls,totalMS=round((time.perf_counter()-started)*1000,3),complete=True)
        # Narrowing keeps at least one valid grant, invalidates old handles/cursors, then disables access.
        old_handle=next(iter(handles)); old=json.loads(profile.read_text())
        if projection_gates:
            response, elapsed = client.call('read_document', document=old_handle)
            assert payload(response)['segments']
            row['readFromCompactHandleMS'] = round(elapsed, 3)
        write_json(profile,dict(old,allowedDocumentIDs=ids[-1:],revision=str(uuid.uuid4())))
        assert client.call('read_document',document=old_handle)[0]['isError']
        response,elapsed=client.call('get_vault_status');assert payload(response)['grantedDocumentCount']==1
        row['narrowGrantMS']=round(elapsed,3)
        write_json(profile,dict(old,enabled=False,revision=str(uuid.uuid4())))
        start=time.perf_counter()
        for name,arguments in [('read_document',dict(document=old_handle)),('list_documents',dict(includeExcerpts=False)),('search_documents',dict(query='Versicherung'))]:
            assert client.call(name,**arguments)[0]['isError']
        row['revocation']=dict(readListSearchBlocked=True,threeCallsMS=round((time.perf_counter()-start)*1000,3))
        write_json(profile,old)
        if not projection_gates:
            row['filters']=[]
            for term in ['Versicherung','Befund','NichtvorhandenerSuchbegriff']:
                expected_count=sum(expected.get(i)==term for i in ids)
                try:
                    response,elapsed=client.call('list_documents',query=term,includeExcerpts=False,pageSize=100)
                    data=payload(response);assert data['totalCount']==expected_count
                    row['filters'].append(dict(query=term,expected=expected_count,actual=data['totalCount'],milliseconds=round(elapsed,3),passed=True))
                except TimeoutError:
                    row['filters'].append(dict(query=term,expected=expected_count,timedOutAfterSeconds=client.timeout,passed=False));raise
            # Exact token at end of a long record, and a non-match, are independent retrieval checks.
            if ids:
                i=next((i for i in ids if i in expected),None)
                if i:
                    index=next(k for k in range(all_count) if str(uuid.uuid5(uuid.NAMESPACE_URL,'vauldy-r3d/'+str(k))).upper()==i)
                    response,elapsed=client.call('search_documents',query='Pruefmarker%06d'%index,limit=1)
                    assert payload(response)['totalCount']==1
                    row['rankedExactMarkerMS']=round(elapsed,3)
            if search_gates:
                expected_count = sum(expected.get(i) == 'Versicherung' for i in ids)
                response, elapsed = client.call('list_documents', query='versicher', matchMode='any-term-substring',
                                                includeExcerpts=False, pageSize=100)
                assert payload(response)['totalCount'] == expected_count
                row['filters'].append(dict(query='versicher', expected=expected_count, actual=expected_count,
                                           milliseconds=round(elapsed,3), passed=True))
                if label == 'all' and all_count == 20000:
                    response, elapsed = client.call('get_topic_overview', topic='insurance')
                    data = payload(response)
                    assert data['candidateCount'] == expected_count and len(data['rows']) == 25
                    row['insuranceOverviewFirstPageMS'] = round(elapsed,3)
        row['correctness']='pass'
    except Exception as error:
        row['correctness']='incomplete-or-failed';row['failureType']=type(error).__name__
        # No raw protocol/document text is logged. Preserve bounded metrics even on timeout/resource stop.
    finally:
        if client:
            client.close();row.update(client.metrics)
    failures=[]
    for metric,limit in [('coldStatusMS',GATES['coldStatusMS']),('peakRSSBytes',GATES['peakRSSBytes'])]:
        if metric not in row or row[metric]>limit:failures.append(metric)
    for metric in ['warmStatus','warmCompact']:
        if not row.get(metric,{}).get('completedRequestedSamples') or row[metric].get('p95MS',float('inf'))>1000:failures.append(metric)
    if row.get('correctness')!='pass':failures.append('correctnessIncomplete')
    if any(not f.get('passed') or f.get('milliseconds',float('inf'))>GATES['filteredListMS'] for f in row.get('filters',[])):failures.append('filterLatencyOrCompleteness')
    row['failedGates']=failures;row['go']=not failures
    return row


def lifecycle(local,binary,store,db,root,ids,expected,seed):
    profile=root/'lifecycle-profile.json';selected=ids[:100];original_profile=grant(db,selected);write_json(profile,original_profile)
    client=Client(binary,profile);worker=importer=None;result={}
    try:
        first=payload(client.call('list_documents',includeExcerpts=False,pageSize=1))
        handle=first['items'][0]['document'];cursor=first['nextCursor']
        # Uncommitted SQL changes must roll back after process death, without advancing generation.
        with sqlite3.connect(db) as sql:generation=sql.execute('SELECT token FROM generation').fetchone()[0]
        transaction=subprocess.Popen(['/usr/bin/python3','-c',
            "import sqlite3,sys,time; d=sqlite3.connect(sys.argv[1]); d.execute('BEGIN IMMEDIATE'); d.execute(\"UPDATE records SET payload=x'00' WHERE id=?\",(sys.argv[2],)); print('READY',flush=True); time.sleep(60)",str(db),selected[0]],stdout=subprocess.PIPE,text=True)
        try:
            assert transaction.stdout.readline().strip()=='READY';transaction.kill();transaction.wait(timeout=5)
        finally:
            if transaction.poll() is None:transaction.kill();transaction.wait(timeout=5)
            transaction.stdout.close()
        with sqlite3.connect(db) as sql:
            assert sql.execute('SELECT token FROM generation').fetchone()[0]==generation
            assert sql.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        result['uncommittedSQLCrashRolledBack']=True
        image=root/'next.png';command(local,'example','--output',image);original=image.read_bytes()
        (store/'worker/stop').unlink(missing_ok=True)
        worker=subprocess.Popen([str(local),'worker','--store',str(store),'--no-watch'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        deadline=time.monotonic()+15
        while not command(local,'worker-status','--store',store)['running']:
            assert worker.poll() is None and time.monotonic()<deadline;time.sleep(.02)
        started=time.perf_counter();importer=subprocess.Popen([str(local),'import','--store',str(store),str(image)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        times=[];errors=0;killed=False;deadline=time.monotonic()+180
        while importer.poll() is None:
            assert time.monotonic()<deadline
            if not killed:
                with sqlite3.connect(db) as sql:active=sql.execute("SELECT count(*) FROM records WHERE import_state='recognizing'").fetchone()[0]
                if active:worker.kill();worker.wait(timeout=5);killed=True
            start=time.perf_counter();response=client.call('list_documents',includeExcerpts=False);times.append((time.perf_counter()-start)*1000)
            if response.get('isError'):
                assert response['content'][0]['text'] in [
                    'Die Freigabe oder das Dokument hat sich geändert. Bitte erneut suchen.',
                    'Der freigegebene lokale Bestand ist nicht lesbar. Original und Bestand bleiben unverändert.']
                errors+=1
            else:assert payload(response)['totalCount']==len(selected)
            time.sleep(.01)
        stdout,stderr=importer.communicate(timeout=10)
        assert importer.returncode==0 and json.loads(stdout)[0]['state']=='completed' and killed
        result.update(workerKilledDuringOCR=True,automaticWorkerRestart=True,importIncludingRecoveryMS=round((time.perf_counter()-started)*1000,3),
                      concurrentList=stats(times),concurrentSourceChangeErrors=errors)
        assert client.call('read_document',document=handle)['isError'] and client.call('list_documents',cursor=cursor)['isError']
        with sqlite3.connect(db) as sql:
            assert sql.execute("SELECT count(*) FROM records WHERE import_state='recognizing'").fetchone()[0]==0
            assert sql.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
            final_count=sql.execute('SELECT count(*) FROM records').fetchone()[0]
        assert image.read_bytes()==original and json.loads(profile.read_text())==original_profile
        result.update(finalDocuments=final_count,newImportDidNotExpandGrant=True,oldHandlesAndCursorsRejected=True,originalUnchanged=True)
        client.close();client=Client(binary,profile)
        start=time.perf_counter();assert payload(client.call('get_vault_status'))['grantedDocumentCount']==len(selected)
        result['restartStatusMS']=round((time.perf_counter()-start)*1000,3)
        fresh=payload(client.call('list_documents',includeExcerpts=False))['items'][0]['document']
        write_json(profile,dict(original_profile,enabled=False,revision=str(uuid.uuid4())))
        assert client.call('read_document',document=fresh)['isError'] and client.call('search_documents',query='Versicherung')['isError']
        result['revocationAfterRestart']=True
        return result
    finally:
        if importer and importer.poll() is None:importer.kill();importer.communicate()
        if worker and worker.poll() is None:worker.kill();worker.wait(timeout=5)
        client.close();stop_worker(local,store)


def index_lifecycle(binary,db,root,ids,expected):
    profile=root/'index-profile.json';value=grant(db,ids[:100]);write_json(profile,value)
    prefix='.vauldy-index-'+hashlib.sha256(profile.name.encode()).hexdigest()
    directory=root/prefix;client=None;thread=None;stop=threading.Event();observed=[]
    def act(action):
        while not stop.wait(.002):
            if list(directory.glob('.build-*')):
                observed.append(action)
                if action=='revoke':write_json(profile,dict(value,enabled=False,revision=str(uuid.uuid4())))
                else:client.process.kill()
                return
    try:
        client=Client(binary,profile,server_options=('--persistent-sqlite-index',))
        thread=threading.Thread(target=act,args=('revoke',),daemon=True);thread.start()
        response=client.call('list_documents',query='Versicherung',includeExcerpts=False)
        thread.join(timeout=2)
        assert observed==['revoke'] and response.get('isError') and not response.get('structuredContent')
        assert client.call('list_documents',includeExcerpts=False)['isError']
        assert not list(directory.glob('.build-*'))
        client.close();value['revision']=str(uuid.uuid4());write_json(profile,value)
        client=Client(binary,profile,server_options=('--persistent-sqlite-index',))
        thread=threading.Thread(target=act,args=('kill',),daemon=True);thread.start()
        try:
            client.call('list_documents',query='Versicherung',includeExcerpts=False)
            raise AssertionError('Killed index builder returned success')
        except (RuntimeError,BrokenPipeError):pass
        thread.join(timeout=2);assert observed==['revoke','kill']
        client.close();client=Client(binary,profile,server_options=('--persistent-sqlite-index',))
        start=time.perf_counter()
        response=payload(client.call('list_documents',query='Versicherung',includeExcerpts=False))
        assert response['totalCount']==sum(expected.get(i)=='Versicherung' for i in ids[:100])
        assert not list(directory.glob('.build-*'))
        return dict(granted=100,revokedWhileStagingObserved=True,revokedReplyContainedNoData=True,
                    builderSIGKILL=True,restartRebuiltAndRemovedStaging=True,
                    restartQueryMS=round((time.perf_counter()-start)*1000,3),
                    derivedIndexBytes=sum(p.stat().st_size for p in directory.iterdir() if p.is_file()))
    finally:
        stop.set()
        if thread:thread.join(timeout=2)
        if client:client.close()


def search_index_recovery(local, binary, store, db, root, ids):
    profile = root/'search-recovery.json'
    write_json(profile, grant(db, ids[:100]))

    def state():
        with sqlite3.connect(db) as sql:
            return (sql.execute('SELECT token FROM generation').fetchone()[0],
                    sql.execute('SELECT count(*) FROM search_indexed_v1').fetchone()[0],
                    sql.execute('SELECT count(*) FROM search_terms_v1').fetchone()[0])

    before = state()
    journal = Path(str(db) + '-journal')
    def journal_populated():
        try:
            return journal.stat().st_size > 512
        except FileNotFoundError:
            return False

    process = subprocess.Popen([str(local), 'storage-rebuild-projections', '--store', str(store)],
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 15
        while not journal_populated():
            assert process.poll() is None and time.monotonic() < deadline, 'No populated rollback journal observed'
            time.sleep(.002)
        process.kill()
        process.wait(timeout=5)
        assert process.returncode == -signal.SIGKILL
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
    # A writable SQLite connection can recover the private hot journal before MCP starts.
    assert state() == before, 'Index row counts or committed generation changed after SIGKILL'
    with sqlite3.connect(db) as sql:
        assert sql.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    # An unsynced journal need not be hot. SQLite can remove it on the next write.
    start = time.perf_counter()
    command(local, 'storage-rebuild-projections', '--store', store)
    elapsed = (time.perf_counter() - start) * 1000
    assert state()[1:] == before[1:], 'Rebuilt index row counts differ'
    assert not journal.exists(), 'Journal remains after successful rebuild'
    client = Client(binary, profile)
    try:
        result = payload(client.call('list_documents', query='Versicherung', includeExcerpts=False))
        assert result['totalCount'] == 25
    finally:
        client.close()
    return dict(builderKilledAfterJournalObserved=True, priorIndexAndGenerationRecovered=True,
                journalRemoved=True, rebuildAndQueryPassed=True, rebuildMS=round(elapsed,3))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('local_binary',type=lambda p:Path(p).resolve());parser.add_argument('mcp_binary',type=lambda p:Path(p).resolve())
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--counts',default='1000,2000,5000,10000,20000')
    parser.add_argument('--samples',type=int,default=25);parser.add_argument('--text-bytes',type=int,default=32768)
    parser.add_argument('--projection-gates', action='store_true',
                        help='Build stored projections and measure status, unfiltered compact lists and reading a compact handle; omit text-search gates.')
    parser.add_argument('--search-gates', action='store_true',
                        help='Build the current index and test exact, substring and ranked retrieval plus index recovery.')
    parser.add_argument('--recovery-at', type=int, default=20000,
                        help='Fixture size at which to run the SQLite index-abort test in search mode.')
    args=parser.parse_args();
    if args.search_gates and args.projection_gates:
        parser.error('Choose one scoped gate set.')
    counts=[int(x) for x in args.counts.split(',')];assert all(100<=n<=20000 for n in counts)
    report=dict(scope='Local stdio, synthetic long OCR records, no relay or installed data; not ChatGPT latency or 20k native OCR ingestion.',
        gates=GATES,emergencyRSSLimitBytes=1536*MIB,samplesRequested=args.samples,textBytesPerGeneratedDocument=args.text_bytes,
        localSHA256=digest(args.local_binary),mcpSHA256=digest(args.mcp_binary),cases=[])
    if args.projection_gates:
        report['scope'] = 'R3d.1 only: status, unfiltered compact lists and reads from compact handles. Text-search acceptance excluded.'
        report['gates'] = {k: v for k, v in GATES.items() if k != 'filteredListMS'}
    if args.search_gates:
        report['scope'] = 'R3d.2: SQLite projections and incremental search index, local stdio and synthetic data.'
    def save():args.output.write_text(json.dumps(report,indent=2)+'\n')
    save()
    for count in counts:
        with tempfile.TemporaryDirectory(prefix='vauldy-r3d-%d-'%count) as temporary:
            root=Path(temporary);store=root/'vault';pdf=root/'seed.pdf'
            row=dict(documents=count);report['cases'].append(row)
            try:
                db=Path(command(args.local_binary,'create-sqlite','--store',store)['vaultPath'])
                command(args.local_binary,'example','--output',pdf);command(args.local_binary,'import','--store',store,pdf);stop_worker(args.local_binary,store)
                with sqlite3.connect(db) as sql:seed=json.loads(sql.execute('SELECT payload FROM records').fetchone()[0])
                ids,expected,fill_metrics=fill(db,seed,count-2,args.text_bytes);row.update(fill_metrics)
                print(json.dumps(dict(stage='fixture',documents=count,bytes=db.stat().st_size)),flush=True)
                if args.projection_gates or args.search_gates:
                    started = time.perf_counter()
                    command(args.local_binary, 'storage-rebuild-projections', '--store', store)
                    row['projectionBackfillMS'] = round((time.perf_counter() - started) * 1000, 3)
                row['lifecycle']=lifecycle(args.local_binary,args.mcp_binary,store,db,root,ids,expected,seed)
                assert row['lifecycle']['finalDocuments']==count
                with sqlite3.connect(db) as sql:all_ids=[x[0] for x in sql.execute('SELECT id FROM records ORDER BY id')]
                before=digest(db);row['databaseBytes']=db.stat().st_size
                row['selectionCases']={}
                for label,selection in [('small',ids[:100]),('all',all_ids)]:
                    profile=root/(label+'-profile.json');write_json(profile,grant(db,selection))
                    print(json.dumps(dict(stage='queries',documents=count,selection=label)),flush=True)
                    row['selectionCases'][label]=case(args.mcp_binary,profile,root,label,selection,expected,count,args.samples,projection_gates=args.projection_gates,search_gates=args.search_gates)
                    save();print(json.dumps(dict(stage='case-finished',documents=count,selection=label,result=row['selectionCases'][label])),flush=True)
                if count==20000 and not args.projection_gates and not args.search_gates:
                    row['persistentIndexLifecycle']=index_lifecycle(args.mcp_binary,db,root,ids,expected)
                assert digest(db)==before;row['readOnlySourceUnchanged']=True
                if count==args.recovery_at and args.search_gates:
                    row['searchIndexRecovery']=search_index_recovery(args.local_binary,args.mcp_binary,store,db,root,ids)
                row['go']=all(c['go'] for c in row['selectionCases'].values())
            except Exception as error:
                row['failureType']=type(error).__name__;row['go']=False
                failure = dict(stage='case-failed', documents=count, failureType=type(error).__name__)
                if isinstance(error, AssertionError) and error.args:
                    failure['check'] = str(error)
                print(json.dumps(failure), flush=True)
            finally:
                if store.exists():stop_worker(args.local_binary,store)
                save()
    report['go']=all(r.get('go') for r in report['cases']) and len(report['cases'])==len(counts);save()
    print(json.dumps(dict(stage='finished',go=report['go'],output=str(args.output))),flush=True)


if __name__=='__main__':main()
