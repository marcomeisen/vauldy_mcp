#!/usr/bin/env python3
"""Real codesign checks for generated bundles; synthetic files only, no installed app changes."""
from pathlib import Path
import plistlib
import subprocess
import tempfile

from package import remove_signing_detritus


def run(*args):
    return subprocess.check_output(list(map(str, args)), stderr=subprocess.STDOUT)


def main():
    with tempfile.TemporaryDirectory(prefix='vauldy-package-metadata-') as directory:
        root = Path(directory)
        app = root / 'Synthetic package.app'
        executable = app / 'Contents/MacOS/synthetic-tool'
        executable.parent.mkdir(parents=True)
        resources = app / 'Contents/Resources'
        resources.mkdir()
        note = resources / 'synthetic.txt'
        note.write_text('Synthetic resource bytes must stay identical.\n')
        source = root / 'main.c'
        source.write_text('int main(void) { return 0; }\n')
        run('xcrun', 'clang', '-mmacosx-version-min=14.0', source, '-o', executable)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier='com.marcomeisen.vauldy.synthetic-package-metadata',
            CFBundleExecutable=executable.name, CFBundlePackageType='APPL',
            CFBundleName='Synthetic package', CFBundleVersion='1')))
        run('codesign', '--force', '--sign', '-', app)
        run('codesign', '--verify', '--deep', '--strict', app)
        before = {p.relative_to(app): p.read_bytes() for p in app.rglob('*') if p.is_file()}

        run('/usr/bin/xattr', '-wx', 'com.apple.FinderInfo', '54657374' * 8, app)
        run('/usr/bin/xattr', '-wx', 'com.apple.ResourceFork', '74657374', note)
        quarantine = '0081;00000000;VauldySyntheticFixture;'
        run('/usr/bin/xattr', '-w', 'com.apple.quarantine', quarantine, app)
        run('/usr/bin/xattr', '-w', 'com.vauldy.synthetic', 'preserve', note)
        failed = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)],
                                capture_output=True, text=True)
        assert failed.returncode != 0 and 'detritus' in failed.stderr, failed

        for _ in range(2):
            remove_signing_detritus(app)
            run('codesign', '--verify', '--deep', '--strict', app)
            assert run('/usr/bin/xattr', '-p', 'com.apple.quarantine', app).decode().strip() == quarantine
            assert run('/usr/bin/xattr', '-p', 'com.vauldy.synthetic', note).decode().strip() == 'preserve'
            assert {p.relative_to(app): p.read_bytes() for p in app.rglob('*') if p.is_file()} == before
            for p in [app, *app.rglob('*')]:
                attributes = set(run('/usr/bin/xattr', p).decode().splitlines())
                assert not attributes & {'com.apple.FinderInfo', 'com.apple.ResourceFork'}

        outside = root / 'outside.txt'
        outside.write_text('Must not change through a bundle symlink.\n')
        run('/usr/bin/xattr', '-wx', 'com.apple.FinderInfo', '54657374' * 8, outside)
        (resources / 'linked-file').symlink_to(outside)
        try:
            remove_signing_detritus(app)
        except SystemExit:
            pass
        else:
            raise AssertionError('Bundle symlink was accepted')
        assert 'com.apple.FinderInfo' in run('/usr/bin/xattr', outside).decode().splitlines()
        assert outside.read_text() == 'Must not change through a bundle symlink.\n'
    print('PASS: real signature rejects Finder/resource-fork metadata; exact cleanup restores validity, '
          'preserves quarantine/custom attributes and all signed bytes, is idempotent and rejects symlinks.')


if __name__ == '__main__':
    main()
