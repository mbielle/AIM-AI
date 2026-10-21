#!/usr/bin/env python3
"""Two real native processes; stdout/stdio is signalling, WebRTC carries payload."""
import argparse, base64, json, os, pathlib, selectors, subprocess, time
p=argparse.ArgumentParser();p.add_argument('--probe',required=True);p.add_argument('--ice');p.add_argument('--relay',action='store_true');p.add_argument('--receipt',required=True);a=p.parse_args()
args=([a.ice] if a.ice else [])+(['relay'] if a.relay else [])
if a.relay and not a.ice: raise SystemExit('Relay qualification requires an explicit local test TURN server')
peers=[subprocess.Popen([a.probe,role,*args],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0) for role in ('offerer','answerer')]
selector=selectors.DefaultSelector();buffers=[b'',b''];opened={};received={};deadline=time.monotonic()+25
payload=b'AIM synthetic durable command '+b'x'*65536
try:
 for i,peer in enumerate(peers):selector.register(peer.stdout,selectors.EVENT_READ,i)
 sent=False
 while time.monotonic()<deadline:
  for key,_ in selector.select(.2):
   i=key.data;chunk=os.read(key.fileobj.fileno(),65536)
   if not chunk:raise RuntimeError('native peer closed before completion')
   buffers[i]+=chunk
   while b'\n' in buffers[i]:
    raw,buffers[i]=buffers[i].split(b'\n',1);line=raw.decode();fields=line.split('\t')
    if fields[0] in ('description','candidate'):
     peers[1-i].stdin.write(raw+b'\n');peers[1-i].stdin.flush()
    elif fields[0]=='open':opened[i]=fields[1]
    elif fields[0]=='message':
     value=base64.b64decode(fields[1],validate=True);received[i]=value
     if i==1:
      assert value==payload
      peers[1].stdin.write(b'send\t'+base64.b64encode(b'ack:synthetic-command-completed')+b'\n');peers[1].stdin.flush()
    elif fields[0]=='error':raise RuntimeError('native peer error '+fields[1])
  if len(opened)==2 and not sent:
   peers[0].stdin.write(b'send\t'+base64.b64encode(payload)+b'\n');peers[0].stdin.flush();sent=True
  if received.get(0)==b'ack:synthetic-command-completed':
   if a.relay:assert set(opened.values())=={'turn'},opened
   receipt={'schema':1,'nativeProcesses':2,'realDataChannel':True,'payloadBytes':len(payload),'receivedBytes':len(received[1]),'acknowledged':True,'paths':opened,'forcedRelay':a.relay,'signalling':'stdio-only','appIntegrationQualified':False,'physicalDevicesQualified':False}
   pathlib.Path(a.receipt).write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt));break
 else:raise RuntimeError('Native ICE/DataChannel qualification timed out')
finally:
 for peer in peers:
  try:peer.stdin.write(b'close\n');peer.stdin.flush()
  except (BrokenPipeError,OSError):pass
 for peer in peers:
  try:peer.wait(timeout=3)
  except subprocess.TimeoutExpired:peer.kill();peer.wait()
