#!/usr/bin/env python3
"""Strict acceptance gate for the frozen, synthetic 35-image/79-field corpus.

A passing Swift regression run alone does NOT satisfy this gate. A candidate must
beat 52 complete literal fields, preserve every previously matched field/line and
all input hashes. The rejected experiment lives in the test target only.
"""
import argparse
import hashlib
import json
from pathlib import Path


def evaluate(root, manifest):
    truth, hashes = manifest['truth'], manifest['sha256']
    if len(truth) != 35 or sum(map(len, truth.values())) != 79 or set(truth) != set(hashes):
        raise ValueError('Frozen corpus must contain exactly 35 images and 79 literal fields')
    cases = []
    for name, fields in sorted(truth.items()):
        if Path(name).name != name or not name.endswith('.png'):
            raise ValueError('Invalid fixture name')
        actual_hash = hashlib.sha256((root / name).read_bytes()).hexdigest()
        if actual_hash != hashes[name]:
            raise ValueError('Frozen image changed: ' + name)
        before = json.loads((root / (name + '.before.json')).read_text())
        after = json.loads((root / (name + '.json')).read_text())
        diagnostics = json.loads((root / (name + '.diagnostics.json')).read_text())
        old = {value for value in fields if value in before['text']}
        new = {value for value in fields if value in after['text']}
        old_lines = before['text'].splitlines()
        remaining = iter(after['text'].splitlines())
        preserved = all(any(line == candidate for candidate in remaining) for line in old_lines)
        # Conservatively prevent an unrelated accepted extra line from hiding a wrong reading.
        additions = after['text'][len(before['text']):] if after['text'].startswith(before['text']) else ''
        unexpected = [line for line in additions.splitlines() if line.strip() and not any(line in field for field in fields)]
        cases.append(dict(file=name, sha256=actual_hash, expected=len(fields), before=len(old), after=len(new),
                          lost=len(old-new), added=len(new-old), evidencePreserved=preserved,
                          unexpectedAdditions=len(unexpected), diagnostics=diagnostics))
    before_total = sum(case['before'] for case in cases)
    after_total = sum(case['after'] for case in cases)
    loss = sum(case['lost'] for case in cases)
    unexpected = sum(case['unexpectedAdditions'] for case in cases)
    go = before_total == 52 and after_total > 52 and not loss and not unexpected and all(c['evidencePreserved'] for c in cases)
    return dict(corpusImages=35, expectedFields=79, before=before_total, after=after_total,
                gainedFields=after_total-before_total, lostFields=loss, unexpectedAdditions=unexpected,
                evidencePreserved=all(c['evidencePreserved'] for c in cases),
                requiredAfterMinimum=53, qualityGate='GO' if go else 'NO-GO', candidateEnabled=False, cases=cases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixtures', type=Path)
    parser.add_argument('--manifest', type=Path, default=Path(__file__).resolve().parents[2] / 'Tests/VauldyMCPRuntimeTests/Fixtures/faint-line-corpus.json')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    report = evaluate(args.fixtures.resolve(), json.loads(args.manifest.read_text()))
    if args.report:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'cases'}, ensure_ascii=False))
    return 0 if report['qualityGate'] == 'GO' else 1


if __name__ == '__main__':
    raise SystemExit(main())
