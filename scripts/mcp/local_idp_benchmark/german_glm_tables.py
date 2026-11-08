"""Separate GLM table-recognition diagnostic with preannotated table regions.

This does not test table detection and never replaces the full-page OCR results.
"""
from pathlib import Path
import hashlib,json,sys,time,resource,threading,os
from PIL import Image

ROOT=Path(sys.argv[1]);CORPUS=ROOT/'corpus/frozen';folder=ROOT/'corpus/table-crops';folder.mkdir(exist_ok=True)
m=json.loads((CORPUS/'manifest.json').read_text());requests=[]
for p in m['pages']:
    for table in p['tables']:
        source=CORPUS/p['image'];assert hashlib.sha256(source.read_bytes()).hexdigest()==p['sha256']
        with Image.open(source) as image:
            w,h=image.size;x,y,bw,bh=table['bbox'];box=(max(0,int(x*w)-24),max(0,int(y*h)-24),min(w,int((x+bw)*w)+24),min(h,int((y+bh)*h)+24));crop=image.crop(box)
        path=folder/(table['id']+'.png');crop.save(path)
        requests.append(dict(id=table['id'],pageID=p['id'],image=str(path.relative_to(ROOT)),sha256=hashlib.sha256(path.read_bytes()).hexdigest(),sourceSHA256=p['sha256'],pixelBox=box))
protocol=dict(role='supplemental table recognition with frozen ground-truth regions; no detector; not pooled into full-page metrics',prompt='Table Recognition:',temperature=0,maxTokens=2048,requests=requests)
(ROOT/'source/glm-table-protocol.json').write_text(json.dumps(protocol,indent=2))
out=ROOT/'results/glm-table-mode';out.mkdir(exist_ok=True)
timer=threading.Timer(600,lambda:os._exit(124));timer.daemon=True;timer.start();start=time.monotonic()
import mlx.core as mx
from mlx_vlm import load,generate
from mlx_vlm.prompt_utils import apply_chat_template
model,processor=load(str(ROOT/'models/glm'),trust_remote_code=False)
prompt=apply_chat_template(processor,model.config,'Table Recognition:',num_images=1)
init=(time.monotonic()-start)*1000;results=[]
for req in requests:
    image=ROOT/req['image'];assert hashlib.sha256(image.read_bytes()).hexdigest()==req['sha256'];start=time.monotonic()
    result=generate(model,processor,prompt=prompt,image=[str(image)],temperature=0.0,max_tokens=2048,verbose=False);mx.synchronize()
    row=dict(**req,text=result.text,milliseconds=(time.monotonic()-start)*1000,tokens=result.generation_tokens,truncated=result.generation_tokens>=2048,mlxPeakBytes=mx.get_peak_memory(),rssPeakBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    results.append(row);(out/(req['id']+'.json')).write_text(json.dumps(row,ensure_ascii=False,indent=2));print(req['id'],round(row['milliseconds']),row['tokens'],flush=True)
timer.cancel();(out/'report.json').write_text(json.dumps(dict(initializationMilliseconds=init,protocol=protocol,cases=results),ensure_ascii=False,indent=2))
