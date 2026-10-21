#!/usr/bin/env python3
"""Prepare pinned public runtimes in NEW private directories; never sign/install AIM.

prepare --output DIR downloads official Node 22.23.3 and exact pnpm 10.11.0,
then installs the unchanged Playwright lock with scripts/browser downloads disabled.
copy --node FILE --node-license FILE --modules DIR --destination NEW_DIR copies
self-contained resources and exact upstream notices before the caller signs.
"""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import plistlib
import re
import runpy
import shutil
import subprocess
import tarfile
import urllib.request
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[2]
NODE_VERSION = '22.23.3'
PNPM_VERSION = '10.11.0'
PACKAGES = {'@playwright/mcp': '0.0.82', 'playwright': '1.64.0-alpha-1789764292000',
            'playwright-core': '1.64.0-alpha-1789764292000'}


def digest(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def new_directory(path):
    path = pathlib.Path(path).absolute()
    if path.exists() or path.is_symlink() or any(p.is_symlink() for p in path.parents):
        raise ValueError('A new directory without symlink ancestors is required')
    path.mkdir(parents=True)
    return path


def official_url(url):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != 'https' or parsed.netloc not in ('nodejs.org', 'registry.npmjs.org')
            or parsed.username or parsed.password or parsed.fragment):
        raise ValueError('Only HTTPS official runtime sources are accepted')
    return url


class OfficialRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        official_url(new_url)
        return super().redirect_request(request, response, code, message, headers, new_url)


def fetch(url, destination):
    official_url(url)
    opener = urllib.request.build_opener(OfficialRedirects())
    with opener.open(url, timeout=120) as response:
        official_url(response.geturl())
        pathlib.Path(destination).write_bytes(response.read())


def verify_hash(path, expected, algorithm='sha256'):
    actual = hashlib.new(algorithm, pathlib.Path(path).read_bytes()).hexdigest()
    if actual != expected:
        raise ValueError('Archive integrity mismatch')


def extract(archive, destination, selected=None):
    """Inspect every member before writing anything. No tar links/devices accepted."""
    with tarfile.open(archive) as tar:
        members = tar.getmembers()
        seen = set()
        for member in members:
            name = pathlib.PurePosixPath(member.name)
            if (name.is_absolute() or '..' in name.parts or '\\' in member.name
                    or (not (member.isdir() or member.isfile()) and not (selected and member.issym() and not pathlib.PurePosixPath(member.linkname).is_absolute() and os.path.normpath(str(name.parent / member.linkname)) != '..' and not os.path.normpath(str(name.parent / member.linkname)).startswith('../'))) or member.name in seen):
                raise ValueError('Unsafe or duplicate archive member')
            seen.add(member.name)
        destination = new_directory(destination)
        for member in members:
            if selected is not None and member.name not in selected:
                continue
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
                target.chmod(member.mode & 0o755)
    return destination


def module_tree_digest(modules):
    modules = pathlib.Path(modules)
    records = []
    for path in sorted(modules.rglob('*')):
        if path.is_file() and path != modules / '.aim-runtime-manifest.json':
            records.append([str(path.relative_to(modules)), path.stat().st_mode & 0o777, digest(path)])
    return hashlib.sha256(json.dumps(records, separators=(',', ':')).encode()).hexdigest()


def validate_modules(modules):
    modules = pathlib.Path(modules)
    if not modules.is_dir() or modules.is_symlink():
        raise ValueError('Playwright modules directory required')
    base = modules.resolve()
    for path in modules.rglob('*'):
        if path.is_symlink() and (path.is_dir() or not path.resolve(strict=True).is_relative_to(base)):
            raise ValueError('Playwright symlink escapes prepared modules')
    actual = {}
    for manifest in modules.rglob('package.json'):
        data = json.loads(manifest.read_text())
        name = data.get('name')
        # Internal package.json exports/assets need not declare a package name.
        if not name:
            continue
        if name not in PACKAGES or data.get('version') != PACKAGES[name]:
            raise ValueError('Playwright package outside frozen graph')
        if name in actual:
            raise ValueError('Duplicate Playwright package')
        dependencies = data.get('dependencies', {})
        expected = {'@playwright/mcp': {'playwright': PACKAGES['playwright'], 'playwright-core': PACKAGES['playwright-core']},
                    'playwright': {'playwright-core': PACKAGES['playwright-core']}, 'playwright-core': {}}[name]
        if dependencies != expected:
            raise ValueError('Playwright dependency graph changed')
        actual[name] = manifest.parent
    if set(actual) != set(PACKAGES):
        raise ValueError('Missing frozen Playwright package')
    notices = []
    for name, package in actual.items():
        license_path = package / 'LICENSE'
        if not license_path.is_file() or license_path.stat().st_size < 100:
            raise ValueError('Missing full Playwright license')
        for file in sorted(package.iterdir()):
            if file.is_file() and re.search(r'license|notice|copying', file.name, re.I):
                if file.stat().st_size < 100:
                    raise ValueError('Empty Playwright notice')
                notices.append({'package': name, 'version': PACKAGES[name],
                                'path': str(file.relative_to(modules)), 'sha256': digest(file)})
    if not (modules / '@playwright/mcp/cli.js').is_file():
        raise ValueError('Missing Playwright CLI')
    receipt = modules / '.aim-runtime-manifest.json'
    if receipt.exists():
        saved = json.loads(receipt.read_text())
        if (saved.get('packages') != PACKAGES or saved.get('notices') != notices
                or saved.get('tree_sha256') != module_tree_digest(modules)):
            raise ValueError('Playwright notice receipt mismatch')
    return notices


def copy_resources(node, node_license, modules, destination):
    node, node_license, modules = map(pathlib.Path, (node, node_license, modules))
    if not node.is_file() or not os.access(node, os.X_OK):
        raise ValueError('Executable Node input required')
    if not node_license.is_file() or node_license.stat().st_size < 100:
        raise ValueError('Full Node license required')
    notices = validate_modules(modules)
    destination = new_directory(destination)
    shutil.copy2(node, destination / 'node')
    shutil.copy2(node_license, destination / 'NODE-LICENSE')
    # Dereference only after validating the complete tree stays inside input root.
    shutil.copytree(modules, destination / 'node_modules', symlinks=False)
    copied = validate_modules(destination / 'node_modules')
    if copied != notices or digest(destination / 'NODE-LICENSE') != digest(node_license):
        raise ValueError('Runtime notice copy mismatch')
    inventory = {'packages': PACKAGES, 'node_sha256': digest(node),
                 'node_license_sha256': digest(node_license), 'notices': copied}
    (destination / 'runtime-notices.json').write_text(json.dumps(inventory, indent=2) + '\n')
    return inventory


def validate_node(node):
    architecture = subprocess.run(['/usr/bin/file', str(node)], check=True, capture_output=True, text=True).stdout
    if 'Mach-O 64-bit executable arm64' not in architecture or 'x86_64' in architecture:
        raise ValueError('Node must be macOS arm64')
    dynamic = subprocess.run(['/usr/bin/otool', '-L', str(node)], check=True, capture_output=True, text=True).stdout
    if any(not line.strip().startswith(('/System/', '/usr/lib/')) for line in dynamic.splitlines()[1:] if line.strip()):
        raise ValueError('Node has external dynamic dependencies')
    version = subprocess.run([str(node), '--version'], check=True, capture_output=True, text=True,
                             env={'PATH': '/usr/bin:/bin'}).stdout.strip()
    if version != 'v' + NODE_VERSION:
        raise ValueError('Node version differs from pinned distribution')
    return architecture, dynamic


def prepare(output):
    output = new_directory(output)
    downloads = output / 'downloads'
    downloads.mkdir()
    prefix = 'https://nodejs.org/dist/v' + NODE_VERSION + '/'
    archive_name = 'node-v' + NODE_VERSION + '-darwin-arm64.tar.gz'
    for name in ('SHASUMS256.txt', 'SHASUMS256.txt.sig', archive_name):
        fetch(prefix + name, downloads / name)
    sums = (downloads / 'SHASUMS256.txt').read_text().splitlines()
    matches = [line.split()[0] for line in sums if line.split()[-1] == archive_name]
    if len(matches) != 1 or not re.fullmatch('[a-f0-9]{64}', matches[0]):
        raise ValueError('Missing exact official Node checksum')
    verify_hash(downloads / archive_name, matches[0])
    node_root = archive_name[:-7]
    node_dir = extract(downloads / archive_name, output / 'node-source',
                       {node_root + '/bin/node', node_root + '/LICENSE'}) / node_root
    node = node_dir / 'bin/node'
    architecture, dynamic = validate_node(node)
    metadata_path = downloads / 'pnpm-metadata.json'
    fetch('https://registry.npmjs.org/pnpm/' + PNPM_VERSION, metadata_path)
    metadata = json.loads(metadata_path.read_text())
    integrity = metadata['dist']['integrity']
    if metadata['version'] != PNPM_VERSION or not integrity.startswith('sha512-'):
        raise ValueError('Pinned pnpm integrity required')
    pnpm_archive = downloads / 'pnpm.tgz'
    fetch(metadata['dist']['tarball'], pnpm_archive)
    verify_hash(pnpm_archive, base64.b64decode(integrity[7:], validate=True).hex(), 'sha512')
    pnpm = extract(pnpm_archive, output / 'pnpm') / 'package/bin/pnpm.cjs'
    source = ROOT / 'Vendor/PlaywrightMCP'
    project = output / 'playwright'
    project.mkdir()
    for name in ('package.json', 'pnpm-lock.yaml'):
        shutil.copy2(source / name, project / name)
    lock_hash = digest(project / 'pnpm-lock.yaml')
    environment = {'PATH': str(node.parent) + ':/usr/bin:/bin', 'CFFIXED_USER_HOME': str(output / 'home'),
                   'XDG_CONFIG_HOME': str(output / 'home/config'), 'XDG_CACHE_HOME': str(output / 'home/cache'),
                   'npm_config_userconfig': str(output / 'home/user.npmrc'),
                   'npm_config_globalconfig': str(output / 'home/global.npmrc'),
                   'TMPDIR': str(output / 'tmp'), 'CI': 'true', 'PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD': '1',
                   'npm_config_ignore_scripts': 'true', 'COREPACK_ENABLE_DOWNLOAD_PROMPT': '0'}
    (output / 'home').mkdir()
    (output / 'tmp').mkdir()
    (output / 'home/user.npmrc').write_text('')
    (output / 'home/global.npmrc').write_text('')
    subprocess.run([str(node), str(pnpm), 'install', '--frozen-lockfile', '--ignore-scripts',
                    '--node-linker=hoisted', '--store-dir', str(output / 'pnpm-store')],
                   cwd=project, env=environment, check=True)
    if digest(project / 'pnpm-lock.yaml') != lock_hash or digest(source / 'pnpm-lock.yaml') != lock_hash:
        raise ValueError('Playwright frozen lock changed')
    modules = project / 'node_modules'
    notices = validate_modules(modules)
    (modules / '.aim-runtime-manifest.json').write_text(json.dumps({'packages': PACKAGES, 'notices': notices,
                                                                  'lock_sha256': lock_hash, 'tree_sha256': module_tree_digest(modules)}, indent=2) + '\n')
    resources = output / 'synthetic.app/Contents/Resources/Playwright'
    inventory = copy_resources(node, node_dir / 'LICENSE', modules, resources)
    subprocess.run([str(node), str(modules / '@playwright/mcp/cli.js'), '--version'],
                   check=True, env=environment)
    receipt = {'node_version': NODE_VERSION, 'node_source': prefix + archive_name,
               'node_archive_sha256': matches[0], 'node_signature_authenticated': False,
               'node_architecture': architecture.strip(), 'node_dynamic_dependencies': dynamic,
               'limitations': ['SHASUMS signature retained; no authenticated release-key verification available. No app signed or installed.'],
               'pnpm_version': PNPM_VERSION, 'pnpm_integrity': integrity,
               'playwright_lock_sha256': lock_hash, 'playwright_tree_sha256': module_tree_digest(modules), 'runtime_inputs': {'node_runtime': str(node),
               'playwright_modules': str(modules)}, 'notices': {'node_license': str(node_dir / 'LICENSE')},
               'copied_inventory': inventory}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


def system_environment():
    environment = {name: os.environ[name] for name in ('HOME', 'USER', 'LOGNAME') if name in os.environ}
    environment.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8',
                       GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0')
    return environment


def snapshot_mlx_notices(source, notices):
    source, notices = pathlib.Path(source), pathlib.Path(notices)
    if (not notices.is_dir() or notices.is_symlink()
            or any(path.is_symlink() for path in notices.rglob('*'))):
        raise ValueError('Declared MLX notices must be a real directory without symlinks')
    shutil.copytree(notices, source / 'Licenses')
    verifier = runpy.run_path(str(ROOT / 'scripts/verify-mlx-license-bundle.py'))['verify']
    verifier(source)
    return source / 'Licenses'


def installed_metal_toolchain():
    """Select existing GPU tools only; never download or replace a toolchain."""
    result = subprocess.run(['/usr/bin/xcodebuild', '-showComponent', 'MetalToolchain', '-json'],
                            check=True, capture_output=True, text=True, env=system_environment())
    component = json.loads(result.stdout)
    search = pathlib.Path(component.get('toolchainSearchPath', ''))
    identifier = component.get('toolchainIdentifier', '')
    if (component.get('status') != 'installed' or not search.is_absolute()
            or not identifier.startswith('com.apple.dt.toolchain.Metal.')):
        raise ValueError('An already installed official Metal component is required')
    toolchain = search / 'Metal.xctoolchain'
    info = plistlib.loads((toolchain / 'ToolchainInfo.plist').read_bytes())
    binaries = toolchain / 'usr/bin'
    metal = binaries / 'metal'
    if info.get('Identifier') != identifier or not metal.is_file() or not os.access(metal, os.X_OK):
        raise ValueError('Installed Metal toolchain metadata or executable mismatch')
    if any((binaries / name).exists() or (binaries / name).is_symlink()
           for name in ('swift', 'swiftc', 'clang', 'clang++', 'ld')):
        raise ValueError('Metal selection must not replace Swift or C/C++ toolchains')
    version = subprocess.run([str(metal), '--version'], check=True, capture_output=True, text=True, env=system_environment()).stdout.strip()
    if not version.startswith('Apple metal version '):
        raise ValueError('Installed Metal executable did not identify its version')
    return {'component': component, 'metal_version': version, 'metal_sha256': digest(metal),
            'environment': {'__XCODE_BUILT_PRODUCTS_DIR_PATHS': str(binaries)}}


def compile_mlx(output):
    output = pathlib.Path(output).resolve(strict=True)
    receipt = installed_metal_toolchain()
    command = ['/usr/bin/xcodebuild', '-scheme', 'AIMMLXEngine', '-destination', 'platform=macOS,arch=arm64',
               '-configuration', 'Release', '-derivedDataPath', str(output / 'dd'),
               '-clonedSourcePackagesDirPath', str(output / 'SourcePackages'),
               '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile',
               '-skipMacroValidation', '-skipPackagePluginValidation', 'CODE_SIGNING_ALLOWED=NO', 'build', '-quiet']
    environment = system_environment()
    environment.update(TMPDIR=str(output / 'tmp'), CFFIXED_USER_HOME=str(output / 'home'),
                       XDG_CACHE_HOME=str(output / 'home/cache'), XDG_CONFIG_HOME=str(output / 'home/config'))
    environment.update(receipt['environment'])
    receipt['command'] = command
    receipt['working_directory'] = str(output / 'source')
    with (output / 'metal-toolchain.json').open('x') as destination:
        destination.write(json.dumps(receipt, indent=2) + '\n')
    subprocess.run(command, cwd=output / 'source', env=environment, check=True)
    return receipt


def inventory_mlx(checkouts, resolved, output):
    """Collect exact source texts; completeness requires a separate human review."""
    checkouts, resolved = pathlib.Path(checkouts), pathlib.Path(resolved)
    pins = json.loads(resolved.read_text())['pins']
    output = new_directory(output)
    components = []
    for pin in pins:
        matches = [p for p in checkouts.iterdir() if p.name.lower() == pin['identity'].lower()]
        if len(matches) != 1:
            raise ValueError('Missing exact MLX checkout')
        checkout = matches[0]
        revision = subprocess.run(['/usr/bin/git', '-C', str(checkout), 'rev-parse', 'HEAD'],
                                  check=True, capture_output=True, text=True).stdout.strip()
        if revision != pin['state']['revision']:
            raise ValueError('MLX checkout revision differs from frozen lock')
        records = []
        for source in sorted(checkout.rglob('*')):
            relative = source.relative_to(checkout)
            if '.git' in relative.parts or source.is_symlink() or not source.is_file():
                continue
            if not re.search(r'license|notice|copying|acknowledg', source.name, re.I):
                continue
            if source.name.startswith('.') or source.stat().st_size == 0:
                continue
            target = output / pin['identity'] / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            record = {'path': str(target.relative_to(output)), 'sha256': digest(target),
                      'upstream_path': str(relative), 'source_revision': revision}
            if target.stat().st_size < 100:
                # Preserve original bytes separately; verifier expects >=100-byte texts.
                licenses = [p for p in checkout.iterdir() if p.is_file() and p.name.upper().startswith('LICENSE')]
                if not licenses:
                    raise ValueError('Short notice needs an accompanying full license')
                combined = target.with_name(target.name + '.with-project-license')
                combined.write_bytes(licenses[0].read_bytes() + b'\n' + target.read_bytes())
                record.update(original_path=record['path'], original_sha256=record['sha256'],
                              path=str(combined.relative_to(output)), sha256=digest(combined))
            records.append(record)
        if not records:
            raise ValueError('Missing pinned MLX upstream licenses')
        components.append({'identity': pin['identity'], 'revision': revision,
                           'source': pin['location'], 'licenses': records})
    mlx = next(p for p in checkouts.iterdir() if p.name.lower() == 'mlx-swift')
    mlx_revision = next(pin['state']['revision'] for pin in pins if pin['identity'] == 'mlx-swift')
    for relative in ('LICENSE', 'ACKNOWLEDGMENTS.md', 'Source/Cmlx/mlx/LICENSE',
                     'Source/Cmlx/mlx/ACKNOWLEDGMENTS.md', 'Source/Cmlx/mlx-c/LICENSE',
                     'Source/Cmlx/mlx-c/ACKNOWLEDGMENTS.md', 'Source/Cmlx/fmt/LICENSE',
                     'Source/Cmlx/json/LICENSE.MIT', 'Source/Cmlx/metal-cpp/LICENSE.txt'):
        if not (mlx / relative).is_file():
            raise ValueError('Missing declared embedded MLX notice')
    embedded_sources = []
    for name, expected in {'mlx': '1f8e74e3f12f31365464a6867c6579f0e9b29d85',
                           'mlx-c': 'ebc88f10caa1b625e6b581437a8dea6df8a70085'}.items():
        revision = subprocess.run(['/usr/bin/git', '-C', str(mlx / 'Source/Cmlx' / name), 'rev-parse', 'HEAD'],
                                  check=True, capture_output=True, text=True).stdout.strip()
        if revision != expected:
            raise ValueError('Vendored MLX submodule revision mismatch')
        source = 'https://github.com/ml-explore/' + name
        prefix = 'Source/Cmlx/' + name + '/'
        embedded_sources.append({'identity': 'cmlx-' + name, 'source': source,
                                 'gitlink_revision': revision, 'parent_identity': 'mlx-swift',
                                 'parent_revision': mlx_revision, 'path': prefix.rstrip('/')})
        for component in components:
            if component['identity'] == 'mlx-swift':
                for record in component['licenses']:
                    if record['upstream_path'].startswith(prefix):
                        record.update(source=source, source_revision=revision, parent_revision=mlx_revision)
    for name, version, upstream in (
            ('fmt', '12.1.0', 'https://github.com/fmtlib/fmt'),
            ('json', '3.11.3', 'https://github.com/nlohmann/json'),
            ('metal-cpp', 'macOS15_iOS18-beta with upstream vendor patch', 'https://developer.apple.com/metal/cpp/')):
        embedded_sources.append({'identity': 'cmlx-' + name, 'upstream_source': upstream,
                                 'vendored_version_label': version, 'parent_identity': 'mlx-swift',
                                 'parent_revision': mlx_revision, 'path': 'Source/Cmlx/' + name,
                                 'provenance': 'Tracked vendored bytes at parent revision; label comes from Source/Cmlx/vendor-README.md, not an independently authenticated upstream archive.'})
    manifest = {'complete': False, 'review_required': 'Review vendored C/C++, acknowledgments and platform build graph before setting complete.',
                'resolved_sha256': digest(resolved), 'embedded_sources': embedded_sources,
                'graph_notes': ['Inventory includes extra source notices conservatively; it does not assert every checkout target is linked.',
                                'Engine roots are MLXLLM, MLXLMCommon and Tokenizers, with empty MLX LM traits.',
                                'macOS Crypto uses CryptoKit; BoringSSL is a non-Darwin conditional dependency.',
                                'XGrammar and picojson source notices are retained where present but XGrammar target is outside this engine graph.'],
                'components': components}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    acquire = sub.add_parser('prepare')
    acquire.add_argument('--output', type=pathlib.Path, required=True)
    snapshot = sub.add_parser('snapshot-mlx-notices')
    snapshot.add_argument('--source', type=pathlib.Path, required=True)
    snapshot.add_argument('--notices', type=pathlib.Path, required=True)
    compile_engine = sub.add_parser('compile-mlx')
    compile_engine.add_argument('--output', type=pathlib.Path, required=True)
    metal = sub.add_parser('metal-toolchain')
    metal.add_argument('--receipt', type=pathlib.Path, required=True)
    inventory = sub.add_parser('inventory-mlx')
    for name in ('checkouts', 'resolved', 'output'):
        inventory.add_argument('--' + name, type=pathlib.Path, required=True)
    copy = sub.add_parser('copy')
    for name in ('node', 'node-license', 'modules', 'destination'):
        copy.add_argument('--' + name, type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare(args.output)
    elif args.command == 'snapshot-mlx-notices':
        snapshot_mlx_notices(args.source, args.notices)
    elif args.command == 'compile-mlx':
        compile_mlx(args.output)
    elif args.command == 'metal-toolchain':
        receipt = installed_metal_toolchain()
        with args.receipt.open('x') as output:
            output.write(json.dumps(receipt, indent=2) + '\n')
        print(receipt['environment']['__XCODE_BUILT_PRODUCTS_DIR_PATHS'])
    elif args.command == 'inventory-mlx':
        inventory_mlx(args.checkouts, args.resolved, args.output)
    else:
        copy_resources(args.node, args.node_license, args.modules, args.destination)


if __name__ == '__main__':
    main()
