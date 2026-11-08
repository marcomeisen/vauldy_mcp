"""Recognition-only worker: deliberately never reads ground truth."""
import json,sys,time,resource,threading,os
from pathlib import Path

ROOT=Path(sys.argv[1]);ENGINE=sys.argv[2]
SUITE=sys.argv[3] if len(sys.argv)>3 else 'input'
OUT=ROOT/'results'/(ENGINE+('' if SUITE=='input' else '-'+SUITE));OUT.mkdir(exist_ok=True)
NAMES=json.loads((ROOT/('source/'+SUITE+'-order.json')).read_text())
def deadline(seconds):
    t=threading.Timer(seconds,lambda:os._exit(124));t.daemon=True;t.start();return t
def emit(row):
    row['rssPeakBytes']=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    print(json.dumps(row),flush=True)
start=time.monotonic();timer=deadline(240)
if ENGINE=='glm':
    import mlx.core as mx
    from mlx_vlm import load,generate
    from mlx_vlm.prompt_utils import apply_chat_template
    model,processor=load(str(ROOT/'models/glm'),trust_remote_code=False)
    prompt=apply_chat_template(processor,model.config,'Text Recognition:',num_images=1)
    def recognize(path):
        result=generate(model,processor,prompt=prompt,image=[str(path)],temperature=0.0,max_tokens=1024,verbose=False)
        mx.synchronize()
        return result.text,{'generationTokens':result.generation_tokens,'mlxPeakBytes':mx.get_peak_memory(),'tokenLimit':1024,'truncated':result.generation_tokens>=1024}
elif ENGINE=='docling-rs':
    import ctypes
    lib=ctypes.CDLL(str(ROOT/'docling-ffi/libdocling_ffi.dylib'))
    lib.docling_convert.argtypes=[ctypes.c_char_p,ctypes.c_size_t,ctypes.c_char_p,ctypes.c_char_p];lib.docling_convert.restype=ctypes.c_void_p
    for func in ['docling_result_output','docling_result_error']:
        getattr(lib,func).argtypes=[ctypes.c_void_p];getattr(lib,func).restype=ctypes.c_char_p
    lib.docling_result_free.argtypes=[ctypes.c_void_p];lib.docling_result_free.restype=None
    lib.docling_version.restype=ctypes.c_char_p
    assert lib.docling_version().decode()=='2.67.1'
    opts=json.dumps({'to':'md','force_full_page_ocr':True,'ocr_lang':'en','ocr_engine':'ppocr'}).encode()
    (OUT/'configuration.json').write_text(json.dumps({'ffiOptions':json.loads(opts),'environment':{k:v for k,v in os.environ.items() if k.startswith('DOCLING_')}},indent=2))
    def recognize(path):
        data=path.read_bytes();result=lib.docling_convert(data,len(data),b'input.png',opts)
        try:
            error=lib.docling_result_error(result)
            if error:raise RuntimeError(error.decode())
            return lib.docling_result_output(result).decode(),{'status':'success','modelInitializationDeferredToConversion':True}
        finally:lib.docling_result_free(result)
elif ENGINE=='docling-py':
    from docling.document_converter import DocumentConverter,ImageFormatOption
    from docling.datamodel.base_models import InputFormat
    from docling.datamodel.pipeline_options import PdfPipelineOptions,RapidOcrOptions,AcceleratorOptions,AcceleratorDevice
    options=PdfPipelineOptions(artifacts_path=ROOT/'models/docling-py',do_ocr=True,do_table_structure=True,
        enable_remote_services=False,accelerator_options=AcceleratorOptions(device=AcceleratorDevice.CPU,num_threads=2),
        ocr_options=RapidOcrOptions(lang=['iso:de'],backend='onnxruntime',model_size='small',force_full_page_ocr=True))
    converter=DocumentConverter(allowed_formats=[InputFormat.IMAGE],format_options={InputFormat.IMAGE:ImageFormatOption(pipeline_options=options)})
    converter.initialize_pipeline(InputFormat.IMAGE)
    (OUT/'configuration.json').write_text(options.model_dump_json(indent=2))
    def recognize(path):
        result=converter.convert(path)
        (OUT/(path.name+'.document.json')).write_text(result.document.model_dump_json())
        return result.document.export_to_markdown(),{'status':str(result.status),'errors':[str(e) for e in result.errors]}
else:raise ValueError(ENGINE)
timer.cancel();emit({'stage':'initialized','milliseconds':(time.monotonic()-start)*1000})
for name in NAMES:
    timer=deadline(90);start=time.monotonic()
    text,extra=recognize(ROOT/'inputs'/name)
    elapsed=(time.monotonic()-start)*1000;timer.cancel()
    row={'file':name,'text':text,'milliseconds':elapsed,**extra}
    (OUT/(name+'.result.json')).write_text(json.dumps(row,ensure_ascii=False,indent=2))
    emit({k:v for k,v in row.items() if k!='text'})
