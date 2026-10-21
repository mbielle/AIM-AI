#!/usr/bin/env python3
"""Bounded real Network.framework observations, never full-controller acceptance.

--diagnostic-plan executes the six preregistered comparisons exactly once.
Otherwise --cases selects normal,absent,late,cancel,cancel-before (default all). Late publication
at 1.5s is expected to connect within 8s. Absent/cancel are negative incidents and
must not write a connection observation; an expected incident is not native success.
Requires a fresh signed helper, no installed apps/devices and no dependencies.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid
from types import SimpleNamespace

_spec = importlib.util.spec_from_file_location('lan_direct', Path(__file__).with_name('qualify-controller.py'))
direct = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(direct)


def validate_observation(path, identity, pid, started, finished):
    value = json.loads(path.read_text())
    required = dict(schema=1, status='observed', outcome='connected', exactSyntheticEcho=True,
        fullControllerQualified=False, physicalDevicesQualified=False, pid=pid, **identity)
    if not isinstance(value, dict) or path.stat().st_mtime < started:
        raise ValueError('Missing/fresh LAN observation required')
    for key, expected in required.items():
        if type(value.get(key)) is not type(expected) or value[key] != expected:
            raise ValueError('LAN observation mismatch: ' + key)
    for key in ('startedAt', 'finishedAt'):
        if type(value.get(key)) not in (int, float) or not started <= value[key] <= finished:
            raise ValueError('LAN observation interval mismatch')
    if value['finishedAt'] < value['startedAt']: raise ValueError('Reversed observation interval')
    return value


def classify(case, code, log, observation_exists, duration):
    if case in ('normal', 'late'):
        return code == 0 and observation_exists and 'lan-echo-and-close-complete' in log
    if observation_exists or code == 0: return False
    if case == 'absent':
        return 'lan-total-deadline' in log or 'lan_timeout:' in log
    if case == 'cancel':
        return ('lan-cancel-requested' in log and 'type=cancelled' in log
            and 'lan-cancellation-quiesced' in log and 'connection-cancelled' in log and duration < 2)
    if case == 'cancel-before':
        return ('lan-cancel-requested' in log and 'type=cancelled' in log
            and 'lan-cancellation-quiesced' in log and duration < 2
            and 'connection-preparing' not in log and 'connection-ready' not in log)
    return False


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--probe', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--diagnostic-plan', type=Path)
    p.add_argument('--cases', default='normal,absent,late,cancel,cancel-before')
    a = p.parse_args(argv); os.umask(0o077)
    cases = a.cases.split(',')
    if any(x not in ('normal', 'absent', 'late', 'cancel', 'cancel-before') for x in cases) or len(set(cases)) != len(cases):
        p.error('Cases must be unique named LAN contracts')
    output = a.output.absolute()
    try: output.mkdir(parents=True, mode=0o700, exist_ok=False)
    except OSError: p.error('Fresh output required; evidence is preserved')
    probe = a.probe.resolve(strict=True)
    try: provenance = direct.build.verify_probe(probe)
    except (OSError, ValueError, subprocess.SubprocessError):
        (output / 'prerequisite.json').write_text(json.dumps(dict(status='prerequisite-missing', launched=False)))
        return 2
    if a.diagnostic_plan:
        plan = json.loads(a.diagnostic_plan.read_text())
        observations = plan['observations']
        if plan['registeredAt'] >= time.time() or plan['maxObservations'] != 6 or len(observations) != 6:
            p.error('Six preregistered observations required')
    else:
        observations = [dict(name=case, case=case, context='direct', observer=True,
            endpoint='reconstructed', parameters='tcp', clientOrdinal=1) for case in cases]
    results = []; hosts = []; clients = []; baseline = None
    try:
        for item in observations:
            started = time.time(); case = item.get('case', 'normal')
            if item['clientOrdinal'] == 2:
                if baseline is None: raise ValueError('Baseline host required for second client')
                root, host, env, identity = baseline
                if host is None or host.poll() is not None: raise ValueError('Baseline publisher expired; comparison not executable')
                observation = root / 'lan-observation.json'
                if observation.exists(): observation.rename(root / 'lan-observation-first.json')
            else:
                root = output / item['name']; root.mkdir(mode=0o700)
                home = root / 'home'; home.mkdir(mode=0o700)
                run_id = uuid.uuid4().hex
                (root / 'service.private').write_text('aim-qa-' + run_id)
                identity = dict(runID=run_id, sourceSHA256=provenance['sourceSHA256'],
                    binarySHA256=provenance['binarySHA256'], namespace=provenance['namespace'])
                env = dict(os.environ)
                if item['context'] == 'run':
                    sys.path.insert(0, str(direct.ROOT / 'scripts/qa'))
                    import run as qa_run
                    run = qa_run.Run(SimpleNamespace(minutes=2, report_dir=str(root / 'run-context'),
                        suite='remote', target='native', dry_run=False, human_minutes=None, interruptions=None))
                    env = run.environment
                env = dict(env, CFFIXED_USER_HOME=str(home), AIM_QA_RUN_ID=run_id,
                    AIM_QA_SOURCE_SHA256=identity['sourceSHA256'], AIM_QA_BINARY_SHA256=identity['binarySHA256'],
                    AIM_QA_LAN_DIAGNOSTICS='1', AIM_QA_LAN_PARAMETERS=item['parameters'],
                    AIM_QA_LAN_OBSERVER='1' if item['observer'] else '0',
                    AIM_QA_LAN_ENDPOINT=item['endpoint'], AIM_QA_LAN_CASE=case)
                (root / 'launch-context.private.json').write_text(json.dumps(direct.launch_context(env, provenance), indent=2))
                host = None
                if case not in ('absent', 'cancel', 'cancel-before'):
                    with (root / 'host.log').open('w') as log:
                        host = subprocess.Popen([str(probe), 'lan-host', str(root)], env=env, stdout=log,
                            stderr=subprocess.STDOUT, start_new_session=True)
                    hosts.append((root, host))
                    if case != 'late':
                        deadline = time.monotonic() + 5
                        while 'listener-ready' not in (root / 'host.log').read_text():
                            if host.poll() is not None or time.monotonic() >= deadline: raise ValueError('Listener not ready')
                            time.sleep(.01)
                if item['name'] == 'baseline': baseline = root, host, env, identity
            direct.build.verify_probe(probe)
            client_started = time.time(); clock = time.monotonic()
            log_path = root / ('client-second.log' if item['clientOrdinal'] == 2 else 'client.log')
            with log_path.open('w') as log:
                child = subprocess.Popen([str(probe), 'lan-client', str(root)], env=env, stdout=log,
                    stderr=subprocess.STDOUT, start_new_session=True)
                try: code = child.wait(timeout=10)
                finally:
                    direct.stop_process(child)
                    clients.append(dict(pid=child.pid, exited=child.poll() is not None, returncode=child.returncode))
            duration = time.monotonic() - clock; finished = time.time()
            text = log_path.read_text(); observation = root / 'lan-observation.json'
            valid = classify(case, code, text, observation.exists(), duration)
            if observation.exists(): validate_observation(observation, identity, child.pid, client_started, finished)
            denied = bool(re.search(r'(?:code=|network_dns:)-65570\b', text))
            results.append(dict(name=item['name'], case=case, factors=item, command=[str(probe), 'lan-client', str(root)],
                code=code, durationSeconds=duration, clientPID=child.pid, hostPID=host.pid if host else None,
                startedAt=started, finishedAt=finished, expectationMet=valid, localNetworkDeniedObserved=denied,
                connectionObservationWritten=observation.exists(), fullControllerQualified=False))
            (output / 'results.json').write_text(json.dumps(dict(status='observations-only', results=results), indent=2)+'\n')
            if host is not None and (baseline is None or host != baseline[1]):
                (root / 'stop').write_text('stop'); host.wait(timeout=3)
    finally:
        cleanup = []
        for root, host in hosts:
            (root / 'stop').write_text('stop')
            try: host.wait(timeout=3)
            except subprocess.TimeoutExpired: direct.stop_process(host)
            cleanup.append(dict(pid=host.pid, exited=host.poll() is not None, returncode=host.returncode))
        (output / 'cleanup.json').write_text(json.dumps(dict(hosts=cleanup, clients=clients), indent=2)+'\n')
    return 0 if len(results) == len(observations) and all(x['expectationMet'] for x in results) else 1


if __name__ == '__main__': raise SystemExit(main())
