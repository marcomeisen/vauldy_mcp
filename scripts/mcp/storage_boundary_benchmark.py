#!/usr/bin/env python3
"""R3 local stdio benchmark: synthetic JSON limits, selected cache, restart, revocation.

Uses /usr/bin/time -l for the server's peak RSS (not sampled RSS or Python memory).
No installed profile, customer archive or remote connector is used.
"""
import argparse
import contextlib
import hashlib
import json
import math
from pathlib import Path
import re
import shlex
import statistics
import tempfile
import time
import uuid

from smoke_test import Client, payload
from architecture_review_probe import grant
from topic_overview_smoke_test import document, write_json

MIB = 1024 * 1024
SAMPLES = 25


def stats(values):
    return dict(samples=len(values), medianMS=round(statistics.median(values), 3),
                p95MS=round(sorted(values)[math.ceil(len(values) * .95) - 1], 3))


def snapshot(file, count, target=None):
    # Prose rather than one huge search token; each long record is 130–260 KiB.
    text = 'Versicherung. Der synthetische Vertrag beschreibt Leistungen, Laufzeit und die monatliche Zahlung. '
    records = [document(text) for _ in range(count)]
    if target:
        size = len(json.dumps(records, ensure_ascii=False).encode())
        extra, remainder = divmod(target - size, count)
        for index, record in enumerate(records):
            length = extra + (remainder if index == count - 1 else 0)
            record['ocrText'] += (text * (length // len(text) + 1))[:length]
    write_json(file, records)
    if target:
        assert file.stat().st_size == target
    return [record['id'] for record in records]


@contextlib.contextmanager
def measured_client(binary, profile, root, label, server_options=()):
    wrapper, log = root / (label + '.sh'), root / (label + '.rss')
    wrapper.write_text('#!/bin/sh\nexec /usr/bin/time -l ' + shlex.quote(str(binary)) + ' "$@"\n')
    wrapper.chmod(0o700)
    metrics = {}
    with log.open('wb') as stderr:
        client = Client(wrapper, profile, stderr=stderr, server_options=server_options)
        try:
            yield client, metrics
        finally:
            client.close()
    match = re.search(r'(\d+)\s+maximum resident set size', log.read_text())
    assert match, 'Native maximum RSS was not recorded'
    metrics['peakRSSBytes'] = int(match.group(1))


def timed(client, name, **args):
    start = time.perf_counter()
    response = client.call(name, **args)
    return response, (time.perf_counter() - start) * 1000


def run(binary, profile, root, label, accepted, improved):
    row = {}
    with measured_client(binary, profile, root, label) as (client, memory):
        response, row['coldStatusMS'] = timed(client, 'get_vault_status')
        row['isError'] = response.get('isError', False)
        if not accepted:
            assert row['isError']
            row['errorText'] = response['content'][0]['text']
            if improved:
                assert 'Grenzen' in row['errorText']
        else:
            assert payload(response)['grantedDocumentCount'] == 1
            durations = []
            for _ in range(SAMPLES):
                response, elapsed = timed(client, 'get_vault_status')
                assert payload(response)['grantedDocumentCount'] == 1
                durations.append(elapsed)
            row['warmStatus'] = stats(durations)
            durations = []
            for _ in range(SAMPLES):
                response, elapsed = timed(client, 'list_documents', query='Versicherung', includeExcerpts=False)
                data = payload(response)
                assert data['totalCount'] == 1 and data['retrievalComplete']
                durations.append(elapsed)
            row['listWithQuery'] = stats(durations)
    row.update(memory)
    if accepted and improved:
        with measured_client(binary, profile, root, label + '-restart') as (client, memory):
            response, row['restartStatusMS'] = timed(client, 'get_vault_status')
            assert payload(response)['grantedDocumentCount'] == 1
            handle = payload(client.call('list_documents', includeExcerpts=False))['items'][0]['document']
            original = json.loads(profile.read_text())
            revoked = dict(original, revision=str(uuid.uuid4()), enabled=False)
            write_json(profile, revoked)
            assert client.call('read_document', document=handle)['isError']
            assert client.call('list_documents', includeExcerpts=False)['isError']
            write_json(profile, original)
            row['revocationBlockedReadAndList'] = True
        row['restartPeakRSSBytes'] = memory['peakRSSBytes']
    row['coldStatusMS'] = round(row['coldStatusMS'], 3)
    return row


def full_selection(args):
    results = []
    for target, options in [(70*MIB, []), (98*MIB, ['--experimental-sqlite-index'])]:
        with tempfile.TemporaryDirectory(prefix='vauldy-r3-full-selection-') as temporary:
            root = Path(temporary); file, profile = root/'documents.json', root/'profile.json'
            ids = snapshot(file, 500, target); write_json(profile, grant(file, ids))
            row = dict(snapshotBytes=target, documents=500, granted=500, serverOptions=options)
            for label, binary in [('before', args.before), ('after', args.binary)]:
                if not binary: continue
                with measured_client(binary, profile, root, label, options) as (client, memory):
                    response, cold = timed(client, 'get_vault_status')
                    assert payload(response)['grantedDocumentCount'] == 500
                    durations = []
                    for _ in range(SAMPLES):
                        response, elapsed = timed(client, 'get_vault_status')
                        assert payload(response)['grantedDocumentCount'] == 500
                        durations.append(elapsed)
                    original = json.loads(profile.read_text())
                    write_json(profile, dict(original, enabled=False, revision=str(uuid.uuid4())))
                    assert client.call('list_documents', includeExcerpts=False)['isError']
                    write_json(profile, original)
                row[label] = dict(coldStatusMS=cold, warmStatus=stats(durations), **memory)
            results.append(row); print(json.dumps(row), flush=True)
    args.output.write_text(json.dumps(dict(scope='Full selection above the 64/96 MiB cache budgets; status only; 25 warm samples; no speedup promise.', cases=results), indent=2)+'\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=lambda x: Path(x).resolve())
    parser.add_argument('--before', type=lambda x: Path(x).resolve())
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--full-selection-only', action='store_true')
    args = parser.parse_args()
    if args.full_selection_only:
        return full_selection(args)
    results = []
    for count, target in [(20000, None), (20001, None)] + [(500, n * MIB + d) for n in [64, 96, 128] for d in [-1024, 1024]]:
        with tempfile.TemporaryDirectory(prefix='vauldy-r3-boundary-') as temporary:
            root = Path(temporary); file, profile = root/'documents.json', root/'profile.json'
            ids = snapshot(file, count, target)
            write_json(profile, grant(file, ids[:1]))
            before_hash = hashlib.sha256(file.read_bytes()).hexdigest()
            row = dict(documents=count, granted=1, snapshotBytes=file.stat().st_size,
                       averageRecordBytes=round(file.stat().st_size/count))
            if args.before:
                row['before'] = run(args.before, profile, root, 'before', count <= 20000 and file.stat().st_size <= 128*MIB, False)
            row['after'] = run(args.binary, profile, root, 'after', file.stat().st_size <= 128*MIB, True)
            assert hashlib.sha256(file.read_bytes()).hexdigest() == before_hash
            row['sourceUnchanged'] = True; results.append(row)
            print(json.dumps(row), flush=True)
    result = dict(scope='Local stdio; one grant; 25 warm samples; native per-process peak RSS; no ChatGPT latency or 20k-real-archive acceptance.',
                  binarySHA256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  beforeSHA256=hashlib.sha256(args.before.read_bytes()).hexdigest() if args.before else None,
                  cases=results)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')


if __name__ == '__main__':
    main()
