"""Render actual OCR candidates with the pinned upstream Jev HTML renderer."""
from pathlib import Path
import asyncio,hashlib,json,sys,time
from PIL import Image
from playwright.async_api import async_playwright

ROOT=Path(sys.argv[1]);CORPUS=ROOT/'corpus/frozen'
sys.path.insert(0,str(ROOT/'source/jev/scripts/minicpm-ocr-jev/renderer/render_module'))
from render_label import render_to_pil,RENDER_PIPELINE_VERSION

async def main():
    m=json.loads((CORPUS/'manifest.json').read_text());candidates=[];engines=['apple','docling-py','docling-rs','glm']
    for d in m['documents']:
        for e in engines:
            result=json.loads((ROOT/'results'/e/(d['id']+'.json')).read_text())
            assert not result.get('error') and not result.get('errors')
            assert len(result['pages'])==len(d['pageIDs'])
            for pid,p in zip(d['pageIDs'],result['pages']):
                source=next(s for s in m['pages'] if s['id']==pid)
                text=p.get('markdown',p['text'])
                candidates.append(dict(id=pid+'-'+e,pageID=pid,engine=e,kind='actual-ocr',text=text,
                  textSHA256=hashlib.sha256(text.encode()).hexdigest(),ocrTextSHA256=hashlib.sha256(p['text'].encode()).hexdigest(),image=source['image'],sourceImageSHA256=source['sha256']))
    candidates.extend(json.loads((ROOT/'source/jev-controls.json').read_text()))
    folder=ROOT/'renders/jev';folder.mkdir(exist_ok=True);results=[]
    async with async_playwright() as playwright:
        context=await playwright.chromium.launch_persistent_context(str(ROOT/'cache/render-profile'),executable_path='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless=True,
          args=['--disable-background-networking','--disable-component-update','--disable-sync','--no-first-run','--disable-crash-reporter','--disable-breakpad','--crash-dumps-dir='+str(ROOT/'cache/chrome-crash-dumps')],
          viewport={'width':1800,'height':1400},device_scale_factor=1)
        browser=context.browser
        await context.route('**/*',lambda route:route.abort())
        for item in candidates:
            image=CORPUS/item['image'];assert hashlib.sha256(image.read_bytes()).hexdigest()==item['sourceImageSHA256']
            begin=time.monotonic();out=folder/(item['id']+'.png')
            if not item['text'].strip():
                rendered=Image.new('RGB',(32,32),'white');errors=[]
            else:
                with Image.open(image) as original:width,height=original.size
                rendered,errors=await render_to_pil(context,item['text'],target_width=width,target_height=height,collect_errors=True)
                if rendered is None:raise RuntimeError('No render for '+item['id'])
            rendered.save(out);elapsed=(time.monotonic()-begin)*1000
            row={**item,'render':str(out.relative_to(ROOT)),'renderSHA256':hashlib.sha256(out.read_bytes()).hexdigest(),'renderMilliseconds':elapsed,
                 'renderDimensions':list(rendered.size),'rendererVersion':RENDER_PIPELINE_VERSION,'renderErrors':errors}
            results.append(row);print(item['id'],rendered.size,round(elapsed),errors,flush=True)
            (ROOT/'results/jev-rendered.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
        metadata=dict(rendererVersion=RENDER_PIPELINE_VERSION,browserVersion=browser.version,deviceScaleFactor=1,macOSSystemFonts=True,
                      externalRequestsBlocked=True,candidates=len(results),actualOCRCandidates=sum(x['kind']=='actual-ocr' for x in results),controls=sum(x['kind']!='actual-ocr' for x in results))
        (ROOT/'source/jev-renderer.json').write_text(json.dumps(metadata,indent=2));await context.close()
asyncio.run(main())
