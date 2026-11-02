#!/usr/bin/env python3
"""Build and launch the complete existing MCP UI from this repository.

No installation or client registration; --setup-root isolates native verification.
"""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--skip-build', action='store_true', help='Use an already built release')
    parser.add_argument('--no-open', action='store_true', help='Prepare the app without launching it')
    parser.add_argument('--setup-root', type=Path, help='Absolute isolated test root; never an existing production vault')
    args = parser.parse_args()
    if args.setup_root and not args.setup_root.is_absolute():
        parser.error('--setup-root must be absolute')
    command = [sys.executable, str(ROOT / 'scripts/mcp/package.py')]
    if args.skip_build:
        command.append('--skip-build')
    subprocess.run(command, check=True)
    app = ROOT / 'dist/mcp/Vauldy MCP Einrichtung.app'
    if not args.no_open:
        launch = ['open', '-n', str(app)]
        if args.setup_root:
            launch += ['--args', '--setup-root', str(args.setup_root)]
        subprocess.run(launch, check=True)
    print(app)


if __name__ == '__main__':
    main()
