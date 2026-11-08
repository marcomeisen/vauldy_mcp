#!/usr/bin/env python3
"""Product-oriented LOCAL MCP acceptance, synthetic sources only.

Answers are deterministic extractive reference answers, NOT generated ChatGPT responses.
Ground truth is used only by the evaluator, never by retrieval or answer composition.
Saved evidence packets support separate, offline structured-answer checks.
"""
import argparse
from collections import Counter
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re
import shutil
import time
import uuid

from smoke_test import Client, payload, assert_v1_discovery
from topic_overview_smoke_test import document, write_json

ROOT = Path(__file__).resolve().parents[2]
READY = {'all-declared-pages-processed', 'all-declared-pages-have-ocr-text'}
PERIOD = {'monatliche rate':'monthly', 'monatsrate':'monthly', 'jahresbeitrag':'annual', 'gesamtbetrag':'total'}


def money(value):
    match = re.fullmatch(r'\s*([\d., ]+)\s*(EUR|€)\s*',value)
    if not match: raise ValueError('Not an evidenced EUR amount')
    number=match[1].replace(' ','')
    if ',' in number:number=number.replace('.','').replace(',','.')
    return str(Decimal(number).quantize(Decimal('.01')))


def evidence(row):
    return {key:row[key] for key in ['document','page','quote','source']}


def validate_answer(question, answer, pages):
    """Independent semantic oracle + exact protected physical-page quote binding."""
    expected=question['expected']
    assert set(answer)<= {'id','question','status','claims','rows','warnings'},'Unvalidated extra answer prose/fields'
    assert answer['id']==question['id'] and answer['question']==question['question']
    assert answer['status']==expected['status'],(question['id'],'status',answer)
    assert set(expected.get('warnings',[]))<=set(answer['warnings'])
    claims=answer.get('claims',[])
    assert not answer.get('rows') or question['kind']=='topic'
    if question['kind']=='topic':assert not claims
    for claim in claims:
        keys={'field','value','evidence'}
        if question['kind']=='cost':keys|={'unit','period'}
        if expected['status']=='calculated':keys.add('method')
        assert set(claim)==keys
        assert claim.get('evidence'),'Missing evidence'
        for source in claim['evidence']:
            assert set(source)=={'document','page','quote','source'}
            assert type(source['page']) is int and source['page']>0
            assert source['source']==f"[Quelle:{source['document']}:S.{source['page']}]"
            assert source['quote'] and source['quote'] in pages[(source['document'],source['page'])], 'Quote/page mismatch'
            context='\n'.join(text for (handle,_),text in pages.items() if handle==source['document'])
            assert expected.get('sourceContains','').casefold() in context.casefold(),'Wrong source document'
    if question['kind']=='topic':
        rows=answer['rows']; counts=Counter(row['status'] for row in rows)
        assert counts=={'policy-heading':expected['policyHeadings'],'topic-mention':expected['mentions']}
        assert len({r['document'] for r in rows})==len(rows)
        for row in rows:
            assert set(row)=={'document','status','evidence'}
            source=row['evidence'];assert source['document']==row['document']
            assert source['source']==f"[Quelle:{row['document']}:S.{source['page']}]"
            assert source['quote'] in pages[(row['document'],source['page'])]
            context='\n'.join(text for (handle,_),text in pages.items() if handle==row['document'])
            heading=any(line.strip().casefold()=='versicherungsschein' for line in context.splitlines())
            assert (row['status']=='policy-heading')==heading
        assert 'ACTIVE_CONTRACT_STATUS_NOT_CHECKED' in answer['warnings']
    elif question['kind']=='passages':
        assert len(claims)>0
        joined='\n'.join(c['value'] for c in claims)
        for text in expected['contains']:assert text in joined,(question['id'],'missing condition/negation')
        assert all(c['field']=='passage' and c['value']==c['evidence'][0]['quote'] for c in claims)
    else:
        assert sorted(c['value'] for c in claims)==sorted(expected['values']),(question['id'],'wrong answer value',answer)
        if question['kind']=='cost':
            for claim in claims:
                assert claim['field']=='cost' and claim['unit']=='EUR' and claim['period']==expected['period']
                assert all(s['quote'].split(':',1)[0].strip().casefold()==question['label'].casefold() for s in claim['evidence']), 'Wrong cost role'
                for source in claim['evidence']:
                    assert money(source['quote'].split(':',1)[1])==claim['value'],'Amount not in quoted source'
        elif expected['status']=='calculated':
            assert len(claims)==1 and claims[0]['field']=='cancellation'
            assert claims[0]['method']=='subtract-calendar-months-same-day'
            assert len(claims[0]['evidence'])==2
            assert any(s['quote'].startswith('Vertragsende:') for s in claims[0]['evidence'])
            assert any(s['quote'].startswith('Kündigungsfrist:') for s in claims[0]['evidence'])
        elif claims:
            assert all(c['field']==question['role'] for c in claims)
            for claim in claims:
                assert any(canonical_date(s['quote'].split(':',1)[1])==claim['value'] for s in claim['evidence'])
                assert all(s['quote'].split(':',1)[0].strip()==expected['evidenceLabel'] for s in claim['evidence'])
        if not claims:
            assert 'NOT_FOUND_IN_AVAILABLE_TEXT' in answer['warnings'] if expected['status']=='not-evidenced' else 'SOURCE_NOT_READY' in answer['warnings']
    source_pages={s['page'] for c in claims for s in c['evidence']}
    if 'page' in expected and claims:assert source_pages=={expected['page']}
    if 'pages' in expected:assert source_pages==set(expected['pages'])


def canonical_date(text):
    value=text.strip()
    if re.fullmatch(r'\d{4}-\d{2}-\d{2}',value):return value
    match=re.fullmatch(r'(\d{1,2})\.(\d{1,2})\.(\d{4})',value)
    return f'{int(match[3]):04}-{int(match[2]):02}-{int(match[1]):02}' if match else None


class Workflow:
    def __init__(self,client,schemas):
        self.client=client;self.schemas=schemas;self.trace=[]
    def call(self,name,**arguments):
        result=payload(self.client.call(name,**arguments),self.schemas[name])
        self.trace.append(dict(tool=name,arguments=arguments,response=result))
        return result
    def all_rows(self,name,key,**arguments):
        response=self.call(name,**arguments);rows=list(response[key])
        while response.get('nextCursor'):
            following={'cursor':response['nextCursor']}
            if name=='get_topic_overview':following|=arguments
            response=self.call(name,**following);rows+=response[key]
        assert response.get('retrievalComplete',True)
        return rows,response
    def select(self,query):
        rows,_=self.all_rows('list_documents','items',query=query,includeExcerpts=False,pageSize=2)
        assert len(rows)==1,(query,'ambiguous document selection',rows)
        return rows[0]['document']
    def answer(self,plan):
        # plan deliberately has no expected answers; routing is explicit, not an NLP model.
        assert 'expected' not in plan
        result=dict(id=plan['id'],question=plan['question'],claims=[],warnings=[])
        if plan['kind']=='topic':
            rows,last=self.all_rows('get_topic_overview','rows',topic='insurance')
            result.update(status='candidates',rows=[dict(document=r['document'],status=r['status'],
                evidence=dict(document=r['document'],**r['evidence'])) for r in rows])
            result['warnings']=last['warnings'];return result
        handle=self.select(plan['query'])
        if plan['kind']=='cost':
            rows,_=self.all_rows('extract_document_fields','results',documents=[handle],fields=['cost'])
            sources=[dict(document=handle,**e) for row in rows for e in row['evidence'] if e['label'].casefold()==plan['label'].casefold()]
            ready=all(row['sourceCoverage'] in READY for row in rows)
            if not ready:result['warnings'].append('SOURCE_NOT_READY')
            if any('FIELD_EXTRACTION_INCOMPLETE' in row['warnings'] for row in rows):
                # The distributable skill requires source readback for incomplete fields.
                # Keep that warning; do not turn an excerpt into a complete contract review.
                segments,last=self.all_rows('read_document','segments',document=handle)
                if not last['containsEntireAvailableText']:result.update(status='unresolved');return result
                sources=[]
                for segment in segments:
                    lines=segment['text'].splitlines()
                    for index,line in enumerate(lines):
                        label,colon,value=line.partition(':')
                        if not colon or label.strip().casefold()!=plan['label'].casefold():continue
                        if index+1<len(lines) and lines[index+1].strip() and ':' not in lines[index+1]:
                            result.update(status='unresolved');return result
                        money(value) # Entire inline value must be a supported amount.
                        sources.append(dict(document=handle,page=segment['page'],quote=line,
                            value=value,source=segment['source']))
                result['warnings']=['FIELD_EXTRACTION_INCOMPLETE','REFERENCE_SOURCE_READBACK']
            values={money(s['value']) for s in sources}
            if not ready and len(values)<2:result.update(status='unresolved');return result
            result['status']='evidenced' if len(values)==1 else 'conflicting' if len(values)>1 else 'not-evidenced'
            result['claims']=[dict(field='cost',value=v,unit='EUR',period=PERIOD[plan['label'].casefold()],
                evidence=[evidence(s) for s in sources if money(s['value'])==v]) for v in sorted(values)]
        elif plan['kind']=='passages':
            segments,_=self.all_rows('read_document','segments',document=handle,view='passages',query=plan['terms'])
            result.update(status='quoted',claims=[dict(field='passage',value=s['text'],evidence=[dict(document=handle,page=s['page'],quote=s['text'],source=s['source'])]) for s in segments])
        else:
            data=self.call('get_deadline_overview',documents=[handle]);row,=data['rows']
            entries={e['role']:e for e in row['entries']}
            if plan['role']=='cancellation':
                result['status']=row['calculationStatus']
                if row['calculationStatus']=='calculated':
                    result['claims']=[dict(field='cancellation',value=row['calculation']['date'],method=row['calculation']['method'],
                        evidence=[evidence(dict(document=handle,**entries[k]['evidence'][0])) for k in ['endDate','noticePeriod']])]
                elif row['calculationStatus']=='stated-date':
                    result['claims']=[dict(field='cancellation',value=entries['cancellationDue']['date'],evidence=[evidence(dict(document=handle,**e)) for e in entries['cancellationDue']['evidence']])]
            else:
                entry=entries[plan['role']];result['status']=entry['status']
                if 'date' in entry:result['claims']=[dict(field=plan['role'],value=entry['date'],evidence=[evidence(dict(document=handle,**e)) for e in entry['evidence']])]
            result['warnings']=row['warnings']+sum((e['warnings'] for e in entries.values()),[])
        if result['status']=='not-evidenced':result['warnings'].append('NOT_FOUND_IN_AVAILABLE_TEXT')
        return result
    def protected_pages(self,answer):
        handles={s['document'] for c in answer['claims'] for s in c['evidence']}|{r['document'] for r in answer.get('rows',[])}
        pages={}
        for handle in sorted(handles):
            segments,_=self.all_rows('read_document','segments',document=handle)
            for segment in segments:
                key=handle,segment['page'];pages[key]=pages.get(key,'')+segment['text']+'\n'
        return pages


def render(answers):
    lines=['# Synthetische Referenzantworten','',
      'Automatisch und extraktiv aus echten lokalen MCP-Antworten zusammengesetzt. Keine ChatGPT-/LLM-Abnahme.','']
    for answer in answers:
        lines += ['## '+answer['question'],'','Status: `'+answer['status']+'`.','']
        if answer.get('rows'):
            lines+=['Dies sind Unterlagen zum Thema. Ein aktuell bestehender Versicherungsschutz ist damit nicht bestätigt.','']
            lines+=['| Dokument | Einordnung | Beleg |','|---|---|---|']
            for row in answer['rows']:
                quote=row['evidence']['quote'].replace('|','\\|').replace('\n','<br>')
                lines.append(f"| {row['document']} | {row['status']} | {quote} {row['evidence']['source']} |")
        for claim in answer['claims']:
            lines += ['- '+claim['value']+(' EUR / '+claim['period'] if claim.get('unit')=='EUR' else '')]
            lines += ['  - '+s['quote']+' '+s['source'] for s in claim['evidence']]
        if answer['status']=='not-evidenced':lines+=['Im verfügbaren Text nicht gefunden. Daraus folgt keine fehlende vertragliche Verpflichtung.']
        if answer['status']=='unresolved':lines+=['Aus der verfügbaren Quelle nicht sicher bestimmbar.']
        if answer['status']=='conflicting':lines+=['Die Quelle enthält widersprüchliche Werte; keine einzelne Monatsrate bestätigt.']
        if 'SOURCE_NOT_READY' in answer['warnings']:lines+=['Die Quellverarbeitung ist unvollständig oder prüfbedürftig. Die zitierten Werte sind keine vollständige Vertragsauswertung.']
        if 'REFERENCE_SOURCE_READBACK' in answer['warnings']:lines+=['Die Feldauslese war unvollständig; die genannte beschriftete Angabe wurde zusätzlich im verfügbaren Quelltext geprüft.']
        lines+=['']
    return '\n'.join(lines)


def main():
    if not __debug__:raise SystemExit('Run without Python -O: assertions are acceptance checks')
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('server',type=Path);parser.add_argument('fixtures',type=Path);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--corpus',type=Path,default=ROOT/'Tests/VauldyMCPRuntimeTests/Fixtures/product-questions.json')
    args=parser.parse_args();output=args.output.resolve();output.mkdir(parents=True,exist_ok=False)
    spec=json.loads(args.corpus.read_text());native=json.loads((args.fixtures/'native-fixtures.json').read_text())
    source_vault=Path(native['vault']).resolve()
    assert source_vault.is_relative_to(args.fixtures.resolve()),'Only task-owned synthetic fixtures allowed'
    assert not output.is_relative_to(source_vault.parent),'Output must be outside the source vault'
    source_before=source_vault.read_bytes()
    shutil.copytree(source_vault.parent,output/'vault')
    vault=output/'vault'/source_vault.name
    records=json.loads(vault.read_text());private=next(r for r in native['documents'] if r['key']=='private')
    # Allow reruns against a previous fixture export, without duplicating coverage controls.
    native_ids={r['id'] for r in native['documents']};records=[r for r in records if r['id'] in native_ids]
    assert len(records)==8
    # Explicit coverage-control fixture, separately labelled; not claimed as native OCR output.
    partial=document('Leasingvertrag\nTeilscan\nVertragsende: 15.04.2027\nKündigungsfrist: 1 Monat vor Vertragsende',pageCount=2)
    records.append(partial);write_json(vault,records)
    profile=output/'profile.json';grant=dict(version=1,revision=str(uuid.uuid4()),connectionID=str(uuid.uuid4()),connectionName='Synthetic product acceptance',enabled=True,
        vaultPath=str(vault),allowedDocumentIDs=[r['id'] for r in records if r['id']!=private['id']],acknowledgedCloudDisclosure=True)
    write_json(profile,grant);before=vault.read_bytes(),profile.read_bytes()
    client=Client(args.server.resolve(),profile);report=dict(scope='local MCP + deterministic extractive reference; not live ChatGPT',questions=[],nativeDocuments=len(native['documents']),controlledCoverageFixtures=1)
    answers=[];packets=[];failures=[]
    try:
        tools=client.request('tools/list',{})['tools'];assert_v1_discovery(tools);schemas={t['name']:t['outputSchema'] for t in tools}
        workflow=Workflow(client,schemas)
        # Complete inventory independently exercises pagination, including unreadable candidates.
        inventory,_=workflow.all_rows('list_documents','items',includeExcerpts=False,pageSize=2)
        assert len(inventory)==8 and len({i['document'] for i in inventory})==8
        report['inventoryPages']=4
        for question in spec['questions']:
            plan={k:v for k,v in question.items() if k!='expected'};start=time.perf_counter();first=len(workflow.trace)
            answer=workflow.answer(plan);answer_calls=len(workflow.trace)-first;answer_ms=(time.perf_counter()-start)*1000
            pages=workflow.protected_pages(answer)
            try:validate_answer(question,answer,pages)
            except (AssertionError,KeyError,ValueError) as error:failures.append(dict(id=question['id'],error=str(error)))
            wire=json.dumps(workflow.trace[first:],ensure_ascii=False)
            for forbidden in [str(args.fixtures.resolve()),'NICHTFREIGEGEBENPRODUKT',*(r['id'] for r in records)]:assert forbidden.lower() not in wire.lower(),forbidden
            answers.append(answer);packets.append(dict(question=question,answer=answer,pages=[dict(document=k[0],page=k[1],text=v) for k,v in pages.items()],trace=workflow.trace[first:]))
            report['questions'].append(dict(id=question['id'],passed=not any(f['id']==question['id'] for f in failures),status=answer['status'],workflowToolCalls=answer_calls,
                evidenceValidationCalls=len(workflow.trace)-first-answer_calls,workflowMilliseconds=round(answer_ms,3),
                totalIncludingEvidenceValidationMilliseconds=round((time.perf_counter()-start)*1000,3)))
        assert (vault.read_bytes(),profile.read_bytes())==before and source_vault.read_bytes()==source_before
        assert not workflow.call('list_documents',query='NICHTFREIGEGEBENPRODUKT',includeExcerpts=False)['items']
        assert client.call('read_document',document=private['id'])['isError']
        live=workflow.select('fahrradleasing')
        grant.update(enabled=False,revision=str(uuid.uuid4()));write_json(profile,grant)
        assert client.call('read_document',document=live)['isError']
        assert client.call('extract_document_fields',documents=[live],fields=['cost'])['isError']
        assert client.call('get_deadline_overview',documents=[live])['isError']
        report.update(passed=not failures,failures=failures,answerMode='deterministic-extractive-reference',chatGPTTested=False,privacyAndRevocationPassed=True,
            originalsUnchanged=all(hashlib.sha256(Path(d['source']).read_bytes()).hexdigest()==d['sha256'] for d in native['documents']),readOnlyDuringQuestions=True)
        assert report['originalsUnchanged']
        (output/'answers.json').write_text(json.dumps(answers,ensure_ascii=False,indent=2)+'\n')
        (output/'answers.md').write_text(render(answers)+'\n')
        (output/'evidence-packets.json').write_text(json.dumps(packets,ensure_ascii=False,indent=2)+'\n')
        (output/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(report,ensure_ascii=False))
        if failures:raise SystemExit(1)
    finally:
        client.close()
        # Restore only this task's synthetic fixture/profile after explicit revocation tests.
        vault.write_bytes(before[0]);profile.write_bytes(before[1])


if __name__=='__main__':main()
