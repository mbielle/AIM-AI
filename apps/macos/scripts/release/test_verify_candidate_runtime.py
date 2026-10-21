"""Disposable offline contracts; commands mocked, no app/Keychain/network execution."""
import copy
import hashlib
import importlib.util
import json
import pathlib
import plistlib
import struct
import shutil
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('candidate_runtime', pathlib.Path(__file__).with_name('verify-candidate-runtime.py'))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
EVIDENCE = verifier.ROOT.parents[1] / 'build/qa-jalon3-candidat-mac-20261020/agent'


def thin_macho(payload=b'fixture code'):
    # One arm64 __TEXT,__text section; signature/header changes do not alter it.
    segment_size = 152
    header = struct.pack('<IIIIIIII', 0xfeedfacf, 0x0100000c, 0, 2, 1, segment_size, 0, 0)
    offset = len(header) + segment_size
    segment = struct.pack('<II16sQQQQIIII', 0x19, segment_size, b'__TEXT', 0, 4096, 0, offset + len(payload), 7, 5, 1, 0)
    section = struct.pack('<16s16sQQIIIIIIII', b'__text', b'__TEXT', 0x1000, len(payload), offset, 0, 0, 0, 0, 0, 0, 0)
    return header + segment + section + payload


class CandidateRuntimeTests(unittest.TestCase):
    def setUp(self):
        EVIDENCE.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='runtime-fixture-', dir=EVIDENCE)
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.app = self.root / 'Candidate.app'
        self.main = self.file('Candidate.app/Contents/MacOS/AIMMac', thin_macho())
        self.lib = self.file('Candidate.app/Contents/Frameworks/libFixture.dylib', thin_macho())
        self.file('packages/AIMDirectNative/Artifacts/AIMDataChannel.xcframework/Info.plist', plistlib.dumps({'AvailableLibraries': []}))
        self.native_binary = self.file('packages/AIMDirectNative/Artifacts/AIMDataChannel.xcframework/macos/fixture.a', b'fixture archive')
        self.file('packages/AIMDirectNative/Artifacts/build-receipt.json', b'{"fixture": true}')
        self.file('packages/AIMDirectNative/dependencies.lock.json', b'{"fixture": true}')
        self.meta = {
            self.main: self.metadata(deps=['@rpath/libFixture.dylib'], rpaths=['@executable_path/../Frameworks'], executable=True),
            self.lib: self.metadata(deps=['/usr/lib/libSystem.B.dylib']),
        }

    def file(self, path, data=b'fixture'):
        result = self.root / path
        result.parent.mkdir(parents=True, exist_ok=True)
        result.write_bytes(data)
        return result

    def metadata(self, deps=(), rpaths=(), executable=False):
        return {'architectures': ['arm64'], 'minimum_os': ['14.0'], 'rpaths': list(rpaths),
                'dependencies': list(deps), 'install_id': None, 'executable': executable}

    def graph(self):
        with mock.patch.object(verifier, 'inspect', side_effect=lambda path, arch: self.meta[path]):
            return verifier.graph(self.app)

    def test_recursive_bundled_graph_and_system_limit_are_explicit(self):
        graph = self.graph()
        self.assertEqual(len(graph['objects']), 2)
        self.assertEqual(graph['macos14_execution'], 'not_verified')
        self.assertIn('system-unverified-on-macos14', [edge['resolution'] for edge in graph['edges']])

    def test_missing_library_cannot_be_hidden_by_system_runpath(self):
        self.lib.unlink()
        self.meta[self.main]['rpaths'].insert(0, '/usr/lib/swift')
        with self.assertRaisesRegex(ValueError, 'Missing or nonresolving'):
            self.graph()

    def test_nonresolving_and_development_rpath_are_refused(self):
        for value, message in [('relative/lib', 'Nonresolving rpath'), ('/Developer/FixtureXcode.app/build', 'External development rpath'),
                               ('@executable_path/../../../../cache', 'External development rpath')]:
            with self.subTest(value=value):
                self.meta[self.main]['rpaths'] = [value]
                with self.assertRaisesRegex(ValueError, message):
                    self.graph()

    def test_absolute_development_dependency_is_refused(self):
        self.meta[self.main]['dependencies'] = ['/private/tmp/fixture.dylib']
        with self.assertRaisesRegex(ValueError, 'External development dependency'):
            self.graph()

    def test_recursive_loader_and_inherited_executable_runpaths(self):
        child = self.file('Candidate.app/Contents/Frameworks/libChild.dylib', thin_macho())
        self.meta[self.lib]['dependencies'] = ['@loader_path/libChild.dylib']
        self.meta[child] = self.metadata(deps=['@rpath/libFixture.dylib'])
        self.assertEqual(len(self.graph()['objects']), 3)  # cycle terminates

    def test_helper_has_own_executable_context(self):
        helper = self.file('Candidate.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper', thin_macho())
        self.meta[helper] = self.metadata(deps=['@rpath/libFixture.dylib'], executable=True)
        with self.assertRaisesRegex(ValueError, 'Missing or nonresolving'):
            self.graph()
        self.meta[helper]['rpaths'] = ['@executable_path/../../../../../Frameworks']
        self.graph()

    def test_too_new_minimum_os_is_refused(self):
        self.meta[self.lib]['minimum_os'] = ['14.1']
        with self.assertRaisesRegex(ValueError, 'Minimum OS exceeds'):
            self.graph()

    def test_architecture_and_platform_load_commands(self):
        commands = '''fixture:
Load command 0
      cmd LC_BUILD_VERSION
 platform 1
    minos 14.0
Load command 1
      cmd LC_BUILD_VERSION
 platform 6
    minos 19.0
Load command 2
      cmd LC_RPATH
     path @loader_path/lib (offset 12)
Load command 3
      cmd LC_ID_DYLIB
     name @rpath/libFixture.dylib (offset 24)
Load command 4
      cmd LC_LOAD_WEAK_DYLIB
     name /usr/lib/libSystem.B.dylib (offset 24)
'''
        with mock.patch.object(verifier, 'command', side_effect=['arm64 x86_64', commands]):
            result = verifier.inspect(self.lib)
        self.assertEqual(result['minimum_os'], ['14.0'])
        self.assertEqual(result['dependencies'], ['/usr/lib/libSystem.B.dylib'])
        self.assertEqual(result['install_id'], '@rpath/libFixture.dylib')
        with mock.patch.object(verifier, 'command', return_value='x86_64'):
            with self.assertRaisesRegex(ValueError, 'architecture missing'):
                verifier.inspect(self.lib)

    def test_missing_macos_minimum_is_refused(self):
        with mock.patch.object(verifier, 'command', side_effect=['arm64', 'fixture:\nLoad command 0\n cmd LC_RPATH\n path /usr/lib/swift (offset 12)']):
            with self.assertRaisesRegex(ValueError, 'Missing macOS minimum'):
                verifier.inspect(self.lib)

    def test_notice_missing_changed_and_equal(self):
        source = self.file('NOTICE', b'full fixture license')
        destination = self.root / 'copied-NOTICE'
        with self.assertRaisesRegex(ValueError, 'notice missing'):
            verifier.compare_notice(source, destination)
        destination.write_bytes(b'other')
        with self.assertRaisesRegex(ValueError, 'differs'):
            verifier.compare_notice(source, destination)
        destination.write_bytes(source.read_bytes())
        verifier.compare_notice(source, destination)

    def test_frozen_configuration_source_and_runtime_drift_are_refused(self):
        config = self.file('reviewed.json', b'{}')
        runtime = self.file('runtime', b'fixture runtime')
        sources = [{'path': 'source', 'sha256': 'fixture'}]
        manifest = {'schema_version': 2, 'configuration_sha256': verifier.digest(config),
                    'source_root': str(self.root), 'sources': sources, 'documentation': [],
                    'documentation_inventory_at': 'fixture-time', 'native_binary_inputs': verifier.native_binary_inputs(self.root),
                    'inputs': [{'root': str(runtime), 'files': verifier.inventory(runtime)}]}
        with mock.patch.object(verifier, 'source_inventory', return_value=sources):
            verifier.verify_manifest(manifest, config)
            runtime.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'Runtime or notice changed'):
                verifier.verify_manifest(manifest, config)
        with mock.patch.object(verifier, 'source_inventory', return_value=[]):
            with self.assertRaisesRegex(ValueError, 'Source changed'):
                verifier.verify_manifest(manifest, config)
        config.write_bytes(b'{"changed":true}')
        with self.assertRaisesRegex(ValueError, 'Configuration changed'):
            verifier.verify_manifest(manifest, config)

    def test_inventory_rejects_external_and_dangling_symlinks(self):
        directory = self.root / 'inventory'
        directory.mkdir()
        (directory / 'link').symlink_to(self.main)
        with self.assertRaisesRegex(ValueError, 'escapes'):
            verifier.inventory(directory)
        (directory / 'link').unlink()
        (directory / 'link').symlink_to(directory / 'missing')
        with self.assertRaisesRegex(ValueError, 'Dangling'):
            verifier.inventory(directory)

    def test_code_sections_survive_header_and_signature_but_detect_code_change(self):
        original = verifier.code_sections(self.main)
        self.main.write_bytes(self.main.read_bytes() + b'synthetic signing data')
        self.assertEqual(original, verifier.code_sections(self.main))
        data = bytearray(self.main.read_bytes())
        data[24] = 1  # flags/header change
        self.main.write_bytes(data)
        self.assertEqual(original, verifier.code_sections(self.main))
        self.main.write_bytes(thin_macho(b'changed code'))
        self.assertNotEqual(original, verifier.code_sections(self.main))

    def test_fat_sections_select_arm64(self):
        thin = thin_macho()
        fat = struct.pack('>II', 0xcafebabe, 1) + struct.pack('>IIIII', 0x0100000c, 0, 28, len(thin), 0) + thin
        path = self.file('fat', fat)
        self.assertEqual(verifier.code_sections(path), verifier.code_sections(self.main))

    def config_and_plists(self):
        config = {'application_version': '0.1.0', 'application_build': '56',
                  'codesign_identity': 'Developer ID Application: Fixture (TEAM)', 'expected_identity_sha1': 'A'*40,
                  'sparkle_feed_url': 'https://fixture.example/feed', 'sparkle_account': 'fixture',
                  'sparkle_public_key': 'eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHg='}
        for relative, identifier in [('Contents/Info.plist', 'com.aimai.macos'),
                                     ('Contents/Library/LoginItems/AIMAgentHost.app/Contents/Info.plist', 'com.aimai.macos.agenthost')]:
            info = {'CFBundleIdentifier': identifier, 'CFBundleVersion': '56', 'CFBundleShortVersionString': '0.1.0',
                    'LSMinimumSystemVersion': '14.0', 'SUFeedURL': config['sparkle_feed_url'], 'SUPublicEDKey': config['sparkle_public_key']}
            self.file('Candidate.app/' + relative, plistlib.dumps(info))
        return self.file('configuration.json', json.dumps(config).encode())

    def test_wrong_bundle_identity_version_and_key_are_refused(self):
        config = self.config_and_plists()
        main = self.app / 'Contents/Info.plist'
        original = plistlib.loads(main.read_bytes())
        for key, value, message in [('CFBundleIdentifier', 'wrong', 'identity'), ('CFBundleVersion', '55', 'version'),
                                    ('SUPublicEDKey', 'wrong', 'public key')]:
            info = dict(original, **{key: value})
            main.write_bytes(plistlib.dumps(info))
            with mock.patch.object(verifier, 'verify_manifest'):
                with self.assertRaisesRegex(ValueError, message):
                    verifier.verify(self.app, config, {})

    def test_wrong_signed_identity_is_refused(self):
        config = self.config_and_plists()
        with mock.patch.object(verifier, 'verify_manifest'), mock.patch.object(verifier, 'verify_composition'), \
             mock.patch.object(verifier, 'graph', return_value={'objects': []}), mock.patch.object(verifier, 'command'), \
             mock.patch.object(verifier.subprocess, 'run', return_value=type('Result', (), {'stdout': '', 'stderr': 'Authority=Developer ID Application: Other (TEAM)\nTeamIdentifier=TEAM\nTimestamp=fixture\nflags=runtime'})()):
            with self.assertRaisesRegex(ValueError, 'Signed identity differs'):
                verifier.verify(self.app, config, {})

    def test_write_new_never_overwrites_report(self):
        report = self.root / 'report.json'
        verifier.write_new(report, {'fixture': True})
        with self.assertRaises(FileExistsError):
            verifier.write_new(report, {'fixture': False})
        self.assertTrue(json.loads(report.read_text())['fixture'])

    def test_portable_rpaths_refuses_any_non_system_dependency_before_mutation(self):
        with mock.patch.object(verifier, 'command', return_value='arm64') as command, \
             mock.patch.object(verifier, 'inspect', return_value=self.metadata(deps=['@rpath/libRequired.dylib'], rpaths=['/Developer/FixtureXcode.app'])):
            with self.assertRaisesRegex(ValueError, 'non-system dependencies'):
                verifier.portable_system_rpaths(self.main)
        self.assertEqual(command.call_count, 1)

    def test_portable_rpaths_preserves_dependencies_and_code(self):
        before = self.metadata(deps=['/usr/lib/libSystem.B.dylib'], rpaths=['/Developer/FixtureXcode.app', '/usr/lib/swift'])
        after = self.metadata(deps=['/usr/lib/libSystem.B.dylib'], rpaths=['/usr/lib/swift'])
        with mock.patch.object(verifier, 'command', side_effect=['arm64', '']) as command, \
             mock.patch.object(verifier, 'inspect', side_effect=[before, after]):
            verifier.portable_system_rpaths(self.main)
        self.assertEqual(command.call_args_list[-1].args[0], ['/usr/bin/install_name_tool', '-delete_rpath', '/Developer/FixtureXcode.app', self.main])

    def test_apple_swift_selection_must_stay_inside_current_toolchain(self):
        with mock.patch.object(verifier, 'command', side_effect=['/usr/lib/libswiftCore.dylib', '/Fixture/Xcode.xctoolchain/usr/bin/swift-stdlib-tool']):
            with self.assertRaisesRegex(ValueError, 'Unexpected Apple Swift library'):
                verifier.embed_swift(self.app, [self.main])

    def test_apple_swift_no_selection_does_not_copy_or_patch(self):
        with mock.patch.object(verifier, 'command', return_value='') as command:
            verifier.embed_swift(self.app, [self.main])
        self.assertEqual(command.call_count, 1)
        self.assertEqual(command.call_args.args[0][-1], '--print')

    def test_certificate_is_public_embedded_der_and_sha_must_match(self):
        config = self.config_and_plists()
        valid = 'Authority=Developer ID Application: Fixture (TEAM)\nTeamIdentifier=TEAM\nTimestamp=fixture\nCodeDirectory flags=runtime'
        extractions = []
        def public_extract(args):
            if any(str(value).startswith('--extract-certificates') for value in args):
                self.assertEqual(len(args), 4)
                self.assertEqual(args[:2], ['/usr/bin/codesign', '-d'])
                self.assertTrue(args[2].startswith('--extract-certificates='))
                self.assertNotIn('--extract-certificates', args)
                self.assertEqual(args[3], self.app)
                prefix = args[2].split('=', 1)[1]
                self.assertTrue(pathlib.Path(prefix).is_absolute())
                extractions.append(args[2])
                pathlib.Path(prefix + '0').write_bytes(b'public synthetic certificate')
            return ''
        patches = (mock.patch.object(verifier, 'verify_manifest'), mock.patch.object(verifier, 'verify_composition'),
                   mock.patch.object(verifier, 'graph', return_value={'objects': []}),
                   mock.patch.object(verifier, 'command', side_effect=public_extract),
                   mock.patch.object(verifier.subprocess, 'run', return_value=type('Result', (), {'stdout': '', 'stderr': valid})()))
        with patches[0], patches[1], patches[2], patches[3], patches[4]:
            with self.assertRaisesRegex(ValueError, 'certificate SHA-1 differs'):
                verifier.verify(self.app, config, {})
            value = json.loads(config.read_text())
            value['expected_identity_sha1'] = hashlib.sha1(b'public synthetic certificate').hexdigest()
            config.write_text(json.dumps(value))
            result = verifier.verify(self.app, config, {})
            self.assertEqual(result['static_verification'], 'passed')
            self.assertEqual(len(extractions), 2)

    def frozen_manifest(self, config, records):
        sources, docs = verifier.split_sources(records)
        return {'schema_version': 2, 'configuration_sha256': verifier.digest(config),
                'source_root': str(self.root), 'sources': sources, 'historical_sources': copy.deepcopy(records),
                'documentation': docs, 'documentation_inventory_at': 'fixture-time',
                'native_binary_inputs': verifier.native_binary_inputs(self.root),
                'inputs': [{'root': str(config), 'files': verifier.inventory(config)}]}

    def test_only_root_documentation_drift_is_tolerated_and_reported(self):
        config = self.file('reviewed.json', b'{}')
        records = [{'path': path, 'sha256': 'frozen'} for path in (
            'docs/qa/report.md', 'docs/REPRISE-FR.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
            'apps/macos/Sources/main.swift', 'apps/macos/scripts/build-app.sh',
            'packages/AIMDirectNative/THIRD_PARTY_NOTICES/libdatachannel.txt')]
        manifest = self.frozen_manifest(config, records)
        changed = copy.deepcopy(records)
        changed[0]['sha256'] = 'new report'
        changed.append({'path': 'docs/qa/after-build.md', 'sha256': 'new'})
        with mock.patch.object(verifier, 'source_inventory', return_value=changed):
            result = verifier.verify_manifest(manifest, config)
        self.assertEqual(result['build_inputs'], 'unchanged')
        self.assertEqual(result['documentation_drift'], [
            {'path': 'docs/qa/after-build.md', 'change': 'added'}, {'path': 'docs/qa/report.md', 'change': 'changed'}])
        self.assertTrue(result['documentation_changes_do_not_prove_code'])
        self.assertEqual(manifest['historical_sources'], records)
        # Swift, packaging, root licenses and nested package notices still fail.
        for index in range(2, len(records)):
            changed = copy.deepcopy(records)
            changed[index]['sha256'] = 'drift'
            with self.subTest(path=records[index]['path']), mock.patch.object(verifier, 'source_inventory', return_value=changed):
                with self.assertRaisesRegex(ValueError, 'Source changed'):
                    verifier.verify_manifest(manifest, config)

    def test_ignored_native_binary_and_receipt_drift_are_refused(self):
        config = self.file('reviewed.json', b'{}')
        records = [{'path': 'apps/macos/Package.swift', 'sha256': 'fixture'}]
        manifest = self.frozen_manifest(config, records)
        receipt = self.root / 'packages/AIMDirectNative/Artifacts/build-receipt.json'
        for path in (self.native_binary, receipt, self.root / 'packages/AIMDirectNative/dependencies.lock.json'):
            original = path.read_bytes()
            path.write_bytes(b'changed ignored native input')
            with self.subTest(path=path), mock.patch.object(verifier, 'source_inventory', return_value=records):
                with self.assertRaisesRegex(ValueError, 'Native binary input changed'):
                    verifier.verify_manifest(manifest, config)
            path.write_bytes(original)

    def test_missing_native_framework_metadata_and_old_manifest_are_refused(self):
        metadata = self.root / 'packages/AIMDirectNative/Artifacts/AIMDataChannel.xcframework/Info.plist'
        metadata.unlink()
        with self.assertRaisesRegex(ValueError, 'XCFramework metadata missing'):
            verifier.native_binary_inputs(self.root)
        with self.assertRaisesRegex(ValueError, 'refreeze including native'):
            verifier.verify_manifest({'schema_version': 1}, self.root / 'missing')

    def apple_provenance(self):
        tool = self.file('FixtureXcode.app/Contents/Developer/Toolchains/Fixture.xctoolchain/usr/bin/swift-stdlib-tool')
        tool.chmod(0o755)
        library = self.file('FixtureXcode.app/Contents/Developer/Toolchains/Fixture.xctoolchain/usr/lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib')
        self.file('Candidate.app/Contents/Frameworks/' + library.name, library.read_bytes())
        record = {'tool': str(tool), 'tool_sha256': verifier.digest(tool), 'libraries': {
            library.name: {'source': str(library), 'source_sha256': verifier.digest(library),
                           'unsigned_sha256': verifier.digest(library)}}}
        provenance = self.file('Candidate.app/Contents/Resources/SwiftRuntime/provenance.json', json.dumps(record).encode())
        return tool, library, provenance

    def test_current_apple_rpath_cleanup_is_limited_and_preserves_main_helper(self):
        tool, library, provenance = self.apple_provenance()
        helper = self.file('Candidate.app/Contents/Library/LoginItems/AIMAgentHost.app/Contents/MacOS/AIMAgentHost', thin_macho())
        old = self.metadata(deps=['@rpath/libswiftCompatibilitySpan.dylib'],
                            rpaths=[str(library.parent), '@loader_path/../Frameworks'], executable=True)
        new = copy.deepcopy(old)
        new['rpaths'].remove(str(library.parent))
        with mock.patch.object(verifier, 'command', side_effect=[str(tool), '', '']) as command, \
             mock.patch.object(verifier, 'inspect', side_effect=[old, new, old, new]), \
             mock.patch.object(verifier, 'graph', return_value={'objects': {'main': {}, 'helper': {}}}) as graph:
            result = verifier.portable_apple_rpaths(self.app, [self.main, helper])
        graph.assert_called_once_with(self.app)
        deletions = [call.args[0] for call in command.call_args_list[1:]]
        self.assertEqual(deletions, [
            ['/usr/bin/install_name_tool', '-delete_rpath', str(library.parent), self.main],
            ['/usr/bin/install_name_tool', '-delete_rpath', str(library.parent), helper]])
        self.assertEqual(len(result['removed_build_rpaths']), 2)
        self.assertEqual(json.loads(provenance.read_text())['removed_build_rpaths'], result['removed_build_rpaths'])

    def test_apple_rpath_cleanup_refuses_foreign_scan_tool_or_changed_library(self):
        tool, library, provenance = self.apple_provenance()
        with self.assertRaisesRegex(ValueError, 'only assembled main/helper'):
            verifier.portable_apple_rpaths(self.app, [self.lib])
        with mock.patch.object(verifier, 'command', return_value=str(tool.parent / 'foreign-tool')):
            with self.assertRaisesRegex(ValueError, 'current Apple toolchain tool'):
                verifier.portable_apple_rpaths(self.app, [self.main])
        library.write_bytes(b'drift')
        with mock.patch.object(verifier, 'command', return_value=str(tool)) as command:
            with self.assertRaisesRegex(ValueError, 'library input or unsigned copy differs'):
                verifier.portable_apple_rpaths(self.app, [self.main])
        self.assertEqual(command.call_count, 1)  # lookup only; no mutation

    def test_foreign_development_rpath_is_never_deleted_and_graph_still_refuses(self):
        tool, library, provenance = self.apple_provenance()
        old = self.metadata(rpaths=['/Developer/ForeignXcode.app/lib'], executable=True)
        with mock.patch.object(verifier, 'command', return_value=str(tool)) as command, \
             mock.patch.object(verifier, 'inspect', return_value=old), \
             mock.patch.object(verifier, 'graph', side_effect=ValueError('External development rpath')):
            with self.assertRaisesRegex(ValueError, 'External development rpath'):
                verifier.portable_apple_rpaths(self.app, [self.main])
        self.assertEqual(command.call_count, 1)
        self.assertNotIn('removed_build_rpaths', json.loads(provenance.read_text()))

    def test_no_backdeployment_copy_still_removes_current_apple_build_rpath(self):
        tool, library, provenance = self.apple_provenance()
        provenance.unlink()
        (self.app / 'Contents/Frameworks' / library.name).unlink()
        old = self.metadata(rpaths=[str(library.parent), '/usr/lib/swift'], executable=True)
        new = self.metadata(rpaths=['/usr/lib/swift'], executable=True)
        with mock.patch.object(verifier, 'command', side_effect=[str(tool), '']), \
             mock.patch.object(verifier, 'inspect', side_effect=[old, new]), \
             mock.patch.object(verifier, 'graph', return_value={'objects': {'main': {}}}) as graph:
            verifier.portable_apple_rpaths(self.app, [self.main])
        graph.assert_called_once_with(self.app)
        record = json.loads(provenance.read_text())
        self.assertEqual(record['libraries'], {})  # no invented copied runtime/notice
        self.assertEqual(record['tool_sha256'], verifier.digest(tool))

    def test_no_provenance_cannot_hide_required_missing_swift_library(self):
        tool, library, provenance = self.apple_provenance()
        provenance.unlink()
        (self.app / 'Contents/Frameworks' / library.name).unlink()
        old = self.metadata(deps=['@rpath/' + library.name], rpaths=[str(library.parent)], executable=True)
        new = self.metadata(deps=old['dependencies'], executable=True)
        with mock.patch.object(verifier, 'command', side_effect=[str(tool), '']), \
             mock.patch.object(verifier, 'inspect', side_effect=[old, new]), \
             mock.patch.object(verifier, 'graph', side_effect=ValueError('Missing or nonresolving dependency')):
            with self.assertRaisesRegex(ValueError, 'Missing or nonresolving'):
                verifier.portable_apple_rpaths(self.app, [self.main])
        self.assertFalse(provenance.exists())

    def test_no_provenance_never_authorizes_foreign_development_path(self):
        tool, library, provenance = self.apple_provenance()
        provenance.unlink()
        (self.app / 'Contents/Frameworks' / library.name).unlink()
        old = self.metadata(rpaths=['/Developer/ForeignXcode.app/lib'], executable=True)
        with mock.patch.object(verifier, 'command', return_value=str(tool)) as command, \
             mock.patch.object(verifier, 'inspect', return_value=old), \
             mock.patch.object(verifier, 'graph', side_effect=ValueError('External development rpath')):
            with self.assertRaisesRegex(ValueError, 'External development rpath'):
                verifier.portable_apple_rpaths(self.app, [self.main])
        self.assertEqual(command.call_count, 1)  # no deletion of the foreign path
        self.assertFalse(provenance.exists())

    def playwright_copy_fixture(self):
        source = self.root / 'playwright-source'
        cli = self.file('playwright-source/package/cli.js', b'fixture CLI')
        cli.chmod(0o755)
        link = source / '.bin/fixture'
        link.parent.mkdir()
        link.symlink_to('../package/cli.js')
        destination = self.root / 'playwright-copy'
        shutil.copytree(source, destination, symlinks=False)
        return source, destination, cli, link

    def test_playwright_expected_copy_dereferences_only_internal_file_links(self):
        source, destination, cli, link = self.playwright_copy_fixture()
        verifier.verify_playwright_copy(source, destination)
        copied = destination / '.bin/fixture'
        self.assertFalse(copied.is_symlink())
        record = next(r for r in verifier.copied_playwright_inventory(source) if r['path'] == '.bin/fixture')
        self.assertEqual(record, {'path': '.bin/fixture', 'sha256': verifier.digest(cli), 'mode': 0o755})
        self.assertIn('symlink', next(r for r in verifier.inventory(source) if r['path'] == '.bin/fixture'))

    def test_playwright_copy_rejects_modified_mode_bytes_extra_or_missing_file(self):
        source, destination, cli, link = self.playwright_copy_fixture()
        copied = destination / '.bin/fixture'
        for change in ('bytes', 'mode', 'extra', 'extra-directory', 'missing', 'symlink'):
            with self.subTest(change=change):
                if change == 'bytes':
                    copied.write_bytes(b'changed CLI')
                elif change == 'mode':
                    copied.chmod(0o644)
                elif change == 'extra':
                    (destination / 'unexpected').write_bytes(b'extra')
                elif change == 'extra-directory':
                    (destination / 'unexpected-directory').mkdir()
                elif change == 'missing':
                    copied.unlink()
                else:
                    copied.unlink()
                    copied.symlink_to('../package/cli.js')
                with self.assertRaisesRegex(ValueError, 'Playwright module'):
                    verifier.verify_playwright_copy(source, destination)
                if copied.is_symlink():
                    copied.unlink()
                shutil.copy2(cli, copied)
                if (destination / 'unexpected').exists():
                    (destination / 'unexpected').unlink()
                if (destination / 'unexpected-directory').exists():
                    (destination / 'unexpected-directory').rmdir()

    def test_playwright_copy_rejects_directory_escaping_and_dangling_links(self):
        source, destination, cli, link = self.playwright_copy_fixture()
        link.unlink()
        for target, message in [('../package', 'directory or non-file'),
                                (str(self.main), 'escapes source'), ('../missing', 'Dangling')]:
            with self.subTest(target=target):
                link.symlink_to(target)
                with self.assertRaisesRegex(ValueError, message):
                    verifier.copied_playwright_inventory(source)
                link.unlink()


if __name__ == '__main__':
    unittest.main()
