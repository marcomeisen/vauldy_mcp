#!/usr/bin/env python3
"""Verify an actual pre-SQLite local CLI refuses a new format-3 vault without modifying it."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile
from import_smoke_test import command
from storage_migration_smoke_test import snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('local_binary', type=lambda p: Path(p).resolve())
    parser.add_argument('legacy_zip', type=lambda p: Path(p).resolve())
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='vauldy-r3c-legacy-') as temp:
        root = Path(temp); old = root/'legacy-local'; source = root/'synthetic.pdf'; vault = root/'vault'
        with zipfile.ZipFile(args.legacy_zip) as package:
            names = [n for n in package.namelist() if n.endswith('/Contents/Resources/vauldy-local')]
            assert len(names) == 1
            old.write_bytes(package.read(names[0])); old.chmod(0o700)
        version = subprocess.check_output([str(old), '--version'], text=True).strip()
        command(args.local_binary, 'create-sqlite', '--store', vault)
        command(args.local_binary, 'example', '--output', source)
        before = snapshot(vault); original = source.read_bytes()
        result = subprocess.run([str(old), 'import', '--store', str(vault), str(source)],
                                capture_output=True, text=True, timeout=30)
        assert result.returncode != 0 and snapshot(vault) == before and source.read_bytes() == original
        assert not (vault/'documents.json').exists() and not (vault/'worker').exists()
        report = dict(legacyVersion=version, legacyZipSHA256=hashlib.sha256(args.legacy_zip.read_bytes()).hexdigest(),
                      legacyBinarySHA256=hashlib.sha256(old.read_bytes()).hexdigest(),
                      currentLocalSHA256=hashlib.sha256(args.local_binary.read_bytes()).hexdigest(),
                      importExitCode=result.returncode, sqliteStoreByteUnchanged=True, originalUnchanged=True,
                      noJSONFallback=True, noWorkerStarted=True)
        args.output.write_text(json.dumps(report,indent=2)+'\n'); print(json.dumps(report))


if __name__ == '__main__': main()
