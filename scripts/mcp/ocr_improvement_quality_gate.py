#!/usr/bin/env python3
"""Compare native results and fresh retries against immutable v14 evidence.

Historical readings prove preservation, never current field accuracy. Expected
text is used only here, after OCR; it is not supplied to the engine.
"""
import argparse
import hashlib
import json
from pathlib import Path


def evaluate(root, manifest, baseline):
    truth = manifest['truth']
    if (len(truth) != 35 or sum(map(len, truth.values())) != 79
            or manifest['sha256'] != baseline['inputHashes']
            or set(truth) != set(baseline['pages']) or set(truth) != set(manifest['sha256'])):
        raise ValueError('Frozen corpus/baseline mismatch')
    cases = []
    for name, fields in sorted(truth.items()):
        if Path(name).name != name or not name.endswith('.png'):
            raise ValueError('Invalid fixture name')
        if hashlib.sha256((root / name).read_bytes()).hexdigest() != manifest['sha256'][name]:
            raise ValueError('Frozen image changed: ' + name)
        before = baseline['pages'][name]
        after = json.loads((root / (name + '.json')).read_text())
        fresh = json.loads((root / (name + '.fresh.json')).read_text())
        old = {field for field in fields if field in before['text']}
        scores = []
        for page in [after, fresh]:
            correct = {field for field in fields if field in page['text']}
            current = page['text'].splitlines()
            history = [text for line in (page.get('geometry') or {}).get('lines', [])
                       for text in line.get('priorReadings', [])]
            remaining = list(current + history)
            preserved = True
            for line in before['text'].splitlines():
                if line in remaining:
                    remaining.remove(line)
                else:
                    preserved = False
            # A changed/new line must itself be a literal expected field. A
            # score gain cannot excuse unrelated or fabricated extra content.
            unexpected = [line for line in current if line.strip()
                          and line not in before['text'].splitlines() and line not in fields]
            scores.append(dict(exact=len(correct), lost=len(old-correct),
                               evidencePreserved=preserved, unexpectedLines=unexpected,
                               unmarkedError=len(correct) < len(fields) and not page['info']['needsReview']))
        cases.append(dict(file=name, expected=len(fields), before=len(old), native=scores[0], fresh=scores[1]))
    before = sum(case['before'] for case in cases)
    after = sum(case['native']['exact'] for case in cases)
    fresh = sum(case['fresh']['exact'] for case in cases)
    safe = all(result['lost'] == 0 and result['evidencePreserved'] and not result['unexpectedLines']
               and not result['unmarkedError'] for case in cases for result in [case['native'], case['fresh']])
    passed = before == 52 and after > before and fresh == after and safe
    return dict(qualityGate='GO' if passed else 'NO-GO', corpusImages=35, expectedFields=79,
                before=before, after=after, fresh=fresh, gainedFields=after-before,
                lostFields=sum(c['native']['lost'] for c in cases),
                unmarkedErrors=sum(c['native']['unmarkedError'] for c in cases),
                allEvidencePreserved=all(c['fresh']['evidencePreserved'] for c in cases), cases=cases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixtures', type=Path)
    defaults = Path(__file__).resolve().parents[2] / 'Tests/VauldyMCPRuntimeTests/Fixtures'
    parser.add_argument('--manifest', type=Path, default=defaults / 'faint-line-corpus.json')
    parser.add_argument('--baseline', type=Path, default=defaults / 'ocr-v14-frozen-baseline.json')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    report = evaluate(args.fixtures, json.loads(args.manifest.read_text()), json.loads(args.baseline.read_text()))
    if args.report:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'cases'}))
    return 0 if report['qualityGate'] == 'GO' else 1


if __name__ == '__main__':
    raise SystemExit(main())
