#!/usr/bin/env python3
"""Exercise the secure launcher using a fake client; no network or real credentials."""
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    launcher = Path(__file__).with_name('start_chatgpt_tunnel.command')
    subprocess.run(['/bin/bash', '-n', str(launcher)], check=True)
    with tempfile.TemporaryDirectory(prefix='vauldy-launcher-test-') as temp:
        root = Path(temp) / 'Root with spaces'
        (root / 'bin').mkdir(parents=True)
        (root / 'tunnel').mkdir()
        (root / 'tunnel/vauldy-chatgpt.yaml').write_text('config_version: 1\n')
        client = root / 'bin/tunnel-client'
        client.write_text('#!/bin/bash\nif [[ "$1" == doctor ]]; then printf "doctor-called\\n"; exit "${DOCTOR_CODE:-0}"; fi\nprintf "run-called\\n"\n')
        client.chmod(0o700)
        secret = 'synthetic-runtime-key-not-a-real-credential'
        base = dict(os.environ)
        base.pop('CONTROL_PLANE_API_KEY', None)

        def run(text, *, key=None, doctor=0):
            env = dict(base, DOCTOR_CODE=str(doctor))
            if key is not None:
                env['CONTROL_PLANE_API_KEY'] = key
            result = subprocess.run(['/bin/bash', str(launcher), str(root)], input=text, text=True, capture_output=True, env=env, timeout=5)
            assert secret not in result.stdout + result.stderr
            assert all(secret.encode() not in p.read_bytes() for p in root.rglob('*') if p.is_file())
            return result

        cancelled = run(secret + '\n\n')
        assert cancelled.returncode == 0 and 'doctor-called' in cancelled.stdout and 'run-called' not in cancelled.stdout
        confirmed = run(secret + '\nSTART\n')
        assert confirmed.returncode == 0 and 'run-called' in confirmed.stdout
        failed = run('START\n', key=secret, doctor=7)
        assert failed.returncode == 7 and 'run-called' not in failed.stdout
        empty = run('\n')
        assert empty.returncode != 0 and 'doctor-called' not in empty.stdout and 'run-called' not in empty.stdout
        print('PASS: masked input, no secret output/files, explicit start, cancellation and failed-doctor guard; no network used.')


if __name__ == '__main__':
    main()
