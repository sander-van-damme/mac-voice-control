#!/usr/bin/env python3
"""Real debug native host, framed stdio, private temporary mailbox. No Chrome or macOS APIs."""
import json, os, pathlib, select, struct, subprocess, tempfile, time, uuid
root=pathlib.Path(__file__).resolve().parents[2]
identity=(root/'BrowserExtension/extension-id.txt').read_text().strip()
exe=root/'.build/debug/MacVoiceBrowserHost'
with tempfile.TemporaryDirectory(dir=root/'work') as directory:
    mailbox=pathlib.Path(directory)/'bridge'
    process=subprocess.Popen([str(exe),f'chrome-extension://{identity}/','--test-directory',str(mailbox)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        deadline=time.monotonic()+3
        while not (mailbox/'heartbeat.json').exists():
            assert time.monotonic()<deadline, 'No host heartbeat'
            time.sleep(.02)
        heartbeat=json.loads((mailbox/'heartbeat.json').read_text())
        assert mailbox.stat().st_mode & 0o777 == 0o700
        command={'id':str(uuid.uuid4()).upper(),'runID':str(uuid.uuid4()).upper(),'kind':'observe','expiresAt':time.time()+3,'connectionID':heartbeat['id']}
        request=mailbox/(command['id']+'.request')
        request.write_text(json.dumps(command));request.chmod(0o600)
        assert select.select([process.stdout],[],[],3)[0], 'No outgoing frame'
        size=struct.unpack('<I',process.stdout.read(4))[0]
        assert json.loads(process.stdout.read(size))==command
        reply={'id':command['id'],'ok':True}
        data=json.dumps(reply).encode();process.stdin.write(struct.pack('<I',len(data))+data);process.stdin.flush()
        response=mailbox/(command['id']+'.response')
        while not response.exists():
            assert time.monotonic()<deadline, 'No incoming response'
            time.sleep(.02)
        assert json.loads(response.read_text())==reply
        assert response.stat().st_mode & 0o777 == 0o600
        # A replacement host must never dispatch a previous connection's queued command.
        command['id']=str(uuid.uuid4()).upper();command['connectionID']=str(uuid.uuid4()).upper()
        request=mailbox/(command['id']+'.request');request.write_text(json.dumps(command));request.chmod(0o600)
        assert not select.select([process.stdout],[],[],.15)[0]
        # Malformed frame length fails closed instead of allocating attacker-sized memory.
        process.stdin.write(struct.pack('<I',900001));process.stdin.flush()
        assert process.wait(timeout=3)==1
        print(json.dumps({'native_host_checks':5,'platform':'Linux','chrome_transport':'framed stdio fixture'}))
    finally:
        if process.poll() is None: process.terminate();process.wait(timeout=3)
# Wrong requesting extension cannot create an authenticated bridge session.
assert subprocess.run([str(exe),'chrome-extension://not-our-extension/','--test-directory',str(root/'work'/'wrong-origin-host')],capture_output=True).returncode==1
print(json.dumps({'wrong_origin_rejected':True}))
