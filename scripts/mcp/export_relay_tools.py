#!/usr/bin/env python3
"""Export/check relay discovery from the real local MCP using an isolated disabled profile."""
import argparse
import json
import os
from pathlib import Path
import re
import tempfile
import uuid
from smoke_test import Client

ROOT = Path(__file__).resolve().parents[2]

def main():
    p = argparse.ArgumentParser(); p.add_argument('server', type=Path); p.add_argument('--check', action='store_true'); args=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='vauldy-relay-discovery-') as temp:
        root=Path(temp); vault=root/'documents.json';vault.write_text('[]')
        profile=root/'profile.json'; profile.write_text(json.dumps(dict(version=1,revision=str(uuid.uuid4()),connectionID=str(uuid.uuid4()),enabled=False,vaultPath=str(vault),allowedDocumentIDs=[],acknowledgedCloudDisclosure=False)))
        client=Client(args.server.resolve(),profile)
        try: tools=client.request('tools/list',{})['tools']
        finally: client.close()
    path=ROOT/'cloud/chatgpt-relay/worker/index.js'; source=path.read_text()
    updated, markers = re.subn(
        r'^const TOOLS = /\* VAULDY_TOOLS \*/ .*?;\n',
        lambda _: 'const TOOLS = /* VAULDY_TOOLS */ '
        + json.dumps(tools, ensure_ascii=False, separators=(',', ':')) + ';\n',
        source, flags=re.M,
    )
    if markers != 1:
        raise SystemExit('Expected exactly one relay discovery export marker.')
    if args.check:
        if source != updated:
            raise SystemExit('Relay tool schemas differ from local MCP.')
    else:
        path.write_text(updated)
    print('PASS: exact four-tool relay discovery matches local MCP')

if __name__=='__main__':main()
