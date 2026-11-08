"""Offline PDF benchmark worker. Requests contain input hashes/pages but no truth."""
from pathlib import Path
import ctypes,hashlib,json,os,resource,sys,threading,time

ROOT=Path(sys.argv[1]);ENGINE=sys.argv[2];CORPUS=ROOT/'corpus/frozen'
OUT=ROOT/'results'/ENGINE;OUT.mkdir(exist_ok=True)
REQUESTS=json.loads((CORPUS/'requests.json').read_text())
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def deadline(seconds):
    timer=threading.Timer(seconds,lambda:os._exit(124));timer.daemon=True;timer.start();return timer
def emit(row):print(json.dumps(row),flush=True)
timer=deadline(240);start=time.monotonic()
if ENGINE=='glm':
    import mlx.core as mx
    from mlx_vlm import load,generate
    from mlx_vlm.prompt_utils import apply_chat_template
    model,processor=load(str(ROOT/'models/glm'),trust_remote_code=False)
    prompt=apply_chat_template(processor,model.config,'Text Recognition:',num_images=1)
else:
    from docling_core.types.doc import DoclingDocument,ContentLayer
    if ENGINE=='docling-py':
        from docling.document_converter import DocumentConverter,PdfFormatOption
        from docling.datamodel.base_models import InputFormat
        from docling.datamodel.pipeline_options import PdfPipelineOptions,RapidOcrOptions,AcceleratorOptions,AcceleratorDevice
        options=PdfPipelineOptions(artifacts_path=ROOT/'models/docling-py',do_ocr=True,do_table_structure=True,
          enable_remote_services=False,accelerator_options=AcceleratorOptions(device=AcceleratorDevice.CPU,num_threads=2),
          document_timeout=600,ocr_options=RapidOcrOptions(lang=['iso:de'],backend='onnxruntime',model_size='small',force_full_page_ocr=True))
        converter=DocumentConverter(allowed_formats=[InputFormat.PDF],format_options={InputFormat.PDF:PdfFormatOption(pipeline_options=options)})
        converter.initialize_pipeline(InputFormat.PDF)
        (OUT/'configuration.json').write_text(options.model_dump_json(indent=2))
    elif ENGINE=='docling-rs':
        lib=ctypes.CDLL(str(ROOT/'docling-ffi/libdocling_ffi.dylib'))
        lib.docling_convert.argtypes=[ctypes.c_char_p,ctypes.c_size_t,ctypes.c_char_p,ctypes.c_char_p];lib.docling_convert.restype=ctypes.c_void_p
        for fn in ['docling_result_output','docling_result_error']:
            getattr(lib,fn).argtypes=[ctypes.c_void_p];getattr(lib,fn).restype=ctypes.c_char_p
        lib.docling_result_free.argtypes=[ctypes.c_void_p];lib.docling_result_free.restype=None
        lib.docling_version.restype=ctypes.c_char_p;assert lib.docling_version().decode()=='2.67.1'
        opts=json.dumps({'to':'json','force_full_page_ocr':True,'ocr_lang':'en','ocr_engine':'ppocr'}).encode()
        (OUT/'configuration.json').write_text(json.dumps({'ffi':json.loads(opts),'environment':{k:v for k,v in os.environ.items() if k.startswith('DOCLING_')}},indent=2))
    else:raise ValueError(ENGINE)
timer.cancel();emit({'stage':'initialized','milliseconds':(time.monotonic()-start)*1000,'rssPeakBytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss})
for request in REQUESTS:
    path=CORPUS/request['pdf'];assert sha(path)==request['sha256'];pages=[]
    timer=deadline(900);start=time.monotonic();extra={}
    try:
        if ENGINE=='glm':
            for index,p in enumerate(request['pages'],1):
                image=CORPUS/p['image'];assert sha(image)==p['sha256'];begin=time.monotonic()
                result=generate(model,processor,prompt=prompt,image=[str(image)],temperature=0.0,max_tokens=2048,verbose=False)
                mx.synchronize()
                pages.append(dict(page=index,id=p['id'],text=result.text,markdown=result.text,milliseconds=(time.monotonic()-begin)*1000,
                  generationTokens=result.generation_tokens,tokenLimit=2048,truncated=result.generation_tokens>=2048,mlxPeakBytes=mx.get_peak_memory(),tables=[]))
                emit({'page':p['id'],'milliseconds':pages[-1]['milliseconds'],'tokens':result.generation_tokens})
            extra['pdfAdapter']='verified original image XObjects, one image per physical page; no PDF text layer or OCR truth'
        else:
            if ENGINE=='docling-py':
                result=converter.convert(path,raises_on_error=False);doc=result.document;extra={'status':str(result.status),'errors':[str(x) for x in result.errors]}
                raw=doc.model_dump_json()
            else:
                data=path.read_bytes();handle=lib.docling_convert(data,len(data),b'input.pdf',opts)
                try:
                    error=lib.docling_result_error(handle)
                    if error:raise RuntimeError(error.decode())
                    raw=lib.docling_result_output(handle).decode()
                finally:lib.docling_result_free(handle)
                doc=DoclingDocument.model_validate_json(raw)
            (OUT/(request['id']+'.document.json')).write_text(raw)
            for num in sorted(doc.pages):
                pg=dict(page=num,text=doc.export_to_text(page_no=num,included_content_layers=set(ContentLayer),traverse_pictures=True),
                  markdown=doc.export_to_markdown(page_no=num,included_content_layers=set(ContentLayer),traverse_pictures=True),tables=[])
                for t in doc.tables:
                    if any(prov.page_no==num for prov in t.prov):pg['tables'].append(t.model_dump(mode='json'))
                pages.append(pg)
        ms=(time.monotonic()-start)*1000
        record=dict(id=request['id'],inputSHA256=request['sha256'],milliseconds=ms,pages=pages,
                    rssPeakBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,**extra)
    except Exception as error:
        record=dict(id=request['id'],inputSHA256=request['sha256'],milliseconds=(time.monotonic()-start)*1000,pages=[],
                    error=repr(error),rssPeakBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    finally:timer.cancel()
    (OUT/(request['id']+'.json')).write_text(json.dumps(record,ensure_ascii=False,indent=2))
    emit({k:v for k,v in record.items() if k!='pages'}|{'pageCount':len(record['pages'])})
