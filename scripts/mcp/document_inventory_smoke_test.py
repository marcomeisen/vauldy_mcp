#!/usr/bin/env python3
"""Real stdio inventory with synthetic metadata: dates, stable identity, legacy SQLite and grants."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import re
from pathlib import Path
import shutil
import sqlite3
import statistics
import tempfile
import time
import uuid
from smoke_test import Client, payload, assert_v1_discovery
from topic_overview_smoke_test import write_json


def identity(raw):
    return 'doc_'+hashlib.sha256(b'vauldy.document-reference.v1\0'+raw.lower().encode()).hexdigest()


def legacy_projection(vault):
    with sqlite3.connect(vault) as db:
        for key,raw in db.execute('SELECT id,payload FROM record_projection_v1').fetchall():
            obj=json.loads(raw)
            for name in ['inventoryVersion','importedAt','contentHash','originalState']:obj['metadata'].pop(name,None)
            data=json.dumps(obj,separators=(',',':'),sort_keys=True).encode()
            db.execute('UPDATE record_projection_v1 SET payload=?,digest=? WHERE id=?',(data,hashlib.sha256(data).digest(),key))


def records(vault):
    if vault.suffix=='.json':return json.loads(vault.read_text())
    with sqlite3.connect(vault) as db:return [json.loads(r[0]) for r in db.execute('SELECT payload FROM records')]


def original_time(record):
    value=record.get('importedAt')
    if not value or value.startswith('0001-'):return None
    return datetime.fromisoformat(value.replace('Z','+00:00')).timestamp()


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('server',type=Path);parser.add_argument('fixtures',type=Path);parser.add_argument('--report',type=Path,required=True);args=parser.parse_args()
    report=dict(scope='actual local stdio; synthetic metadata, no live ChatGPT',cases=[])
    with tempfile.TemporaryDirectory(prefix='vauldy-inventory-wire-') as temp:
        root=Path(temp)
        for name in ['json','sqlite','legacy-sqlite','large']:
            fixture=args.fixtures/('sqlite' if name=='legacy-sqlite' else name)
            if not (fixture/'fixture.json').exists():raise AssertionError('Missing current native fixture: '+name)
            info=json.loads((fixture/'fixture.json').read_text());target=root/name;shutil.copytree(fixture,target)
            vault=target/Path(info['vault']).relative_to(fixture)
            if name=='legacy-sqlite':legacy_projection(vault)
            all_records=records(vault);allowed={v.upper() for v in info['granted']};selected=[r for r in all_records if r['id'].upper() in allowed]
            known=sorted([r for r in selected if original_time(r) is not None],key=lambda r:(-original_time(r),identity(r['id'])))
            unknown=sorted([r for r in selected if original_time(r) is None],key=lambda r:identity(r['id']))
            expected=known+unknown
            grant=dict(version=1,revision=str(uuid.uuid4()),connectionID=str(uuid.uuid4()),connectionName='Synthetic inventory acceptance',enabled=True,vaultPath=str(vault),allowedDocumentIDs=info['granted'],acknowledgedCloudDisclosure=True)
            profile=target/'profile.json';write_json(profile,grant);before=vault.read_bytes(),profile.read_bytes();client=Client(args.server.resolve(),profile)
            def inv(**kw):return payload(client.call('get_document_inventory',**kw),schema)
            try:
                tools=client.request('tools/list',{})['tools'];assert_v1_discovery(tools)
                schema=next(t['outputSchema'] for t in tools if t['name']=='get_document_inventory')
                first_size=5 if name=='large' else 2
                started=time.perf_counter();first=inv(pageSize=first_size);cold=(time.perf_counter()-started)*1000
                assert [r['documentID'] for r in first['items']]==[identity(d['id']) for d in expected[:first_size]]
                assert first['totalCount']==len(selected) and first['scope']=='currently-authorized-documents'
                last=inv(pageSize=100) if name=='large' else first
                output=list(last['items']);pages=1
                while last.get('nextCursor'):last=inv(cursor=last['nextCursor']);output+=last['items'];pages+=1
                assert last['retrievalComplete'] and len(output)==len(expected)
                assert [r['documentID'] for r in output]==[identity(d['id']) for d in expected]
                for row,source in zip(output,expected):
                    if original_time(source) is None:assert 'importedAt' not in row
                    else:assert datetime.fromisoformat(row['importedAt'].replace('Z','+00:00')).timestamp()==original_time(source)
                    assert row.get('contentHash')==source.get('localImport',{}).get('contentHash')
                wire=json.dumps(output).lower()
                raw_ids={v.lower() for v in info['granted']}|{info.get('hidden','never-present').lower()}
                exposed=set(re.findall(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',wire))
                assert not raw_ids.intersection(exposed),'Original UUID leaked'
                for raw in [str(target),'Private synthetic','private-source.pdf']:
                    assert raw.lower() not in wire,raw
                assert (vault.read_bytes(),profile.read_bytes())==before,'Read mutated source/profile'
                if name!='large':
                    sample=first['items'][0]
                    assert not client.call('read_document',document=sample['document']).get('isError',False),'Inventory handle must read the correct source'
                    assert client.call('read_document',document=sample['documentID'])['isError'],'Stable identity is not an access capability'
                    for invalid in [dict(pageSize=0),dict(pageSize=101),dict(order='unknown'),dict(cursor=first['nextCursor'],order='imported-asc'),dict(cursor=first['nextCursor']+':forged')]:
                        assert client.call('get_document_inventory',**invalid)['isError'],invalid
                    client.close();client=Client(args.server.resolve(),profile)
                    restarted=inv(pageSize=first_size)
                    assert [(r['documentID'],r.get('importedAt'),r.get('contentHash')) for r in first['items']]==[(r['documentID'],r.get('importedAt'),r.get('contentHash')) for r in restarted['items']]
                    assert restarted['items'][0]['document']!=sample['document']
                    grant.update(revision=str(uuid.uuid4()),connectionID=str(uuid.uuid4()));write_json(profile,grant)
                    revised=inv(pageSize=5);assert revised['items'][0]['documentID']==sample['documentID']
                    removed=expected[0]['id'];grant['allowedDocumentIDs']=[s for s in grant['allowedDocumentIDs'] if s.upper()!=removed.upper()];grant['revision']=str(uuid.uuid4());write_json(profile,grant)
                    assert client.call('get_document_inventory',cursor=restarted['nextCursor'])['isError']
                    reduced=inv(pageSize=100);assert reduced['totalCount']==len(selected)-1 and sample['documentID'] not in [i['documentID'] for i in reduced['items']]
                    assert 'MISSING_ROW_DOES_NOT_PROVE_DELETION' in reduced['warnings']
                    assert vault.read_bytes()==before[0],'Grant removal is not document deletion'
                    grant.update(enabled=False,revision=str(uuid.uuid4()));write_json(profile,grant)
                    assert client.call('get_document_inventory')['isError']
                else:
                    samples=[]
                    for _ in range(5):
                        start=time.perf_counter();inv(pageSize=5);samples.append((time.perf_counter()-start)*1000)
                    report['largeWarm']=dict(runs=5,medianMS=round(statistics.median(samples),3),p95MS=round(sorted(samples)[math.ceil(.95*len(samples))-1],3),note='five observed requests; not a general latency SLA')
                report['cases'].append(dict(case=name,passed=True,documents=len(selected),fullPaginationCalls=pages,firstPageMS=round(cold,3),firstPageCalls=1,readOnly=True))
            finally:client.close()
    report.update(passed=True,v1SchemasUnchanged=True,stableIdentityAcrossRestartsAndGrantChanges=True,unknownDatesLast=True,revocationPassed=True,legacySQLiteReadWithoutMigration=True)
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print(json.dumps(report,ensure_ascii=False))


if __name__=='__main__':main()
