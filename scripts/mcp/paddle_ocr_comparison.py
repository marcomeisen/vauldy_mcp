#!/usr/bin/env python3
"""Isolated PP-OCRv6 medium German benchmark. No installation or downloads by this script.

Run with system Python; `run` launches the explicitly supplied virtual-environment Python
inside a network- and user-file-denied macOS sandbox. All input images must match the
frozen 35-image/79-field manifest. Production OCR and vaults are never write targets.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import threading
import time

from local_ocr_comparison import digest, timing

REPO = Path(__file__).resolve().parents[2]
ENGINE = 'paddleocr-pp-ocrv6-medium'
WEIGHTS = {'det': '85218d2e3d98f5a21c58b4220627be923a97aee5db3cc71f39536ab31ac53960',
           'rec': '1b01c79a914587933f615569e75de54f2e638ebb5d3f3b3c1b38c24ede8c7319'}
VARIANTS = ['original', 'scale3', 'contrast3']


def environment(root):
    values = dict(os.environ)
    for key, folder in [('PADDLE_HOME','paddle-home'), ('PADDLE_PDX_CACHE_HOME','paddlex-cache'),
                        ('PADDLE_EXTENSION_DIR','paddle-extensions'), ('HF_HOME','hf-cache'),
                        ('MODELSCOPE_CACHE','modelscope-cache'), ('XDG_CACHE_HOME','xdg-cache')]:
        values[key] = str(root/folder)
    values.update(PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK='True', HF_HUB_OFFLINE='1',
                  OMP_NUM_THREADS='2', OPENBLAS_NUM_THREADS='2', MKL_NUM_THREADS='2',
                  NUMEXPR_NUM_THREADS='2', PYTHONDONTWRITEBYTECODE='1')
    return values


def sandbox_profile(user_home):
    quoted = json.dumps(str(user_home))
    return '(version 1)(allow default)(deny network*)(deny file-read* (subpath '+quoted+'))(deny file-write* (subpath '+quoted+'))'


def watchdog(seconds):
    # Abort only this isolated benchmark worker if a native call does not return.
    timer = threading.Timer(seconds, lambda: os._exit(124))
    timer.daemon = True; timer.start()
    return timer


def candidate_lines(result, width, height):
    texts, scores, polygons = result['rec_texts'], result['rec_scores'], result['rec_polys']
    if not len(texts) == len(scores) == len(polygons) or len(texts) > 256:
        raise ValueError('Invalid or unbounded recognition output')
    lines = []
    for text, score, polygon in zip(texts, scores, polygons):
        xs, ys = [float(p[0]) for p in polygon], [float(p[1]) for p in polygon]
        if not xs or not ys or not 0 <= float(score) <= 1: raise ValueError('Invalid OCR observation')
        bounds = [max(0,min(xs)/width), max(0,1-max(ys)/height),
                  min(1,(max(xs)-min(xs))/width), min(1,(max(ys)-min(ys))/height)]
        if not all(__import__('math').isfinite(value) for value in bounds): raise ValueError('Invalid source coordinates')
        lines.append(dict(text=str(text), confidence=float(score), bounds=bounds))
    return lines


def prepare_image(source, destination, transform):
    from PIL import Image
    with Image.open(source) as opened:
        gray = opened.convert('L')
    w,h = gray.size
    if w*h > 1_000_000 or w*h*9 > 4_000_000: raise ValueError('Benchmark image budget exceeded')
    if transform == 'contrast3':
        import numpy as np
        array = np.asarray(gray)
        mask = np.zeros(array.shape, dtype=bool);mask[:4,:]=True;mask[-4:,:]=True;mask[:,:4]=True;mask[:,-4:]=True
        border = np.sort(array[mask]);anchor=int(border[len(border)//20])
        gray = gray.point([max(0,min(255,round(255+(value-anchor)*255/32))) for value in range(256)])
    gray.resize((w*3,h*3),Image.Resampling.NEAREST).save(destination)


def worker(request):
    from importlib.metadata import version
    from PIL import Image
    from paddleocr import PaddleOCR
    root, fixtures, output = (Path(request[k]) for k in ['root','fixtures','output'])
    manifest = json.loads(Path(request['manifest']).read_text())
    truth, hashes = manifest['truth'], manifest['sha256']
    if len(truth)!=35 or sum(map(len,truth.values()))!=79 or set(truth)!=set(hashes): raise ValueError('Frozen corpus changed')
    source_hashes, baseline = {}, {}
    for name in truth:
        if Path(name).name!=name or not name.endswith('.png') or digest(fixtures/name)!=hashes[name]: raise ValueError('Frozen image changed')
        old=fixtures/(name+'.before.json');page=json.loads(old.read_text())
        if page['info']['metrics']['cacheHit']: raise ValueError('Fresh native reference required')
        baseline[name]=page;source_hashes[name]=hashes[name];source_hashes[name+'.before.json']=digest(old)
    if sum(sum(value in baseline[name]['text'] for value in fields) for name,fields in truth.items())!=52:
        raise ValueError('Native reference does not reproduce 52/79')
    versions={name:version(name) for name in ['paddleocr','paddlepaddle','paddlex','numpy','Pillow']}
    if {k:versions[k] for k in ['paddleocr','paddlepaddle','paddlex']}!={'paddleocr':'3.7.0','paddlepaddle':'3.3.1','paddlex':'3.7.2'}:
        raise ValueError('Runtime differs from pinned benchmark versions')
    names=PaddleOCR._get_ocr_model_names(None,'de','PP-OCRv6')
    if names!=('PP-OCRv6_medium_det','PP-OCRv6_medium_rec'): raise ValueError('German model resolution changed')
    for kind in ['det','rec']:
        if digest(root/'models'/('PP-OCRv6_medium_'+kind)/'inference.pdiparams')!=WEIGHTS[kind]: raise ValueError('Model weights changed')
    output.mkdir(parents=True,exist_ok=False);prepared=output/'prepared';prepared.mkdir()
    setup=watchdog(120);begin=time.monotonic()
    pipeline=PaddleOCR(text_detection_model_name=names[0], text_detection_model_dir=str(root/'models'/names[0]),
        text_recognition_model_name=names[1], text_recognition_model_dir=str(root/'models'/names[1]),
        use_doc_orientation_classify=False,use_doc_unwarping=False,use_textline_orientation=False,
        device='cpu',enable_mkldnn=False,cpu_threads=2)
    init_ms=(time.monotonic()-begin)*1000;setup.cancel()
    report=dict(schemaVersion=1,engine=ENGINE,language='de',resolvedGermanModels=list(names),versions=versions,
        modelProvenance=json.loads((root/'model-provenance.json').read_text()),candidateEnabled=False,
        fixtures=str(fixtures),sourceHashes=source_hashes,manifestSHA256=digest(Path(request['manifest'])),
        networkDeniedForOCR=True,userHomeReadWriteDenied=True,sandboxProfile=request['sandboxProfile'],cpuThreads=2,
        modelInitializationMilliseconds=round(init_ms,3),apple=dict(exactFields=52,timing=timing([p['info']['elapsedMilliseconds'] for p in baseline.values()])),
        variants=[])
    for transform in VARIANTS:
        folder=output/transform;folder.mkdir();cases=[];started=time.monotonic()
        for name,fields in sorted(truth.items()):
            file=fixtures/name
            if transform!='original':
                file=prepared/(transform+'-'+name);prepare_image(fixtures/name,file,transform)
            with Image.open(file) as image:w,h=image.size
            timeout=watchdog(90);start=time.monotonic()
            results=list(pipeline.predict(str(file)));elapsed=(time.monotonic()-start)*1000;timeout.cancel()
            if len(results)!=1: raise ValueError('Expected one physical source page')
            result=results[0].json['res'];lines=candidate_lines(result,w,h)
            text='\n'.join(line['text'] for line in lines)
            candidate=dict(engine=ENGINE,language='de',text=text,lines=lines)
            (folder/(name+'.candidate.json')).write_text(json.dumps(candidate,ensure_ascii=False))
            results[0].save_to_json(str(folder/(name+'.raw.json')))
            old={v for v in fields if v in baseline[name]['text']};new={v for v in fields if v in text}
            row=dict(file=name,expected=len(fields),apple=len(old),paddle=len(new),lost=len(old-new),added=len(new-old),
                     textSHA256=hashlib.sha256(text.encode()).hexdigest(),milliseconds=round(elapsed,3),recognizedLines=len(lines))
            cases.append(row);print(json.dumps(dict(variant=transform,**row)),flush=True)
        variant=dict(name=transform,exactFields=sum(c['paddle'] for c in cases),lostAppleFields=sum(c['lost'] for c in cases),
            additionalExactFields=sum(c['added'] for c in cases),timing=timing([c['milliseconds'] for c in cases]),
            totalVariantMilliseconds=round((time.monotonic()-started)*1000,3),cases=cases)
        report['variants'].append(variant);report['peakResidentBytes']=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        (output/'comparison.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print('VARIANT '+json.dumps({k:v for k,v in variant.items() if k!='cases'}),flush=True)
    for name,sha in source_hashes.items():
        if digest(fixtures/name)!=sha: raise ValueError('Source image or existing evidence changed')
    report['sourceAndEvidenceFilesUnchanged']=True
    (output/'comparison.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    return 0


def run(args):
    root=args.root.resolve();fixture=args.fixtures.resolve();output=args.output.resolve()
    profile=sandbox_profile(Path.home())
    request=dict(root=str(root),fixtures=str(fixture),output=str(output),manifest=str(args.manifest.resolve()),sandboxProfile=profile)
    requestfile=root/'paddle-execution-request.json'
    if requestfile.exists() or output.exists(): raise ValueError('Use a new isolated benchmark directory/output')
    requestfile.write_text(json.dumps(request,indent=2))
    # Keep the venv interpreter symlink: resolving it would select the global environment.
    command=['/usr/bin/sandbox-exec','-p',profile,str(args.python.absolute()),str(Path(__file__).resolve()),'_worker',str(requestfile)]
    start=time.monotonic();result=subprocess.run(command,env=environment(root),cwd=root,timeout=1800)
    (root/'paddle-execution.json').write_text(json.dumps(dict(command=command,exitCode=result.returncode,seconds=round(time.monotonic()-start,3)),indent=2))
    return result.returncode


def check(output):
    run=json.loads((output/'comparison.json').read_text());protected=json.loads((output/'preserved-results.json').read_text())
    if not run['sourceAndEvidenceFilesUnchanged'] or {p['name'] for p in protected}!={v['name'] for v in run['variants']}:
        raise ValueError('Incomplete evidence-protection results')
    passing=[p['name'] for p in protected if p['before']==52 and p['after']>52 and p['lost']==0 and p['preservedEvidence'] and p['unexpectedAdditions']==0]
    report=dict(engine=ENGINE,language='de',apple=52,bestRawPaddleOCR=max(v['exactFields'] for v in run['variants']),
                bestProtected=max(p['after'] for p in protected),qualityGate='GO' if passing else 'NO-GO',passingVariants=passing,candidateEnabled=False)
    (output/'quality-gate.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
    return 0 if passing else 1


def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='action',required=True)
    execute=sub.add_parser('run')
    for name in ['root','fixtures','output','python']:execute.add_argument('--'+name,type=Path,required=True)
    execute.add_argument('--manifest',type=Path,default=REPO/'Tests/VauldyMCPRuntimeTests/Fixtures/faint-line-corpus.json')
    inside=sub.add_parser('_worker');inside.add_argument('request',type=Path)
    evaluate=sub.add_parser('check');evaluate.add_argument('output',type=Path)
    args=parser.parse_args()
    if args.action=='run':return run(args)
    if args.action=='check':return check(args.output.resolve())
    return worker(json.loads(args.request.read_text()))


if __name__=='__main__':raise SystemExit(main())
