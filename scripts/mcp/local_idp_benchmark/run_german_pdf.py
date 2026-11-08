"""Sequential launcher for the frozen synthetic German PDF corpus. No downloads."""
from pathlib import Path
import hashlib,json,os,subprocess,sys,time

r=Path(sys.argv[1]);protocol=json.loads((r/'source/protocol.json').read_text())
assert hashlib.sha256((r/'corpus/frozen/manifest.json').read_bytes()).hexdigest()==protocol['manifestSHA256']
base=dict(os.environ,HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HOME=str(r/'cache/hf'),XDG_CACHE_HOME=str(r/'cache/xdg'),TORCH_HOME=str(r/'cache/torch'),PYTHONDONTWRITEBYTECODE='1',OMP_NUM_THREADS='2',OPENBLAS_NUM_THREADS='2',MKL_NUM_THREADS='2')
native='(version 1)(allow default)(deny network*)'
isolated=native+'(deny file-read* (subpath "/Users/marcomeisen"))(deny file-write* (subpath "/Users/marcomeisen"))'
font_metadata=isolated+'(allow file-read* (literal "/Users/marcomeisen/Library/Fonts"))'
jobs=[('apple',[str(r/'german-apple-probe'),str(r)],native,{})]
for e in ['docling-py','docling-rs','glm']:
    env={}
    if e=='docling-rs':
        d=r/'models/docling-rs';env=dict(DOCLING_RS_MODELS_DIR=str(d),DOCLING_LAYOUT_ONNX=str(d/'layout_heron.onnx'),DOCLING_OCR_REC_ONNX=str(d/'ocr_rec_v6.onnx'),DOCLING_OCR_DICT=str(d/'ocr_rec_v6_dict.txt'),DOCLING_OCR_DET_ONNX=str(d/'ocr_det.onnx'),DOCLING_RS_EP='cpu',DOCLING_RS_FP32='1',DOCLING_RS_PDF_THREADS='2',DOCLING_RS_PDF_WORKERS='1',DOCLING_RS_PDF_INTRA='2',DOCLING_RS_OCR_SESSIONS='1')
    py=r/('venv-mlx' if e=='glm' else 'venv-docling')/'bin/python'
    jobs.append((e,[str(py),str(r/'source/german_pdf_worker.py'),str(r),e],font_metadata if e=='docling-py' else isolated,env))
if len(sys.argv)>2:jobs=[j for j in jobs if j[0] in sys.argv[2:]]
status=[]
for e,cmd,sandbox,extra in jobs:
    started=time.time();print('start',e,flush=True)
    with (r/'logs'/(e+'.stdout.log')).open('wb') as out,(r/'logs'/(e+'.stderr.log')).open('wb') as err:
        process=subprocess.run(['sandbox-exec','-p',sandbox,*cmd],cwd=r,env={**base,**extra},stdout=out,stderr=err,timeout=5400)
    files=list((r/'results'/e).glob('*.json'));docs=[p for p in files if p.name not in ['configuration.json'] and not p.name.endswith('.document.json')]
    errors=[p.stem for p in docs if json.loads(p.read_text()).get('error') or json.loads(p.read_text()).get('errors')]
    status.append(dict(engine=e,command=cmd,sandbox=sandbox,startedUnixSeconds=started,finishedUnixSeconds=time.time(),exitCode=process.returncode,documents=len(docs),errors=errors))
    (r/'results'/('execution'+('-'+'-'.join(sys.argv[2:]) if len(sys.argv)>2 else '')+'.json')).write_text(json.dumps(status,indent=2));print('done',e,process.returncode,len(docs),'errors',errors,flush=True)
    if process.returncode:raise SystemExit(process.returncode)
