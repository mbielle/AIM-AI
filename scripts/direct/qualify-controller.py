#!/usr/bin/env python3
"""Bounded synthetic Bonjour qualification with source/binary/run-bound evidence."""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location('direct_probe_build', Path(__file__).with_name('build-swift-probe.py'))
build = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(build)
COMMON = dict(realNativeDataChannel=True, encryptedRPC=True, nativeEffectCount=1,
              physicalDevicesQualified=False, appIntegrationQualified=False)
LIFECYCLE = dict(COMMON, receivedEchoBytes=270000, completedAfterPhoneProcessExit=True,
                 reconnectReadSucceeded=True, crossedForegroundResume=True,
                 explicitDisconnectStayedDisconnected=True)
PERMISSIONS = dict(COMMON, initialRevision=1, updatedRevision=2, pairedOnce=True,
    automaticReconnectWithoutRepairing=True, preservedPairIdentityLocationAndKey=True,
    readOnlyOverviewSucceeded=True, removedChatEffectDenied=True,
    priorPrivilegedReplyDenied=True, ungrantedTerminalDenied=True, permissionEditQualified=True)
RECONNECT = dict(LIFECYCLE, crossedForegroundResume=False, explicitDisconnectStayedDisconnected=False)
SCENARIOS = {'lifecycle': LIFECYCLE, 'permissions': PERMISSIONS, 'reconnect': RECONNECT}

# Deliberately never serialize os.environ: provider credentials can be inherited.
CONTEXT_KEYS = ('CFFIXED_USER_HOME', 'AIM_TEST_INSTALLATION_ID', 'MOBILEBUILDMCP_SENTRY_DISABLED',
    'CLANG_MODULE_CACHE_PATH', 'SWIFTPM_MODULECACHE_OVERRIDE', 'AIM_QA_RUN_ID',
    'AIM_QA_DIRECT_SCENARIO', 'AIM_QA_SOURCE_SHA256', 'AIM_QA_BINARY_SHA256',
    'AIM_QA_LAN_DIAGNOSTICS', 'AIM_QA_LAN_OBSERVER', 'AIM_QA_LAN_ENDPOINT',
    'AIM_QA_LAN_PARAMETERS', 'AIM_QA_LAN_CASE')


def launch_context(env, provenance):
    return dict(schema=1, interpreter=str(Path(sys.executable).resolve()), parentPID=os.getppid(),
        namespace=provenance['namespace'], signing=provenance['signing'],
        signingIdentity=provenance['signingIdentity'], capturedAt=time.time(),
        environment={key: env[key] for key in CONTEXT_KEYS if key in env})


def exact_fields(value, expected):
    if not isinstance(value, dict): raise ValueError('Receipt must be an object')
    for name, wanted in expected.items():
        if type(value.get(name)) is not type(wanted) or value[name] != wanted:
            raise ValueError('Missing, false, contradictory or mistyped check: ' + name)


def finite_time(value):
    if type(value) not in (float, int) or not math.isfinite(value): raise ValueError('Invalid receipt time')
    return value


def validate_receipt(path, scenario, run_id, source_sha, binary_sha, namespace, started, finished, paired_via='local-Bonjour-first', secure=False, relay=False):
    if scenario not in SCENARIOS: raise ValueError('Unknown scenario')
    path = Path(path); value = json.loads(path.read_text())
    exact_fields(value, dict(schema=2, scenario=scenario, runID=run_id, sourceSHA256=source_sha,
        binarySHA256=binary_sha, namespace=namespace, status='passed', pairedVia=paired_via,
        secureSignalling=secure, forcedRelay=relay, nativeProcesses=2 if scenario == 'permissions' else 3,
        **SCENARIOS[scenario]))
    if not started <= finite_time(value.get('startedAt')) <= finite_time(value.get('finishedAt')) <= finished:
        raise ValueError('Stale or invalid receipt execution interval')
    if path.stat().st_mtime < started: raise ValueError('Receipt predates execution')
    if value.get('transportPath') not in (('turn',) if relay else ('lan', 'peerToPeer')): raise ValueError('Unexpected native transport')
    return value


def validate_child(path, mode, identity, started, finished, expected_pid, relay=False):
    path = Path(path); value = json.loads(path.read_text())
    exact_fields(value, dict(schema=2, mode=mode, status='passed', **identity, **COMMON))
    if type(value.get('pid')) is not int or value['pid'] != expected_pid or expected_pid <= 0: raise ValueError('Child PID does not match launched process')
    if not started <= finite_time(value.get('startedAt')) <= finite_time(value.get('finishedAt')) <= finished:
        raise ValueError('Child receipt from another execution')
    if path.stat().st_mtime < started or value.get('transportPath') not in (('turn',) if relay else ('lan', 'peerToPeer')):
        raise ValueError('Child receipt freshness/transport mismatch')
    if mode == 'phone-permission-edit':
        exact_fields(value, {k: v for k, v in PERMISSIONS.items() if k != 'permissionEditQualified'})
    else:
        exact_fields(value, dict(receivedEchoBytes=270000, completedAfterPhoneExit=mode != 'phone-first',
            crossedForegroundResume=mode == 'phone-lifecycle',
            explicitDisconnectStayedDisconnected=mode == 'phone-lifecycle', automaticRecoveryAfterRelayRestart=False))
    return value


def stop_process(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=5)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--probe', required=True); p.add_argument('--receipt', required=True)
    p.add_argument('--lifecycle', action='store_true'); p.add_argument('--permission-edit', action='store_true')
    p.add_argument('--run-id', default=uuid.uuid4().hex)
    p.add_argument('--work-dir', type=Path)
    p.add_argument('--absent-service', action='store_true', help='QA negative incident: stop publisher before client; never success')
    p.add_argument('--coordinator'); p.add_argument('--relay', action='store_true')
    a = p.parse_args(argv)
    os.umask(0o077)
    if a.lifecycle and a.permission_edit: p.error('Scenarios must be separate')
    if a.relay and not a.coordinator: p.error('--relay requires --coordinator')
    if a.absent_service and a.coordinator: p.error('Absent Bonjour service incident requires the Bonjour route')
    if not re.fullmatch('[0-9a-f]{32}', a.run_id): p.error('Invalid run id')
    receipt = Path(a.receipt).absolute()
    if receipt.exists(): p.error('Existing receipt preserved; supply a new path')
    try:
        probe = Path(a.probe).resolve(strict=True); provenance = build.verify_probe(probe)
        subprocess.run(['codesign', '--verify', '--strict', str(probe.parent.parent.parent)], check=True, timeout=30,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        print('QA prerequisite missing: isolated current-source signed probe required; no process launched.')
        return 2
    scenario = 'permissions' if a.permission_edit else ('lifecycle' if a.lifecycle else 'reconnect')
    root = a.work_dir.absolute() if a.work_dir else Path(tempfile.mkdtemp(prefix='aim-direct-controller-'))
    if a.work_dir:
        try: root.mkdir(parents=True, mode=0o700, exist_ok=False)
        except OSError:
            print('QA prerequisite missing: fresh synthetic work directory required.'); return 2
    os.chmod(root, 0o700); home = root / 'home'; home.mkdir(mode=0o700)
    identity = dict(runID=a.run_id, scenario=scenario, sourceSHA256=provenance['sourceSHA256'],
                    binarySHA256=provenance['binarySHA256'], namespace=provenance['namespace'])
    env = dict(os.environ, CFFIXED_USER_HOME=str(home), AIM_QA_RUN_ID=a.run_id,
        AIM_QA_DIRECT_SCENARIO=scenario, AIM_QA_SOURCE_SHA256=identity['sourceSHA256'],
        AIM_QA_BINARY_SHA256=identity['binarySHA256'])
    (root / 'launch-context.private.json').write_text(json.dumps(launch_context(env, provenance), indent=2) + '\n')
    extra = ([a.coordinator] + (['--relay'] if a.relay else [])) if a.coordinator else []
    paired_via = 'coordinator-only' if a.coordinator else 'local-Bonjour-first'
    secure = bool(a.coordinator and a.coordinator.startswith('wss:'))
    def terminate_owned_run(signum, frame):
        raise InterruptedError('QA wrapper interrupted')
    previous_term = signal.signal(signal.SIGTERM, terminate_owned_run)
    started = time.time(); host = None
    owned_pids = []
    phase = 'host-start'
    try:
        with (root / 'host.log').open('w') as log:
            host = subprocess.Popen([str(probe), 'host', str(root), *extra], stdout=log, stderr=subprocess.STDOUT,
                                    env=env, start_new_session=True)
            owned_pids.append(host.pid)
            deadline = time.monotonic() + 20
            while not (root / 'invite.private').exists():
                if host.poll() is not None: raise ValueError('Host quit before invitation')
                if time.monotonic() >= deadline: raise ValueError('Host invitation timed out')
                time.sleep(.1)
            if a.absent_service:
                (root / 'stop').write_text('stop'); host.wait(timeout=5)
                phase = 'bonjour-publisher-stopped-before-client'
            modes = ('phone-permission-edit',) if a.permission_edit else ('phone-first', 'phone-lifecycle' if a.lifecycle else 'phone-reconnect')
            children = []
            for mode in modes:
                if mode in ('phone-lifecycle', 'phone-reconnect'): time.sleep(4)
                # Recheck after waiting; source/binary substitution never creates new proof.
                build.verify_probe(probe)
                if not a.absent_service: phase = mode
                child_start = time.time()
                with (root / (mode + '.log')).open('w') as childlog:
                    child = subprocess.Popen([str(probe), mode, str(root), *extra], stdout=childlog,
                        stderr=subprocess.STDOUT, env=env, start_new_session=True)
                    owned_pids.append(child.pid)
                    try: code = child.wait(timeout=90)
                    finally: stop_process(child)
                if code: raise ValueError(mode + ' failed')
                if a.absent_service: raise ValueError('Unexpected client success with publisher absent')
                children.append(validate_child(root / (mode + '-receipt.json'), mode, identity, child_start, time.time(), child.pid, a.relay))
            last = children[-1]
            if a.permission_edit and not (root / 'permission-edit-done').is_file(): raise ValueError('Permission edit not acknowledged')
            build.verify_probe(probe)
            value = dict(schema=2, **identity, status='passed', startedAt=started, finishedAt=time.time(),
                nativeProcesses=2 if a.permission_edit else 3, pairedVia=paired_via,
                secureSignalling=secure, forcedRelay=a.relay, transportPath=last['transportPath'],
                **SCENARIOS[scenario])
            # Clean shutdown is part of execution success; receipt is written afterwards.
            (root / 'stop').write_text('stop')
            try: host.wait(timeout=5)
            except subprocess.TimeoutExpired: raise ValueError('Host did not stop')
            if host.returncode: raise ValueError('Host failed')
            temporary = receipt.with_suffix(receipt.suffix + '.partial')
            temporary.write_text(json.dumps(value, indent=2) + '\n'); os.chmod(temporary, 0o600)
            validate_receipt(temporary, scenario, a.run_id, identity['sourceSHA256'], identity['binarySHA256'], identity['namespace'], started, time.time(), paired_via, secure, a.relay)
            temporary.replace(receipt)
            print(json.dumps(value)); return 0
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        logs = '\n'.join(path.read_text(errors='replace') for path in root.glob('*.log'))
        denied = bool(re.search(r'bonjour-browser-blocked code=(?:-65570|1|13)(?:\s|$)', logs))
        failure = dict(schema=2, **identity, status='prerequisite-missing' if denied else 'failed',
            startedAt=started, finishedAt=time.time(), errorType=type(error).__name__,
            phase=phase, localNetworkPolicyDenied=denied, absentServiceIncident=a.absent_service,
            ownedPIDs=owned_pids, successReceiptWritten=False,
            nextAction='Owner must review the system Local Network permission for the isolated AIM Direct QA helper.' if denied else 'Inspect bounded synthetic milestones; do not retry without a corrective hypothesis.')
        (root / 'failure.json').write_text(json.dumps(failure, indent=2) + '\n')
        print('QA prerequisite missing: owner Local Network permission required.' if denied else 'QA scenario failed; no success receipt.')
        print('Private synthetic diagnostics: ' + str(root))
        return 2 if denied else 1
    finally:
        (root / 'stop').write_text('stop')
        if host is not None: stop_process(host)
        (root / 'cleanup.json').write_text(json.dumps(dict(ownedPIDs=owned_pids,
            hostExited=host is None or host.poll() is not None, completedAt=time.time()), indent=2) + '\n')
        signal.signal(signal.SIGTERM, previous_term)


if __name__ == '__main__':
    raise SystemExit(main())
