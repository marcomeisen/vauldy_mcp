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
        run('swift-tests', ['swift', 'test', '--disable-sandbox', '--disable-automatic-resolution'])
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
            ('base_analysis_wire_test', [local, server, originals, '--include-raster']),
            ('import_smoke_test', [local, server]),
            ('audit_smoke_test', [local]),
            ('client_install_smoke_test', [local]),
            ('management_smoke_test', [resources]),
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
