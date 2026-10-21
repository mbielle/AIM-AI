"""Offline synthetic integrity, extraction, graph and pre-signature copy contracts."""
import copy
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import plistlib
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('prepare_runtimes', pathlib.Path(__file__).with_name('prepare-runtime-inputs.py'))
prep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prep)


class RuntimeInputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='synthetic-runtime-', dir='/private/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.modules = self.root / 'modules'
        for name, version in prep.PACKAGES.items():
            package = self.modules / name
            package.mkdir(parents=True)
            deps = {'@playwright/mcp': {'playwright': prep.PACKAGES['playwright'], 'playwright-core': prep.PACKAGES['playwright-core']},
                    'playwright': {'playwright-core': prep.PACKAGES['playwright-core']}, 'playwright-core': {}}[name]
            (package / 'package.json').write_text(json.dumps({'name': name, 'version': version, 'dependencies': deps}))
            (package / 'LICENSE').write_bytes(b'Synthetic upstream license, never real source text. ' * 8)
        (self.modules / '@playwright/mcp/cli.js').write_text('// synthetic CLI never executed')
        self.node = self.root / 'node'
        self.node.write_text('synthetic executable never run')
        self.node.chmod(0o755)
        self.license = self.root / 'NODE-LICENSE'
        self.license.write_bytes(b'Synthetic Node license, never real source text. ' * 8)
        self.output = self.root / 'Synthetic.app/Contents/Resources/Playwright'

    def archive(self, names):
        path = self.root / 'fixture.tar.gz'
        with tarfile.open(path, 'w:gz') as tar:
            for name, kind, link in names:
                member = tarfile.TarInfo(name)
                member.type = kind
                member.linkname = link
                member.size = 8 if kind == tarfile.REGTYPE else 0
                tar.addfile(member, io.BytesIO(b'fixture!') if member.size else None)
        return path

    def test_hash_rejects_tampering(self):
        prep.verify_hash(self.license, hashlib.sha256(self.license.read_bytes()).hexdigest())
        with self.assertRaisesRegex(ValueError, 'integrity'):
            prep.verify_hash(self.license, '0' * 64)

    def test_safe_extraction(self):
        archive = self.archive([('safe/LICENSE', tarfile.REGTYPE, '')])
        prep.extract(archive, self.root / 'extracted')
        self.assertEqual((self.root / 'extracted/safe/LICENSE').read_bytes(), b'fixture!')

    def test_extraction_rejects_traversal_absolute_links_devices_duplicates_before_write(self):
        for records in ([('../escape', tarfile.REGTYPE, '')], [('/escape', tarfile.REGTYPE, '')],
                        [('link', tarfile.SYMTYPE, '../escape')], [('link', tarfile.LNKTYPE, 'safe')],
                        [('device', tarfile.CHRTYPE, '')], [('same', tarfile.REGTYPE, ''), ('same', tarfile.REGTYPE, '')]):
            with self.subTest(records=records):
                archive = self.archive(records)
                destination = self.root / 'rejected'
                with self.assertRaises(ValueError):
                    prep.extract(archive, destination)
                self.assertFalse(destination.exists())

    def test_selected_node_extraction_skips_safe_unneeded_links(self):
        archive = self.archive([('node/bin/node', tarfile.REGTYPE, ''), ('node/bin/npm', tarfile.SYMTYPE, '../lib/npm.js')])
        prep.extract(archive, self.root / 'selected', {'node/bin/node'})
        self.assertTrue((self.root / 'selected/node/bin/node').is_file())
        self.assertFalse((self.root / 'selected/node/bin/npm').exists())

    def test_selected_extraction_still_rejects_escaping_links(self):
        for target in ('../../../outside', '../../..'):
            with self.subTest(target=target):
                archive = self.archive([('node/bin/node', tarfile.REGTYPE, ''), ('node/bin/npm', tarfile.SYMTYPE, target)])
                with self.assertRaises(ValueError):
                    prep.extract(archive, self.root / 'selected', {'node/bin/node'})

    def test_existing_or_symlink_destinations_are_preserved(self):
        for destination in (self.modules, self.root / 'link'):
            if destination.name == 'link':
                destination.symlink_to(self.root / 'missing')
            with self.assertRaises(ValueError):
                prep.copy_resources(self.node, self.license, self.modules, destination)
        self.assertTrue((self.modules / '@playwright/mcp/cli.js').is_file())

    def test_external_symlink_is_refused_before_copy(self):
        (self.modules / 'escape').symlink_to(self.license)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            prep.copy_resources(self.node, self.license, self.modules, self.output)
        self.assertFalse(self.output.exists())

    def test_copy_materializes_safe_file_symlink_and_notices_before_signature(self):
        (self.modules / 'safe-license').symlink_to('@playwright/mcp/LICENSE')
        inventory = prep.copy_resources(self.node, self.license, self.modules, self.output)
        def simulated_signature(bundle):
            self.assertTrue((bundle / 'NODE-LICENSE').is_file())
            self.assertTrue((bundle / 'runtime-notices.json').is_file())
            self.assertEqual(len(inventory['notices']), 3)
            self.assertFalse(any(p.is_symlink() for p in bundle.rglob('*')))
        simulated_signature(self.output)
        self.assertEqual((self.output / 'NODE-LICENSE').read_bytes(), self.license.read_bytes())
        self.assertEqual(prep.validate_modules(self.output / 'node_modules'), inventory['notices'])

    def test_missing_or_empty_node_license_blocks_simulated_signature(self):
        for contents in (b'', b'short'):
            self.license.write_bytes(contents)
            with self.assertRaisesRegex(ValueError, 'Node license'):
                prep.copy_resources(self.node, self.license, self.modules, self.output)
            self.assertFalse(self.output.exists())

    def test_missing_node_executable_refused(self):
        self.node.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'Executable Node'):
            prep.copy_resources(self.node, self.license, self.modules, self.output)

    def test_wrong_package_version_or_graph_is_refused(self):
        manifest = self.modules / 'playwright/package.json'
        original = json.loads(manifest.read_text())
        for field, value in (('version', 'wrong'), ('dependencies', {'unlocked': '1.0.0'})):
            changed = dict(original, **{field: value})
            manifest.write_text(json.dumps(changed))
            with self.assertRaises(ValueError):
                prep.validate_modules(self.modules)
        manifest.write_text(json.dumps(original))

    def test_missing_locked_package_or_notice_is_refused(self):
        license_path = self.modules / 'playwright/LICENSE'
        license_path.unlink()
        with self.assertRaisesRegex(ValueError, 'license'):
            prep.validate_modules(self.modules)
        (self.modules / 'playwright/package.json').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing frozen'):
            prep.validate_modules(self.modules)

    def test_additional_package_is_refused(self):
        extra = self.modules / 'unlocked'
        extra.mkdir()
        (extra / 'package.json').write_text(json.dumps({'name': 'unlocked', 'version': '1.0.0'}))
        with self.assertRaisesRegex(ValueError, 'outside frozen'):
            prep.validate_modules(self.modules)

    def test_tampered_notice_receipt_is_refused(self):
        notices = prep.validate_modules(self.modules)
        (self.modules / '.aim-runtime-manifest.json').write_text(json.dumps({'packages': prep.PACKAGES, 'notices': notices, 'tree_sha256': prep.module_tree_digest(self.modules)}))
        (self.modules / 'playwright/LICENSE').write_text('Changed synthetic license. ' * 10)
        with self.assertRaisesRegex(ValueError, 'receipt mismatch'):
            prep.copy_resources(self.node, self.license, self.modules, self.output)
        self.assertFalse(self.output.exists())

    def test_tampered_javascript_is_refused(self):
        receipt = {'packages': prep.PACKAGES, 'notices': prep.validate_modules(self.modules),
                   'tree_sha256': prep.module_tree_digest(self.modules)}
        (self.modules / '.aim-runtime-manifest.json').write_text(json.dumps(receipt))
        (self.modules / '@playwright/mcp/cli.js').write_text('// altered synthetic JavaScript')
        with self.assertRaisesRegex(ValueError, 'receipt mismatch'):
            prep.validate_modules(self.modules)

    def test_redirects_reject_downgrade_and_unofficial_origin(self):
        handler = prep.OfficialRedirects()
        request = prep.urllib.request.Request('https://nodejs.org/pinned-archive')
        for url in ('http://nodejs.org/archive', 'https://synthetic.example/archive',
                    'https://nodejs.org.synthetic.example/archive'):
            with self.subTest(url=url):
                with self.assertRaises(ValueError):
                    handler.redirect_request(request, None, 302, 'redirect', {}, url)
        approved = handler.redirect_request(request, None, 302, 'redirect', {}, 'https://nodejs.org/official')
        self.assertEqual(approved.full_url, 'https://nodejs.org/official')

    def test_acquisition_source_rejects_untrusted_origin(self):
        with self.assertRaises(ValueError):
            prep.fetch('https://synthetic.example/archive', self.root / 'file')

    def test_node_os_architecture_dependencies_and_version_are_checked(self):
        good_arch = 'synthetic: Mach-O 64-bit executable arm64'
        good_libs = 'synthetic:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n'
        for arch, libs, version, passes in (
                (good_arch, good_libs, 'v' + prep.NODE_VERSION, True),
                ('ELF executable arm64', good_libs, '', False),
                ('Mach-O 64-bit executable x86_64', good_libs, '', False),
                (good_arch, 'synthetic:\n /opt/unbundled/libnode.dylib', '', False),
                (good_arch, good_libs, 'v0.0.0', False)):
            with self.subTest(arch=arch, passes=passes):
                with mock.patch.object(prep.subprocess, 'run', side_effect=[
                        subprocess.CompletedProcess([], 0, stdout=arch),
                        subprocess.CompletedProcess([], 0, stdout=libs),
                        subprocess.CompletedProcess([], 0, stdout=version)]) as run:
                    if passes:
                        prep.validate_node(self.node)
                        self.assertEqual(run.call_args.kwargs['env'], {'PATH': '/usr/bin:/bin'})
                    else:
                        with self.assertRaises(ValueError):
                            prep.validate_node(self.node)

    def test_directory_symlink_cycle_is_refused(self):
        (self.modules / 'cycle').symlink_to('.')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            prep.validate_modules(self.modules)

    def prepare_fixture(self, mutate_lock=False, installation_fails=False):
        source_root = self.root / 'fixture-source'
        vendor = source_root / 'Vendor/PlaywrightMCP'
        vendor.mkdir(parents=True)
        (vendor / 'package.json').write_text('{"private":true}')
        (vendor / 'pnpm-lock.yaml').write_text('synthetic frozen lock\n')
        archive_data = {}
        def make_tar(files):
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode='w:gz') as tar:
                for name, data in files.items():
                    member = tarfile.TarInfo(name)
                    member.size, member.mode = len(data), 0o755
                    tar.addfile(member, io.BytesIO(data))
            return buffer.getvalue()
        node_name = 'node-v' + prep.NODE_VERSION + '-darwin-arm64'
        archive_data['node'] = make_tar({node_name + '/bin/node': b'synthetic never executed',
                                         node_name + '/LICENSE': self.license.read_bytes()})
        archive_data['pnpm'] = make_tar({'package/bin/pnpm.cjs': b'// synthetic never executed'})
        import base64
        integrity = 'sha512-' + base64.b64encode(hashlib.sha512(archive_data['pnpm']).digest()).decode()
        def fake_fetch(url, destination):
            if url.endswith('SHASUMS256.txt'):
                data = (hashlib.sha256(archive_data['node']).hexdigest() + '  ' + node_name + '.tar.gz\n').encode()
            elif url.endswith('.sig'):
                data = b'synthetic unauthenticated signature'
            elif url.endswith(node_name + '.tar.gz'):
                data = archive_data['node']
            elif url.endswith('/pnpm/' + prep.PNPM_VERSION):
                data = json.dumps({'version': prep.PNPM_VERSION, 'dist': {'integrity': integrity,
                                  'tarball': 'https://registry.npmjs.org/pnpm/-/pnpm-fixture.tgz'}}).encode()
            else:
                data = archive_data['pnpm']
            pathlib.Path(destination).write_bytes(data)
        calls = []
        def fake_run(command, **kwargs):
            calls.append((command, kwargs))
            if 'install' in command:
                self.assertIn('--frozen-lockfile', command)
                self.assertIn('--ignore-scripts', command)
                self.assertIn('--node-linker=hoisted', command)
                env = kwargs['env']
                self.assertEqual(env['PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD'], '1')
                self.assertEqual(env['npm_config_ignore_scripts'], 'true')
                for name in ('NODE_OPTIONS', 'AIM_NODE_RUNTIME', 'NPM_CONFIG_REGISTRY', 'ENV', 'BASH_ENV'):
                    self.assertNotIn(name, env)
                if installation_fails:
                    raise subprocess.CalledProcessError(1, command)
                import shutil
                shutil.copytree(self.modules, pathlib.Path(kwargs['cwd']) / 'node_modules')
                if mutate_lock:
                    (pathlib.Path(kwargs['cwd']) / 'pnpm-lock.yaml').write_text('mutation refused')
            return subprocess.CompletedProcess(command, 0)
        with mock.patch.object(prep, 'ROOT', source_root), mock.patch.object(prep, 'fetch', side_effect=fake_fetch), \
             mock.patch.object(prep, 'validate_node', return_value=('synthetic arm64', 'synthetic system dylibs')), \
             mock.patch.object(prep.subprocess, 'run', side_effect=fake_run), \
             mock.patch.dict(os.environ, {'NODE_OPTIONS': 'synthetic hostile', 'NPM_CONFIG_REGISTRY': 'synthetic hostile'}):
            result = prep.prepare(self.root / 'prepared')
        self.assertEqual((vendor / 'pnpm-lock.yaml').read_text(), 'synthetic frozen lock\n')
        return result, calls

    def test_prepare_uses_isolated_environment_frozen_lock_and_disables_scripts_browsers(self):
        receipt, calls = self.prepare_fixture()
        self.assertFalse(receipt['node_signature_authenticated'])
        self.assertTrue((self.root / 'prepared/receipt.json').is_file())
        self.assertTrue((self.root / 'prepared/synthetic.app/Contents/Resources/Playwright/NODE-LICENSE').is_file())
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[-1][0][-1], '--version')

    def test_prepare_refuses_lock_mutation_without_publishing_receipt(self):
        with self.assertRaisesRegex(ValueError, 'frozen lock changed'):
            self.prepare_fixture(mutate_lock=True)
        self.assertFalse((self.root / 'prepared/receipt.json').exists())
        self.assertFalse((self.root / 'prepared/synthetic.app').exists())

    def test_prepare_propagates_frozen_install_failure_without_receipt(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare_fixture(installation_fails=True)
        self.assertFalse((self.root / 'prepared/receipt.json').exists())

    def test_mlx_inventory_rejects_missing_checkout(self):
        checkouts = self.root / 'checkouts'
        checkouts.mkdir()
        lock = self.root / 'Package.resolved'
        lock.write_text(json.dumps({'pins': [{'identity': 'missing', 'state': {'revision': 'fake'}}]}))
        with self.assertRaisesRegex(ValueError, 'Missing exact'):
            prep.inventory_mlx(checkouts, lock, self.root / 'licenses')

    def metal_fixture(self, status='installed', wrong_identifier=False, cpu_tool=False):
        search = self.root / 'metal-component'
        toolchain = search / 'Metal.xctoolchain'
        binary = toolchain / 'usr/bin/metal'
        binary.parent.mkdir(parents=True)
        binary.write_text('synthetic Metal compiler never executed')
        binary.chmod(0o755)
        identifier = 'com.apple.dt.toolchain.Metal.synthetic'
        (toolchain / 'ToolchainInfo.plist').write_bytes(plistlib.dumps({'Identifier': 'wrong' if wrong_identifier else identifier}))
        if cpu_tool:
            (binary.parent / 'clang').write_text('synthetic forbidden CPU override')
        component = {'status': status, 'toolchainIdentifier': identifier, 'toolchainSearchPath': str(search)}
        return component, binary

    def test_installed_metal_is_selected_locally_without_install_or_cpu_replacement(self):
        component, binary = self.metal_fixture()
        with mock.patch.object(prep.subprocess, 'run', side_effect=[
                subprocess.CompletedProcess([], 0, stdout=json.dumps(component)),
                subprocess.CompletedProcess([], 0, stdout='Apple metal version synthetic')]) as run:
            receipt = prep.installed_metal_toolchain()
        self.assertEqual(run.call_args_list[0].args[0], ['/usr/bin/xcodebuild', '-showComponent', 'MetalToolchain', '-json'])
        self.assertEqual(run.call_args_list[1].args[0], [str(binary), '--version'])
        self.assertEqual(receipt['environment'], {'__XCODE_BUILT_PRODUCTS_DIR_PATHS': str(binary.parent)})
        self.assertEqual(receipt['metal_sha256'], prep.digest(binary))

    def test_metal_rejects_missing_component_mismatch_or_cpu_override(self):
        for status, mismatch, cpu in (('absent', False, False), ('installed', True, False), ('installed', False, True)):
            with self.subTest(status=status, mismatch=mismatch, cpu=cpu):
                import shutil
                shutil.rmtree(self.root / 'metal-component', ignore_errors=True)
                component, _ = self.metal_fixture(status, mismatch, cpu)
                with mock.patch.object(prep.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=json.dumps(component))) as run:
                    with self.assertRaises(ValueError):
                        prep.installed_metal_toolchain()
                    self.assertEqual(run.call_count, 1)

    def test_engine_command_preserves_frozen_graph_isolation_and_disables_signing(self):
        output = self.root / 'engine-build'
        output.mkdir()
        metal_environment = {'__XCODE_BUILT_PRODUCTS_DIR_PATHS': '/synthetic/metal/bin'}
        hostile = {name: 'synthetic hostile override' for name in ('SWIFT_EXEC', 'SDKROOT', 'CPATH', 'LIBRARY_PATH', 'DYLD_LIBRARY_PATH', 'SWIFTCI_USE_LOCAL_DEPS', 'DEVELOPER_DIR')}
        with mock.patch.object(prep, 'installed_metal_toolchain', return_value={'environment': metal_environment}), \
             mock.patch.object(prep.subprocess, 'run') as run, mock.patch.dict(os.environ, hostile):
            receipt = prep.compile_mlx(output)
        command = run.call_args.args[0]
        self.assertEqual(command, ['/usr/bin/xcodebuild', '-scheme', 'AIMMLXEngine', '-destination', 'platform=macOS,arch=arm64',
                                  '-configuration', 'Release', '-derivedDataPath', str(output / 'dd'),
                                  '-clonedSourcePackagesDirPath', str(output / 'SourcePackages'),
                                  '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile',
                                  '-skipMacroValidation', '-skipPackagePluginValidation', 'CODE_SIGNING_ALLOWED=NO', 'build', '-quiet'])
        self.assertEqual(run.call_args.kwargs['cwd'], output / 'source')
        self.assertEqual(run.call_args.kwargs['env']['__XCODE_BUILT_PRODUCTS_DIR_PATHS'], '/synthetic/metal/bin')
        for name in hostile:
            self.assertNotIn(name, run.call_args.kwargs['env'])
        self.assertEqual(run.call_args.kwargs['env']['GIT_CONFIG_GLOBAL'], '/dev/null')
        self.assertEqual(run.call_args.kwargs['env']['CFFIXED_USER_HOME'], str(output / 'home'))
        self.assertEqual(run.call_args.kwargs['env']['TMPDIR'], str(output / 'tmp'))
        self.assertEqual(receipt['command'], command)
        self.assertTrue((output / 'metal-toolchain.json').is_file())
        with mock.patch.object(prep, 'installed_metal_toolchain', return_value={'environment': metal_environment}), \
             mock.patch.object(prep.subprocess, 'run') as run:
            with self.assertRaises(FileExistsError):
                prep.compile_mlx(output)
            run.assert_not_called()

    def mlx_fixture(self):
        checkouts = self.root / 'checkouts'
        mlx = checkouts / 'mlx-swift'
        files = ['LICENSE', 'ACKNOWLEDGMENTS.md', 'Source/Cmlx/mlx/LICENSE',
                 'Source/Cmlx/mlx/ACKNOWLEDGMENTS.md', 'Source/Cmlx/mlx-c/LICENSE',
                 'Source/Cmlx/mlx-c/ACKNOWLEDGMENTS.md', 'Source/Cmlx/fmt/LICENSE',
                 'Source/Cmlx/json/LICENSE.MIT', 'Source/Cmlx/metal-cpp/LICENSE.txt']
        for name in files:
            path = mlx / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(('Synthetic exact source notice for ' + name + '. ').encode() * 8)
        lock = self.root / 'Package.resolved'
        lock.write_text(json.dumps({'pins': [{'identity': 'mlx-swift', 'location': 'https://source.example/synthetic-mlx',
                                            'state': {'revision': 'synthetic-parent-revision'}}]}))
        def git(command, **kwargs):
            name = pathlib.Path(command[2]).name
            revision = {'mlx-swift': 'synthetic-parent-revision',
                        'mlx': '1f8e74e3f12f31365464a6867c6579f0e9b29d85',
                        'mlx-c': 'ebc88f10caa1b625e6b581437a8dea6df8a70085'}[name]
            return subprocess.CompletedProcess(command, 0, stdout=revision + '\n')
        return checkouts, lock, git

    def test_mlx_wrong_pin_is_refused(self):
        checkouts, lock, _ = self.mlx_fixture()
        with mock.patch.object(prep.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='wrong')):
            with self.assertRaisesRegex(ValueError, 'revision differs'):
                prep.inventory_mlx(checkouts, lock, self.root / 'licenses')

    def test_mlx_inventory_preserves_exact_notices_child_provenance_and_stays_incomplete(self):
        checkouts, lock, git = self.mlx_fixture()
        before = {str(p.relative_to(checkouts)): p.read_bytes() for p in checkouts.rglob('*') if p.is_file()}
        with mock.patch.object(prep.subprocess, 'run', side_effect=git):
            inventory = prep.inventory_mlx(checkouts, lock, self.root / 'licenses')
        self.assertFalse(inventory['complete'])
        self.assertEqual(len(inventory['embedded_sources']), 5)
        for record in inventory['components'][0]['licenses']:
            source = checkouts / 'mlx-swift' / record['upstream_path']
            self.assertEqual((self.root / 'licenses' / record['path']).read_bytes(), source.read_bytes())
            if record['upstream_path'].startswith('Source/Cmlx/mlx/'):
                self.assertEqual(record['source_revision'], '1f8e74e3f12f31365464a6867c6579f0e9b29d85')
        after = {str(p.relative_to(checkouts)): p.read_bytes() for p in checkouts.rglob('*') if p.is_file()}
        self.assertEqual(after, before)

    def test_missing_embedded_notice_cannot_complete_inventory(self):
        checkouts, lock, git = self.mlx_fixture()
        (checkouts / 'mlx-swift/Source/Cmlx/metal-cpp/LICENSE.txt').unlink()
        with mock.patch.object(prep.subprocess, 'run', side_effect=git):
            with self.assertRaisesRegex(ValueError, 'Missing declared embedded'):
                prep.inventory_mlx(checkouts, lock, self.root / 'licenses')
        self.assertFalse((self.root / 'licenses/manifest.json').exists())

    def test_mlx_notice_snapshot_verifies_frozen_lock_before_compile(self):
        source = self.root / 'source'
        source.mkdir()
        notices = self.root / 'reviewed-notices'
        notices.mkdir()
        text = notices / 'LICENSE'
        text.write_bytes(b'Synthetic full exact license text. ' * 8)
        pin = {'identity': 'synthetic-pin', 'state': {'revision': 'synthetic-revision'}}
        (source / 'Package.resolved').write_text(json.dumps({'pins': [pin]}))
        manifest = {'complete': True, 'components': [{'identity': 'synthetic-pin', 'revision': 'synthetic-revision',
                    'source': 'https://source.example/synthetic',
                    'licenses': [{'path': 'LICENSE', 'sha256': prep.digest(text)}]}]}
        (notices / 'manifest.json').write_text(json.dumps(manifest))
        snapshot = prep.snapshot_mlx_notices(source, notices)
        self.assertEqual((snapshot / 'LICENSE').read_bytes(), text.read_bytes())
        text.write_bytes(b'External source changed after snapshot. ' * 8)
        self.assertNotEqual((snapshot / 'LICENSE').read_bytes(), text.read_bytes())
        with self.assertRaises(FileExistsError):
            prep.snapshot_mlx_notices(source, notices)

    def test_missing_or_incomplete_declared_mlx_notices_are_refused(self):
        source = self.root / 'source'
        source.mkdir()
        with self.assertRaisesRegex(ValueError, 'Declared MLX notices'):
            prep.snapshot_mlx_notices(source, self.root / 'missing')
        notices = self.root / 'notices'
        notices.mkdir()
        (source / 'Package.resolved').write_text('{"pins":[]}')
        (notices / 'manifest.json').write_text('{"complete":false}')
        with self.assertRaisesRegex(ValueError, 'reviewed as complete'):
            prep.snapshot_mlx_notices(source, notices)

    def test_new_output_rejects_symlink_ancestor(self):
        target = self.root / 'real'
        target.mkdir()
        link = self.root / 'linked'
        link.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'symlink ancestors'):
            prep.new_directory(link / 'new-output')
        self.assertFalse((target / 'new-output').exists())


if __name__ == '__main__':
    unittest.main()
