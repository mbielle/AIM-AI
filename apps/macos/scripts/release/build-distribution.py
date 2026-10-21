#!/usr/bin/env python3
"""Build a new Developer ID candidate; never notarize, install or launch it.

Usage: build-distribution.py --configuration reviewed.json --output-app <macos>/build/New.app
Historical mode additionally accepts --reference-app <verified.app>.

The JSON retains application_version, application_build, codesign_identity,
expected_identity_sha1, sparkle_feed_url, sparkle_account and sparkle_public_key.
Without --reference-app it also requires absolute paths in these objects:
  runtime_inputs: node_runtime, llama_cpp_dir, mlx_engine_dir, cua_driver_path
  notices: node_license, llama_cpp_license, mlx_licenses, cua_driver_license
llama_cpp_license must be runtime_inputs.llama_cpp_dir/LICENSE; mlx_licenses
must be runtime_inputs.mlx_engine_dir/Licenses. The lower builder copies these
and the separate Node/CUA notices before signature. runtime_inputs optionally
accepts playwright_modules for an isolated frozen installation.
The MLX directory also needs its reviewed Package.resolved/license manifest.
Optional public_supabase contains url and public_key together, or neither.
No runtime, backend or build option is taken from ambient AIM_* variables.
Reference mode gets runtimes/backend from the strictly verified bundle and CUA
from the historical driver-qualification paths; explicit inputs cannot be mixed.
These preflights do not establish runtime provenance, rights or release acceptance.
"""
import argparse
import base64
import binascii
import json
import hashlib
import os
import pathlib
import plistlib
import re
import runpy
import subprocess
import sys
import urllib.parse

root = pathlib.Path(__file__).resolve().parents[2]
LLAMA_LIBRARIES = (
    'libllama-server-impl.dylib', 'libllama-common.0.dylib', 'libmtmd.0.dylib',
    'libllama.0.dylib', 'libggml.0.dylib', 'libggml-cpu.0.dylib',
    'libggml-blas.0.dylib', 'libggml-metal.0.dylib', 'libggml-rpc.0.dylib',
    'libggml-base.0.dylib',
)


class ReviewedInputError(ValueError):
    """A prerequisite diagnostic whose text contains no supplied values."""


def reviewed_string(configuration, key):
    value = configuration.get(key)
    if not isinstance(value, str) or not value or value != value.strip() or '\0' in value:
        raise ReviewedInputError('Reviewed ' + key + ' required')
    return value


def validate_release(configuration):
    version = reviewed_string(configuration, 'application_version')
    build = reviewed_string(configuration, 'application_build')
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', version) or not re.fullmatch(r'[1-9][0-9]*', build):
        raise ReviewedInputError('Reviewed application_version and application_build required')
    identity = reviewed_string(configuration, 'codesign_identity')
    sha = reviewed_string(configuration, 'expected_identity_sha1')
    if not identity.startswith('Developer ID Application: ') or any(c in identity for c in '\r\n"'):
        raise ReviewedInputError('Reviewed Developer ID Application identity required')
    if not re.fullmatch(r'[0-9A-Fa-f]{40}', sha):
        raise ReviewedInputError('Reviewed certificate SHA-1 required')
    feed = reviewed_string(configuration, 'sparkle_feed_url')
    try:
        url = urllib.parse.urlsplit(feed)
        port = url.port
        if (url.scheme != 'https' or not url.hostname or url.username is not None
                or url.password is not None or '#' in feed or '?' in feed
                or any(c.isspace() for c in feed) or '\\' in feed
                or url.netloc.endswith(':') or (port is not None and not 1 <= port <= 65535)):
            raise ValueError()
    except ValueError:
        raise ReviewedInputError('HTTPS public feed without credentials, query or fragment required') from None
    account = reviewed_string(configuration, 'sparkle_account')
    if account.startswith('-') or any(c in account for c in '\r\n'):
        raise ReviewedInputError('Reviewed named Sparkle account required')
    public_key = reviewed_string(configuration, 'sparkle_public_key')
    try:
        if len(base64.b64decode(public_key, validate=True)) != 32:
            raise ValueError()
    except (ValueError, binascii.Error):
        raise ReviewedInputError('Reviewed Sparkle public key must encode 32 bytes') from None


def new_target(path):
    target = path.absolute()
    build = root / 'build'
    if (target.exists() or target.is_symlink() or target.parent != build
            or target.suffix != '.app' or build.is_symlink()
            or (build.exists() and not build.is_dir())):
        raise ReviewedInputError('New app path inside build/ required; existing paths and symlinks are refused')
    return target


def new_scratch(path):
    """Only an explicit, absent direct child of this checkout's build directory."""
    target = path.absolute()
    build = root / 'build'
    if (not path.is_absolute() or target.parent != build or target.name in ('.', '..')
            or target.suffix == '.app' or target.exists() or target.is_symlink()
            or build.is_symlink() or (build.exists() and not build.is_dir())):
        raise ReviewedInputError('Fresh absolute Swift scratch directly inside build/ required; existing paths and symlinks refused')
    return target


def exact_object(value, keys, name):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise ReviewedInputError('Reviewed ' + name + ' requires exactly: ' + ', '.join(keys))
    return value


def input_path(value, name, directory=False, executable=False):
    if not isinstance(value, str) or not value or '\0' in value or not pathlib.Path(value).is_absolute():
        raise ReviewedInputError('Reviewed absolute path required for ' + name)
    path = pathlib.Path(value)
    valid = path.is_dir() if directory else path.is_file()
    if not valid or (not directory and path.stat().st_size == 0) or (executable and not os.access(path, os.X_OK)):
        raise ReviewedInputError('Missing, empty or unusable reviewed input: ' + name)
    return path.resolve(strict=True)


def validate_backend(value):
    if not isinstance(value, dict) or set(value) - {'url', 'public_key'}:
        raise ReviewedInputError('public_supabase accepts only url and public_key')
    url, key = value.get('url', ''), value.get('public_key', '')
    if not isinstance(url, str) or not isinstance(key, str):
        raise ReviewedInputError('Public Supabase URL and key must be strings')
    if not url and not key:
        return {}
    if not url or not key:
        raise ReviewedInputError('Public Supabase URL and key are required together')
    # Reuse the lower builder's validator; never print either input value.
    validator = runpy.run_path(str(root / 'scripts/validate-client-config.py'))
    try:
        validator['validate_origin'](url)
        validator['validate_public_key'](key)
    except ValueError as error:
        # The shared validator emits fixed diagnostics without either input value.
        raise ReviewedInputError(str(error)) from None
    return {'AIM_SUPABASE_URL': url.strip(), 'AIM_SUPABASE_PUBLIC_KEY': key.strip()}


def validate_runtime_paths(paths, modules=None):
    node = input_path(str(paths['node_runtime']), 'node_runtime', executable=True)
    llama = input_path(str(paths['llama_cpp_dir']), 'llama_cpp_dir', directory=True)
    mlx = input_path(str(paths['mlx_engine_dir']), 'mlx_engine_dir', directory=True)
    cua = input_path(str(paths['cua_driver_path']), 'cua_driver_path', executable=True)
    input_path(str(llama / 'llama-server'), 'llama-server', executable=True)
    input_path(str(llama / 'LICENSE'), 'llama.cpp LICENSE')
    for library in LLAMA_LIBRARIES:
        input_path(str(llama / library), 'llama.cpp ' + library)
    input_path(str(mlx / 'aim-mlx-engine'), 'aim-mlx-engine', executable=True)
    input_path(str(mlx / 'mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib'), 'MLX Metal library')
    verifier = runpy.run_path(str(root / 'scripts/verify-mlx-license-bundle.py'))
    try:
        verifier['verify'](mlx)
    except (ValueError, KeyError, TypeError, OSError):
        raise ReviewedInputError('MLX notices require reviewed, complete and consistent Package.resolved and Licenses') from None
    modules = input_path(str(modules or root / 'Vendor/PlaywrightMCP/node_modules'), 'Playwright modules', directory=True)
    input_path(str(modules / '@playwright/mcp/cli.js'), 'vendored Playwright MCP cli.js')
    try:
        runpy.run_path(str(pathlib.Path(__file__).with_name('prepare-runtime-inputs.py')))['validate_modules'](modules)
    except (ValueError, KeyError, TypeError, OSError):
        raise ReviewedInputError('Playwright requires the frozen package graph and full unchanged notices') from None
    return {'AIM_NODE_RUNTIME': str(node), 'AIM_PLAYWRIGHT_MODULES': str(modules), 'AIM_LLAMA_CPP_DIR': str(llama),
            'AIM_MLX_ENGINE_DIR': str(mlx), 'AIM_CUA_DRIVER_PATH': str(cua)}


def explicit_inputs(configuration):
    paths = configuration.get('runtime_inputs')
    required = {'node_runtime', 'llama_cpp_dir', 'mlx_engine_dir', 'cua_driver_path'}
    if not isinstance(paths, dict) or not required <= set(paths) or set(paths) - required - {'playwright_modules'}:
        raise ReviewedInputError('Reviewed runtime_inputs requires four runtime paths and optional playwright_modules')
    modules = paths.get('playwright_modules')
    if 'playwright_modules' in paths:
        modules = input_path(modules, 'playwright_modules', directory=True)
    paths = {name: paths[name] for name in required}
    notices = exact_object(configuration.get('notices'),
                           ('node_license', 'llama_cpp_license', 'mlx_licenses', 'cua_driver_license'), 'notices')
    resolved = {name: input_path(value, name, directory=name.endswith('_dir'),
                                 executable=name in ('node_runtime', 'cua_driver_path'))
                for name, value in paths.items()}
    legal = {name: input_path(value, name, directory=name == 'mlx_licenses')
             for name, value in notices.items()}
    if (legal['llama_cpp_license'] != (resolved['llama_cpp_dir'] / 'LICENSE').resolve()
            or legal['mlx_licenses'] != (resolved['mlx_engine_dir'] / 'Licenses').resolve()):
        raise ReviewedInputError('Reviewed llama.cpp and MLX notices must match the lower builder input layout')
    if legal['node_license'].stat().st_size < 100:
        raise ReviewedInputError('Full Node license required')
    env = validate_runtime_paths(resolved, modules)
    env['AIM_NODE_LICENSE'] = str(legal['node_license'])
    env['AIM_CUA_DRIVER_LICENSE'] = str(legal['cua_driver_license'])
    env.update(validate_backend(configuration.get('public_supabase', {})))
    return env


def reference_inputs(reference, environment):
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(reference)],
                   check=True, env=environment)
    info = plistlib.loads((reference / 'Contents/Info.plist').read_bytes())
    resources = reference.resolve(strict=True) / 'Contents/Resources'
    env = validate_runtime_paths({
        'node_runtime': resources / 'Playwright/node',
        'llama_cpp_dir': resources / 'LlamaCpp',
        'mlx_engine_dir': resources / 'MLXEngine',
        'cua_driver_path': root / 'build/driver-qualification/cua-driver-rs-0.28.2-darwin-arm64/cua-driver',
    }, resources / 'Playwright/node_modules')
    license_path = input_path(str(resources / 'Playwright/NODE-LICENSE'), 'historical Node license')
    if license_path.stat().st_size < 100:
        raise ReviewedInputError('Full historical Node license required')
    env['AIM_NODE_LICENSE'] = str(license_path)
    env['AIM_CUA_DRIVER_LICENSE'] = str(input_path(str(root / 'build/driver-qualification/LICENSE.md'), 'historical CUA license'))
    env.update(validate_backend({'url': info.get('AIMSupabaseURL', ''),
                                 'public_key': info.get('AIMSupabasePublicKey', '')}))
    return env


def sparkle_key_tool(configuration):
    reviewed = configuration.get('sparkle_key_tool')
    if reviewed is None:
        return root / '.build/artifacts/sparkle/Sparkle/bin/generate_keys'
    exact_object(reviewed, ('path', 'sha256'), 'sparkle_key_tool')
    path = input_path(reviewed['path'], 'sparkle_key_tool', executable=True)
    if (not isinstance(reviewed['sha256'], str) or
            not re.fullmatch(r'[0-9a-f]{64}', reviewed['sha256']) or
            hashlib.sha256(path.read_bytes()).hexdigest() != reviewed['sha256']):
        raise ReviewedInputError('Reviewed Sparkle key tool hash mismatch')
    if path.name != 'generate_keys' or path.parent.name != 'bin':
        raise ReviewedInputError('Reviewed Sparkle tool distribution layout required')
    info = path.parent.parent / 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Resources/Info.plist'
    try:
        pins = json.loads((root / 'Package.resolved').read_text())['pins']
        pin = next(p for p in pins if p['identity'] == 'sparkle')['state']['version']
        if plistlib.loads(info.read_bytes()).get('CFBundleShortVersionString') != pin:
            raise ValueError()
    except (KeyError, StopIteration, ValueError, OSError):
        raise ReviewedInputError('Sparkle tool version must match the unchanged Package.resolved pin') from None
    return path


def verify_frozen_inputs(manifest_path, configuration_path):
    verifier = runpy.run_path(str(pathlib.Path(__file__).with_name('verify-candidate-runtime.py')))
    result = verifier['verify_manifest'](json.loads(manifest_path.read_text()), configuration_path)
    print('Frozen build inputs unchanged; documentation changes: ' + str(len(result['documentation_drift'])))


def clean_environment():
    # No inherited AIM_*, shell startup hooks, toolchain overrides or secret config.
    environment = {key: os.environ[key] for key in ('HOME', 'TMPDIR', 'USER', 'LOGNAME') if key in os.environ}
    environment.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', LANG='en_US.UTF-8',
                       LC_ALL='en_US.UTF-8', PYTHONDONTWRITEBYTECODE='1')
    return environment


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--configuration', type=pathlib.Path, required=True)
    parser.add_argument('--reference-app', type=pathlib.Path, help='Historical strictly signed reference bundle; cannot mix explicit inputs')
    parser.add_argument('--output-app', type=pathlib.Path, required=True)
    parser.add_argument('--input-manifest', type=pathlib.Path, help='Versioned freeze; recheck before credentials/build and after build')
    parser.add_argument('--swift-scratch', type=pathlib.Path, help='Explicit fresh direct child of build/; legacy default is unchanged')
    args = parser.parse_args(arguments)
    configuration = json.loads(args.configuration.read_text())
    if not isinstance(configuration, dict):
        raise ReviewedInputError('Reviewed JSON configuration object required')
    validate_release(configuration)
    target = new_target(args.output_app)
    key_tool = sparkle_key_tool(configuration)
    scratch = new_scratch(args.swift_scratch) if args.swift_scratch else root / '.build'
    environment = clean_environment()
    if args.reference_app:
        if any(key in configuration for key in ('runtime_inputs', 'notices', 'public_supabase')):
            raise ReviewedInputError('Reference mode cannot mix explicit runtime, notice or backend inputs')
    else:
        environment.update(explicit_inputs(configuration))
    # The first external operation guards all AIM apps before artifacts/builds can change.
    subprocess.run(['/usr/bin/python3', str(root / 'scripts/distribution-tools.py'),
                    'guard', '--all-aim', str(target), str(scratch)], check=True, env=environment)
    if args.input_manifest:
        verify_frozen_inputs(args.input_manifest, args.configuration)
    if args.reference_app:
        environment.update(reference_inputs(args.reference_app, environment))
    identities = subprocess.run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'],
                                check=True, capture_output=True, text=True, env=environment).stdout
    expected = (configuration['expected_identity_sha1'].upper(), configuration['codesign_identity'])
    available = [match.groups() for line in identities.splitlines()
                 if (match := re.fullmatch(r'\s*\d+\) ([0-9A-Fa-f]{40}) "([^"\r\n]+)"\s*', line))]
    if not any((sha.upper(), identity) == expected for sha, identity in available):
        raise ReviewedInputError('Reviewed Developer ID identity and certificate SHA-1 are not available together')
    key_tool = sparkle_key_tool(configuration)  # Check reviewed hash again before public lookup.
    key = subprocess.run([str(key_tool), '--account', configuration['sparkle_account'], '-p'],
                         check=True, capture_output=True, text=True, env=environment).stdout.strip()
    if key != configuration['sparkle_public_key']:
        raise ReviewedInputError('Keychain public key mismatch')
    environment.update(AIM_RELEASE_VERSION=configuration['application_version'],
                       AIM_RELEASE_BUILD=configuration['application_build'],
                       AIM_CODESIGN_IDENTITY=configuration['codesign_identity'], AIM_APP_OUTPUT=str(target),
                       AIM_SPARKLE_FEED_URL=configuration['sparkle_feed_url'],
                       AIM_SPARKLE_PUBLIC_KEY=configuration['sparkle_public_key'])
    new_target(target)  # Never knowingly hand an existing/dangling destination to the lower builder.
    command = ['/bin/zsh', '-f', str(root / 'scripts/build-app.sh'), 'release']
    if args.swift_scratch:
        new_scratch(scratch)  # Refuse a destination that appeared during credential preflight.
        command += ['--swift-scratch', str(scratch)]
    subprocess.run(command, cwd=root, env=environment, check=True)
    if args.input_manifest:
        verify_frozen_inputs(args.input_manifest, args.configuration)


def cli():
    try:
        main()
    except ReviewedInputError as error:
        print('Distribution build refused: ' + str(error), file=sys.stderr)
        return 2
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError):
        # Public configuration can still contain secrets entered in error. Do not echo it.
        print('Distribution build refused; check reviewed inputs and local prerequisites.', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(cli())
