#!/usr/bin/env python3
"""Isolated real TURN outage test. Never run against a public or shared TURN service."""
import argparse, json, os, pathlib, signal, subprocess, tempfile, time
p=argparse.ArgumentParser();p.add_argument('--probe',required=True);p.add_argument('--coordinator',required=True);p.add_argument('--turn-binary',required=True);p.add_argument('--turn-config',required=True);p.add_argument('--turn-pidfile',required=True);p.add_argument('--receipt',required=True);a=p.parse_args()
assert a.coordinator.startswith(('ws://127.0.0.1:','ws://localhost:')), 'Synthetic loopback only'
assert 'listening-ip=127.0.0.1' in pathlib.Path(a.turn_config).read_text(), 'Loopback TURN required'
root=pathlib.Path(tempfile.mkdtemp(prefix='aim-direct-recovery-'));env=dict(os.environ,CFFIXED_USER_HOME=str(root/'home'))
probe=str(pathlib.Path(a.probe).resolve());flags=[a.coordinator,'--relay'];host=None;phone=None;turn=None
log=open(root/'host.log','w');turnlog=open(root/'turn.log','w')
def wait_file(name,seconds,process=None):
 deadline=time.monotonic()+seconds
 while not (root/name).exists():
  if process is not None and process.poll() is not None:raise RuntimeError('Probe exited before '+name+'; inspect '+str(root))
  if time.monotonic()>deadline:raise RuntimeError('Timed out '+name+'; inspect '+str(root))
  time.sleep(.1)
def stop_initial_turn():
 pid=int(pathlib.Path(a.turn_pidfile).read_text())
 command=subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True).strip()
 assert command.startswith(str(pathlib.Path(a.turn_binary).resolve())+' ') and a.turn_config in command, 'Unexpected TURN process'
 os.kill(pid,signal.SIGTERM)
try:
 host=subprocess.Popen([probe,'host',str(root)]+flags,stdout=log,stderr=subprocess.STDOUT,env=env);wait_file('invite.private',20,host)
 first=subprocess.run([probe,'phone-first',str(root)]+flags,capture_output=True,text=True,timeout=45,env=env)
 (root/'phone-first.log').write_text(first.stdout+first.stderr)
 if first.returncode:raise RuntimeError('Initial phone failed; inspect '+str(root))
 time.sleep(4)
 phonelog=open(root/'phone-recovery.log','w')
 phone=subprocess.Popen([probe,'phone-recovery',str(root)]+flags,stdout=phonelog,stderr=subprocess.STDOUT,env=env)
 wait_file('recovery-ready',40,phone);stop_initial_turn()
 wait_file('recovery-dropped',125,phone)
 # The WSS coordinator is deliberately kept up; only real relay allocations disappear.
 time.sleep(2)
 turn=subprocess.Popen([a.turn_binary,'-c',a.turn_config],stdout=turnlog,stderr=subprocess.STDOUT)
 phone.wait(timeout=155);phonelog.close()
 if phone.returncode:raise RuntimeError('Recovery phone failed; inspect '+str(root))
 actual=json.loads((root/'phone-recovery-receipt.json').read_text())
 assert actual['automaticRecoveryAfterRelayRestart'] and actual['transportPath']=='turn' and actual['nativeEffectCount']==1 and actual['completedAfterPhoneExit']
 receipt={'schema':1,'realRelayProcessStoppedAndRestarted':True,'coordinatorKeptRunning':True,'automaticRecoveryWithoutConnectCall':True,'forcedRelayAfterRecovery':True,'sameCommandIDEffectCount':1,'completedJobReadableAfterRecovery':True,'physicalDevicesQualified':False,'appIntegrationQualified':False}
 pathlib.Path(a.receipt).write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
finally:
 (root/'stop').write_text('stop')
 for process in (phone,host,turn):
  if process is not None and process.poll() is None:
   process.terminate()
   try:process.wait(timeout=8)
   except subprocess.TimeoutExpired:process.kill();process.wait()
 log.close();turnlog.close()
