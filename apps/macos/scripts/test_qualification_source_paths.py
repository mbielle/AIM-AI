import importlib.util
import pathlib
import plistlib
import tempfile
import unittest


script = pathlib.Path(__file__).with_name('prepare-qualification-candidate.py')
spec = importlib.util.spec_from_file_location('qualification_candidate', script)
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)


class SourceInputTests(unittest.TestCase):
    def test_fresh_build_directory_is_created_and_symlink_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            directory = candidate.prepare_build_directory(root)
            self.assertTrue(directory.is_dir())
            self.assertEqual(candidate.prepare_build_directory(root), directory)
            directory.rmdir()
            target = root / 'elsewhere'
            target.mkdir()
            directory.symlink_to(target, target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, 'must not be a symlink'):
                candidate.prepare_build_directory(root)

    def fixture(self, directory):
        root = pathlib.Path(directory)
        mac, core, native = root / 'apps/macos', root / 'packages/AIMCore', root / 'packages/AIMDirectNative'
        for package in (mac, core, native):
            (package / 'Sources').mkdir(parents=True)
            (package / 'Package.swift').write_text('// fixture manifest')
            (package / 'Sources/Fixture.swift').write_text('// fixture source')
        (mac / 'Config').mkdir()
        for name in ('Info.plist', 'AgentHostInfo.plist'):
            (mac / 'Config' / name).write_bytes(plistlib.dumps({}))
        for name, value in {
            'README.md': 'fixture rebuild instructions',
            'dependencies.lock.json': '{}',
            'THIRD_PARTY_NOTICES/upstream.txt': 'fixture upstream license',
            'patches/fixture.patch': 'fixture MPL patch source',
            'Artifacts/build-receipt.json': '{}',
            'Artifacts/AIMDataChannel.xcframework/Info.plist': 'fixture XCFramework',
            'Artifacts/AIMDataChannel.xcframework/macos-arm64_x86_64/libFixture.a': 'fixture native bytes',
        }.items():
            path = native / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)
        return mac, core, native

    def test_monorepo_inventory_includes_three_packages_permissions_and_native_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            mac, core, native = self.fixture(temporary)
            expected = {path for package in (mac, core, native) for path in package.rglob('*') if path.is_file()}
            self.assertEqual(set(candidate.source_inputs(mac)), expected)
            # A neighbouring historical copy must not enter this checkout's provenance.
            decoy = pathlib.Path(temporary) / 'AIMCore/Sources/Old.swift'
            decoy.parent.mkdir(parents=True)
            decoy.write_text('// not the monorepo package')
            self.assertNotIn(decoy, candidate.source_inputs(mac))

    def test_missing_core_is_refused_before_signing_or_bundle_work(self):
        with tempfile.TemporaryDirectory() as temporary:
            mac, core, _ = self.fixture(temporary)
            (core / 'Package.swift').unlink()
            with self.assertRaisesRegex(RuntimeError, 'Required source manifest is missing'):
                candidate.source_inputs(mac)

    def test_missing_native_manifest_or_artifact_is_not_silently_omitted(self):
        with tempfile.TemporaryDirectory() as temporary:
            mac, _, native = self.fixture(temporary)
            manifest = native / 'Package.swift'
            manifest.unlink()
            with self.assertRaisesRegex(RuntimeError, 'Required source manifest is missing'):
                candidate.source_inputs(mac)
            manifest.write_text('// restored fixture')
            artifact = native / 'Artifacts/AIMDataChannel.xcframework'
            for path in sorted(artifact.rglob('*'), reverse=True):
                if path.is_file(): path.unlink()
                else: path.rmdir()
            artifact.rmdir()
            with self.assertRaisesRegex(RuntimeError, 'Required source directory is missing'):
                candidate.source_inputs(mac)

    def test_native_binary_patch_and_notices_have_actual_content_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            mac, _, native = self.fixture(temporary)
            paths = candidate.source_inputs(mac)
            before = {path: candidate.d.digest(path) for path in paths}
            for relative in ('Artifacts/AIMDataChannel.xcframework/macos-arm64_x86_64/libFixture.a',
                             'patches/fixture.patch', 'THIRD_PARTY_NOTICES/upstream.txt'):
                path = native / relative
                path.write_text(path.read_text() + ' updated')
                self.assertNotEqual(before[path], candidate.d.digest(path))

    def test_native_publication_copy_matches_pinned_notices_and_patch_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            _, _, native = self.fixture(temporary)
            destination = pathlib.Path(temporary) / 'candidate/Contents/Resources/ThirdParty/AIMDirectNative'
            recorded = candidate.copy_native_publication_inputs(native, destination)
            self.assertEqual(set(recorded), {'README.md', 'dependencies.lock.json',
                'THIRD_PARTY_NOTICES/upstream.txt', 'patches/fixture.patch'})
            self.assertEqual(recorded, {path.relative_to(destination).as_posix(): candidate.d.digest(path)
                for path in destination.rglob('*') if path.is_file()})
            (native / 'patches/fixture.patch').write_text('modified after copying')
            self.assertEqual(candidate.d.digest(destination / 'patches/fixture.patch'), recorded['patches/fixture.patch'])
            self.assertNotEqual(candidate.d.digest(native / 'patches/fixture.patch'), recorded['patches/fixture.patch'])

    def test_native_publication_refuses_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            mac, _, native = self.fixture(temporary)
            (native / 'THIRD_PARTY_NOTICES/foreign.txt').symlink_to(native / 'README.md')
            with self.assertRaisesRegex(RuntimeError, 'refuses symlinks'):
                candidate.source_inputs(mac)


class QualificationInfoTests(unittest.TestCase):
    def test_network_permissions_are_merged_without_official_identity_or_url_schemes(self):
        previous = {'CFBundleIdentifier': 'com.aimai.macos.qualification.fixture',
            'CFBundleURLTypes': [{'CFBundleURLSchemes': ['aim-test-fixture']}],
            'CFBundleVersion': '49', 'AIMInstallationNamespace': 'preserve-fixture',
            'SUEnableAutomaticChecks': False}
        current = {'CFBundleIdentifier': 'com.aimai.macos',
            'CFBundleURLTypes': [{'CFBundleURLSchemes': ['aimmac']}],
            'NSLocalNetworkUsageDescription': 'Connect devices when requested.',
            'NSBonjourServices': ['_aimdirect._tcp'], 'SUEnableAutomaticChecks': True}
        result = candidate.qualification_info(previous, current, '51', 'main')
        for key in ('CFBundleIdentifier', 'CFBundleURLTypes', 'AIMInstallationNamespace', 'SUEnableAutomaticChecks'):
            self.assertEqual(result[key], previous[key])
        self.assertEqual(result['CFBundleVersion'], '51')
        self.assertEqual(result['NSBonjourServices'], ['_aimdirect._tcp'])
        self.assertEqual(result['NSLocalNetworkUsageDescription'], current['NSLocalNetworkUsageDescription'])
        self.assertEqual(previous['CFBundleVersion'], '49')
        self.assertNotIn('NSBonjourServices', previous)

    def test_helper_keeps_its_identity_and_existing_permissions(self):
        previous = {'CFBundleIdentifier': 'com.aimai.macos.qualification.fixture.agenthost',
            'LSUIElement': True, 'NSAppleEventsUsageDescription': 'Existing helper permission.'}
        result = candidate.qualification_info(previous, {'CFBundleIdentifier': 'com.aimai.macos.agenthost'}, '51', 'helper')
        self.assertEqual(result['CFBundleIdentifier'], previous['CFBundleIdentifier'])
        self.assertEqual(result['NSAppleEventsUsageDescription'], previous['NSAppleEventsUsageDescription'])
        self.assertTrue(result['LSUIElement'])
        self.assertNotIn('NSBonjourServices', result)

    def test_main_refuses_missing_permission_declarations(self):
        for current in ({}, {'NSLocalNetworkUsageDescription': 'description'},
                        {'NSLocalNetworkUsageDescription': 'description', 'NSBonjourServices': []}):
            with self.assertRaises(RuntimeError):
                candidate.qualification_info({'CFBundleIdentifier': 'fixture'}, current, '51', 'main')


if __name__ == '__main__':
    unittest.main()
