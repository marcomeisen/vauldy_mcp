#!/usr/bin/env python3
"""Mutation controls for the frozen image/PDF preservation gate; no OCR is run."""
import argparse
import json
from pathlib import Path
import shutil
import tempfile
from ocr_source_punctuation_quality_gate import evaluate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['images', 'corpus', 'pdfs']: parser.add_argument(name, type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    assert evaluate(args.images, args.corpus, args.pdfs)['passed']
    rejected = []
    for mutation in ['priorCorrectField', 'decimalRepair', 'inventedText', 'priorPDFUnit', 'originalBytes']:
        with tempfile.TemporaryDirectory(prefix='vauldy-punctuation-gate-') as temp:
            root = Path(temp); images = root/'images'; pdfs = root/'pdfs'
            shutil.copytree(args.images, images); shutil.copytree(args.pdfs, pdfs)
            if mutation in ['priorCorrectField','decimalRepair','inventedText']:
                name = dict(priorCorrectField='clean.png',decimalRepair='tilted-9-right.png',inventedText='grid-9-93-25.png')[mutation]
                for suffix in ['.json','.fresh.json','.v17-fresh.json']:
                    file = images/(name+suffix); data = json.loads(file.read_text())
                    if mutation == 'priorCorrectField': data['text'] = data['text'].replace('82,47', '82,48')
                    elif mutation == 'decimalRepair': data['text'] = data['text'].replace('82,47', '82.47')
                    else: data['text'] += '\nInvented content'
                    file.write_text(json.dumps(data))
            elif mutation == 'priorPDFUnit':
                file = pdfs/'doc-005.json'; data = json.loads(file.read_text())
                for key in ['pages','freshPages']:
                    for page in data[key]: page['text'] = page['text'].replace('86,240 m³','86,240 m²')
                file.write_text(json.dumps(data))
            else:
                with (images/'clean.png').open('ab') as stream: stream.write(b'changed')
            try: evaluate(images,args.corpus,pdfs)
            except (AssertionError, ValueError): rejected.append(mutation)
            else: raise AssertionError('Mutation was accepted: '+mutation)
    result=dict(passed=True,rejectedMutations=rejected)
    args.report.write_text(json.dumps(result,indent=2)+'\n'); print(json.dumps(result))

if __name__ == '__main__': main()
