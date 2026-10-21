#!/usr/bin/env python3
"""Pure isolated fixtures: acceptance contracts, build provenance, preflight.

These tests never qualify Bonjour, a native transport, an app or physical device.
"""
import copy
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('direct_contract', Path(__file__).with_name('qualify-controller.py'))
direct = importlib.util.module_from_spec(spec); spec.loader.exec_module(direct)
build = direct.build
lan_spec = importlib.util.spec_from_file_location('lan_contracts', Path(__file__).with_name('test-lan-contracts.py'))
lan = importlib.util.module_from_spec(lan_spec); lan_spec.loader.exec_module(lan)


class LANDiagnosticContracts(unittest.TestCase):
    def test_context_is_allowlisted_and_never_copies_credentials(self):
        context = direct.launch_context(dict(AIM_QA_RUN_ID='a' * 32, PROVIDER_API_KEY='secret',
            OPENAI_API_KEY='secret', PATH='sensitive', CFFIXED_USER_HOME='/synthetic'),
            dict(namespace='synthetic', signing='Apple Development', signingIdentity='A' * 40))
        self.assertEqual(context['environment'], dict(AIM_QA_RUN_ID='a' * 32, CFFIXED_USER_HOME='/synthetic'))
        self.assertNotIn('secret', json.dumps(context))

    def test_incidents_require_failure_and_cannot_accept_connection_observations(self):
        for case, log in [('absent', 'lan-total-deadline'), ('cancel', 'lan-cancel-requested type=cancelled lan-cancellation-quiesced connection-cancelled')]:
            self.assertTrue(lan.classify(case, 1, log, False, .25))
            self.assertFalse(lan.classify(case, 0, log, False, .25))
            self.assertFalse(lan.classify(case, 1, log, True, .25))
        self.assertFalse(lan.classify('cancel', 1, 'lan-cancel-requested lan-total-deadline', False, 8))
        self.assertFalse(lan.classify('cancel', 1, 'lan-cancel-requested type=cancelled', False, 8))
        before = 'lan-cancel-requested type=cancelled lan-cancellation-quiesced'
        self.assertTrue(lan.classify('cancel-before', 1, before, False, .1))
        self.assertFalse(lan.classify('cancel-before', 1, before + ' connection-preparing', False, .1))
        self.assertFalse(lan.classify('cancel-before', 1, before, True, .1))
        self.assertFalse(lan.classify('normal', 0, '', True, .2))

    def test_lan_observation_requires_exact_process_provenance_and_time(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'observation.json'; started = time.time() - .5
            identity = dict(runID='a' * 32, sourceSHA256='b' * 64, binarySHA256='c' * 64, namespace='synthetic')
            value = dict(schema=1, status='observed', outcome='connected', exactSyntheticEcho=True,
                fullControllerQualified=False, physicalDevicesQualified=False, pid=123, **identity,
                startedAt=started + .1, finishedAt=started + .2)
            path.write_text(json.dumps(value)); lan.validate_observation(path, identity, 123, started, time.time())
            for key, wrong in [('pid', True), ('pid', 124), ('outcome', 'failed'), ('runID', 'other'),
                ('exactSyntheticEcho', False), ('fullControllerQualified', True), ('finishedAt', float('nan'))]:
                path.write_text(json.dumps(dict(value, **{key: wrong})))
                with self.assertRaises(ValueError): lan.validate_observation(path, identity, 123, started, time.time())

    def test_cleanup_stops_only_its_own_process(self):
        owned = subprocess.Popen([os.sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)
        other = subprocess.Popen([os.sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)
        try:
            direct.stop_process(owned)
            self.assertIsNotNone(owned.poll()); self.assertIsNone(other.poll())
        finally:
            direct.stop_process(owned); direct.stop_process(other)


class ReceiptContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.path = self.root / 'receipt.json'
        self.start = time.time() - .5
        self.identity = dict(runID='a' * 32, sourceSHA256='b' * 64, binarySHA256='c' * 64,
                             namespace='com.aimai.macos.qualification.' + 'd' * 32)

    def receipt(self, scenario):
        return dict(schema=2, scenario=scenario, **self.identity, status='passed',
            startedAt=self.start + .1, finishedAt=self.start + .2,
            pairedVia='local-Bonjour-first', secureSignalling=False, forcedRelay=False,
            nativeProcesses=2 if scenario == 'permissions' else 3, transportPath='lan', **direct.SCENARIOS[scenario])

    def validate(self, scenario, value):
        self.path.write_text(json.dumps(value))
        return direct.validate_receipt(self.path, scenario, self.identity['runID'], self.identity['sourceSHA256'],
            self.identity['binarySHA256'], self.identity['namespace'], self.start, time.time())

    def test_both_complete_receipts_accepted(self):
        for scenario in direct.SCENARIOS:
            self.assertEqual(self.validate(scenario, self.receipt(scenario))['nativeEffectCount'], 1)

    def test_every_required_field_must_be_present_and_exactly_typed(self):
        for scenario in direct.SCENARIOS:
            valid = self.receipt(scenario)
            for key in valid:
                with self.subTest(scenario=scenario, field=key):
                    missing = dict(valid); del missing[key]
                    with self.assertRaises(ValueError): self.validate(scenario, missing)
                    for wrong in [None, [], {}, False if valid[key] is True else True]:
                        if type(wrong) is type(valid[key]) and wrong == valid[key]: continue
                        with self.assertRaises(ValueError): self.validate(scenario, dict(valid, **{key: wrong}))

    def test_negative_assertions_counts_revision_sizes_and_substitutions_rejected(self):
        for scenario in direct.SCENARIOS:
            valid = self.receipt(scenario)
            alterations = dict(schema=1, nativeEffectCount=2, nativeProcesses=99, runID='x', scenario='wrong',
                sourceSHA256='x', binarySHA256='x', namespace='x', status='failed', transportPath='turn',
                pairedVia='loopback', physicalDevicesQualified=True, appIntegrationQualified=True,
                forcedRelay=True, secureSignalling=True, startedAt=self.start - 1, finishedAt=time.time() + 1)
            if scenario == 'lifecycle': alterations.update(receivedEchoBytes=0)
            elif scenario == 'permissions': alterations.update(initialRevision=2, updatedRevision=1)
            for key, wrong in alterations.items():
                with self.subTest(scenario=scenario, field=key):
                    with self.assertRaises(ValueError): self.validate(scenario, dict(valid, **{key: wrong}))
            for key in ['startedAt', 'finishedAt']:
                for wrong in [float('nan'), float('inf'), float('-inf'), True, 'now']:
                    with self.assertRaises(ValueError): self.validate(scenario, dict(valid, **{key: wrong}))

    def test_absent_malformed_empty_array_and_stale_file_rejected(self):
        with self.assertRaises(OSError): direct.validate_receipt(self.path, 'lifecycle', '', '', '', '', 0, time.time())
        for malformed in [None, [], '', {}, dict(nativeEffectCount=2, readOnlyOverviewSucceeded=False)]:
            with self.assertRaises(ValueError): self.validate('lifecycle', malformed)
        self.path.write_text('{broken')
        with self.assertRaises(ValueError): direct.validate_receipt(self.path, 'lifecycle', '', '', '', '', 0, time.time())
        self.path.write_text(json.dumps(self.receipt('lifecycle'))); os.utime(self.path, (0, 0))
        with self.assertRaises(ValueError): direct.validate_receipt(self.path, 'lifecycle', self.identity['runID'],
            self.identity['sourceSHA256'], self.identity['binarySHA256'], self.identity['namespace'], self.start, time.time())

    def test_child_receipt_is_bound_to_pid_mode_identity_and_interval(self):
        value = dict(self.receipt('permissions'), mode='phone-permission-edit', pid=123)
        value.pop('permissionEditQualified')
        self.path.write_text(json.dumps(value))
        direct.validate_child(self.path, 'phone-permission-edit', dict(self.identity, scenario='permissions'), self.start, time.time(), 123)
        for key, wrong in [('pid', 124), ('pid', True), ('mode', 'phone-first'), ('updatedRevision', 1), ('runID', 'old')]:
            self.path.write_text(json.dumps(dict(value, **{key: wrong})))
            with self.assertRaises(ValueError): direct.validate_child(self.path, 'phone-permission-edit', dict(self.identity, scenario='permissions'), self.start, time.time(), 123)


class ProvenanceContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.bundle = self.root / 'QA.app'
        self.probe = self.bundle / 'Contents/MacOS/AIMDirectProbe'; self.probe.parent.mkdir(parents=True)
        self.probe.write_bytes(b'unexecuted fixture')
        self.namespace = 'com.aimai.macos.qualification.' + 'd' * 32
        self.info = self.probe.parent.parent / 'Info.plist'
        self.info.write_bytes(plistlib.dumps(dict(CFBundleIdentifier=self.namespace, AIMQualificationNamespace=self.namespace,
            CFBundleExecutable='AIMDirectProbe', NSBonjourServices=['_aimdirect._tcp'], NSLocalNetworkUsageDescription='QA fixture')))
        scratch = self.root / 'scratch'; products = scratch / 'out/Products/Debug'
        products.mkdir(parents=True); (products / 'libAIMCore.a').write_bytes(b'fresh core')
        (products / 'AIMCore.swiftmodule').mkdir(); (products / 'AIMCore.swiftmodule/arm64.swiftmodule').write_bytes(b'module')
        dep = scratch / 'checkouts/pinned/source.swift'; dep.parent.mkdir(parents=True); dep.write_bytes(b'dependency')
        native = self.root / 'native.a'; native.write_bytes(b'pinned native')
        self.patches = [patch.object(build, 'ROOT', self.root), patch.object(build, 'source_inputs', return_value={'source.swift': 'hash'}),
                        patch.object(build.subprocess, 'run')]
        for item in self.patches: item.start(); self.addCleanup(item.stop)
        native_target = self.root / 'packages/AIMDirectNative/Artifacts/AIMDataChannel.xcframework/macos-arm64_x86_64/libAIMDataChannel-macos.a'
        native_target.parent.mkdir(parents=True); native_target.write_bytes(b'pinned native')
        self.value = dict(schema=2, probe='controller', namespace=self.namespace, freshCoreBuild=True, status='built',
            inputs={'source.swift': 'hash'}, sourceSHA256=build.map_digest({'source.swift': 'hash'}),
            binarySHA256=build.digest(self.probe), infoSHA256=build.digest(self.info), coreScratch=str(scratch),
            dependencyInputs={'pinned/source.swift': build.digest(dep)},
            linkedInputs={str(p): build.digest(p) for p in [products / 'libAIMCore.a', products / 'AIMCore.swiftmodule/arm64.swiftmodule', native_target]},
            buildStarted=time.time() - 2, buildFinished=time.time() - 1, coreBuildCommand=['swift', 'build', '--scratch-path', str(scratch)],
            signing='Apple Development', signingIdentity='A' * 40)
        self.manifest = self.bundle.with_suffix('.provenance.json')
        self.write(self.value)

    def write(self, value): self.manifest.write_text(json.dumps(value))

    def test_complete_manifest_checks_signature(self):
        self.assertIs(build.verify_probe(self.probe)['freshCoreBuild'], True)
        self.assertEqual(build.subprocess.run.call_args.args[0][:3], ['codesign', '--verify', '--strict'])

    def test_stale_binary_module_dependency_source_metadata_and_recipe_fail(self):
        for key, wrong in [('freshCoreBuild', False), ('inputs', {}), ('sourceSHA256', 'old'),
            ('binarySHA256', 'old'), ('infoSHA256', 'old'), ('namespace', 'wrong'), ('probe', 'rpc'),
            ('linkedInputs', {}), ('dependencyInputs', {}), ('schema', True), ('signing', 'ad-hoc'),
            ('buildStarted', float('nan')), ('buildFinished', float('inf')), ('coreBuildCommand', [])]:
            self.write(dict(self.value, **{key: wrong}))
            with self.subTest(field=key):
                with self.assertRaises(ValueError): build.verify_probe(self.probe)
        self.write(self.value)
        for path in [self.probe, *(Path(p) for p in self.value['linkedInputs']),
                     Path(self.value['coreScratch']) / 'checkouts/pinned/source.swift']:
            data = path.read_bytes(); path.write_bytes(data + b'drift')
            with self.assertRaises(ValueError): build.verify_probe(self.probe)
            path.write_bytes(data)

    def test_missing_and_malformed_metadata_and_provenance_fail_controlled(self):
        for value in [None, [], {}, 'malformed']:
            self.write(value)
            with self.assertRaises(ValueError): build.verify_probe(self.probe)
        self.write(self.value)
        self.info.write_bytes(plistlib.dumps([]))
        with self.assertRaises(ValueError): build.verify_probe(self.probe)

    def test_invalid_or_missing_preflight_launches_no_native_process(self):
        with patch.object(direct.build, 'verify_probe', side_effect=ValueError('stale')), patch.object(direct.subprocess, 'Popen') as launch:
            self.assertEqual(direct.main(['--probe', str(self.probe), '--receipt', str(self.root / 'result'), '--lifecycle']), 2)
            launch.assert_not_called()
        with patch.object(direct.subprocess, 'Popen') as launch:
            for flags in [['--lifecycle', '--permission-edit'], ['--relay'], ['--absent-service', '--coordinator', 'ws://localhost']]:
                with self.assertRaises(SystemExit): direct.main(['--probe', str(self.probe), '--receipt', str(self.root / 'result'), *flags])
            launch.assert_not_called()


if __name__ == '__main__': unittest.main()
