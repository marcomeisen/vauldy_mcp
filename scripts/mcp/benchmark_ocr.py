#!/usr/bin/env python3
"""Sequential cold/warm/cache comparison. Prints timings and quality checks, never document contents."""
import argparse
import json
from pathlib import Path
import tempfile
import time
from import_smoke_test import command, stop_worker


def timed(binary, *args):
    start = time.monotonic()
    result = command(binary, *args)
    return result, round(time.monotonic() - start, 3)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path)
    args = parser.parse_args(); binary = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix='vauldy-ocr-benchmark-') as temporary:
        root = Path(temporary); pdf = root/'mixed.pdf'; image = root/'other-original.png'; store = root/'worker-vault'
        command(binary, 'example', '--output', pdf); command(binary, 'example', '--output', image)
        try:
            baseline, baseline_time = timed(binary, 'direct-import', '--store', root/'baseline-vault', pdf)
            cold, cold_time = timed(binary, 'import', '--store', store, pdf)
            identity = command(binary, 'worker-status', '--store', store)['instance']
            warm, warm_time = timed(binary, 'import', '--store', store, image)
            cached, cache_time = timed(binary, 'retry', '--store', store, '--document', cold[0]['documentID'])
            warm_process, warm_process_time = timed(binary, 'direct-import', '--store', root/'warm-process-control', pdf)
            assert warm_process['state'] == 'completed'
            assert command(binary, 'worker-status', '--store', store)['instance'] == identity
            docs = json.loads((store/'documents.json').read_text())
            baseline_doc = json.loads((root/'baseline-vault'/'documents.json').read_text())[0]
            pdf_doc = next(d for d in docs if d['id'] == cold[0]['documentID'])
            image_doc = next(d for d in docs if d['id'] == warm[0]['documentID'])
            assert baseline['state'] == cold[0]['state'] == warm[0]['state'] == cached['state'] == 'completed'
            assert pdf_doc['ocrText'] == baseline_doc['ocrText']
            for term in ['49,99', '27.01.2026', 'Fahrradwartung']:
                assert term in pdf_doc['ocrText'] and term in image_doc['ocrText']
            assert '8246' in pdf_doc['ocrText'] and pdf_doc['pageCount'] == 2
            assert all(p['metrics']['cacheHit'] for p in pdf_doc['localImport']['pages'])
            print(json.dumps(dict(baseline_new_process_seconds=baseline_time, worker_cold_seconds=cold_time,
                worker_warm_new_original_seconds=warm_time, page_cache_retry_seconds=cache_time,
                fresh_process_after_system_warmup_seconds=warm_process_time,
                measurement_note='Sequential order warms OS caches. Cold-worker follows baseline; do not attribute the full initial delay to process startup or worker optimization.',
                baseline_metrics=baseline.get('metrics'), cold_metrics=cold[0].get('metrics'), warm_metrics=warm[0].get('metrics'),
                cached_metrics=cached.get('metrics'), warm_page_metrics=image_doc['localImport']['pages'],
                quality='PASS: exact PDF text equality, amount/date/reference and physical pages; synthetic originals only'), indent=2))
        finally:
            if (store/'store.json').exists(): stop_worker(binary, store)

if __name__ == '__main__': main()
