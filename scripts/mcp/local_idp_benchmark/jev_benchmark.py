"""Offline Jev validation: official adapter, frozen calibration images, supplied renders.

Scores are not calibrated probabilities of field correctness. Ground truth is used
only for explicit controls; actual OCR candidate text comes exclusively from engines.
"""
import asyncio,base64,hashlib,json,os,resource,subprocess,sys,threading,time,urllib.request
from pathlib import Path
import psutil
from PIL import Image,ImageDraw,ImageFont

ROOT=Path(sys.argv[1]);OUT=ROOT/'results/jev';OUT.mkdir(exist_ok=True)
sys.path.insert(0,str(ROOT/'source/jev/scripts/minicpm-ocr-jev/sdk'))
from jev_score.backends.llamacpp_backend import LlamaCppBackend
from jev_score.prompt import build_parts
PORT=19089
fontfile=Path('/System/Library/Fonts/Supplemental/Arial.ttf')
font=ImageFont.truetype(str(fontfile),24)
report={'schemaVersion':1,'role':'verifier-not-recognizer','renderVariant':'Pillow Arial 24px, literal text, white background, 16px padding; not upstream Chromium renderer',
        'fontSHA256':hashlib.sha256(fontfile.read_bytes()).hexdigest(),'pillowVersion':Image.__version__,'cases':[],'calibration':[],'controls':[]}
def render(text,path):
    # Keep raw OCR text intact in both the request and literal render. Explicitly
    # a supplied-render macOS experiment, not published Linux score equivalence.
    lines=text.split('\n') or [''];bounds=[font.getbbox(s or ' ') for s in lines]
    width=max(32,min(4096,max(b[2]-b[0] for b in bounds)+32));height=max(48,min(4096,34*len(lines)+32))
    image=Image.new('RGB',(width,height),'white');ImageDraw.Draw(image).multiline_text((16,16),text,font=font,fill='black',spacing=6)
    image.save(path)
def data_url(path):return 'data:image/png;base64,'+base64.b64encode(path.read_bytes()).decode()
def persist(): (OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
async def main():
    cmd=[str(ROOT/'llama/llama-b12110/llama-server'),'-m',str(ROOT/'models/jev/MiniCPM-OCR-Jev-F16.gguf'),'--mmproj',str(ROOT/'models/jev/mmproj-model-f16.gguf'),'-ngl','99','-c','8192','-np','1','-t','2','-tb','2','--host','127.0.0.1','--port',str(PORT)]
    profile='(version 1)(allow default)(deny network*)(allow network-inbound (local ip "localhost:19089"))(deny file-read* (subpath "/Users/marcomeisen"))(deny file-write* (subpath "/Users/marcomeisen"))'
    report['serverCommand']=cmd;report['sandboxProfile']=profile;report['serverRSSSamplePeriodSeconds']=0.05
    log=(ROOT/'logs/jev-server.log').open('wb');start=time.monotonic();proc=subprocess.Popen(['sandbox-exec','-p',profile,*cmd],cwd=ROOT,stdout=log,stderr=log)
    peak=[0];stop=threading.Event()
    def monitor():
        p=psutil.Process(proc.pid)
        while not stop.wait(.05):
            try:peak[0]=max(peak[0],p.memory_info().rss)
            except psutil.Error:return
    thread=threading.Thread(target=monitor,daemon=True);thread.start()
    backend=LlamaCppBackend(f'http://127.0.0.1:{PORT}',timeout=90,max_in_flight=1)
    try:
        for _ in range(240):
            if proc.poll() is not None:raise RuntimeError('Jev server exited '+str(proc.returncode))
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{PORT}/health',timeout=1) as response:
                    if json.load(response).get('status')=='ok':break
            except Exception:pass
            await asyncio.sleep(1)
        else:raise TimeoutError('Jev initialization exceeded 240s')
        report['modelInitializationMilliseconds']=(time.monotonic()-start)*1000
        if 'decision model type: openbmb-minicpm-ocr-jev' not in (ROOT/'logs/jev-server.log').read_text(errors='replace'):
            raise RuntimeError('Decision model identity missing')
        async def score(original,renderfile,text):
            start=time.monotonic();probs=await backend.forward(build_parts(text),data_url(original),data_url(renderfile));elapsed=(time.monotonic()-start)*1000
            assert len(probs)==2 and all(0<=v<=1 for v in probs) and abs(sum(probs)-1)<1e-4
            return {'probability':probs[1],'milliseconds':elapsed,'serverRSSPeakBytes':peak[0]}
        examples=ROOT/'source/jev/scripts/minicpm-ocr-jev/examples'
        for dirname in ['01_text_putnam','02_formula_putnam','03_table_gb_standard']:
            folder=examples/dirname;case=json.loads((folder/'case.json').read_text());role=case['reference_render_of'];text=next(x['text'] for x in case['candidates'] if x['role']==role)
            row=await score(folder/case['block_image'],folder/case['reference_render'],text);row.update(case=dirname,reference=case['observed_prob_yes'][role]);row['absoluteDifference']=abs(row['probability']-row['reference']);report['calibration'].append(row);persist();print('calibration',row,flush=True)
        report['calibrationPassed']=all(x['absoluteDifference']<=.02 for x in report['calibration']);persist()
        if not report['calibrationPassed']:raise RuntimeError('Official three-case calibration failed; do not interpret corpus scores')
        for name in json.loads((ROOT/'source/input-order.json').read_text()):
            for engine in ['apple','docling-py','docling-rs','glm']:
                file=ROOT/'results'/engine/(name+('.page.json' if engine=='apple' else '.result.json'));text=json.loads(file.read_text())['text'];renderfile=OUT/(name+'-'+engine+'.png')
                begin=time.monotonic();render(text,renderfile);render_ms=(time.monotonic()-begin)*1000
                row=await score(ROOT/'inputs'/name,renderfile,text);row.update(file=name,engine=engine,renderMilliseconds=render_ms,textSHA256=hashlib.sha256(text.encode()).hexdigest(),renderSHA256=hashlib.sha256(renderfile.read_bytes()).hexdigest())
                report['cases'].append(row);persist();print(name,engine,round(row['probability'],5),round(row['milliseconds']),flush=True)
        truth=json.loads((ROOT/'source/manifest.json').read_text())['truth']
        for name in ['clean.png','date.png','invoice.png','ambiguous.png','italic-Helvetica-Oblique-14.png','tilted-12-left.png']:
            correct='Synthetische Zeilenpruefung\n'+'\n'.join(truth[name]);bad=correct
            # One deterministic alphanumeric corruption, in the first field.
            target=truth[name][0];offset=next((i for i,c in enumerate(target) if c.isdigit()),len(target)//2);changed=target[:offset]+('8' if target[offset]!='8' else '7')+target[offset+1:];bad=correct.replace(target,changed,1)
            for label,text in [('source-control',correct),('one-character-error',bad)]:
                renderfile=OUT/(name+'-'+label+'.png');render(text,renderfile);row=await score(ROOT/'inputs'/name,renderfile,text);row.update(file=name,label=label,text=text);report['controls'].append(row);persist();print('control',name,label,row['probability'],flush=True)
    except BaseException as e:
        report['failure']=repr(e);persist();raise
    finally:
        await backend._client.aclose()
        if proc.poll() is None:
            proc.terminate()
            try:proc.wait(timeout=15)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
        stop.set();thread.join(timeout=1);log.close();report['serverRSSPeakBytes']=peak[0];report['clientRSSPeakBytes']=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss;persist()
asyncio.run(main())
