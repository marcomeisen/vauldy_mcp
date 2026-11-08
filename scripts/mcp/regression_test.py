#!/usr/bin/env python3
"""Complete standalone regression. Uses only synthetic originals and isolated stores.

No installation into /Applications or mutation of existing client configurations.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--skip-build', action='store_true', help='Reuse already-built release programs')
    parser.add_argument('--update-reports', action='store_true', help='Copy measured corpus/wire/P0 reports into docs/quality')
    args = parser.parse_args()
    output = ROOT / 'dist/mcp/regression' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    output.mkdir(parents=True, exist_ok=False)
    originals = output / 'originals'
    env = dict(os.environ, VAULDY_BASE_ANALYSIS_DIAGNOSTICS=str(originals),
               VAULDY_OCR_AB_FIXTURES=str(output / 'ocr-raster'),
               VAULDY_OCR_VECTOR_FIXTURES=str(output / 'ocr-vector'),
               VAULDY_OCR_COVERAGE_FIXTURES=str(output / 'ocr-coverage'),
               VAULDY_OCR_REGION_FIXTURES=str(output / 'ocr-regions'),
               VAULDY_OCR_SMALL_FIXTURES=str(output / 'ocr-small'),
               VAULDY_OCR_DENSE_FIXTURES=str(output / 'ocr-dense'),
               VAULDY_OCR_LINE_FIXTURES=str(output / 'ocr-lines'),
               VAULDY_OCR_FAINT_FIXTURES=str(output / 'ocr-faint'),
               VAULDY_PRODUCT_FIXTURES=str(output / 'product-native'),
               VAULDY_DOCUMENT_INVENTORY_FIXTURES=str(output / 'document-inventory'),
               VAULDY_BASE_ANALYSIS_REPORT=str(output / 'transcript-baseline.json'),
               VAULDY_BASE_ANALYSIS_NATIVE_REPORT=str(output / 'native-raster-baseline.json'))
    stages = []

    def run(name, command):
        print(name, flush=True)
        with (output / (name + '.log')).open('w') as log:
            result = subprocess.run(list(map(str, command)), cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        stages.append(dict(name=name, passed=result.returncode == 0))
        (output / 'summary.json').write_text(json.dumps(dict(allPassed=all(s['passed'] for s in stages), stages=stages), indent=2) + '\n')
        if result.returncode:
            raise SystemExit(f'{name} failed. See {output / (name + ".log")}')

    try:
        run('faint-ocr-gate-policy', [sys.executable, ROOT / 'scripts/mcp/faint_ocr_quality_gate_test.py'])
        run('local-ocr-comparison-conversion', [sys.executable, ROOT / 'scripts/mcp/local_ocr_comparison_test.py'])
        run('swift-tests', ['swift', 'test', '--disable-sandbox', '--disable-automatic-resolution', '--no-parallel'])
        run('package-metadata', [sys.executable, ROOT / 'scripts/mcp/package_metadata_smoke_test.py'])
        command = [sys.executable, ROOT / 'scripts/mcp/package.py']
        if args.skip_build:
            command.append('--skip-build')
        run('package', command)
        run('relay-worker-tests', ['node', '--test', ROOT / 'cloud/chatgpt-relay/tests/relay.mjs'])
        app = ROOT / 'dist/mcp/Vauldy MCP Einrichtung.app'
        resources = app / 'Contents/Resources'
        local, server = resources / 'vauldy-local', resources / 'vauldy-mcp'
        scripts = ROOT / 'scripts/mcp'
        run('relay-tool-parity', [sys.executable, scripts / 'export_relay_tools.py', server, '--check'])
        for name, arguments in [
            ('smoke_test', [server]),
            ('index_recovery_smoke_test', [server]),
            ('research_agent_smoke_test', [server]),
            ('topic_overview_smoke_test', [server]),
            ('search_normalization_smoke_test', [server]),
            ('storage_boundary_benchmark', [server, '--output', output / 'storage-boundaries.json']),
            ('storage_import_smoke_test', [local, server, '--output', output / 'storage-import.json']),
            ('sqlite_integration_smoke_test', [local, server, '--output', output / 'sqlite-integration.json']),
            ('storage_migration_smoke_test', [local, server, '--output', output / 'storage-migration.json']),
            ('field_extraction_smoke_test', [server]),
            ('contract_comparison_smoke_test', [server]),
            ('deadline_overview_smoke_test', [server]),
            ('document_inventory_smoke_test', [server, output / 'document-inventory', '--report', output / 'document-inventory.json']),
            ('product_acceptance', [server, output / 'product-native', '--output', output / 'product-acceptance']),
            ('product_answer_check', [output / 'product-acceptance/evidence-packets.json', output / 'product-acceptance/answers.json']),
            ('product_acceptance_test', ['--packets', output / 'product-acceptance/evidence-packets.json', '--report', output / 'product-answer-gates.json']),
            ('base_analysis_wire_test', [local, server, originals, '--include-raster']),
            ('import_smoke_test', [local, server]),
            ('raster_ocr_quality_smoke_test', [local, server, output / 'ocr-raster']),
            ('vector_ocr_quality_smoke_test', [local, server, output / 'ocr-vector']),
            ('visual_coverage_smoke_test', [local, server, output / 'ocr-regions']),
            ('dense_ocr_smoke_test', [local, server, output / 'ocr-dense']),
            ('line_ocr_smoke_test', [local, server, output / 'ocr-lines']),
            ('small_text_chat_smoke_test', [server, output / 'ocr-small', '--report', output / 'ocr-small-wire.json']),
            ('audit_smoke_test', [local]),
            ('client_install_smoke_test', [local]),
            ('management_smoke_test', [resources]),
            ('software_update_smoke_test', [app]),
            ('status_smoke_test', [local, server, resources / 'Vauldy MCP Status.app']),
            ('watch_smoke_test', [local, server]),
            ('setup_startup_smoke_test', [app]),
            ('original_reference_smoke_test', [local, server]),
            ('oauth_smoke_test', [local, resources / 'vauldy-mcp-http']),
            ('scalability_benchmark', [server, output / 'scalability.json']),
            ('tunnel_launcher_smoke_test', []),
            ('benchmark_ocr', [local]),
            ('retrieval_benchmark', [server, '--local', local, '--p0', '--gate', '--output', output / 'p0-retrieval.json']),
        ]:
            run(name, [sys.executable, scripts / (name + '.py'), *arguments])
        for name in ['transcript-baseline', 'native-raster-baseline']:
            assert json.loads((output / (name + '.json')).read_text())['allPassed'], name
        wire = json.loads((output / 'base_analysis_wire_test.log').read_text())
        (output / 'base-analysis-wire.json').write_text(json.dumps(wire, ensure_ascii=False, indent=2) + '\n')
        if args.update_reports:
            for name in ['transcript-baseline', 'native-raster-baseline', 'base-analysis-wire', 'p0-retrieval']:
                shutil.copy2(output / (name + '.json'), ROOT / 'docs/quality' / (name + '.json'))
        print(f'PASS: {len(stages)} regression stages. Reports: {output}', flush=True)
    finally:
        # Only these generated synthetic originals belong to this runner.
        if originals.exists():
            shutil.rmtree(originals)


if __name__ == '__main__':
    main()
