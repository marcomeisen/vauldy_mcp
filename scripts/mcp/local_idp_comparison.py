#!/usr/bin/env python3
"""Summarize isolated local IDP runs; never installs, downloads or invokes OCR.

Recognition workers receive images and a constant prompt, never field truth.
This evaluator checks the frozen image hashes before reading output text.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import unicodedata

REPO = Path(__file__).resolve().parents[2]
ENGINES = ['apple', 'docling-py', 'docling-rs', 'glm']


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def read(path):
    return json.loads(path.read_text())


def timing(values):
    assert values and all(math.isfinite(v) and v >= 0 for v in values)
    ordered = sorted(values)
    return dict(count=len(values), totalMilliseconds=sum(values),
                medianMilliseconds=statistics.median(values),
                p95Milliseconds=ordered[math.ceil(.95 * len(values)) - 1])


def normalized(text):
    # Descriptive secondary metric only. No case folding or punctuation repair.
    return ' '.join(re.sub(r'(?m)^#{1,6}\s+', '', unicodedata.normalize('NFC', text)).split())


def distance(left, right):
    previous = list(range(len(right) + 1))
    for i, a in enumerate(left, 1):
        row = [i]
        for j, b in enumerate(right, 1):
            row.append(min(row[-1] + 1, previous[j] + 1, previous[j - 1] + (a != b)))
        previous = row
    return previous[-1]


def auc(positives, negatives):
    assert positives and negatives
    return sum((a > b) + .5 * (a == b) for a in positives for b in negatives) / (len(positives) * len(negatives))


def output(root, engine, name, suite=''):
    return read(root / 'results' / (engine + suite) / (name + ('.page.json' if engine == 'apple' else '.result.json')))


def evaluate(root):
    manifest = read(root / 'source/manifest.json')
    canonical = REPO / 'Tests/VauldyMCPRuntimeTests/Fixtures/faint-line-corpus.json'
    assert manifest == read(canonical), 'Frozen corpus contract changed'
    truth = manifest['truth']
    assert len(truth) == 35 and sum(map(len, truth.values())) == 79
    for name, expected in manifest['sha256'].items():
        assert Path(name).name == name and sha(root / 'inputs' / name) == expected, 'Frozen image changed: ' + name
    apple = {n: output(root, 'apple', n)['text'] for n in truth}
    assert sum(sum(f in apple[n] for f in fs) for n, fs in truth.items()) == 52
    report = dict(schemaVersion=1, date='2026-11-08', candidateEnabled=False,
                  hardware=read(root / 'source/hardware.json'),
                  appleSourceVerification=read(root / 'source/apple-source-verification.json'),
                  corpus=dict(images=35, expectedFields=79, manifestSHA256=sha(canonical),
                              imageSHA256=manifest['sha256'], scope='synthetic difficult German lines; ASCII transliterations; no real archive or table benchmark'),
                  primaryMetric='literal exact substring fields; unchanged 79-field contract',
                  secondaryMetric='post-hoc descriptive CER/WER; source header plus fields from LineScan.write; NFC, remove Markdown heading prefix, collapse whitespace',
                  memoryMetric='macOS process ru_maxrss bytes; Jev server sampled RSS every 50 ms; excludes Apple service processes; MLX GPU allocations reported separately and not summed with RSS',
                  execution='sequential, offline, two CPU threads for model pipelines; one measured pass per model; separate Apple repetition',
                  engines={})
    all_outputs = {}
    for engine in ENGINES:
        events = [json.loads(line) for line in (root / 'results' / (engine + '-timing.jsonl')).read_text().splitlines()]
        rows = [x for x in events if 'file' in x]
        assert [x['file'] for x in rows] == sorted(truth)
        cases = []; chars = edits = words = word_edits = 0
        for row in rows:
            n = row['file']; fields = truth[n]; result = output(root, engine, n)
            text = result['text']; all_outputs[n, engine] = text
            old = {f for f in fields if f in apple[n]}; new = {f for f in fields if f in text}
            if engine == 'apple':
                assert result['info'].get('metrics', {}).get('cacheHit') is not True
                assert result['info']['method'] not in ['unreadable', 'blank']
            else:
                assert not result.get('errors') and not result.get('truncated')
            ref = normalized('Synthetische Zeilenpruefung\n' + '\n'.join(fields)); got = normalized(text)
            chars += len(ref); edits += distance(ref, got); words += len(ref.split()); word_edits += distance(ref.split(), got.split())
            cases.append(dict(expectedFields=len(fields), exactFields=len(new),
                              lostFields=sorted(old-new), addedFields=sorted(new-old),
                              text=text, textSHA256=hashlib.sha256(text.encode()).hexdigest(), **row))
        entry = dict(exactFields=sum(x['exactFields'] for x in cases),
                     completeImages=sum(x['exactFields'] == x['expectedFields'] for x in cases),
                     lostFields=sum(len(x['lostFields']) for x in cases),
                     addedFields=sum(len(x['addedFields']) for x in cases),
                     initializationMilliseconds=next((x['milliseconds'] for x in events if x.get('stage') == 'initialized'), None),
                     firstImageMilliseconds=rows[0]['milliseconds'],
                     timing=timing([x['milliseconds'] for x in rows]),
                     subsequentImagesTiming=timing([x['milliseconds'] for x in rows[1:]]),
                     rssPeakBytes=max(x['rssPeakBytes'] for x in events),
                     characterErrorRate=edits/chars, wordErrorRate=word_edits/words,
                     referenceCharacters=chars, characterEdits=edits,
                     referenceWords=words, wordEdits=word_edits, cases=cases)
        if engine == 'glm':
            entry['mlxPeakBytes'] = max(x.get('mlxPeakBytes', 0) for x in rows)
        entry['qualityGate'] = entry['exactFields'] > 52 and entry['lostFields'] == 0
        report['engines'][engine] = entry
    warm = [json.loads(line) for line in (root / 'results/apple-warm-timing.jsonl').read_text().splitlines()]
    assert len(warm) == 35
    repeat = {n: output(root, 'apple', n, '-warm')['text'] for n in truth}
    report['appleRepetition'] = dict(exactFields=sum(sum(f in repeat[n] for f in fs) for n, fs in truth.items()),
                                    identicalTexts=sum(apple[n] == repeat[n] for n in truth),
                                    firstImageMilliseconds=warm[0]['milliseconds'],
                                    timing=timing([x['milliseconds'] for x in warm]),
                                    subsequentImagesTiming=timing([x['milliseconds'] for x in warm[1:]]),
                                    rssPeakBytes=max(x['rssPeakBytes'] for x in warm))
    j = read(root / 'results/jev/report.json')
    assert j.get('calibrationPassed') and len(j['calibration']) == 3 and not j.get('failure')
    assert len(j['cases']) == 140 and len(j['controls']) == 12
    assert len({(x['file'], x['engine']) for x in j['cases']}) == 140
    scores = {(x['file'], x['engine']): x['probability'] for x in j['cases']}
    positive = []; negative = []; confusion = dict(tp=0, fp=0, tn=0, fn=0); selected = []
    for row in j['cases']:
        n, e = row['file'], row['engine']; text = all_outputs[n, e]
        assert row['textSHA256'] == hashlib.sha256(text.encode()).hexdigest(), 'Score/text binding changed'
        assert math.isfinite(row['probability']) and 0 <= row['probability'] <= 1
        complete = all(f in text for f in truth[n])
        (positive if complete else negative).append(row['probability'])
        verdict = ('tp' if complete else 'fp') if row['probability'] >= .5 else ('fn' if complete else 'tn')
        confusion[verdict] += 1
    for n, fields in truth.items():
        # Fixed engine priority resolves ties. No field truth participates in selection.
        best = max(ENGINES, key=lambda e: scores[n, e]); text = all_outputs[n, best]
        selected.append(dict(file=n, engine=best, probability=scores[n, best],
                             exactFields=sum(f in text for f in fields),
                             lostFields=[f for f in fields if f in apple[n] and f not in text],
                             addedFields=[f for f in fields if f not in apple[n] and f in text]))
    selection = dict(exactFields=sum(x['exactFields'] for x in selected), lostFields=sum(len(x['lostFields']) for x in selected),
                     addedFields=sum(len(x['addedFields']) for x in selected), cases=selected)
    selection['qualityGate'] = selection['exactFields'] > 52 and selection['lostFields'] == 0
    report['jev'] = dict(**j, timing=timing([x['milliseconds'] for x in j['cases']]),
                        renderTiming=timing([x['renderMilliseconds'] for x in j['cases']]),
                        fieldCompletenessAUC=auc(positive, negative), completeCandidates=len(positive), incompleteCandidates=len(negative),
                        diagnosticThreshold=.5, fieldCompletenessConfusion=confusion,
                        controlPairedRankingCorrect=sum(a['probability'] > b['probability'] for a, b in zip(j['controls'][::2], j['controls'][1::2])),
                        selected=selection)
    cm = read(root / 'source/controls-manifest.json'); controls = {}
    for n, expected in cm['sha256'].items():
        assert sha(root/'inputs'/n) == expected
    for e in ENGINES:
        cases = []
        for n, fs in cm['truth'].items():
            d = output(root, e, n, '-controls')
            cases.append(dict(file=n, expectedFields=len(fs), exactFields=sum(f in d['text'] for f in fs),
                              text=d['text'], isBlankControl=not fs))
        controls[e] = dict(exactFields=sum(x['exactFields'] for x in cases), expectedFields=10,
                           blankFalsePositives=sum(bool(x['text'].strip()) for x in cases if x['isBlankControl']), cases=cases)
    report['supplementalControls'] = dict(manifest=cm, engines=controls, includedInPrimaryMetric=False)
    report['artifacts'] = [read(p) for p in sorted((root/'licenses').glob('artifact*.json'))]
    for artifact in report['artifacts']:
        path = root / artifact['relativePath']
        assert '..' not in Path(artifact['relativePath']).parts and not Path(artifact['relativePath']).is_absolute()
        assert path.is_file()
        assert sha(path) == artifact['sha256'], 'Downloaded artifact changed'
        if artifact.get('expectedSHA256'):
            assert artifact['sha256'] == artifact['expectedSHA256']
    report['licenseInventory'] = {e: dict(file='local-idp-licenses/'+e+'-inventory.json', sha256=sha(root/'licenses'/(e+'-inventory.json')), count=len(read(root/'licenses'/(e+'-inventory.json')))) for e in ['docling', 'mlx', 'jev', 'rust-lock']}
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args(); report = evaluate(args.root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    for engine, values in report['engines'].items():
        print(engine, values['exactFields'], '/79; lost', values['lostFields'], '; gate', values['qualityGate'])
    print('Jev selection', report['jev']['selected']['exactFields'], '/79; lost', report['jev']['selected']['lostFields'])
