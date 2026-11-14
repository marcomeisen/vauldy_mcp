from pathlib import Path
from collections import Counter
import hashlib,json,re,sys
sys.path.insert(0,'/Users/marcomeisen/Documents/ChatGPT/Vauldy/vauldy_mcp/scripts/mcp')
from german_document_comparison import contains,normalize
root=Path('/private/tmp/vauldy-ocr-improvement-20261111'); corpus=root/'v2/Vauldy-DE-Testkorpus-v2/frozen'
m=json.loads((corpus/'manifest.json').read_text()); cases=[]
for d in m['documents']:
 assert hashlib.sha256((corpus/d['pdf']).read_bytes()).hexdigest()==d['sha256']
 results=[json.loads((root/('v2-'+label)/'results/apple'/(d['id']+'.json')).read_text()) for label in ['before','after']]
 assert all(r['inputSHA256']==d['sha256'] for r in results)
 for i,pid in enumerate(d['pageIDs']):
  truth=next(p for p in m['pages'] if p['id']==pid)
  assert hashlib.sha256((corpus/truth['image']).read_bytes()).hexdigest()==truth['sha256']
  pages=[r['pages'][i] for r in results]; old,new=[p['text'] for p in pages]
  assert all(p['info']['page']==i+1 and not p['info']['metrics']['cacheHit'] for p in pages)
  matched=[set(f['id'] for f in truth['fields'] if contains(t,f['text'])) for t in [old,new]]
  reference=Counter(normalize(truth['text']).split()); words=[reference & Counter(normalize(t).split()) for t in [old,new]]
  cells=Counter(normalize(c['text']) for t in truth['tables'] for c in t['cells'] if c['text'])
  matched_cells=[Counter({s:min(n,len(re.findall(r'(?<!\w)'+re.escape(s)+r'(?!\w)',normalize(t)))) for s,n in cells.items()}) for t in [old,new]]
  cases.append(dict(page=pid,fields=[len(s) for s in matched],lostFields=sorted(matched[0]-matched[1]),
    lostCorrectWordOccurrences=dict(words[0]-words[1]),cellText=[sum(c.values()) for c in matched_cells],
    lostCellText=dict(matched_cells[0]-matched_cells[1]),textUnchanged=old==new,
    review=[p['info']['needsReview'] for p in pages],blankFalsePositive=truth['blank'] and bool(new.strip())))
report=dict(documents=15,pages=31,expectedFields=133,expectedNonemptyCells=345,
 fields=[sum(c['fields'][i] for c in cases) for i in [0,1]],tableTextCells=[sum(c['cellText'][i] for c in cases) for i in [0,1]],
 lostFields=sum(len(c['lostFields']) for c in cases),lostCorrectWordOccurrences=sum(sum(c['lostCorrectWordOccurrences'].values()) for c in cases),
 lostCellText=sum(sum(c['lostCellText'].values()) for c in cases),unchangedTextPages=sum(c['textUnchanged'] for c in cases),
 reviewPages=[sum(c['review'][i] for c in cases) for i in [0,1]],blankFalsePositives=sum(c['blankFalsePositive'] for c in cases),cases=cases)
(root/'v2-regression.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='cases'}))
assert not report['lostFields'] and not report['lostCorrectWordOccurrences'] and not report['lostCellText'] and not report['blankFalsePositives']
