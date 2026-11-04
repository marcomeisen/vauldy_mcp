#!/usr/bin/env python3
"""Build a self-contained macOS setup app. No install, vault access or client mutation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MINIMUM_MACOS = "14.0"
PRODUCTS = {
    'vauldy-mcp-setup': 'MacOS/vauldy-mcp-setup',
    'vauldy-mcp': 'Resources/vauldy-mcp',
    'vauldy-local': 'Resources/vauldy-local',
    'vauldy-mcp-http': 'Resources/vauldy-mcp-http',
    'vauldy-relay': 'Resources/vauldy-relay',
    'vauldy-mcp-status': 'Resources/Vauldy MCP Status.app/Contents/MacOS/vauldy-mcp-status',
}


def capture(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs).strip()


def release_values():
    source = (ROOT / 'Sources/VauldyMCPRuntime/MCPBuild.swift').read_text()
    match = re.search(r'^    public static let version = "([0-9]+\.[0-9]+\.[0-9]+)"$', source, re.M)
    epoch = re.search(r'^    public static let softwareCompatibilityEpoch = ([1-9][0-9]*)$', source, re.M)
    if not match or not epoch:
        raise SystemExit('MCPBuild.swift must declare a numeric product version and compatibility epoch.')
    return match[1], int(epoch[1])


def verify_product_versions(binary_dir, version, env):
    for product in PRODUCTS:
        try:
            reported = capture([str(binary_dir / product), '--version'], env=env, timeout=10)
        except (OSError, subprocess.SubprocessError) as error:
            raise SystemExit(f'Cannot verify {product}: {error}') from error
        if reported != f'{product} {version}':
            raise SystemExit(f'{product} version mismatch: expected {version}, got {reported!r}')


def verify_platform(binary_dir):
    architectures = set()
    for product in PRODUCTS:
        executable = str(binary_dir / product)
        slices = tuple(sorted(capture(['lipo', '-archs', executable]).split()))
        if not slices:
            raise SystemExit(f'Cannot determine architectures for {product}.')
        architectures.add(slices)
        for architecture in slices:
            build = capture(['xcrun', 'vtool', '-arch', architecture, '-show-build', executable])
            platform = re.findall(r'^\s*platform[ \t]+(\w+)$', build, re.M)
            minimum = re.findall(r'^\s*minos[ \t]+([0-9.]+)$', build, re.M)
            if platform != ['MACOS'] or minimum != [MINIMUM_MACOS]:
                raise SystemExit(f'{product} ({architecture}) must target macOS {MINIMUM_MACOS}.')
    if len(architectures) != 1:
        raise SystemExit('Package components target different architectures.')
    return list(architectures.pop())


def source_commit():
    if capture(['git', 'status', '--porcelain'], cwd=ROOT):
        return None
    return capture(['git', 'rev-parse', 'HEAD'], cwd=ROOT)

def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / 'dist' / 'mcp')
    parser.add_argument('--identity', default='-', help='Developer ID Application identity; default ad-hoc for local testing')
    parser.add_argument('--notary-profile', help='Existing notarytool keychain profile, used only when explicitly supplied')
    parser.add_argument('--skip-build', action='store_true', help='Package an already-built release (developer use)')
    args = parser.parse_args()
    version, compatibility_epoch = release_values()
    signed = args.identity != '-'
    if args.notary_profile and not signed:
        parser.error('Notarization requires a Developer ID Application identity.')
    if signed and (not args.identity.startswith('Developer ID Application: ') or args.skip_build):
        parser.error('Distribution signing requires a Developer ID Application identity and a fresh build.')
    commit = source_commit() if not args.skip_build else None
    if signed and not commit:
        parser.error('Distribution signing requires a clean Git checkout.')
    output = args.output.resolve()
    with tempfile.TemporaryDirectory(prefix='vauldy-mcp-package-') as temp:
        temp = Path(temp)
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(temp / 'module-cache'),
                   SWIFTPM_MODULECACHE_OVERRIDE=str(temp / 'module-cache'))
        command = ['swift', 'build', '--package-path', str(ROOT), '-c', 'release', '--disable-sandbox',
                   '--cache-path', str(temp / 'cache'), '--disable-automatic-resolution']
        # Distribution builds use a new scratch path to avoid packaging old same-version objects.
        scratch = temp / 'build' if signed else ROOT / '.build'
        command += ['--scratch-path', str(scratch)]
        if not args.skip_build:
            for product in PRODUCTS:
                run(command + ['--product', product], env=env)
        binary_dir = Path(capture(command + ['--show-bin-path'], env=env))
        verify_product_versions(binary_dir, version, env)
        architectures = verify_platform(binary_dir)
        if signed and source_commit() != commit:
            raise SystemExit('Source checkout changed during the distribution build.')
        app = temp / 'Vauldy MCP Einrichtung.app'
        contents = app / 'Contents'
        resources = contents / 'Resources'
        for product, relative_path in PRODUCTS.items():
            destination = contents / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(binary_dir / product, destination)
        status_app = resources / 'Vauldy MCP Status.app'
        status_info = dict(CFBundleIdentifier='com.marcomeisen.vauldy.mcp-status',
                           CFBundleName='Vauldy MCP Status', CFBundleDisplayName='Vauldy MCP Status',
                           CFBundleExecutable='vauldy-mcp-status', CFBundlePackageType='APPL',
                           CFBundleShortVersionString=version, CFBundleVersion='1',
                           LSMinimumSystemVersion=MINIMUM_MACOS, LSUIElement=True, NSHighResolutionCapable=True)
        with (status_app / 'Contents' / 'Info.plist').open('wb') as f: plistlib.dump(status_info, f)
        # Preserve dependency notices in every distributable.
        notices = resources / 'ThirdPartyNotices'; notices.mkdir()
        for checkout in sorted((scratch / 'checkouts').iterdir()):
            for license_file in checkout.glob('LICENSE*'):
                if license_file.is_file():
                    shutil.copy2(license_file, notices / (checkout.name + '-' + license_file.name))
        shutil.copy2(ROOT / 'docs' / 'mcp-installation.md', resources / 'Anleitung.md')
        for guide in ['base-analysis.md', 'mcp-mvp.md', 'provenance.md', 'mcp-oauth.md', 'mcp-chatgpt-sso.md']:
            shutil.copy2(ROOT / 'docs' / guide, resources / guide)
        release_info = dict(manifestVersion=1, productVersion=version, sourceCommit=commit,
                            softwareCompatibilityEpoch=compatibility_epoch,
                            packageLockSHA256=hashlib.sha256((ROOT / 'Package.resolved').read_bytes()).hexdigest(),
                            swift=capture(['swift', '--version']), xcode=capture(['xcodebuild', '-version']),
                            architectures=architectures, minimumMacOS=MINIMUM_MACOS,
                            buildMode='reused' if args.skip_build else 'release', products=PRODUCTS)
        (resources / 'release.json').write_text(json.dumps(release_info, indent=2, sort_keys=True) + '\n')
        info = dict(CFBundleIdentifier='com.marcomeisen.vauldy.mcp-setup',
                    CFBundleName='Vauldy MCP Einrichtung', CFBundleDisplayName='Vauldy MCP Einrichtung',
                    CFBundleExecutable='vauldy-mcp-setup', CFBundlePackageType='APPL',
                    CFBundleShortVersionString=version, CFBundleVersion='1', LSMinimumSystemVersion=MINIMUM_MACOS,
                    NSHighResolutionCapable=True,
                    CFBundleURLTypes=[dict(CFBundleURLName='Vauldy OAuth connection', CFBundleURLSchemes=['vauldy-mcp'])])
        with (app / 'Contents' / 'Info.plist').open('wb') as f: plistlib.dump(info, f)
        sign = ['codesign', '--force', '--sign', args.identity]
        if args.identity != '-': sign += ['--options', 'runtime', '--timestamp']
        run(sign + [str(resources / 'vauldy-mcp')])
        run(sign + [str(resources / 'vauldy-local')])
        run(sign + [str(resources / 'vauldy-mcp-http')])
        run(sign + [str(resources / 'vauldy-relay')])
        run(sign + [str(status_app)])
        run(sign + [str(app)])
        run(['codesign', '--verify', '--deep', '--strict', str(app)])
        archive = temp / 'Vauldy-MCP-macOS.zip'
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)])
        if args.notary_profile:
            run(['xcrun', 'notarytool', 'submit', str(archive), '--keychain-profile', args.notary_profile, '--wait'])
            run(['xcrun', 'stapler', 'staple', str(app)])
            run(['xcrun', 'stapler', 'validate', str(app)])
            run(['spctl', '--assess', '--type', 'execute', str(app)])
            archive.unlink()
            run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)])
        local_app = output / app.name
        if local_app.is_symlink():
            raise SystemExit('Refusing to replace a symlink at the app output.')
        if local_app.exists():
            with (local_app / 'Contents' / 'Info.plist').open('rb') as f:
                if plistlib.load(f).get('CFBundleIdentifier') != info['CFBundleIdentifier']:
                    raise SystemExit('Refusing to replace an unrelated app.')
            shutil.rmtree(local_app)
        output.mkdir(parents=True, exist_ok=True)
        shutil.copytree(app, local_app)
        run(['codesign', '--verify', '--deep', '--strict', str(local_app)])
        final_archive = output / archive.name
        shutil.copy2(archive, final_archive)
        (output / 'SHA256SUMS').write_text(hashlib.sha256(final_archive.read_bytes()).hexdigest() + '  ' + final_archive.name + '\n')
        print(local_app)
        print(final_archive)
        print('Signing: ' + ('Developer ID, notarized' if args.notary_profile else
                            'Developer ID, not notarized' if signed else 'local ad-hoc, not notarized'))

if __name__ == '__main__': main()
