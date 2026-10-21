#!/usr/bin/env python3
"""Static candidate evidence; never launches code or proves operation on macOS 14.

freeze --configuration reviewed.json --source-root AIM --output manifest.json
verify Candidate.app --configuration reviewed.json --manifest manifest.json --output report.json
embed-swift Candidate.app --scan executable [--scan executable ...]  (before signing only)
All output files are new. freeze binds the exact configuration, source tree and runtime
inputs, including the ignored AIMDirectNative binary artifact. Root docs/ are
inventoried historically; later documentation changes are reported separately.
verify checks build inputs again, copied notices, all Mach-O dependency graphs and
nested signatures. System framework presence/availability on macOS 14 is not inferred
from this host's SDK or dyld shared cache.
"""
import argparse
import hashlib
import datetime
import json
import os
import pathlib
import plistlib
import re
import runpy
import subprocess
import struct
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
MAGIC = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
                                  'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
SYSTEM = ('/System/Library/', '/usr/lib/')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(args):
    return subprocess.run([str(x) for x in args], check=True, text=True,
                          capture_output=True).stdout.strip()


def digest(path):
    value = hashlib.sha256()
    with pathlib.Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def write_new(path, value):
    with pathlib.Path(path).open('x') as handle:
        os.chmod(path, 0o600)
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write('\n')


def macho(path):
    if not path.is_file() or path.is_symlink():
        return False
    with path.open('rb') as handle:
        return handle.read(4) in MAGIC


def inventory(path):
    path = pathlib.Path(path)
    require(path.exists() and not path.is_symlink(), 'Inventory root missing or symlink')
    files = [path] if path.is_file() else sorted(path.rglob('*'))
    result = []
    for member in files:
        name = '.' if member == path else member.relative_to(path).as_posix()
        if member.is_symlink():
            require(member.resolve().is_relative_to(path.resolve()), 'Input symlink escapes inventory')
            require(member.resolve().exists(), 'Dangling input symlink')
            result.append({'path': name, 'symlink': os.readlink(member)})
        elif member.is_file():
            result.append({'path': name, 'sha256': digest(member), 'mode': member.stat().st_mode & 0o777})
        else:
            require(member.is_dir(), 'Unsupported input file')
    require(bool(result), 'Empty input inventory')
    return result


def copied_playwright_inventory(path):
    """Expected copy_resources(symlinks=False) output for confined file links only.

    This normalization is specific to the Playwright copy contract. Directory
    links, escaping/dangling links and special files are refused; every expected
    path retains the exact target bytes and permission mode. Destination inventory
    remains strict, so extra, missing, modified or still-symlinked members fail.
    """
    path = pathlib.Path(path)
    require(path.is_dir() and not path.is_symlink(), 'Playwright source directory missing or symlink')
    result = []
    for member in sorted(path.rglob('*')):
        name = member.relative_to(path).as_posix()
        target = member
        if member.is_symlink():
            try:
                target = member.resolve(strict=True)
            except (OSError, RuntimeError):
                raise ValueError('Dangling or cyclic Playwright file link') from None
            require(target.is_relative_to(path.resolve()), 'Playwright file link escapes source directory')
            require(target.is_file() and not target.is_dir(), 'Playwright directory or non-file link refused')
        if target.is_file():
            result.append({'path': name, 'sha256': digest(target), 'mode': target.stat().st_mode & 0o777})
        else:
            require(target.is_dir(), 'Unsupported Playwright source member')
    require(bool(result), 'Playwright source inventory empty')
    return result


def verify_playwright_copy(source, destination):
    require(copied_playwright_inventory(source) == inventory(destination), 'Playwright modules differ')
    directories = lambda root: {p.relative_to(root).as_posix() for p in root.rglob('*')
                                if p.is_dir() and not p.is_symlink()}
    require(directories(source) == directories(destination), 'Playwright module directories differ')


def source_inventory(root):
    # Include dirty and untracked, non-ignored sources. Build artifacts remain excluded.
    names = command(['/usr/bin/git', '-C', root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).split('\0')
    records = []
    for name in sorted(set(filter(None, names))):
        path = root / name
        if not path.exists() and not path.is_symlink():
            records.append({'path': name, 'deleted': True})
        elif path.is_symlink():
            records.append({'path': name, 'symlink': os.readlink(path)})
        elif path.is_file():
            records.append({'path': name, 'sha256': digest(path), 'mode': path.stat().st_mode & 0o777})
    require(bool(records), 'Source inventory empty')
    return records


def split_sources(records):
    # Only root docs/ are reporting material. Root licenses and every app,
    # package and script (including their documentation/notices) remain frozen.
    return ([r for r in records if not r['path'].startswith('docs/')],
            [r for r in records if r['path'].startswith('docs/')])


def native_binary_inputs(source_root):
    package = source_root / 'packages/AIMDirectNative'
    artifacts = package / 'Artifacts'
    require((artifacts / 'AIMDataChannel.xcframework/Info.plist').is_file(),
            'Required AIMDirectNative XCFramework metadata missing')
    paths = [artifacts, package / 'dependencies.lock.json']
    return [{'root': str(p.resolve()), 'files': inventory(p)} for p in paths]


def documentation_changes(before, after):
    old, new = ({r['path']: r for r in records} for records in (before, after))
    return [{'path': name, 'change': 'added' if name not in old else 'removed' if name not in new else 'changed'}
            for name in sorted(old.keys() | new.keys()) if old.get(name) != new.get(name)]


def freeze(configuration_path, source_root):
    configuration = json.loads(configuration_path.read_text())
    builder = runpy.run_path(str(ROOT / 'scripts/release/build-distribution.py'))
    builder['validate_release'](configuration)
    env = builder['explicit_inputs'](configuration)
    inputs = sorted({str(pathlib.Path(value)) for key, value in env.items()
                     if key not in ('AIM_SUPABASE_URL', 'AIM_SUPABASE_PUBLIC_KEY')})
    if configuration.get('sparkle_key_tool'):
        inputs.append(str(builder['sparkle_key_tool'](configuration)))
    historical = source_inventory(source_root)
    sources, documentation = split_sources(historical)
    return {'schema_version': 2, 'configuration_sha256': digest(configuration_path),
            'source_root': str(source_root.resolve()), 'sources': sources,
            'historical_sources': historical, 'documentation': documentation,
            'documentation_inventory_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'native_binary_inputs': native_binary_inputs(source_root),
            'inputs': [{'root': p, 'files': inventory(p)} for p in inputs]}


def verify_manifest(manifest, configuration_path):
    require(manifest.get('schema_version') == 2, 'Unsupported frozen manifest; refreeze including native binary inputs')
    require(digest(configuration_path) == manifest['configuration_sha256'], 'Configuration changed after freeze')
    source_root = pathlib.Path(manifest['source_root'])
    sources, documentation = split_sources(source_inventory(source_root))
    require(sources == manifest['sources'], 'Source changed after freeze')
    require(native_binary_inputs(source_root) == manifest['native_binary_inputs'], 'Native binary input changed after freeze')
    require(bool(manifest['inputs']), 'Frozen runtime inventory empty')
    for entry in manifest['inputs']:
        require(inventory(pathlib.Path(entry['root'])) == entry['files'], 'Runtime or notice changed after freeze')
    return {'build_inputs': 'unchanged',
            'documentation_inventory_at': manifest['documentation_inventory_at'],
            'documentation_drift': documentation_changes(manifest['documentation'], documentation),
            'documentation_changes_do_not_prove_code': True}


def version(value):
    require(bool(re.fullmatch(r'\d+(?:\.\d+){0,2}', value)), 'Invalid minimum OS')
    return tuple((list(map(int, value.split('.'))) + [0, 0])[:3])


def inspect(path, arch='arm64'):
    architectures = command(['/usr/bin/lipo', '-archs', path]).split()
    require(arch in architectures, 'Required architecture missing: ' + str(path))
    text = command(['/usr/bin/otool', '-arch', arch, '-l', path])
    deps, rpaths, minimum = [], [], []
    install_id = None
    execute = False
    # Each load command is parsed individually, so LC_ID_DYLIB is not a dependency.
    for chunk in re.split(r'Load command \d+\n', text)[1:]:
        kind = re.search(r'^\s*cmd (\S+)', chunk, re.M)
        if not kind:
            continue
        kind = kind.group(1)
        if kind == 'LC_RPATH':
            match = re.search(r'^\s*path (.+) \(offset \d+\)', chunk, re.M)
            require(match is not None, 'Malformed LC_RPATH')
            rpaths.append(match.group(1))
        elif kind in ('LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB', 'LC_ID_DYLIB'):
            match = re.search(r'^\s*name (.+) \(offset \d+\)', chunk, re.M)
            require(match is not None, 'Malformed dylib command')
            if kind == 'LC_ID_DYLIB':
                install_id = match.group(1)
            else:
                deps.append(match.group(1))
        elif kind == 'LC_BUILD_VERSION':
            platform = re.search(r'^\s*platform (\S+)', chunk, re.M)
            value = re.search(r'^\s*minos (\S+)', chunk, re.M)
            if platform and platform.group(1) in ('1', 'MACOS') and value:
                minimum.append(value.group(1))
        elif kind == 'LC_VERSION_MIN_MACOSX':
            match = re.search(r'^\s*version (\S+)', chunk, re.M)
            require(match is not None, 'Malformed minimum OS')
            minimum.append(match.group(1))
        elif kind == 'LC_MAIN':
            execute = True
    require(bool(minimum), 'Missing macOS minimum load command: ' + str(path))
    return {'architectures': architectures, 'minimum_os': minimum, 'rpaths': rpaths,
            'dependencies': deps, 'install_id': install_id, 'executable': execute}


def inside(path, app):
    return path.resolve().is_relative_to(app.resolve())


def expand(value, loader, executable):
    if value == '@loader_path' or value.startswith('@loader_path/'):
        return loader.parent / value[len('@loader_path'):].lstrip('/')
    if value == '@executable_path' or value.startswith('@executable_path/'):
        return executable.parent / value[len('@executable_path'):].lstrip('/')
    return pathlib.Path(value) if value.startswith('/') else None


def graph(app, arch='arm64', minimum='14.0'):
    app = app.resolve()
    objects = {p.resolve(): inspect(p, arch) for p in sorted(app.rglob('*')) if macho(p)}
    require(bool(objects), 'No Mach-O objects selected')
    for path, meta in objects.items():
        require(all(version(v) <= version(minimum) for v in meta['minimum_os']), 'Minimum OS exceeds candidate: ' + str(path))
    visited, edges = set(), []

    def visit(path, executable, inherited=(), ancestors=()):
        require(path in objects, 'Dependency is not a bundled Mach-O: ' + str(path))
        if path in ancestors:
            return
        meta = objects[path]
        own = []
        for value in meta['rpaths']:
            resolved = expand(value, path, executable)
            require(resolved is not None, 'Nonresolving rpath: ' + value)
            # System runpaths are SDK conventions. Development/cache paths always fail.
            require(value.startswith(SYSTEM) or inside(resolved, app), 'External development rpath: ' + value)
            own.append(resolved)
        stack = tuple(own) + inherited
        key = (path, executable, stack)
        if key in visited:
            return
        visited.add(key)
        for dep in meta['dependencies']:
            if dep.startswith(SYSTEM):
                edges.append({'loader': str(path.relative_to(app)), 'dependency': dep, 'resolution': 'system-unverified-on-macos14'})
                continue
            if dep.startswith('@rpath/'):
                candidates = [p / dep[len('@rpath/'):] for p in stack]
                # @rpath dependencies must close inside the bundle. A newer host's
                # system library must never hide a missing backdeployment copy.
                target = next((p.resolve() for p in candidates if inside(p, app) and p.is_file()), None)
            else:
                target = expand(dep, path, executable)
                if target is not None:
                    require(inside(target, app), 'External development dependency: ' + dep)
                    target = target.resolve() if target.is_file() else None
            require(target is not None, 'Missing or nonresolving dependency: ' + dep)
            edges.append({'loader': str(path.relative_to(app)), 'dependency': dep,
                          'resolution': str(target.relative_to(app)), 'executable': str(executable.relative_to(app))})
            visit(target, executable, stack, ancestors + (path,))

    executables = [p for p, m in objects.items() if m['executable']]
    require(bool(executables), 'No Mach-O executable roots')
    for path in executables:
        visit(path, path)
    # Unreferenced libraries are still inspected as independent load roots.
    reached = {key[0] for key in visited}
    for path in objects.keys() - reached:
        visit(path, path)
    return {'objects': {str(p.relative_to(app)): m for p, m in objects.items()}, 'edges': edges,
            'macos14_execution': 'not_verified', 'system_api_availability': 'not_verified'}


def embed_swift(app, scans):
    """Apple decides which backdeployment libraries to copy; no system dylib copying."""
    app = app.resolve()
    require(app.is_dir(), 'Bundle missing')
    scans = [path.resolve() for path in scans]
    require(bool(scans) and all(inside(p, app) and macho(p) for p in scans), 'Scan must name bundled Mach-O files')
    args = ['/usr/bin/xcrun', 'swift-stdlib-tool', '--platform', 'macosx']
    for path in scans:
        args += ['--scan-executable', str(path)]
    selected = [pathlib.Path(p) for p in command(args + ['--print']).splitlines() if p]
    if not selected:
        return
    tool = pathlib.Path(command(['/usr/bin/xcrun', '--find', 'swift-stdlib-tool'])).resolve()
    toolchain = tool.parents[2]
    require(all(p.is_file() and inside(p, toolchain) and p.name.startswith('libswift')
                and p.suffix == '.dylib' for p in selected), 'Unexpected Apple Swift library selection')
    frameworks = app / 'Contents/Frameworks'
    frameworks.mkdir(parents=True, exist_ok=True)
    command(args + ['--copy', '--destination', str(frameworks)])
    notice = toolchain.parents[2] / 'Resources/Acknowledgments.pdf'
    require(notice.is_file(), 'Installed Xcode acknowledgments missing')
    legal = app / 'Contents/Resources/SwiftRuntime'
    legal.mkdir(parents=True, exist_ok=True)
    import shutil
    shutil.copy2(notice, legal / 'Xcode-Acknowledgments.pdf')
    record_path = legal / 'provenance.json'
    record = json.loads(record_path.read_text()) if record_path.exists() else {'schema_version': 1, 'libraries': {}}
    for source in selected:
        destination = frameworks / source.name
        require(destination.is_file(), 'Apple-selected Swift library was not copied')
        require(digest(source) == digest(destination), 'Apple Swift copy differs before signature')
        record['libraries'][source.name] = {'source': str(source), 'source_sha256': digest(source),
                                          'unsigned_sha256': digest(destination)}
    record.update(tool=str(tool), tool_sha256=digest(tool), notice_source=str(notice), notice_sha256=digest(notice))
    record_path.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    for executable in scans:
        meta = inspect(executable)
        if any(dep.startswith('@rpath/' + name) for dep in meta['dependencies'] for name in record['libraries']):
            rpath = '@loader_path/' + os.path.relpath(frameworks, executable.parent)
            if rpath not in meta['rpaths']:
                command(['/usr/bin/install_name_tool', '-add_rpath', rpath, executable])


def portable_apple_rpaths(app, scans):
    """Remove only the current Apple Swift library search path from main/helper copies.

    The compiler inserts this path even when --print selects no library for those
    executables. Bind it to the current tool and the already copied/provenanced
    backdeployment library. Other absolute development paths remain graph errors.
    """
    app = app.resolve()
    allowed = {app / 'Contents/MacOS/AIMMac',
               app / 'Contents/Library/LoginItems/AIMAgentHost.app/Contents/MacOS/AIMAgentHost'}
    scans = [p.resolve() for p in scans]
    require(bool(scans) and all(p in allowed and macho(p) for p in scans),
            'Apple rpath cleanup permits only assembled main/helper scans')
    tool = pathlib.Path(command(['/usr/bin/xcrun', '--find', 'swift-stdlib-tool'])).resolve()
    toolchain = tool.parents[2]
    require(tool.is_file() and os.access(tool, os.X_OK) and tool.name == 'swift-stdlib-tool' and
            tool.parent.name == 'bin' and tool.parent.parent.name == 'usr' and
            toolchain.suffix == '.xctoolchain', 'Apple rpath cleanup requires the current Apple toolchain tool')
    # The installed toolchain's precise Swift/macOS library directories are known
    # build search paths, even if no backdeployment library is needed/copied.
    approved = {str(p) for p in (toolchain / 'usr/lib').glob('swift*/macosx')
                if p.is_dir() and inside(p, toolchain / 'usr/lib') and
                re.fullmatch(r'swift(?:-[0-9]+(?:\.[0-9]+)*)?', p.parent.name)}
    require(bool(approved), 'Current Apple toolchain Swift macOS directories missing')
    provenance = app / 'Contents/Resources/SwiftRuntime/provenance.json'
    if provenance.exists():
        record = json.loads(provenance.read_text())
        require(record['tool'] == str(tool) and record['tool_sha256'] == digest(tool),
                'Apple rpath cleanup tool provenance differs')
    else:
        require(not list((app / 'Contents/Frameworks').glob('libswift*.dylib')),
                'Copied Swift libraries require existing provenance')
        record = {'schema_version': 1, 'tool': str(tool), 'tool_sha256': digest(tool), 'libraries': {}}
    for name, entry in record['libraries'].items():
        source = pathlib.Path(entry['source'])
        require(source.is_file() and inside(source, toolchain / 'usr/lib') and
                source.parent.name == 'macosx' and source.name == name and
                source.name.startswith('libswift') and source.suffix == '.dylib',
                'Apple rpath cleanup library provenance outside current toolchain')
        require(digest(source) == entry['source_sha256'] == entry['unsigned_sha256'] and
                digest(app / 'Contents/Frameworks' / name) == entry['unsigned_sha256'],
                'Apple rpath cleanup library input or unsigned copy differs')
        require(str(source.parent) in approved, 'Apple library directory differs from installed Swift macOS directories')
    removed = {}
    for executable in scans:
        old = inspect(executable)
        sections = code_sections(executable)
        paths = sorted(set(old['rpaths']) & approved)
        for value in paths:
            command(['/usr/bin/install_name_tool', '-delete_rpath', value, executable])
        current = inspect(executable)
        require(current['dependencies'] == old['dependencies'] and
                current['minimum_os'] == old['minimum_os'] and
                current['architectures'] == old['architectures'] and code_sections(executable) == sections,
                'Main/helper code, dependency, architecture or minimum changed')
        require(not (set(current['rpaths']) & approved), 'Apple build rpath still present')
        if paths:
            removed[str(executable.relative_to(app))] = paths
    # No signature may follow unless the complete unchanged strict graph closes.
    result = graph(app)
    record.setdefault('removed_build_rpaths', {}).update(removed)
    provenance.parent.mkdir(parents=True, exist_ok=True)
    provenance.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    return {'removed_build_rpaths': removed, 'mach_o_objects': len(result['objects']),
            'macos14_execution': 'not_verified'}


def code_sections(path):
    """Hash arm64 section bytes, excluding signatures/load-command header edits.

    Signing changes __LINKEDIT and rpath insertion changes headers; neither is a
    section. Every file-backed section (code, strings, constants, data) must match
    its reviewed source. Architectures/load commands/signatures are checked separately.
    """
    data = pathlib.Path(path).read_bytes()
    base = 0
    if data[:4] in (bytes.fromhex('cafebabe'), bytes.fromhex('cafebabf')):
        fat64 = data[:4] == bytes.fromhex('cafebabf')
        count = struct.unpack_from('>I', data, 4)[0]
        require(count < 100, 'Invalid fat architecture count')
        entries = [struct.unpack_from('>IIQQII' if fat64 else '>IIIII', data, 8 + i * (32 if fat64 else 20)) for i in range(count)]
        arm = next((entry for entry in entries if entry[0] == 0x0100000c), None)
        require(arm is not None, 'Required arm64 code sections missing')
        base = arm[2]
    require(data[base:base+4] == bytes.fromhex('cffaedfe'), 'Expected little endian 64-bit Mach-O')
    count = struct.unpack_from('<I', data, base + 16)[0]
    require(count < 10000, 'Invalid Mach-O load command count')
    cursor, sections = base + 32, {}
    for _ in range(count):
        kind, size = struct.unpack_from('<II', data, cursor)
        require(size >= 8 and cursor + size <= len(data), 'Invalid Mach-O load command size')
        if kind == 0x19:  # LC_SEGMENT_64
            number = struct.unpack_from('<I', data, cursor + 64)[0]
            require(72 + number * 80 <= size, 'Invalid Mach-O section count')
            for index in range(number):
                off = cursor + 72 + index * 80
                name, segment, address, length, offset = struct.unpack_from('<16s16sQQI', data, off)
                flags = struct.unpack_from('<I', data, off + 64)[0]
                if flags & 0xff in (1, 0xc, 0x12):  # zero-fill sections have no file bytes
                    continue
                require(base + offset + length <= len(data), 'Mach-O section exceeds file')
                key = segment.rstrip(b'\0').decode() + '/' + name.rstrip(b'\0').decode()
                require(key not in sections, 'Duplicate Mach-O section')
                sections[key] = hashlib.sha256(data[base + offset:base + offset + length]).hexdigest()
        cursor += size
    require(bool(sections), 'Mach-O code section selection empty')
    return sections


def portable_system_rpaths(path):
    """Remove unused build-machine search paths from a system-only runtime copy.

    No load dependency is removed or rewritten. Refuse non-system dependencies;
    their runpaths must instead be resolved and packaged explicitly.
    """
    architectures = command(['/usr/bin/lipo', '-archs', path]).split()
    before = {arch: inspect(path, arch) for arch in architectures}
    require(all(dep.startswith(SYSTEM) for m in before.values() for dep in m['dependencies']),
            'Cannot remove search paths from runtime with non-system dependencies')
    sections = code_sections(path)
    paths = {value for m in before.values() for value in m['rpaths']
             if value.startswith('/') and not value.startswith(SYSTEM)}
    for value in sorted(paths):
        command(['/usr/bin/install_name_tool', '-delete_rpath', value, path])
    for arch, old in before.items():
        current = inspect(path, arch)
        require(current['dependencies'] == old['dependencies'] and current['minimum_os'] == old['minimum_os'],
                'Runtime dependency or minimum changed while removing development rpaths')
    require(code_sections(path) == sections, 'Runtime code changed while removing development rpaths')


def compare_notice(source, destination):
    require(destination.is_file() and destination.stat().st_size > 0, 'Required copied notice missing')
    require(digest(source) == digest(destination), 'Copied notice differs from frozen source')


def verify_composition(app, configuration):
    resources = app / 'Contents/Resources'
    paths, notices = configuration['runtime_inputs'], configuration['notices']
    for name, relative in [('node_license', 'Playwright/NODE-LICENSE'), ('llama_cpp_license', 'LlamaCpp/LICENSE'),
                           ('cua_driver_license', 'CuaDriver/LICENSE.md')]:
        compare_notice(pathlib.Path(notices[name]), resources / relative)
    mlx = resources / 'MLXEngine'
    runpy.run_path(str(ROOT / 'scripts/verify-mlx-license-bundle.py'))['verify'](mlx)
    require(inventory(pathlib.Path(notices['mlx_licenses'])) == inventory(mlx / 'Licenses'), 'MLX notice composition differs')
    compare_notice(pathlib.Path(paths['mlx_engine_dir']) / 'Package.resolved', mlx / 'Package.resolved')
    modules = pathlib.Path(paths.get('playwright_modules', str(ROOT / 'Vendor/PlaywrightMCP/node_modules')))
    # Complete exact module tree, not just seven known notice filenames.
    verify_playwright_copy(modules, resources / 'Playwright/node_modules')
    runtime_sources = {
        'Playwright/node': pathlib.Path(paths['node_runtime']),
        'CuaDriver/cua-driver': pathlib.Path(paths['cua_driver_path']),
        'LlamaCpp/llama-server': pathlib.Path(paths['llama_cpp_dir']) / 'llama-server',
        'MLXEngine/aim-mlx-engine': pathlib.Path(paths['mlx_engine_dir']) / 'aim-mlx-engine',
    }
    for relative, source in runtime_sources.items():
        require(macho(resources / relative), 'Required runtime missing: ' + relative)
        require(code_sections(source) == code_sections(resources / relative), 'Bundled runtime code differs from frozen source')
    for name in runpy.run_path(str(ROOT / 'scripts/release/build-distribution.py'))['LLAMA_LIBRARIES']:
        require(macho(resources / 'LlamaCpp' / name), 'Required llama library missing')
        require(code_sections(pathlib.Path(paths['llama_cpp_dir']) / name) == code_sections(resources / 'LlamaCpp' / name), 'Bundled llama library code differs')
    source = pathlib.Path(paths['mlx_engine_dir'])
    for bundle in source.glob('*.bundle'):
        # Resource bundles contain no signatures/code in the prepared engine.
        require(inventory(bundle) == inventory(mlx / bundle.name), 'MLX resource bundle differs')
    swift = resources / 'SwiftRuntime'
    libraries = list((app / 'Contents/Frameworks').glob('libswift*.dylib'))
    if libraries:
        require((swift / 'provenance.json').is_file(), 'Swift runtime provenance missing')
        record = json.loads((swift / 'provenance.json').read_text())
        require(set(record['libraries']) == {p.name for p in libraries}, 'Swift runtime composition differs')
        require(digest(swift / 'Xcode-Acknowledgments.pdf') == record['notice_sha256'], 'Swift notice missing or changed')
        for name, entry in record['libraries'].items():
            require(code_sections(entry['source']) == code_sections(app / 'Contents/Frameworks' / name), 'Bundled Swift runtime code differs')
            require(digest(entry['source']) == entry['source_sha256'] == entry['unsigned_sha256'], 'Swift toolchain input drift')
        require(digest(record['tool']) == record['tool_sha256'], 'Swift packaging tool drift')
        require(digest(record['notice_source']) == record['notice_sha256'], 'Swift source notice drift')


def verify(app, configuration_path, manifest):
    input_verification = verify_manifest(manifest, configuration_path)
    config = json.loads(configuration_path.read_text())
    runpy.run_path(str(ROOT / 'scripts/release/build-distribution.py'))['validate_release'](config)
    for relative, identifier in [('Contents/Info.plist', 'com.aimai.macos'),
                                 ('Contents/Library/LoginItems/AIMAgentHost.app/Contents/Info.plist', 'com.aimai.macos.agenthost')]:
        info = plistlib.loads((app / relative).read_bytes())
        require(info.get('CFBundleIdentifier') == identifier, 'Bundle identity differs')
        require(info.get('CFBundleVersion') == config['application_build'] and
                info.get('CFBundleShortVersionString') == config['application_version'], 'Bundle version differs')
        require(not info.get('AIMQualificationNamespace') and not info.get('AIMAdHocSigned'), 'Qualification or ad hoc candidate refused')
        if relative == 'Contents/Info.plist':
            require(info.get('LSMinimumSystemVersion') == '14.0', 'Candidate minimum OS differs')
            require(info.get('SUFeedURL') == config['sparkle_feed_url'] and
                    info.get('SUPublicEDKey') == config['sparkle_public_key'], 'Sparkle feed or public key differs')
    verify_composition(app, config)
    result = graph(app)
    command(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    identity = 'Authority=' + config['codesign_identity']
    team = re.search(r'\(([^()]+)\)$', config['codesign_identity'])
    require(team is not None, 'Developer ID team missing')
    targets = [app] + [app / p for p in result['objects']] + [app / 'Contents/Library/LoginItems/AIMAgentHost.app']
    for target in targets:
        # codesign writes details to stderr, unlike otool.
        detail = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(target)],
                                check=True, text=True, capture_output=True)
        lines = (detail.stdout + detail.stderr).splitlines()
        require(identity in lines and 'TeamIdentifier=' + team.group(1) in lines,
                'Signed identity differs')
        require(any(x.startswith('Timestamp=') for x in lines) and any('runtime' in x for x in lines),
                'Missing timestamp or hardened runtime')
    # Extract only certificates already embedded in this signature; no Keychain read.
    with tempfile.TemporaryDirectory(prefix='public-certificate-', dir=configuration_path.parent) as temporary:
        prefix = pathlib.Path(temporary) / 'certificate'
        command(['/usr/bin/codesign', '-d', '--extract-certificates=' + str(prefix), app])
        require(hashlib.sha1(pathlib.Path(str(prefix) + '0').read_bytes()).hexdigest().upper() ==
                config['expected_identity_sha1'].upper(), 'Signing certificate SHA-1 differs')
    result.update(schema_version=1, static_verification='passed', input_verification=input_verification, artifact=inventory(app),
                  manifest_sha256=hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest())
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    modes = parser.add_subparsers(dest='mode', required=True)
    frozen = modes.add_parser('freeze')
    frozen.add_argument('--configuration', type=pathlib.Path, required=True)
    frozen.add_argument('--source-root', type=pathlib.Path, required=True)
    frozen.add_argument('--output', type=pathlib.Path, required=True)
    check = modes.add_parser('verify')
    check.add_argument('app', type=pathlib.Path)
    check.add_argument('--configuration', type=pathlib.Path, required=True)
    check.add_argument('--manifest', type=pathlib.Path, required=True)
    check.add_argument('--output', type=pathlib.Path, required=True)
    inputs = modes.add_parser('check-inputs')
    inputs.add_argument('--configuration', type=pathlib.Path, required=True)
    inputs.add_argument('--manifest', type=pathlib.Path, required=True)
    load = modes.add_parser('graph')
    load.add_argument('app', type=pathlib.Path)
    apple = modes.add_parser('portable-apple-rpaths')
    apple.add_argument('app', type=pathlib.Path)
    apple.add_argument('--scan', type=pathlib.Path, action='append', required=True)
    portable = modes.add_parser('portable-system-rpaths')
    portable.add_argument('executable', type=pathlib.Path)
    embed = modes.add_parser('embed-swift')
    embed.add_argument('app', type=pathlib.Path)
    embed.add_argument('--scan', type=pathlib.Path, action='append', required=True)
    args = parser.parse_args()
    if args.mode == 'freeze':
        write_new(args.output, freeze(args.configuration, args.source_root))
    elif args.mode == 'verify':
        write_new(args.output, verify(args.app, args.configuration, json.loads(args.manifest.read_text())))
    elif args.mode == 'check-inputs':
        print(json.dumps(verify_manifest(json.loads(args.manifest.read_text()), args.configuration), sort_keys=True))
    elif args.mode == 'graph':
        result = graph(args.app)
        print(json.dumps({'mach_o_objects': len(result['objects']), 'macos14_execution': 'not_verified'}))
    elif args.mode == 'portable-apple-rpaths':
        print(json.dumps(portable_apple_rpaths(args.app, args.scan), sort_keys=True))
    elif args.mode == 'portable-system-rpaths':
        portable_system_rpaths(args.executable)
    else:
        embed_swift(args.app, args.scan)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print('Candidate runtime refused: ' + str(error), file=sys.stderr)
        sys.exit(2)
