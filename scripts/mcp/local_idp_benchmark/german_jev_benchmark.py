"""Score rendered full-page German OCR candidates and explicit error controls."""
from pathlib import Path
import asyncio,base64,hashlib,json,os,resource,subprocess,sys,threading,time,urllib.request
import psutil

ROOT=Path(sys.argv[1]);OUT=ROOT/'results/jev';OUT.mkdir(exist_ok=True);PORT=19189
sys.path.insert(0,str(ROOT/'source/jev/scripts/minicpm-ocr-jev/sdk'))
from jev_score.backends.llamacpp_backend import LlamaCppBackend
from jev_score.prompt import build_parts
from jev_score.images import read_data_url

async def main():
    items=json.loads((ROOT/'results/jev-rendered.json').read_text());assert len(items)==236
    report=dict(schemaVersion=2,role='verifier-not-OCR',calibration=[],cases=[],controls=[],renderer=json.loads((ROOT/'source/jev-renderer.json').read_text()))
    def persist():(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    cmd=[str(ROOT/'llama/llama-b12110/llama-server'),'-m',str(ROOT/'models/jev/MiniCPM-OCR-Jev-F16.gguf'),'--mmproj',str(ROOT/'models/jev/mmproj-model-f16.gguf'),'--image-max-tokens','1024','-ngl','99','-c','32768','-np','1','-t','2','-tb','2','--host','127.0.0.1','--port',str(PORT)]
    profile='(version 1)(allow default)(deny network*)(allow network-inbound (local ip "localhost:19189"))(deny file-read* (subpath "/Users/marcomeisen"))(deny file-write* (subpath "/Users/marcomeisen"))'
    report['command']=cmd;report['sandbox']=profile;report['rssSamplePeriodSeconds']=.05
    log=(ROOT/'logs/jev-server.log').open('wb');started=time.monotonic();proc=subprocess.Popen(['sandbox-exec','-p',profile,*cmd],cwd=ROOT,stdout=log,stderr=log)
    peak=[0];stop=threading.Event()
    def monitor():
        p=psutil.Process(proc.pid)
        while not stop.wait(.05):
            try:peak[0]=max(peak[0],p.memory_info().rss)
            except psutil.Error:return
    thread=threading.Thread(target=monitor,daemon=True);thread.start();backend=LlamaCppBackend(f'http://127.0.0.1:{PORT}',timeout=180,max_in_flight=1)
    try:
        for _ in range(240):
            if proc.poll() is not None:raise RuntimeError('Jev server exited '+str(proc.returncode))
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{PORT}/health',timeout=1) as response:
                    if json.load(response).get('status')=='ok':break
            except Exception:pass
            await asyncio.sleep(1)
        else:raise TimeoutError('Jev initialization')
        report['initializationMilliseconds']=(time.monotonic()-started)*1000
        assert 'decision model type: openbmb-minicpm-ocr-jev' in (ROOT/'logs/jev-server.log').read_text()
        async def score(original,render,text):
            begin=time.monotonic();values=await backend.forward(build_parts(text),read_data_url(original),read_data_url(render));elapsed=(time.monotonic()-begin)*1000
            assert len(values)==2 and all(0<=v<=1 for v in values) and abs(sum(values)-1)<1e-4
            return dict(probability=values[1],milliseconds=elapsed,rssPeakBytes=peak[0])
        examples=ROOT/'source/jev/scripts/minicpm-ocr-jev/examples'
        for dirname in ['01_text_putnam','02_formula_putnam','03_table_gb_standard']:
            folder=examples/dirname;c=json.loads((folder/'case.json').read_text());role=c['reference_render_of'];text=next(x['text'] for x in c['candidates'] if x['role']==role)
            row=await score(folder/c['block_image'],folder/c['reference_render'],text);row.update(id=dirname,reference=c['observed_prob_yes'][role]);row['absoluteDifference']=abs(row['probability']-row['reference']);report['calibration'].append(row);persist();print('calibration',row,flush=True)
        report['calibrationPassed']=all(x['absoluteDifference']<=.02 for x in report['calibration']);persist()
        if not report['calibrationPassed']:raise RuntimeError('Official calibration failed')
        for item in items:
            original=ROOT/'corpus/frozen'/item['image'];render=ROOT/item['render']
            assert hashlib.sha256(original.read_bytes()).hexdigest()==item['sourceImageSHA256']
            assert hashlib.sha256(render.read_bytes()).hexdigest()==item['renderSHA256']
            assert hashlib.sha256(item['text'].encode()).hexdigest()==item['textSHA256']
            row={k:v for k,v in item.items() if k!='text'}
            try:row.update(await score(original,render,item['text']))
            except Exception as error:row.update(error=repr(error),probability=None)
            report['cases' if item['kind']=='actual-ocr' else 'controls'].append(row);persist();print(item['id'],row.get('probability'),round(row.get('milliseconds',0)),row.get('error'),flush=True)
    except BaseException as error:report['failure']=repr(error);persist();raise
    finally:
        await backend._client.aclose()
        if proc.poll() is None:
            proc.terminate()
            try:proc.wait(timeout=15)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
        stop.set();thread.join(timeout=1);log.close();report['serverRSSPeakBytes']=peak[0];report['clientRSSPeakBytes']=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss;persist()
asyncio.run(main())
