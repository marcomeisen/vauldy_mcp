#!/usr/bin/env python3
"""Native UI startup must not resume folder imports. Synthetic fixture only."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

def run(*args):
    return subprocess.check_output(list(map(str,args)),stderr=subprocess.DEVNULL,text=True)

def main():
    supplied=Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='vauldy-setup-startup-') as temp:
        base=Path(temp); app=base/'Vauldy Starttest.app';shutil.copytree(supplied,app)
        info=app/'Contents/Info.plist';value=plistlib.loads(info.read_bytes())
        value['CFBundleIdentifier']='com.marcomeisen.vauldy.startup-test.'+uuid.uuid4().hex
        value['CFBundleName']='Vauldy Starttest';value['CFBundleDisplayName']='Vauldy Starttest';info.write_bytes(plistlib.dumps(value))
        subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        local=app/'Contents/Resources/vauldy-local'; root=base/'installation';store=root/'vault'; source=base/'synthetic originals';source.mkdir()
        original=source/'fixture.pdf';run(local,'example','--output',original)
        digest=hashlib.sha256(original.read_bytes()).hexdigest()
        process=None
        try:
            run(local,'watch-add','--store',store,source)
            # This prepares the fixture, not a performance assertion. A cold native
            # Vision process can take longer than 25 s to initialise on the test Mac.
            deadline=time.monotonic()+90
            while time.monotonic()<deadline:
                status=json.loads(run(local,'worker-status','--store',store))
                snapshot=store/'documents.json'
                if snapshot.exists() and len(json.loads(snapshot.read_text()))==1 and status['processing']==0 and status['queued']==0:break
                time.sleep(.1)
            else:raise AssertionError('Synthetic initial import did not finish')
            run(local,'worker-stop','--store',store)
            deadline=time.monotonic()+5
            while json.loads(run(local,'worker-status','--store',store))['running'] and time.monotonic()<deadline:time.sleep(.1)
            assert not json.loads(run(local,'worker-status','--store',store))['running']
            protected=[store/'documents.json',store/'documents.backup.json',store/'watched-folders.json']
            before={p:p.read_bytes() for p in protected}
            process=subprocess.Popen([str(app/'Contents/MacOS/vauldy-mcp-setup'),'--setup-root',str(root),'--section','oauth'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                assert process.poll() is None,'Native setup exited before observation'
                assert not json.loads(run(local,'worker-status','--store',store))['running'],'Opening setup resumed a writer'
                assert all(p.read_bytes()==data for p,data in before.items()),'Opening setup rewrote snapshot/config'
                time.sleep(.25)
            assert hashlib.sha256(original.read_bytes()).hexdigest()==digest
            print('PASS: native setup with enabled watched folder starts no import worker; snapshots, config and original unchanged.')
        finally:
            if process is not None:
                process.terminate()
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:process.kill();process.wait()
            run(local,'worker-stop','--store',store)
            run(local,'status-menu-stop','--root',root)

if __name__=='__main__':main()
