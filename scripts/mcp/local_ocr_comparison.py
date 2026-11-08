#!/usr/bin/env python3
"""German Tesseract vs frozen native Apple-Vision fixtures. Benchmark only; no downloads or installation.

Run native OCRFaintRasterTests first with VAULDY_OCR_FAINT_FIXTURES pointing at a fresh directory.
Each fixed configuration is applied to ALL 35 images. No per-image oracle selection or custom words.
Then run LocalOCRAlternativeComparisonTests and `check` to evaluate preserved evidence and >52/79.
"""
import argparse
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import struct
import subprocess
import time
import zlib

REPO = Path(__file__).resolve().parents[2]
MODEL_SHA256 = '8407331d6aa0229dc927685c01a7938fc5a641d1a9524f74838cdac599f0d06e'
MODEL_COMMIT = 'e12c65a915945e4c28e237a9b52bc4a8f39a0cec'
PROFILE = '(version 1)(allow default)(deny network*)'
# label, preprocessing, PSM, thresholding. Globally fixed, never chosen from expected fields.
VARIANTS = [('auto', 'original', 3, 0), ('block', 'original', 6, 0),
            ('adaptive-block', 'original', 6, 1), ('scale3-auto', 'scale3', 3, 0),
            ('scale3-block', 'scale3', 6, 0), ('contrast3-auto', 'contrast3', 3, 0),
            ('contrast3-block', 'contrast3', 6, 0), ('contrast3-sauvola', 'contrast3', 6, 2)]


def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


def grey_png(data):
    """Read only the fixed corpus' bounded, noninterlaced 8-bit grayscale PNG format."""
    if len(data) > 2_000_000 or data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('Expected bounded grayscale corpus PNG')
    pos, compressed, dimensions = 8, bytearray(), None
    while pos < len(data):
        size, = struct.unpack('>I', data[pos:pos+4])
        tag, chunk = data[pos+4:pos+8], data[pos+8:pos+8+size]
        if len(chunk) != size or pos + size + 12 > len(data):
            raise ValueError('Truncated PNG')
        if tag == b'IHDR':
            w, h, bits, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', chunk)
            if not (0 < w <= 3072 and 0 < h <= 3072 and w*h <= 1_000_000) or (bits, color, compression, filtering, interlace) != (8, 0, 0, 0, 0):
                raise ValueError('Unsupported corpus PNG format')
            dimensions = w, h
        if tag == b'IDAT': compressed.extend(chunk)
        pos += size + 12
        if tag == b'IEND': break
    if dimensions is None: raise ValueError('Missing dimensions')
    w, h = dimensions
    inflater = zlib.decompressobj()
    raw = inflater.decompress(compressed, (w+1)*h+1)
    if len(raw) != (w+1)*h or not inflater.eof or inflater.unconsumed_tail:
        raise ValueError('Invalid bounded PNG payload')
    pixels = bytearray(w*h)
    for y in range(h):
        mode = raw[y*(w+1)]
        if mode > 4: raise ValueError('Invalid PNG filter')
        for x in range(w):
            left = pixels[y*w+x-1] if x else 0
            up = pixels[(y-1)*w+x] if y else 0
            corner = pixels[(y-1)*w+x-1] if x and y else 0
            p = left+up-corner
            a, b, c = abs(p-left), abs(p-up), abs(p-corner)
            paeth = left if a <= b and a <= c else up if b <= c else corner
            pixels[y*w+x] = (raw[y*(w+1)+1+x] + (0, left, up, (left+up)//2, paeth)[mode]) % 256
    return w, h, pixels


def prepared_pgm(data, contrast):
    w, h, pixels = grey_png(data)
    if w*h*9 > 4_000_000: raise ValueError('Prepared image exceeds benchmark pixel budget')
    if contrast:
        border = sorted(pixels[y*w+x] for y in range(h) for x in range(w)
                        if y < 4 or y >= h-4 or x < 4 or x >= w-4)
        anchor = border[len(border)//20]
        pixels = bytes(max(0, min(255, round(255+(value-anchor)*255/32))) for value in pixels)
    enlarged = bytearray()
    for y in range(h):
        row = bytes(value for value in pixels[y*w:(y+1)*w] for _ in range(3))
        enlarged.extend(row*3)
    return f'P5\n{w*3} {h*3}\n255\n'.encode() + enlarged


def word_confidences(file):
    with file.open() as stream:
        values = [float(row['conf']) for row in csv.DictReader(stream, delimiter='\t')
                  if row['level'] == '5' and row['text'].strip() and float(row['conf']) >= 0]
    return dict(minWordConfidence=min(values) if values else None,
                meanWordConfidence=statistics.mean(values) if values else None)


def timing(values):
    ordered = sorted(values)
    return dict(sumMilliseconds=round(sum(values), 3), medianMilliseconds=round(statistics.median(values), 3),
                p95Milliseconds=round(ordered[math.ceil(len(ordered)*0.95)-1], 3))


def run(args):
    fixtures, tessdata, output = args.fixtures.resolve(), args.tessdata.resolve(), args.output.resolve()
    manifest = json.loads(args.manifest.read_text())
    truth, hashes = manifest['truth'], manifest['sha256']
    if len(truth) != 35 or sum(map(len, truth.values())) != 79 or set(truth) != set(hashes):
        raise ValueError('Expected frozen 35-image/79-field corpus')
    if digest(tessdata/'deu.traineddata') != MODEL_SHA256:
        raise ValueError('Expected the pinned official tessdata_best German model')
    if not Path('/usr/bin/sandbox-exec').is_file(): raise RuntimeError('Required offline process sandbox unavailable')
    executable = Path(shutil.which(args.tesseract) or args.tesseract).resolve(strict=True)
    versions = subprocess.run([str(executable), '--version'], check=True, capture_output=True, text=True).stdout.splitlines()
    source_hashes, baseline = {}, {}
    for name in truth:
        if Path(name).name != name or not name.endswith('.png'): raise ValueError('Invalid frozen fixture name')
        if digest(fixtures/name) != hashes[name]: raise ValueError('Frozen pixels changed: '+name)
        old = fixtures/(name+'.before.json')
        page = json.loads(old.read_text())
        if page['info']['metrics']['cacheHit']: raise ValueError('Fresh Apple-Vision baseline required')
        source_hashes[name] = hashes[name]; source_hashes[name+'.before.json'] = digest(old)
        baseline[name] = page
    apple_score = sum(sum(field in baseline[name]['text'] for field in fields) for name, fields in truth.items())
    if apple_score != 52: raise ValueError('Apple baseline must independently reproduce 52/79')
    output.mkdir(parents=True, exist_ok=False)
    prep = output/'prepared'; prep.mkdir()
    for name in truth:
        data = (fixtures/name).read_bytes()
        for transform in ['scale3', 'contrast3']:
            folder = prep/transform; folder.mkdir(exist_ok=True)
            (folder/(name+'.pgm')).write_bytes(prepared_pgm(data, transform == 'contrast3'))
    report = dict(schemaVersion=1, corpusImages=35, expectedFields=79, language='deu',
                  modelCommit=MODEL_COMMIT, modelSHA256=MODEL_SHA256, modelBytes=(tessdata/'deu.traineddata').stat().st_size,
                  tesseractVersion=versions[0], executableSHA256=digest(executable), candidateEnabled=False,
                  networkDeniedForOCR=True, sandboxProfile=PROFILE, threads=2,
                  manifestSHA256=digest(args.manifest), sourceHashes=source_hashes,
                  apple=dict(exactFields=apple_score, timing=timing([p['info']['elapsedMilliseconds'] for p in baseline.values()]),
                             timingScope='native page-reported OCR; no cache; excludes Swift process/build startup'),
                  fixtures=str(fixtures), output=str(output), variants=[])
    started = time.monotonic()
    for label, transform, psm, threshold in VARIANTS:
        folder = output/label; folder.mkdir()
        cases = []
        for name, fields in sorted(truth.items()):
            file = fixtures/name if transform == 'original' else prep/transform/(name+'.pgm')
            base = folder/name
            command = ['/usr/bin/sandbox-exec', '-p', PROFILE, str(executable), str(file), str(base),
                       '--tessdata-dir', str(tessdata), '-l', 'deu', '--oem', '1', '--psm', str(psm),
                       '-c', 'thresholding_method='+str(threshold), '-c', 'tessedit_create_tsv=1', '-c', 'tessedit_create_txt=1']
            begin = time.monotonic()
            result = subprocess.run(command, env=dict(os.environ, OMP_THREAD_LIMIT='2'), capture_output=True, timeout=30)
            elapsed = (time.monotonic()-begin)*1000
            if result.returncode: raise RuntimeError('German local OCR failed for '+label+'/'+name+' with code '+str(result.returncode))
            text_file, tsv_file = Path(str(base)+'.txt'), Path(str(base)+'.tsv')
            if max(text_file.stat().st_size, tsv_file.stat().st_size) > 1_000_000: raise ValueError('OCR output limit exceeded')
            text = text_file.read_text()
            old = {value for value in fields if value in baseline[name]['text']}
            new = {value for value in fields if value in text}
            cases.append(dict(file=name, expected=len(fields), apple=len(old), tesseract=len(new),
                              matchedFieldIndices=[i for i, value in enumerate(fields) if value in text],
                              lost=len(old-new), added=len(new-old), milliseconds=round(elapsed, 3),
                              textSHA256=digest(text_file), tsvSHA256=digest(tsv_file), **word_confidences(tsv_file)))
            (folder/(name+'.candidate.json')).write_text(json.dumps(dict(engine='tesseract', language='deu', text=text)))
        total, lost, added = (sum(case[key] for case in cases) for key in ['tesseract', 'lost', 'added'])
        variant = dict(name=label, preprocessing=transform, psm=psm, thresholding=threshold, exactFields=total,
                       lostAppleFields=lost, additionalExactFields=added, directReplacementGate='GO' if total > 52 and lost == 0 else 'NO-GO',
                       timing=timing([c['milliseconds'] for c in cases]), timingScope='fresh OCR subprocess including model loading; preprocessing excluded', cases=cases)
        report['variants'].append(variant)
        report['elapsedSeconds'] = round(time.monotonic()-started, 3)
        (output/'comparison.json').write_text(json.dumps(report, indent=2, ensure_ascii=False)+'\n')
        print(json.dumps({k: v for k, v in variant.items() if k != 'cases'}), flush=True)
    for name, sha in source_hashes.items():
        if digest(fixtures/name) != sha: raise ValueError('Original or Apple evidence was modified: '+name)
    report['sourceAndEvidenceFilesUnchanged'] = True
    (output/'comparison.json').write_text(json.dumps(report, indent=2, ensure_ascii=False)+'\n')
    return 0


def check(output):
    report = json.loads((output/'comparison.json').read_text())
    preserved = json.loads((output/'preserved-results.json').read_text())
    if {row['name'] for row in preserved} != {row['name'] for row in report['variants']}:
        raise ValueError('Missing Swift evidence-protection results')
    passing = [row['name'] for row in preserved if row['before'] == 52 and row['after'] > 52
               and row['lost'] == 0 and row['preservedEvidence'] and row['unexpectedAdditions'] == 0]
    result = dict(language='deu', apple=52, bestRawTesseract=max(v['exactFields'] for v in report['variants']),
                  bestProtected=max(v['after'] for v in preserved), qualityGate='GO' if passing else 'NO-GO',
                  passingVariants=passing, candidateEnabled=False)
    (output/'quality-gate.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))
    return 0 if passing else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    execute = sub.add_parser('run')
    execute.add_argument('--fixtures', type=Path, required=True)
    execute.add_argument('--tessdata', type=Path, required=True)
    execute.add_argument('--output', type=Path, required=True)
    execute.add_argument('--tesseract', default='tesseract')
    execute.add_argument('--manifest', type=Path, default=REPO/'Tests/VauldyMCPRuntimeTests/Fixtures/faint-line-corpus.json')
    evaluate = sub.add_parser('check'); evaluate.add_argument('output', type=Path)
    args = parser.parse_args()
    return run(args) if args.action == 'run' else check(args.output.resolve())


if __name__ == '__main__':
    raise SystemExit(main())
