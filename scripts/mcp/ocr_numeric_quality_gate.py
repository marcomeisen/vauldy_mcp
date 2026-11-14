#!/usr/bin/env python3
"""Compare the unchanged German V2 corpus with v16, including old evidence.

Global table text coverage is not positional cell accuracy. The seven reported
errors have additional explicit, page-bound assertions below.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
from german_document_comparison import normalize as normalized, contains


def evaluate(corpus, results, baseline):
    manifest_bytes = (corpus / 'manifest.json').read_bytes()
    assert hashlib.sha256(manifest_bytes).hexdigest() == 'e8d6d5a7bb874081381eacdd541b686acb0643d1249bd36cc4785fb5ace947c0'
    manifest = json.loads(manifest_bytes)
    for item in manifest['documents'] + manifest['pages']:
        file = corpus / item.get('pdf', item.get('image'))
        assert hashlib.sha256(file.read_bytes()).hexdigest() == item['sha256'], str(file)
    cases = []; totals = Counter(); changed = []
    for truth in manifest['pages']:
        name = truth['documentID'] + '.json'; index = truth['physicalPage'] - 1
        candidate = json.loads((results / name).read_text())
        assert [p['text'] for p in candidate['pages']] == [p['text'] for p in candidate['freshPages']]
        assert candidate['inputSHA256'] == baseline[name]['inputSHA256']
        before = baseline[name]['pages'][index]; after = candidate['pages'][index]
        assert after['info']['page'] == truth['physicalPage'] and not after['info']['metrics']['cacheHit']
        old, new = normalized(before['text']), normalized(after['text'])
        fields = truth['fields']; cells = [c for t in truth['tables'] for c in t['cells'] if c['text'].strip()]
        old_fields = {f['id'] for f in fields if contains(old, f['text'])}
        new_fields = {f['id'] for f in fields if contains(new, f['text'])}
        lost_fields = sorted(old_fields - new_fields)
        expected_cells = Counter(normalized(c['text']) for c in cells)
        def matched_cells(text):
            return Counter({cell: min(count, len(re.findall(r'(?<!\w)' + re.escape(cell) + r'(?!\w)', text)))
                            for cell, count in expected_cells.items()})
        old_cells, new_cells = matched_cells(old), matched_cells(new)
        lost_cells = dict(old_cells - new_cells)
        # Count occurrences, not just a set: repeated correct words must survive.
        words = Counter(normalized(truth['text']).split())
        old_words = Counter(old.split()) & words; new_words = Counter(new.split()) & words
        lost_words = dict(old_words - new_words)
        current = Counter(after['text'].splitlines())
        history = Counter(s for line in after.get('geometry', {}).get('lines', []) for s in line.get('priorReadings', []))
        lost_evidence = dict(Counter(before['text'].splitlines()) - current - history)
        assert not lost_fields and not lost_cells and not lost_words and not lost_evidence, truth['id']
        assert not truth['blank'] or not after['text'].strip()
        metrics = after['info']['metrics']
        assert metrics.get('fieldRetries', 0) <= 8 and metrics.get('fieldRetryPixels', 0) <= 8_000_000
        if before['text'] != after['text']: changed.append(truth['id'])
        counts = dict(beforeFields=len(old_fields), afterFields=len(new_fields), expectedFields=len(fields),
                      beforeTableText=sum(old_cells.values()), afterTableText=sum(new_cells.values()), expectedTableText=len(cells))
        totals.update(counts)
        cases.append(dict(page=truth['id'], **counts, lostFields=lost_fields, lostCells=lost_cells,
                          lostCorrectWordOccurrences=lost_words, lostLiteralEvidence=lost_evidence))
    def page(doc, index):
        return json.loads((results / (doc + '.json')).read_text())['pages'][index]['text']
    assert 'Fahrgestellnummer: TESTWVWZZZ26K08417' in page('doc-001', 1)
    keys = page('doc-004', 2)
    for row in ['Wohnung 3 beide Schließzylinder', 'Keller 1 gekennzeichnet', 'Briefkasten 0 Nachlieferung vereinbart']:
        assert row in keys, row
    units = page('doc-009', 1).splitlines()
    assert all(unit in units for unit in ['g/dl', '10³/µl', 'mg/l']) and units.count('mg/dl') == 2
    assert len(cases) == 31 and totals['beforeFields'] == 133 and totals['beforeTableText'] == 316 and totals['afterTableText'] == 345 and totals['afterFields'] == 133
    return dict(passed=True, corpusDocuments=15, corpusPages=31, manifestSHA256=hashlib.sha256(manifest_bytes).hexdigest(),
                **dict(totals), confirmedPriorExamples=7, repairedTableOccurrences=29, lostPriorCorrectFields=0,
                lostPriorCorrectTableText=0, lostCorrectWordOccurrences=0, lostLiteralEvidence=0,
                blankControlsWithoutInventedText=3, changedPages=changed, cases=cases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('corpus', type=Path); parser.add_argument('results', type=Path)
    parser.add_argument('--baseline', type=Path, default=Path(__file__).resolve().parents[2] /
                        'docs/quality/ocr-fields-2026-11-13/v2-results.json')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    report = evaluate(args.corpus, args.results, json.loads(args.baseline.read_text()))
    if args.report: args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'cases'}, ensure_ascii=False))


if __name__ == '__main__': main()
