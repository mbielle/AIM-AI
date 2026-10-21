#!/usr/bin/env python3
"""Build an isolated QA bundle from a fresh Core build and attest actual inputs.

--core-products supplies ONLY the existing local dependency seed, never a Core
archive to trust. No dependency is fetched and no installed app identity is used.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
NAMESPACE = r"com\.aimai\.macos\.qualification\.[0-9a-f]{32}"


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def tree_files(folder):
    return sorted(p for p in folder.rglob('*') if p.is_file() and '.git' not in p.parts
                  and '.build' not in p.relative_to(folder).parts)


def source_inputs(probe='controller'):
    paths = []
    for folder in ['packages/AIMCore/Sources', 'packages/AIMDirectNative/Sources',
                   'packages/AIMDirectNative/Artifacts']:
        paths.extend(tree_files(ROOT / folder))
    paths += [ROOT / name for name in ['packages/AIMCore/Package.swift', 'packages/AIMCore/Package.resolved',
        'packages/AIMDirectNative/Package.swift', 'scripts/direct/build-swift-probe.py',
        'scripts/direct/qualify-controller.py', 'scripts/direct/test-lan-contracts.py',
        'scripts/direct/test_qualification_contracts.py', 'scripts/qa/run.py', f'scripts/direct/native-{probe}-probe.swift']]
    return {str(p.relative_to(ROOT)): digest(p) for p in sorted(set(paths)) if p.is_file()}


def map_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def verify_probe(probe):
    """Independent preflight: stale inputs/archive/module/binary cannot qualify."""
    probe = Path(probe).resolve(strict=True)
    info = plistlib.loads((probe.parent.parent / 'Info.plist').read_bytes())
    if not isinstance(info, dict): raise ValueError('Invalid QA bundle metadata')
    namespace = info.get('AIMQualificationNamespace', '')
    if (probe.name != 'AIMDirectProbe' or info.get('CFBundleExecutable') != probe.name
        or info.get('CFBundleIdentifier') != namespace or not re.fullmatch(NAMESPACE, namespace)
        or info.get('NSBonjourServices') != ['_aimdirect._tcp']
        or not isinstance(info.get('NSLocalNetworkUsageDescription'), str)
        or not info['NSLocalNetworkUsageDescription']):
        raise ValueError('Isolated QA bundle/network declarations required')
    path = probe.parent.parent.parent.with_suffix('.provenance.json')
    value = json.loads(path.read_text())
    if (not isinstance(value, dict) or type(value.get('schema')) is not int or value['schema'] != 2
        or value.get('probe') != 'controller' or value.get('namespace') != namespace
        or value.get('freshCoreBuild') is not True or value.get('status') != 'built'
        or value.get('binarySHA256') != digest(probe) or value.get('infoSHA256') != digest(probe.parent.parent / 'Info.plist')):
        raise ValueError('Fresh build provenance required')
    inputs = source_inputs(value['probe'])
    if value.get('inputs') != inputs or value.get('sourceSHA256') != map_digest(inputs):
        raise ValueError('Probe sources changed since construction')
    linked = value.get('linkedInputs')
    if not isinstance(linked, dict) or not linked or any(not isinstance(k, str) or not isinstance(v, str)
                                                       or digest(k) != v for k, v in linked.items()):
        raise ValueError('Linked archive/module changed or absent')
    dependencies = value.get('dependencyInputs')
    scratch = Path(value['coreScratch'])
    products = scratch / 'out/Products/Debug'
    modules = tree_files(products / 'AIMCore.swiftmodule')
    if not (products / 'AIMCore.swiftmodule').is_dir(): modules = [products / 'AIMCore.swiftmodule']
    required_linked = [products / 'libAIMCore.a', ROOT / 'packages/AIMDirectNative/Artifacts/AIMDataChannel.xcframework/macos-arm64_x86_64/libAIMDataChannel-macos.a', *modules]
    if not modules or set(linked) != {str(p) for p in required_linked}:
        raise ValueError('Core/module/native link provenance incomplete')
    observed = {str(p.relative_to(scratch / 'checkouts')): digest(p) for p in tree_files(scratch / 'checkouts')}
    if not observed or dependencies != observed:
        raise ValueError('Dependency build inputs changed or absent')
    if (type(value.get('buildStarted')) not in (int, float) or type(value.get('buildFinished')) not in (int, float)
        or not math.isfinite(value['buildStarted']) or not math.isfinite(value['buildFinished'])
        or not 0 < value['buildStarted'] <= value['buildFinished'] <= time.time()
        or not isinstance(value.get('coreBuildCommand'), list) or '--scratch-path' not in value['coreBuildCommand']):
        raise ValueError('Invalid build recipe/time')
    if value.get('signing') != 'Apple Development' or not isinstance(value.get('signingIdentity'), str) or not re.fullmatch('[A-F0-9]{40}', value['signingIdentity']):
        raise ValueError('Development signature provenance missing')
    subprocess.run(['codesign', '--verify', '--strict', str(probe.parent.parent.parent)], check=True, timeout=30, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    return value


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--core-products', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--probe', choices=['rpc', 'controller'], default='rpc')
    p.add_argument('--module-cache', type=Path, required=True)
    p.add_argument('--native-archive', type=Path)
    p.add_argument('--native-headers', type=Path)
    p.add_argument('--campaign-id', default=uuid.uuid4().hex)
    p.add_argument('--signing-identity', required=True, help='Existing Apple Development identity SHA-1; no key export')
    a = p.parse_args()
    os.umask(0o077)
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    if not any(a.signing_identity in line and 'Apple Development:' in line for line in identities.splitlines()):
        p.error('An already available Apple Development signing identity is required')
    if not re.fullmatch('[0-9a-f]{32}', a.campaign_id):
        p.error('--campaign-id must be 32 lowercase hex digits')
    # Only shipped pinned native inputs are accepted; overrides would sever provenance.
    native = ROOT / 'packages/AIMDirectNative'
    native_base = native / 'Artifacts/AIMDataChannel.xcframework/macos-arm64_x86_64'
    archive = native_base / 'libAIMDataChannel-macos.a'; headers = native_base / 'Headers'
    if (a.native_archive and a.native_archive.resolve() != archive.resolve()) or (a.native_headers and a.native_headers.resolve() != headers.resolve()):
        p.error('Native overrides lack verified provenance; use the pinned local artifacts')
    output = a.output.absolute(); bundle = output.with_suffix('.app')
    scratch = output.with_suffix('.core-build')
    if output.exists() or bundle.exists() or scratch.exists() or bundle.with_suffix('.provenance.json').exists():
        p.error('Fresh output/bundle/Core scratch required; existing evidence is preserved')
    seed = a.core_products.resolve()
    while not (seed / 'workspace-state.json').is_file() and seed != seed.parent:
        seed = seed.parent
    if not (seed / 'checkouts').is_dir() or not (seed / 'workspace-state.json').is_file():
        p.error('--core-products must locate the existing local SwiftPM dependency seed')
    before = source_inputs(a.probe)
    scratch.mkdir(parents=True, mode=0o700)
    for name in ['checkouts', 'repositories', 'artifacts']:
        if (seed / name).exists(): shutil.copytree(seed / name, scratch / name, symlinks=True)
    shutil.copy2(seed / 'workspace-state.json', scratch / 'workspace-state.json')
    deps = {str(p.relative_to(scratch / 'checkouts')): digest(p) for p in tree_files(scratch / 'checkouts')}
    command = ['swift', 'build', '--disable-sandbox', '--disable-automatic-resolution', '--skip-update',
               '--package-path', str(ROOT / 'packages/AIMCore'), '--scratch-path', str(scratch), '--product', 'AIMCore']
    started = time.time()
    with (scratch / 'core-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=900)
    products = scratch / 'out/Products/Debug'
    core_archive = products / 'libAIMCore.a'
    if not core_archive.is_file() or core_archive.stat().st_mtime < started:
        raise ValueError('Fresh Core static archive missing')
    contents = bundle / 'Contents'; binary = contents / 'MacOS/AIMDirectProbe'
    binary.parent.mkdir(parents=True)
    namespace = 'com.aimai.macos.qualification.' + a.campaign_id
    (contents / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=namespace,
        AIMQualificationNamespace=namespace, CFBundleExecutable='AIMDirectProbe', CFBundlePackageType='APPL',
        CFBundleName='AIM Direct QA', CFBundleVersion='1',
        NSLocalNetworkUsageDescription='Qualify synthetic AIM Direct connections on this Mac.',
        NSBonjourServices=['_aimdirect._tcp'])))
    args = ['xcrun', 'swiftc', '-parse-as-library', '-disable-sandbox', '-swift-version', '6',
        '-D', 'AIM_QA_LAN_DIAGNOSTICS',
        '-module-cache-path', str(a.module_cache), '-I', str(products), '-I', str(headers)]
    for relative in ['swift-cmark/src/include', 'swift-cmark/extensions/include', 'swift-markdown/Sources/CAtomic/include']:
        args += ['-I', str(scratch / 'checkouts' / relative)]
    args += [str(x) for x in sorted((native / 'Sources/AIMDirectNative').glob('*.swift'))]
    args += [str(ROOT / f'scripts/direct/native-{a.probe}-probe.swift'), str(core_archive), str(archive),
             '-lz', '-lc++', '-framework', 'Network', '-o', str(binary)]
    subprocess.run(args, check=True, timeout=180)
    subprocess.run(['codesign', '--force', '--sign', a.signing_identity, str(bundle)], check=True, timeout=30)
    subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True, timeout=30)
    after = source_inputs(a.probe)
    if before != after or deps != {str(p.relative_to(scratch / 'checkouts')): digest(p) for p in tree_files(scratch / 'checkouts')}:
        raise ValueError('Inputs changed during construction')
    linked = [core_archive, archive] + tree_files(products / 'AIMCore.swiftmodule')
    if not (products / 'AIMCore.swiftmodule').is_dir(): linked.append(products / 'AIMCore.swiftmodule')
    value = dict(schema=2, probe=a.probe, namespace=namespace, status='built', freshCoreBuild=True,
        buildStarted=started, buildFinished=time.time(), coreBuildCommand=command, probeBuildCommand=args,
        coreScratch=str(scratch), inputs=after, sourceSHA256=map_digest(after), dependencyInputs=deps,
        linkedInputs={str(path): digest(path) for path in linked}, binarySHA256=digest(binary),
        infoSHA256=digest(contents / 'Info.plist'), signing='Apple Development', signingIdentity=a.signing_identity)
    bundle.with_suffix('.provenance.json').write_text(json.dumps(value, indent=2) + '\n')
    output.symlink_to(binary)
    print('Qualification executable:', binary)


if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit('QA build prerequisite failed: ' + type(error).__name__)
