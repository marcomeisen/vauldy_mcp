#!/usr/bin/env python3
"""Build a self-contained macOS setup app. No install, vault access or client mutation."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / 'dist' / 'mcp')
    parser.add_argument('--identity', default='-', help='Developer ID Application identity; default ad-hoc for local testing')
    parser.add_argument('--notary-profile', help='Existing notarytool keychain profile, used only when explicitly supplied')
    parser.add_argument('--skip-build', action='store_true', help='Package an already-built release (developer use)')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='vauldy-mcp-package-') as temp:
        temp = Path(temp)
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(temp / 'module-cache'),
                   SWIFTPM_MODULECACHE_OVERRIDE=str(temp / 'module-cache'))
        command = ['swift', 'build', '--package-path', str(ROOT), '-c', 'release', '--disable-sandbox',
                   '--cache-path', str(temp / 'cache'), '--disable-automatic-resolution']
        if not args.skip_build:
            for product in ['vauldy-relay', 'vauldy-mcp', 'vauldy-mcp-http', 'vauldy-local', 'vauldy-mcp-setup', 'vauldy-mcp-status']:
                run(command + ['--product', product], env=env)
        binary_dir = Path(subprocess.check_output(command + ['--show-bin-path'], env=env, text=True).strip())
        app = temp / 'Vauldy MCP Einrichtung.app'
        macos = app / 'Contents' / 'MacOS'
        resources = app / 'Contents' / 'Resources'
        macos.mkdir(parents=True); resources.mkdir()
        shutil.copy2(binary_dir / 'vauldy-mcp-setup', macos / 'vauldy-mcp-setup')
        shutil.copy2(binary_dir / 'vauldy-mcp', resources / 'vauldy-mcp')
        shutil.copy2(binary_dir / 'vauldy-local', resources / 'vauldy-local')
        shutil.copy2(binary_dir / 'vauldy-mcp-http', resources / 'vauldy-mcp-http')
        shutil.copy2(binary_dir / 'vauldy-relay', resources / 'vauldy-relay')
        status_app = resources / 'Vauldy MCP Status.app'
        status_macos = status_app / 'Contents' / 'MacOS'
        status_macos.mkdir(parents=True)
        shutil.copy2(binary_dir / 'vauldy-mcp-status', status_macos / 'vauldy-mcp-status')
        status_info = dict(CFBundleIdentifier='com.marcomeisen.vauldy.mcp-status',
                           CFBundleName='Vauldy MCP Status', CFBundleDisplayName='Vauldy MCP Status',
                           CFBundleExecutable='vauldy-mcp-status', CFBundlePackageType='APPL',
                           CFBundleShortVersionString='0.12.0', CFBundleVersion='1',
                           LSMinimumSystemVersion='14.0', LSUIElement=True, NSHighResolutionCapable=True)
        with (status_app / 'Contents' / 'Info.plist').open('wb') as f: plistlib.dump(status_info, f)
        # Preserve dependency notices in every distributable.
        notices = resources / 'ThirdPartyNotices'; notices.mkdir()
        for checkout in (ROOT / '.build' / 'checkouts').iterdir():
            for license_file in checkout.glob('LICENSE*'):
                if license_file.is_file():
                    shutil.copy2(license_file, notices / (checkout.name + '-' + license_file.name))
        shutil.copy2(ROOT / 'docs' / 'mcp-installation.md', resources / 'Anleitung.md')
        for guide in ['base-analysis.md', 'mcp-mvp.md', 'provenance.md', 'mcp-oauth.md', 'mcp-chatgpt-sso.md']:
            shutil.copy2(ROOT / 'docs' / guide, resources / guide)
        info = dict(CFBundleIdentifier='com.marcomeisen.vauldy.mcp-setup',
                    CFBundleName='Vauldy MCP Einrichtung', CFBundleDisplayName='Vauldy MCP Einrichtung',
                    CFBundleExecutable='vauldy-mcp-setup', CFBundlePackageType='APPL',
                    CFBundleShortVersionString='0.12.0', CFBundleVersion='1', LSMinimumSystemVersion='14.0',
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
        archive = output / 'Vauldy-MCP-macOS.zip'
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)])
        if args.notary_profile:
            if args.identity == '-': raise SystemExit('Notarization requires a Developer ID identity.')
            run(['xcrun', 'notarytool', 'submit', str(archive), '--keychain-profile', args.notary_profile, '--wait'])
            run(['xcrun', 'stapler', 'staple', str(app)])
            archive.unlink()
            run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)])
        import hashlib
        (output / 'SHA256SUMS').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
        local_app = output / app.name
        if local_app.is_symlink():
            raise SystemExit('Refusing to replace a symlink at the app output.')
        if local_app.exists():
            with (local_app / 'Contents' / 'Info.plist').open('rb') as f:
                if plistlib.load(f).get('CFBundleIdentifier') != info['CFBundleIdentifier']:
                    raise SystemExit('Refusing to replace an unrelated app.')
            shutil.rmtree(local_app)
        shutil.copytree(app, local_app)
        run(['codesign', '--verify', '--deep', '--strict', str(local_app)])
        print(local_app)
        print(archive)
        print('Signing: ' + ('local ad-hoc; NOT notarized for public distribution' if args.identity == '-' else args.identity))

if __name__ == '__main__': main()
