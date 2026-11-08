#!/usr/bin/env python3
"""Evaluate the frozen German raster-document corpus, never invoke a model."""
from pathlib import Path
from collections import Counter,defaultdict
from html import unescape
from html.parser import HTMLParser
import argparse,hashlib,json,math,re,statistics,unicodedata
try:
    from rapidfuzz.distance.Levenshtein import distance
except ImportError:
    from local_idp_comparison import distance

ENGINES=['apple','docling-py','docling-rs','glm']
def read(p):return json.loads(p.read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

class TextContent(HTMLParser):
    def __init__(self):super().__init__(convert_charrefs=True);self.parts=[]
    def handle_starttag(self,tag,attrs):
        if tag in ['p','br','div','tr','td','th','table','li']:self.parts.append(' ')
    def handle_endtag(self,tag):
        if tag in ['p','br','div','tr','td','th','table','li']:self.parts.append(' ')
    def handle_data(self,data):self.parts.append(data)

def normalize(s):
    # Presentation only: no spelling correction, transliteration, case folding,
    # punctuation repair, number parsing, or ground-truth-driven replacement.
    s=unescape(unicodedata.normalize('NFC',s))
    s=re.sub(r'<!--.*?-->','',s,flags=re.S)
    s='\n'.join(line for line in s.splitlines() if not re.fullmatch(r'\s*\|?\s*:?-{3,}:?(?:\s*\|\s*:?-{3,}:?)*\s*\|?\s*',line))
    s=re.sub(r'(?m)^\s*#{1,6}\s+','',s);s=re.sub(r'(?m)^```[^\n]*$','',s)
    if re.search(r'</?(?:p|div|table|tr|td|th|br|span|h[1-6]|b|i|strong|em)\b',s,re.I):
        parser=TextContent();parser.feed(s);s=''.join(parser.parts)
    s=re.sub(r'\\([_*$|`])',r'\1',s);s=s.replace('**','').replace('__','').replace('`','').replace('|',' ')
    return ' '.join(s.split())

def contains(text,expected):
    return bool(re.search(r'(?<!\w)'+re.escape(normalize(expected))+r'(?!\w)',normalize(text)))

def md_tables(text):
    lines=text.splitlines();tables=[];i=0
    def split(line):return [normalize(s) for s in line.strip().strip('|').split('|')]
    while i+1<len(lines):
        if '|' in lines[i] and '|' in lines[i+1]:
            sep=lines[i+1].strip().strip('|').split('|')
            if sep and all(re.fullmatch(r'\s*:?-{3,}:?\s*',s) for s in sep):
                grid=[split(lines[i])];i+=2
                while i<len(lines) and '|' in lines[i] and lines[i].strip():grid.append(split(lines[i]));i+=1
                tables.append(grid);continue
        i+=1
    return tables

class HTMLTables(HTMLParser):
    def __init__(self):super().__init__(convert_charrefs=True);self.tables=[];self.grid=None;self.row=-1;self.col=0;self.cell=None;self.pending={}
    def handle_starttag(self,tag,attrs):
        if tag=='table':self.grid=[];self.row=-1;self.pending={}
        if self.grid is None:return
        if tag=='tr':
            self.row+=1;self.col=0;self.grid.append([])
            for (y,x),value in self.pending.items():
                if y==self.row:
                    while len(self.grid[self.row])<=x:self.grid[self.row].append('')
                    self.grid[self.row][x]=value
        if tag in ['td','th']:
            if self.row<0:self.row=0;self.grid.append([])
            self.cell=[];self.span=min(100,max(1,int(dict(attrs).get('colspan','1'))));self.rowspan=min(200,max(1,int(dict(attrs).get('rowspan','1'))))
    def handle_data(self,s):
        if self.cell is not None:self.cell.append(s)
    def handle_endtag(self,tag):
        if tag in ['td','th'] and self.cell is not None and self.grid is not None:
            while (self.row,self.col) in self.pending:self.col+=1
            value=normalize(' '.join(self.cell))
            for x in range(self.col,self.col+self.span):
                while len(self.grid[self.row])<=x:self.grid[self.row].append('')
                self.grid[self.row][x]=value
                for y in range(self.row+1,self.row+self.rowspan):self.pending[y,x]=value
            self.col+=self.span;self.cell=None
        if tag=='table' and self.grid is not None:self.tables.append(self.grid);self.grid=None

def predicted_tables(page,engine):
    if engine=='apple':return []
    if engine=='glm':
        parser=HTMLTables();parser.feed(page.get('markdown',page['text']))
        return parser.tables+md_tables(page.get('markdown',page['text']))
    grids=[]
    for t in page.get('tables',[]):
        data=t['data'];rows,cols=data['num_rows'],data['num_cols']
        if not 0<rows<=200 or not 0<cols<=100:continue
        grid=[['']*cols for _ in range(rows)]
        for c in data['table_cells']:
            y,x=c['start_row_offset_idx'],c['start_col_offset_idx']
            if 0<=y<rows and 0<=x<cols:
                for yy in range(y,min(rows,y+max(1,c.get('row_span',1)))):
                    for xx in range(x,min(cols,x+max(1,c.get('col_span',1)))):grid[yy][xx]=normalize(c['text'])
        grids.append(grid)
    return grids

def time_summary(values):
    assert values and all(math.isfinite(v) and v>=0 for v in values)
    values=sorted(values)
    return dict(count=len(values),totalMilliseconds=sum(values),medianMilliseconds=statistics.median(values),p95Milliseconds=values[math.ceil(.95*len(values))-1])

def summarize_cases(cases):
    ref=sum(x['referenceCharacters'] for x in cases);words=sum(x['referenceWords'] for x in cases)
    return dict(pages=len(cases),criticalFields=sum(x['expectedFields'] for x in cases),exactFields=sum(x['exactFields'] for x in cases),
      allCriticalFieldsCorrectPages=sum(x['exactFields']==x['expectedFields'] for x in cases if x['expectedFields']),
      characterErrorRate=sum(x['characterEdits'] for x in cases)/ref if ref else None,
      wordErrorRate=sum(x['wordEdits'] for x in cases)/words if words else None,
      unorderedWordRecall=sum(x['matchedWordOccurrences'] for x in cases)/words if words else None,
      unorderedWordPrecision=sum(x['matchedWordOccurrences'] for x in cases)/sum(x['predictedWordOccurrences'] for x in cases) if sum(x['predictedWordOccurrences'] for x in cases) else None,
      blankFalsePositives=sum(x['blankFalsePositive'] for x in cases),
      tableTextCells=sum(x['expectedTableTextCells'] for x in cases),tableTextCellsFound=sum(x['tableTextCellsFound'] for x in cases),
      tablePositionCells=sum(x['expectedTablePositionCells'] for x in cases),tablePositionCellsCorrect=sum(x['tablePositionCellsCorrect'] for x in cases),
      exactTables=sum(x['exactTables'] for x in cases),expectedTables=sum(x['expectedTables'] for x in cases),
      exactTableRows=sum(x['exactTableRows'] for x in cases),expectedTableRows=sum(x['expectedTableRows'] for x in cases),
      returnedTables=sum(x['returnedTables'] for x in cases))

def evaluate(root,allow_partial=False):
    corpus=root/'corpus/frozen';m=read(corpus/'manifest.json');protocol=read(root/'source/protocol.json')
    assert sha(corpus/'manifest.json')==protocol['manifestSHA256'],'Frozen manifest changed'
    for d in m['documents']:assert sha(corpus/d['pdf'])==d['sha256'],'Frozen PDF changed'
    for p in m['pages']:assert sha(corpus/p['image'])==p['sha256'],'Frozen image changed'
    report=dict(schemaVersion=2,protocol=protocol,corpus=m['statistics'],manifestSHA256=sha(corpus/'manifest.json'),engines={})
    source_pages={p['id']:p for p in m['pages']};outputs={};byengine={}
    for e in ENGINES:
        mapping={};docs=[]
        for did in m['executionOrder']:
            d=next(d for d in m['documents'] if d['id']==did);path=root/'results'/e/(did+'.json')
            if not path.exists():
                if allow_partial:continue
                raise AssertionError('Missing engine document: '+str(path))
            result=read(path);assert result['inputSHA256']==d['sha256'],'Output source binding changed'
            if result.get('error') or result.get('errors'):
                if allow_partial:continue
                raise AssertionError('Execution failure must not count as OCR quality: '+e+' '+did)
            assert [p.get('page',p.get('info',{}).get('page')) for p in result['pages']]==list(range(1,len(d['pageIDs'])+1)),'Physical page coverage lost'
            for pid,p in zip(d['pageIDs'],result['pages']):
                mapping[pid]=p;outputs[pid,e]=p['text']
                if e=='apple':assert p['info'].get('metrics',{}).get('cacheHit') is not True,'Native cache hit'
            docs.append({k:v for k,v in result.items() if k!='pages'})
        byengine[e]=mapping
        if not mapping:continue
        cases=[]
        for pid,p in mapping.items():
            truth=source_pages[pid];text=p['text'];norm=normalize(text);ref=normalize(truth['text']);correct=[f['id'] for f in truth['fields'] if contains(text,f['text'])]
            ref_words=Counter(ref.split());pred_words=Counter(norm.split())
            expected_cells=[c for t in truth['tables'] for c in t['cells'] if c['text']];counts=Counter(normalize(c['text']) for c in expected_cells)
            found=sum(min(n,len(re.findall(r'(?<!\w)'+re.escape(s)+r'(?!\w)',norm))) for s,n in counts.items())
            grids=predicted_tables(p,e);position=rows_correct=tables_exact=totalrows=0
            for t in truth['tables']:
                reference=[['']*t['cols'] for _ in range(t['rows'])]
                for cell in t['cells']:reference[cell['row']][cell['col']]=normalize(cell['text'])
                def score(grid):return sum(bool(value) and y<len(grid) and x<len(grid[y]) and value==grid[y][x] for y,row in enumerate(reference) for x,value in enumerate(row))
                # Annotation association only; never used to choose OCR text or modify it.
                best=max(grids,key=score) if grids else []
                position+=score(best);rows_correct+=sum(y<len(best) and row==best[y] for y,row in enumerate(reference));tables_exact+=int(best==reference);totalrows+=len(reference)
            cases.append(dict(pageID=pid,documentID=truth['documentID'],physicalPage=truth['physicalPage'],kind=truth['kind'],scan=truth['scan'],
              text=text,markdown=p.get('markdown'),textSHA256=hashlib.sha256(text.encode()).hexdigest(),expectedFields=len(truth['fields']),exactFields=len(correct),correctFieldIDs=correct,
              missingFields=[f for f in truth['fields'] if f['id'] not in correct],referenceCharacters=len(ref),characterEdits=distance(ref,norm),referenceWords=len(ref.split()),wordEdits=distance(ref.split(),norm.split()),
              matchedWordOccurrences=sum((ref_words&pred_words).values()),predictedWordOccurrences=sum(pred_words.values()),nativeInfo=p.get('info'),
              blank=truth['blank'],blankFalsePositive=truth['blank'] and bool(norm),expectedTableTextCells=len(expected_cells),tableTextCellsFound=found,
              expectedTablePositionCells=len(expected_cells),tablePositionCellsCorrect=position,expectedTables=len(truth['tables']),exactTables=tables_exact,
              expectedTableRows=totalrows,exactTableRows=rows_correct,returnedTables=len(grids),truncated=p.get('truncated',False),milliseconds=p.get('milliseconds',p.get('info',{}).get('elapsedMilliseconds'))))
        groups=defaultdict(list);quality=defaultdict(list)
        for c in cases:
            if not c['blank']:groups[c['kind']].append(c);quality[c['scan']['quality']].append(c)
        summary=summarize_cases(cases)
        if e=='apple' or (e=='glm' and summary['returnedTables']==0):
            for key in ['tablePositionCellsCorrect','exactTables','exactTableRows']:summary[key]=None
            summary['structureNote']='Native Vauldy OCR emits text/geometry, no table-cell structure; not reconstructed from annotations' if e=='apple' else 'Text Recognition prompt emits flat text here; separate Table Recognition crop diagnostic is not pooled into this result'
        summary.update(cases=cases,documents=docs,byDocumentType={k:summarize_cases(v) for k,v in groups.items()},byScanQuality={k:summarize_cases(v) for k,v in quality.items()},
          rssPeakBytes=max(d['rssPeakBytes'] for d in docs),documentTiming=time_summary([d['milliseconds'] for d in docs]),
          contentDocumentMillisecondsPerPage=time_summary([d['milliseconds']/len(next(x['pageIDs'] for x in m['documents'] if x['id']==d['id'])) for d in docs if not d['id'].startswith('control-')]),
          truncatedPages=[x['pageID'] for x in cases if x['truncated']])
        if e=='glm':summary['mlxPeakBytes']=max(p.get('mlxPeakBytes',0) for p in mapping.values())
        if e!='apple':
            first=(root/'logs'/(e+'.stdout.log')).read_text().splitlines()[0]
            summary['initializationMilliseconds']=json.loads(first)['milliseconds']
        report['engines'][e]=summary
    if 'apple' in report['engines']:
        baseline={x['pageID']:set(x['correctFieldIDs']) for x in report['engines']['apple']['cases']}
        for e,v in report['engines'].items():
            v['lostAppleFields']=sum(len(baseline[c['pageID']]-set(c['correctFieldIDs'])) for c in v['cases'])
            v['addedFields']=sum(len(set(c['correctFieldIDs'])-baseline[c['pageID']]) for c in v['cases'])
            v['qualityGate']=v['exactFields']>report['engines']['apple']['exactFields'] and v['lostAppleFields']==0 and v['blankFalsePositives']==0 and not v['truncatedPages']
    table_file=root/'results/glm-table-mode/report.json'
    if table_file.exists():
        diagnostic=read(table_file);table_cases=[]
        for item in diagnostic['cases']:
            assert sha(root/item['image'])==item['sha256'],'Table crop changed'
            assert sha(corpus/next(p['image'] for p in m['pages'] if p['id']==item['pageID']))==item['sourceSHA256']
            t=next(t for p in m['pages'] for t in p['tables'] if t['id']==item['id'])
            reference=[['']*t['cols'] for _ in range(t['rows'])]
            for c in t['cells']:reference[c['row']][c['col']]=normalize(c['text'])
            grids=predicted_tables({'text':item['text']},'glm')
            def position(grid):return sum(bool(value) and y<len(grid) and x<len(grid[y]) and value==grid[y][x] for y,row in enumerate(reference) for x,value in enumerate(row))
            best=max(grids,key=position) if grids else []
            compact=sum(bool(value) and y<len(best) and x<len(best[y]) and ''.join(value.split())==''.join(best[y][x].split()) for y,row in enumerate(reference) for x,value in enumerate(row))
            table_cases.append(dict(**item,correctPositionCells=position(best),whitespaceInsensitivePositionCells=compact,
              expectedNonemptyCells=sum(bool(c['text']) for c in t['cells']),exactTable=best==reference,returnedTables=len(grids)))
        report['glmTableDiagnostic']=dict(role=diagnostic['protocol']['role'],tables=len(table_cases),expectedCells=sum(x['expectedNonemptyCells'] for x in table_cases),
          correctPositionCells=sum(x['correctPositionCells'] for x in table_cases),exactTables=sum(x['exactTable'] for x in table_cases),truncated=sum(x['truncated'] for x in table_cases),
          whitespaceInsensitivePositionCells=sum(x['whitespaceInsensitivePositionCells'] for x in table_cases),
          formattingOnlyCells=sum(x['whitespaceInsensitivePositionCells']-x['correctPositionCells'] for x in table_cases),
          cellsWithoutStructure=sum(x['expectedNonemptyCells'] for x in table_cases if not x['returnedTables']),
          secondaryWhitespaceMetricIsPostHocAndDoesNotChangePrimaryScores=True,
          timing=time_summary([x['milliseconds'] for x in table_cases]),cases=table_cases)
    repeat=root/'native-repeat/results/apple/doc-003.json'
    if repeat.exists():
        initial=read(root/'results/apple/doc-003.json');new=read(repeat)
        assert new['inputSHA256']==initial['inputSHA256']
        report['nativeOutlierRepetition']=dict(documentID='doc-003',initialMilliseconds=initial['milliseconds'],repeatedMilliseconds=new['milliseconds'],
          identicalPageTexts=sum(a['text']==b['text'] for a,b in zip(initial['pages'],new['pages'])),pages=len(new['pages']),includedInPrimaryScores=False)
    jfile=root/'results/jev/report.json'
    if jfile.exists():
        j=read(jfile);rendered=read(root/'results/jev-rendered.json');render_map={x['id']:x for x in rendered};valid=[];errors=[]
        assert len(render_map)==len(rendered)==236,'Jev render coverage changed'
        expected_actual={(pid,e) for pid in source_pages for e in ENGINES}
        assert {(x['pageID'],x['engine']) for x in rendered if x['kind']=='actual-ocr'}==expected_actual,'Jev OCR candidate coverage changed'
        expected_controls={(p['id'],kind) for p in m['pages'] if not p['blank'] for kind in ['source-complete','one-character-error','paragraph-omitted','page-empty']}
        assert {(x['pageID'],x['kind']) for x in rendered if x['kind']!='actual-ocr'}==expected_controls,'Jev control coverage changed'
        assert len({x['id'] for x in j['cases']+j['controls']})==len(j['cases'])+len(j['controls']),'Duplicate Jev scores'
        if not j.get('calibrationPassed'):
            report['jev']={**j,'complete':False,'status':'calibration pending or failed'}
            return report
        assert j.get('calibrationPassed') and len(j['calibration'])==3 and all(abs(x['probability']-x['reference'])<=.02 for x in j['calibration']),'Jev calibration not established'
        for item in j['cases']+j['controls']:
            request=render_map[item['id']]
            assert all(item.get(k)==request.get(k) for k in ['pageID','kind','engine','image','sourceImageSHA256','render','renderSHA256']),'Jev request identity changed'
            assert item['textSHA256']==hashlib.sha256(request['text'].encode()).hexdigest(),'Jev score text binding changed'
            assert sha(root/item['render'])==item['renderSHA256'],'Jev render changed'
            assert sha(corpus/item['image'])==item['sourceImageSHA256'],'Jev source changed'
            if item['kind']=='actual-ocr':
                p=byengine[item['engine']][item['pageID']]
                assert request['text']==p.get('markdown',p['text']),'Jev rendered text differs from actual OCR markup'
                assert item['ocrTextSHA256']==hashlib.sha256(p['text'].encode()).hexdigest(),'Jev OCR text binding changed'
            if item.get('error') or item.get('probability') is None:errors.append(item)
            else:
                assert math.isfinite(item['probability']) and 0<=item['probability']<=1,'Invalid Jev probability'
                valid.append(item)
        j['complete']=len(j['cases'])==124 and len(j['controls'])==112 and not j.get('failure') and not errors and 'serverRSSPeakBytes' in j
        j['scoringErrors']=errors
        actual=[x for x in valid if x['kind']=='actual-ocr'];controls=[x for x in valid if x['kind']!='actual-ocr']
        if actual:
            j['timing']=time_summary([x['milliseconds'] for x in actual]);j['renderTiming']=time_summary([x['renderMilliseconds'] for x in actual])
        byid={x['id']:x for x in controls};groups={};source=[x['probability'] for x in controls if x['kind']=='source-complete']
        for kind in ['one-character-error','paragraph-omitted','page-empty']:
            rows=[x for x in controls if x['kind']==kind]
            groups[kind]=dict(scored=len(rows),acceptedAtPointFive=sum(x['probability']>=.5 for x in rows),
              pairedRankingCorrect=sum(byid[x['pageID']+'-source-complete']['probability']>x['probability'] for x in rows if x['pageID']+'-source-complete' in byid))
        j['controlSummary']=dict(sourceCompleteScored=len(source),sourceCompleteAcceptedAtPointFive=sum(p>=.5 for p in source),errors=groups,thresholdIsDiagnostic=True)
        if len(actual)==124 and len({(x['pageID'],x['engine']) for x in actual})==124:
            scores={(x['pageID'],x['engine']):x['probability'] for x in actual};case_map={(c['pageID'],e):c for e,s in report['engines'].items() for c in s['cases']};selected=[];confusion=dict(tp=0,fp=0,tn=0,fn=0)
            for x in actual:
                c=case_map[x['pageID'],x['engine']]
                if c['blank']:continue
                complete=c['exactFields']==c['expectedFields'];accept=x['probability']>=.5
                confusion['tp' if complete and accept else 'fn' if complete else 'fp' if accept else 'tn']+=1
            for pid in source_pages:
                best=max(ENGINES,key=lambda e:scores[pid,e]);case=case_map[pid,best]
                selected.append(dict(pageID=pid,engine=best,probability=scores[pid,best],exactFields=case['exactFields'],
                  correctFieldIDs=case['correctFieldIDs'],blankFalsePositive=case['blankFalsePositive'],characterEdits=case['characterEdits'],referenceCharacters=case['referenceCharacters']))
            lost=sum(len(baseline[c['pageID']]-set(c['correctFieldIDs'])) for c in selected);added=sum(len(set(c['correctFieldIDs'])-baseline[c['pageID']]) for c in selected)
            j['selection']=dict(exactFields=sum(x['exactFields'] for x in selected),expectedFields=133,lostAppleFields=lost,addedFields=added,
              blankFalsePositives=sum(x['blankFalsePositive'] for x in selected),characterErrorRate=sum(x['characterEdits'] for x in selected)/sum(x['referenceCharacters'] for x in selected),
              chosenEngines=dict(Counter(x['engine'] for x in selected)),cases=selected)
            j['fieldCompletenessConfusion']=confusion
        report['jev']=j
    return report

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--root',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--allow-partial',action='store_true');parser.add_argument('--require-jev',action='store_true');args=parser.parse_args()
    report=evaluate(args.root,args.allow_partial)
    if args.require_jev:assert report.get('jev',{}).get('complete'),'Complete calibrated Jev scoring required'
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    for e,v in report['engines'].items():print(e,'fields',v['exactFields'],'/',v['criticalFields'],'CER',v['characterErrorRate'],'cell text',v['tableTextCellsFound'],'/',v['tableTextCells'],'position',v['tablePositionCellsCorrect'],'tables',v['exactTables'],'blank FP',v['blankFalsePositives'])
