"""Offline input contracts. ALL subprocesses are mocked, including signing/key lookup.

Fixtures are synthetic and disposable under build/qa-distribution-builder-20261020/agent.
No actual app, codesign, security, Keychain, build tool or network is used.
"""
import base64
import copy
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import urllib.parse
from unittest import mock

SOURCE_ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('distribution_builder', pathlib.Path(__file__).with_name('build-distribution.py'))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
EVIDENCE = SOURCE_ROOT.parents[1] / 'build/qa-jalon3-candidat-mac-20261020/agent'


class BuildDistributionTests(unittest.TestCase):
    def setUp(self):
        EVIDENCE.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='synthetic-', dir=EVIDENCE)
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(builder, 'root', self.root).start()
        self.calls = []
        self.identities = '  1) ' + 'A' * 40 + ' "Developer ID Application: Fixture (TESTTEAM)"\n  1 valid identities found\n'
        self.public_key = base64.b64encode(b'x' * 32).decode()
        self.guard_fails = False
        self.signature_fails = False
        self.key_hook = None
        self.run = mock.patch.object(builder.subprocess, 'run', side_effect=self.fake_run).start()
        self.config = {
            'application_version': '0.2.0', 'application_build': '77',
            'codesign_identity': 'Developer ID Application: Fixture (TESTTEAM)',
            'expected_identity_sha1': 'A' * 40,
            'sparkle_feed_url': 'https://release.example/updates/appcast.xml',
            'sparkle_account': 'synthetic-only', 'sparkle_public_key': self.public_key,
        }
        for name in ('validate-client-config.py', 'verify-mlx-license-bundle.py'):
            self.file('scripts/' + name, (SOURCE_ROOT / 'scripts' / name).read_bytes())
        self.node = self.file('runtime/node', executable=True)
        self.cua = self.file('runtime/cua-driver', executable=True)
        self.llama = self.root / 'runtime/llama'
        self.file('runtime/llama/llama-server', executable=True)
        self.file('runtime/llama/LICENSE', b'Synthetic llama license')
        for name in builder.LLAMA_LIBRARIES:
            self.file('runtime/llama/' + name)
        self.mlx = self.root / 'runtime/mlx'
        self.file('runtime/mlx/aim-mlx-engine', executable=True)
        self.file('runtime/mlx/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib')
        legal = self.file('runtime/mlx/Licenses/fixture.txt', b'Synthetic license text. ' * 8)
        self.file('runtime/mlx/Package.resolved', json.dumps({'pins': [
            {'identity': 'fixture', 'state': {'revision': 'synthetic-revision'}}]}).encode())
        manifest = {'complete': True, 'components': [{
            'identity': 'fixture', 'revision': 'synthetic-revision', 'source': 'https://source.example/fixture',
            'licenses': [{'path': 'fixture.txt', 'sha256': hashlib.sha256(legal.read_bytes()).hexdigest()}],
        }]}
        self.file('runtime/mlx/Licenses/manifest.json', json.dumps(manifest).encode())
        self.cli = self.file('Vendor/PlaywrightMCP/node_modules/@playwright/mcp/cli.js')
        versions = {'@playwright/mcp': '0.0.82', 'playwright': '1.64.0-alpha-1789764292000', 'playwright-core': '1.64.0-alpha-1789764292000'}
        for name, version in versions.items():
            deps = {'@playwright/mcp': {'playwright': versions['playwright'], 'playwright-core': versions['playwright-core']}, 'playwright': {'playwright-core': versions['playwright-core']}, 'playwright-core': {}}[name]
            self.file('Vendor/PlaywrightMCP/node_modules/' + name + '/package.json', json.dumps({'name': name, 'version': version, 'dependencies': deps}).encode())
            self.file('Vendor/PlaywrightMCP/node_modules/' + name + '/LICENSE', b'Synthetic full upstream license. ' * 8)
        self.node_license = self.file('legal/node-LICENSE', b'Synthetic Node license. ' * 8)
        self.cua_license = self.file('legal/cua-LICENSE', b'Synthetic CUA license')
        self.config.update(runtime_inputs={
            'node_runtime': str(self.node), 'llama_cpp_dir': str(self.llama),
            'mlx_engine_dir': str(self.mlx), 'cua_driver_path': str(self.cua),
        }, notices={
            'node_license': str(self.node_license), 'llama_cpp_license': str(self.llama / 'LICENSE'),
            'mlx_licenses': str(self.mlx / 'Licenses'), 'cua_driver_license': str(self.cua_license),
        })
        self.configuration = self.root / 'reviewed.json'
        self.output = self.root / 'build/New.app'
        self.marker = self.root / 'BUILD_WAS_SIMULATED'

    def file(self, relative, contents=b'synthetic, never executed', executable=False):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)
        if executable:
            path.chmod(0o755)
        return path

    def synthetic_privileged_key(self, kind='secret', label='SYNTHETIC_SECRET'):
        """Construct hostile synthetic inputs at runtime; never store a usable key."""
        prefix = {'secret': 'sb_' + 'secret_', 'personal': 'sbp_'}[kind]
        value = prefix + label
        self.assertTrue(value.startswith(prefix))
        self.assertEqual(value[len(prefix):], label)
        self.assertEqual(len(value), len(prefix) + len(label))
        return value

    def synthetic_credential_url(self, hostname, path=''):
        """Keep userinfo rejection coverage without embedding a credential URL."""
        netloc = ':'.join(('user', 'secret')) + '@' + hostname
        value = urllib.parse.urlunsplit(('https', netloc, path, '', ''))
        parsed = urllib.parse.urlsplit(value)
        self.assertEqual((parsed.scheme, parsed.username, parsed.password, parsed.hostname, parsed.path),
                         ('https', 'user', 'secret', hostname, path))
        return value

    def fake_run(self, command, **kwargs):
        self.calls.append((list(command), copy.deepcopy(kwargs)))
        if command[0] == '/usr/bin/python3' and command[2:4] == ['guard', '--all-aim']:
            if self.guard_fails:
                raise subprocess.CalledProcessError(2, command)
            return subprocess.CompletedProcess(command, 0)
        if command[0] == '/usr/bin/security':
            self.assertEqual(command, ['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'])
            return subprocess.CompletedProcess(command, 0, stdout=self.identities)
        if command[0].endswith('/generate_keys'):
            self.assertEqual(command[1:], ['--account', 'synthetic-only', '-p'])
            if self.key_hook:
                self.key_hook()
            return subprocess.CompletedProcess(command, 0, stdout=self.public_key + '\n')
        if command[0] == '/usr/bin/codesign':
            self.assertEqual(command[1:4], ['--verify', '--deep', '--strict'])
            if self.signature_fails:
                raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0)
        if command[0] == '/bin/zsh':
            self.assertEqual(command[:4], ['/bin/zsh', '-f', str(self.root / 'scripts/build-app.sh'), 'release'])
            self.marker.write_text('Mock subprocess only; no build performed')
            return subprocess.CompletedProcess(command, 0)
        self.fail('Unexpected subprocess (all real processes are forbidden): ' + repr(command))

    def invoke(self, reference=None, scratch=None, manifest=None):
        self.configuration.write_text(json.dumps(self.config))
        arguments = ['--configuration', str(self.configuration), '--output-app', str(self.output)]
        if manifest:
            arguments += ['--input-manifest', str(manifest)]
        if scratch:
            arguments += ['--swift-scratch', str(scratch)]
        if reference:
            arguments += ['--reference-app', str(reference)]
        builder.main(arguments)

    def refused_without_processes(self, message=None):
        with self.assertRaisesRegex((ValueError, OSError, KeyError), message or '.'):
            self.invoke()
        self.run.assert_not_called()
        self.assertFalse(self.marker.exists())

    def build_environment(self):
        self.assertTrue(self.marker.is_file())
        command, kwargs = self.calls[-1]
        self.assertEqual(command[0], '/bin/zsh')
        self.assertTrue(kwargs['check'])
        self.assertEqual(kwargs['cwd'], self.root)
        return kwargs['env']

    def reference(self, backend=None):
        reference = self.root / 'Reference.app'
        resources = reference / 'Contents/Resources'
        (resources / 'Playwright').mkdir(parents=True)
        shutil.copy2(self.node, resources / 'Playwright/node')
        shutil.copy2(self.node_license, resources / 'Playwright/NODE-LICENSE')
        shutil.copytree(self.cli.parents[2], resources / 'Playwright/node_modules')
        shutil.copytree(self.llama, resources / 'LlamaCpp')
        shutil.copytree(self.mlx, resources / 'MLXEngine')
        self.file('Reference.app/Contents/Info.plist', plistlib.dumps(backend or {}))
        self.file('build/driver-qualification/cua-driver-rs-0.28.2-darwin-arm64/cua-driver', executable=True)
        self.file('build/driver-qualification/LICENSE.md', b'Synthetic historical license')
        del self.config['runtime_inputs'], self.config['notices']
        return reference

    def test_explicit_backend_absent_and_no_reference_succeeds(self):
        self.invoke()
        env = self.build_environment()
        self.assertNotIn('AIM_SUPABASE_URL', env)
        self.assertNotIn('AIM_SUPABASE_PUBLIC_KEY', env)
        self.assertEqual(env['AIM_NODE_RUNTIME'], str(self.node))
        self.assertEqual(env['AIM_CUA_DRIVER_LICENSE'], str(self.cua_license))
        self.assertFalse(any(command[0] == '/usr/bin/codesign' for command, _ in self.calls))

    def test_node_notice_is_passed_to_lower_builder(self):
        self.invoke()
        self.assertEqual(self.build_environment()['AIM_NODE_LICENSE'], str(self.node_license))

    def test_explicit_isolated_playwright_modules_are_passed(self):
        modules = self.root / 'isolated/node_modules'
        shutil.copytree(self.cli.parents[2], modules)
        self.config['runtime_inputs']['playwright_modules'] = str(modules)
        shutil.rmtree(self.cli.parents[2])
        self.invoke()
        self.assertEqual(self.build_environment()['AIM_PLAYWRIGHT_MODULES'], str(modules))

    def test_declared_missing_playwright_modules_are_refused(self):
        self.config['runtime_inputs']['playwright_modules'] = str(self.root / 'missing')
        self.refused_without_processes('playwright_modules')

    def test_declared_null_playwright_modules_are_refused(self):
        self.config['runtime_inputs']['playwright_modules'] = None
        self.refused_without_processes('playwright_modules')

    def test_short_node_license_is_refused_before_build(self):
        self.node_license.write_bytes(b'short')
        self.refused_without_processes('Full Node license')

    def test_backend_publishable_public_pair_is_passed(self):
        self.config['public_supabase'] = {'url': 'https://public.example', 'public_key': 'sb_publishable_synthetic'}
        self.invoke()
        env = self.build_environment()
        self.assertEqual(env['AIM_SUPABASE_URL'], 'https://public.example')
        self.assertEqual(env['AIM_SUPABASE_PUBLIC_KEY'], 'sb_publishable_synthetic')

    def test_backend_anon_jwt_uses_shared_validator(self):
        payload = base64.urlsafe_b64encode(b'{"role":"anon"}').decode().rstrip('=')
        self.config['public_supabase'] = {'url': 'https://public.example', 'public_key': 'header.' + payload + '.signature'}
        self.invoke()
        self.assertEqual(self.build_environment()['AIM_SUPABASE_PUBLIC_KEY'], 'header.' + payload + '.signature')

    def test_empty_backend_object_or_pair_is_allowed(self):
        for value in ({}, {'url': '', 'public_key': ''}):
            with self.subTest(value=value):
                self.config['public_supabase'] = value
                self.invoke()
                self.assertNotIn('AIM_SUPABASE_PUBLIC_KEY', self.build_environment())

    def test_partial_backend_is_refused_before_processes(self):
        for value in ({'url': 'https://public.example'}, {'public_key': 'sb_publishable_synthetic'}):
            with self.subTest(value=value):
                self.config['public_supabase'] = value
                self.refused_without_processes('together')

    def test_privileged_or_malformed_backend_keys_are_refused(self):
        service = base64.urlsafe_b64encode(b'{"role":"service_role"}').decode().rstrip('=')
        for key in (self.synthetic_privileged_key(), self.synthetic_privileged_key(kind='personal'),
                    'head.' + service + '.sig', 'invalid'):
            with self.subTest(kind=key.split('_')[0]):
                self.config['public_supabase'] = {'url': 'https://public.example', 'public_key': key}
                self.refused_without_processes('key')

    def test_non_public_backend_origins_are_refused(self):
        for url in ('http://public.example', self.synthetic_credential_url('public.example'),
                    'https://public.example/path', 'https://public.example?token=secret',
                    'https://public.example#secret', 'https://public.example:bad'):
            with self.subTest(origin=url):
                self.config['public_supabase'] = {'url': url, 'public_key': 'sb_publishable_synthetic'}
                self.refused_without_processes('HTTPS origin')

    def test_invalid_backend_schema_is_refused(self):
        for value in (None, [], {'url': 7}, {'service_role': 'SYNTHETIC_SECRET'}):
            with self.subTest(value=value):
                self.config['public_supabase'] = value
                self.refused_without_processes()

    def test_each_missing_runtime_declaration_is_refused(self):
        original = copy.deepcopy(self.config['runtime_inputs'])
        for key in original:
            with self.subTest(key=key):
                self.config['runtime_inputs'] = {k: v for k, v in original.items() if k != key}
                self.refused_without_processes('runtime_inputs')

    def test_each_missing_notice_declaration_is_refused(self):
        original = copy.deepcopy(self.config['notices'])
        for key in original:
            with self.subTest(key=key):
                self.config['notices'] = {k: v for k, v in original.items() if k != key}
                self.refused_without_processes('notices')

    def test_missing_runtime_or_notice_objects_are_refused(self):
        original = copy.deepcopy(self.config)
        for key in ('runtime_inputs', 'notices'):
            with self.subTest(key=key):
                self.config = copy.deepcopy(original)
                del self.config[key]
                self.refused_without_processes(key)

    def test_each_missing_runtime_file_or_directory_is_refused(self):
        original = copy.deepcopy(self.config['runtime_inputs'])
        for key in original:
            with self.subTest(key=key):
                self.config['runtime_inputs'] = dict(original, **{key: str(self.root / 'missing')})
                self.refused_without_processes(key)

    def test_each_missing_notice_path_is_refused(self):
        original = copy.deepcopy(self.config['notices'])
        for key in original:
            with self.subTest(key=key):
                self.config['notices'] = dict(original, **{key: str(self.root / 'missing')})
                self.refused_without_processes(key)

    def test_relative_input_paths_are_refused(self):
        self.config['runtime_inputs']['node_runtime'] = 'runtime/node'
        self.refused_without_processes('absolute')

    def test_nonexecutable_runtime_is_refused(self):
        self.node.chmod(0o644)
        self.refused_without_processes('node_runtime')

    def test_unrelated_notice_paths_are_refused(self):
        self.config['notices']['llama_cpp_license'] = str(self.node_license)
        self.refused_without_processes('layout')

    def test_missing_llama_library_is_refused(self):
        (self.llama / 'libllama.0.dylib').unlink()
        self.refused_without_processes('libllama')

    def test_missing_mlx_license_lock_is_refused(self):
        (self.mlx / 'Package.resolved').unlink()
        self.refused_without_processes('Package.resolved')

    def test_unreviewed_or_changed_mlx_notices_are_refused(self):
        manifest = self.mlx / 'Licenses/manifest.json'
        original = manifest.read_text()
        content = json.loads(original)
        content['complete'] = False
        manifest.write_text(json.dumps(content))
        self.refused_without_processes('reviewed, complete and consistent')
        manifest.write_text(original)
        (self.mlx / 'Licenses/fixture.txt').write_text('changed')
        self.refused_without_processes('reviewed, complete and consistent')

    def test_empty_node_and_cua_notices_are_refused(self):
        for path in (self.node_license, self.cua_license):
            with self.subTest(notice=path.name):
                original = path.read_bytes()
                path.write_bytes(b'')
                self.refused_without_processes('empty')
                path.write_bytes(original)

    def test_cli_reports_missing_input_without_echoing_secret_config(self):
        secret = 'SYNTHETIC_SECRET_DO_NOT_ECHO'
        self.config['runtime_inputs']['node_runtime'] = str(self.root / secret)
        self.configuration.write_text(json.dumps(self.config))
        stderr = io.StringIO()
        arguments = ['build-distribution.py', '--configuration', str(self.configuration), '--output-app', str(self.output)]
        with mock.patch('sys.argv', arguments), mock.patch('sys.stderr', stderr):
            self.assertEqual(builder.cli(), 2)
        self.assertIn('node_runtime', stderr.getvalue())
        self.assertIn('Missing', stderr.getvalue())
        self.assertNotIn(secret, stderr.getvalue())
        self.run.assert_not_called()

    def test_cli_reports_privileged_key_rejection_without_echoing_key(self):
        secret = self.synthetic_privileged_key(label='SYNTHETIC_DO_NOT_ECHO')
        self.config['public_supabase'] = {'url': 'https://public.example', 'public_key': secret}
        self.configuration.write_text(json.dumps(self.config))
        stderr = io.StringIO()
        arguments = ['build-distribution.py', '--configuration', str(self.configuration), '--output-app', str(self.output)]
        with mock.patch('sys.argv', arguments), mock.patch('sys.stderr', stderr):
            self.assertEqual(builder.cli(), 2)
        self.assertIn('never a privileged key', stderr.getvalue())
        self.assertNotIn(secret, stderr.getvalue())
        self.assertNotIn('https://public.example', stderr.getvalue())
        self.run.assert_not_called()

    def test_missing_playwright_package_is_refused_before_processes(self):
        self.cli.unlink()
        self.refused_without_processes('Playwright MCP')

    def test_exact_identity_and_sha_must_be_on_same_line(self):
        self.identities = ('  1) ' + 'A' * 40 + ' "Developer ID Application: Other (TESTTEAM)"\n'
                           '  2) ' + 'B' * 40 + ' "Developer ID Application: Fixture (TESTTEAM)"\n')
        with self.assertRaisesRegex(ValueError, 'not available together'):
            self.invoke()
        self.assertFalse(self.marker.exists())
        self.assertFalse(any(command[0].endswith('/generate_keys') for command, _ in self.calls))

    def test_identity_substring_is_not_accepted(self):
        self.identities = self.identities.replace('(TESTTEAM)"', '(TESTTEAM) copied"')
        with self.assertRaisesRegex(ValueError, 'not available together'):
            self.invoke()
        self.assertFalse(self.marker.exists())

    def test_bad_sha_or_adhoc_identity_is_refused_before_processes(self):
        self.config['expected_identity_sha1'] = 'A' * 39
        self.refused_without_processes('SHA-1')
        self.config['expected_identity_sha1'] = 'A' * 40
        self.config['codesign_identity'] = '-'
        self.refused_without_processes('Developer ID')

    def test_sparkle_lookup_is_only_named_account_public_read(self):
        self.invoke()
        lookups = [command for command, _ in self.calls if command[0].endswith('/generate_keys')]
        self.assertEqual(lookups, [[str(self.root / '.build/artifacts/sparkle/Sparkle/bin/generate_keys'),
                                    '--account', 'synthetic-only', '-p']])

    def test_key_mismatch_prevents_build(self):
        self.public_key = base64.b64encode(b'y' * 32).decode()
        with self.assertRaisesRegex(ValueError, 'public key mismatch'):
            self.invoke()
        self.assertFalse(self.marker.exists())

    def test_existing_output_file_or_directory_is_refused(self):
        self.output.parent.mkdir()
        for directory in (False, True):
            with self.subTest(directory=directory):
                if directory:
                    self.output.mkdir()
                else:
                    self.output.write_text('preserve')
                self.refused_without_processes('New app path')
                if directory:
                    self.output.rmdir()
                else:
                    self.assertEqual(self.output.read_text(), 'preserve')
                    self.output.unlink()

    def test_live_and_dangling_output_symlinks_are_refused(self):
        self.output.parent.mkdir()
        for destination in (self.node, self.root / 'missing'):
            with self.subTest(dangling=not destination.exists()):
                self.output.symlink_to(destination)
                self.refused_without_processes('symlinks')
                self.assertTrue(self.output.is_symlink())
                self.output.unlink()

    def test_output_parent_symlink_and_outside_paths_are_refused(self):
        elsewhere = self.root / 'elsewhere'
        elsewhere.mkdir()
        self.output.parent.symlink_to(elsewhere, target_is_directory=True)
        self.refused_without_processes('symlinks')
        self.output.parent.unlink()
        for output in (elsewhere / 'New.app', self.root / 'build/nested/New.app', self.root / 'build/New.zip'):
            with self.subTest(output=output):
                self.output = output
                self.refused_without_processes('New app path')

    def test_destination_appearing_during_preflight_prevents_build(self):
        def appear():
            self.output.parent.mkdir(exist_ok=True)
            self.output.symlink_to(self.root / 'missing')
        self.key_hook = appear
        with self.assertRaisesRegex(ValueError, 'New app path'):
            self.invoke()
        self.assertFalse(self.marker.exists())
        self.assertTrue(self.output.is_symlink())

    def test_active_guard_failure_is_first_external_call_and_prevents_mutation(self):
        self.guard_fails = True
        before = sorted(str(path.relative_to(self.root)) for path in self.root.rglob('*'))
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        after = sorted(str(path.relative_to(self.root)) for path in self.root.rglob('*') if path != self.configuration)
        self.assertEqual(before, after)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][0], ['/usr/bin/python3', str(self.root / 'scripts/distribution-tools.py'),
                                          'guard', '--all-aim', str(self.output), str(self.root / '.build')])
        self.assertFalse(self.marker.exists())

    def test_ambient_build_backend_and_secret_configuration_are_discarded(self):
        pollution = {name: 'AMBIENT_MUST_NOT_REACH_CHILD' for name in (
            'AIM_PUBLIC_CONFIG_PLIST', 'AIM_SUPABASE_URL', 'AIM_SUPABASE_PUBLIC_KEY',
            'AIM_NODE_RUNTIME', 'AIM_LLAMA_CPP_DIR', 'AIM_MLX_ENGINE_DIR', 'AIM_CUA_DRIVER_PATH',
            'AIM_CUA_DRIVER_LICENSE', 'AIM_RELEASE_VERSION', 'AIM_RELEASE_BUILD',
            'AIM_APP_OUTPUT', 'AIM_CODESIGN_IDENTITY', 'AIM_SPARKLE_FEED_URL', 'AIM_SPARKLE_PUBLIC_KEY',
            'AIM_QUALIFICATION_NSXPC', 'AIM_ENABLE_VIRTUALIZATION', 'AIM_PROVIDER_API_KEY',
            'AIM_UNKNOWN_FUTURE_FLAG', 'BASH_ENV', 'ENV', 'ZDOTDIR', 'DEVELOPER_DIR',
            'SWIFT_EXEC', 'DYLD_INSERT_LIBRARIES', 'PYTHONPATH', 'PATH',
        )}
        with mock.patch.dict(os.environ, pollution):
            self.invoke()
        env = self.build_environment()
        self.assertEqual(env['AIM_RELEASE_BUILD'], '77')
        self.assertEqual(env['AIM_APP_OUTPUT'], str(self.output))
        self.assertEqual(env['PATH'], '/usr/bin:/bin:/usr/sbin:/sbin')
        for _, kwargs in self.calls:
            self.assertNotIn('AMBIENT_MUST_NOT_REACH_CHILD', kwargs['env'].values())
        for name in ('AIM_PUBLIC_CONFIG_PLIST', 'AIM_QUALIFICATION_NSXPC', 'AIM_ENABLE_VIRTUALIZATION',
                     'AIM_UNKNOWN_FUTURE_FLAG', 'AIM_PROVIDER_API_KEY', 'AIM_SUPABASE_PUBLIC_KEY'):
            self.assertNotIn(name, env)

    def test_reference_mode_strict_signature_and_historical_paths(self):
        reference = self.reference({'AIMSupabaseURL': 'https://reference.example',
                                    'AIMSupabasePublicKey': 'sb_publishable_reference'})
        self.invoke(reference)
        env = self.build_environment()
        self.assertEqual(self.calls[1][0], ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(reference)])
        self.assertEqual(env['AIM_NODE_RUNTIME'], str(reference / 'Contents/Resources/Playwright/node'))
        self.assertEqual(env['AIM_CUA_DRIVER_PATH'], str(self.root / 'build/driver-qualification/cua-driver-rs-0.28.2-darwin-arm64/cua-driver'))
        self.assertEqual(env['AIM_SUPABASE_PUBLIC_KEY'], 'sb_publishable_reference')

    def test_reference_mode_backend_can_be_absent(self):
        self.invoke(self.reference())
        self.assertNotIn('AIM_SUPABASE_URL', self.build_environment())

    def test_reference_signature_failure_prevents_build_or_plist_read(self):
        reference = self.reference()
        (reference / 'Contents/Info.plist').write_bytes(b'invalid plist; must not be read')
        self.signature_fails = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke(reference)
        self.assertFalse(self.marker.exists())
        self.assertEqual(len(self.calls), 2)

    def test_reference_active_guard_failure_precedes_signature_and_data_read(self):
        reference = self.reference()
        (reference / 'Contents/Info.plist').write_bytes(b'invalid; guard must run first')
        self.guard_fails = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke(reference)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][0][2:4], ['guard', '--all-aim'])
        self.assertFalse(self.marker.exists())

    def test_reference_partial_or_privileged_backend_is_refused(self):
        reference = self.reference()
        for info in ({'AIMSupabaseURL': 'https://reference.example'},
                     {'AIMSupabaseURL': 'https://reference.example',
                      'AIMSupabasePublicKey': self.synthetic_privileged_key(label='SYNTHETIC')}):
            with self.subTest(fields=sorted(info)):
                (reference / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                with self.assertRaises(ValueError):
                    self.invoke(reference)
                self.assertFalse(self.marker.exists())
        self.assertFalse(any(command[0] == '/usr/bin/security' for command, _ in self.calls))

    def test_reference_mode_cannot_mix_explicit_inputs(self):
        reference = self.reference()
        for key in ('runtime_inputs', 'notices', 'public_supabase'):
            with self.subTest(key=key):
                self.config[key] = {}
                with self.assertRaisesRegex(ValueError, 'cannot mix'):
                    self.invoke(reference)
                del self.config[key]
                self.run.assert_not_called()

    def test_invalid_release_and_private_feed_are_refused_before_processes(self):
        original = copy.deepcopy(self.config)
        for key, value in (('application_build', '0'), ('application_version', 'review'),
                           ('sparkle_feed_url', self.synthetic_credential_url('example.com', '/feed')),
                           ('sparkle_feed_url', 'https://example.com/feed?secret=synthetic'),
                           ('sparkle_public_key', 'not-base64'), ('sparkle_account', '-new-account')):
            with self.subTest(key=key):
                self.config = copy.deepcopy(original)
                self.config[key] = value
                self.refused_without_processes()


    def test_fresh_explicit_scratch_is_passed_as_argument_and_guarded(self):
        scratch = self.root / 'build/fresh-swift'
        self.invoke(scratch=scratch)
        self.assertEqual(self.calls[0][0][-1], str(scratch))
        self.assertEqual(self.calls[-1][0][-2:], ['--swift-scratch', str(scratch)])
        self.assertNotIn('AIM_SWIFT_SCRATCH', self.build_environment())

    def test_existing_symlink_outside_relative_and_app_scratch_refused(self):
        self.output.parent.mkdir()
        existing = self.output.parent / 'existing'
        existing.mkdir()
        link = self.output.parent / 'link'
        link.symlink_to(self.root / 'missing')
        for scratch in (existing, link, self.root / 'outside', pathlib.Path('build/relative'), self.root / 'build/X.app'):
            with self.subTest(scratch=scratch):
                with self.assertRaisesRegex(ValueError, 'scratch'):
                    self.invoke(scratch=scratch)
                self.run.assert_not_called()

    def test_scratch_appearing_during_preflight_refused(self):
        scratch = self.root / 'build/fresh'
        def appear():
            scratch.mkdir(parents=True)
        self.key_hook = appear
        with self.assertRaisesRegex(ValueError, 'scratch'):
            self.invoke(scratch=scratch)
        self.assertFalse(self.marker.exists())

    def test_ambient_scratch_is_discarded(self):
        with mock.patch.dict(os.environ, {'AIM_SWIFT_SCRATCH': '/SYNTHETIC_UNREVIEWED'}):
            self.invoke()
        self.assertNotIn('AIM_SWIFT_SCRATCH', self.build_environment())
        self.assertEqual(len(self.calls[-1][0]), 4)

    def reviewed_tool(self, version='2.10.0'):
        tool = self.file('tools/Sparkle/bin/generate_keys', executable=True)
        self.file('Package.resolved', json.dumps({'pins': [{'identity': 'sparkle', 'state': {'version': '2.10.0'}}]}).encode())
        self.file('tools/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Resources/Info.plist',
                  plistlib.dumps({'CFBundleShortVersionString': version}))
        self.config['sparkle_key_tool'] = {'path': str(tool), 'sha256': hashlib.sha256(tool.read_bytes()).hexdigest()}
        return tool

    def test_reviewed_sparkle_tool_matches_hash_and_pin(self):
        tool = self.reviewed_tool()
        self.invoke()
        self.assertIn([str(tool), '--account', 'synthetic-only', '-p'], [c for c, _ in self.calls])

    def test_reviewed_sparkle_tool_wrong_hash_or_version_refused(self):
        tool = self.reviewed_tool()
        tool.write_text('changed')
        self.refused_without_processes('hash mismatch')
        self.reviewed_tool(version='2.9.0')
        self.refused_without_processes('Package.resolved pin')

    def test_frozen_inputs_are_checked_after_guard_and_after_build(self):
        frozen = self.file('frozen.json', b'{}')
        observations = []
        def verify_inputs(manifest, configuration):
            self.assertEqual((manifest, configuration), (frozen, self.configuration))
            observations.append((len(self.calls), self.marker.exists()))
        with mock.patch.object(builder, 'verify_frozen_inputs', side_effect=verify_inputs):
            self.invoke(manifest=frozen)
        self.assertEqual(observations[0], (1, False))
        self.assertEqual(observations[1], (len(self.calls), True))

    def test_frozen_input_drift_prevents_credentials_and_build(self):
        frozen = self.file('frozen.json', b'{}')
        with mock.patch.object(builder, 'verify_frozen_inputs', side_effect=ValueError('Native binary input changed')):
            with self.assertRaisesRegex(ValueError, 'Native binary input changed'):
                self.invoke(manifest=frozen)
        self.assertEqual(len(self.calls), 1)  # unchanged all-AIM guard only
        self.assertFalse(self.marker.exists())

    def test_frozen_input_drift_after_build_is_not_success(self):
        frozen = self.file('frozen.json', b'{}')
        with mock.patch.object(builder, 'verify_frozen_inputs', side_effect=[None, ValueError('Source changed')]):
            with self.assertRaisesRegex(ValueError, 'Source changed'):
                self.invoke(manifest=frozen)
        self.assertTrue(self.marker.exists())  # mock build ran, but was rejected

if __name__ == '__main__':
    unittest.main()
