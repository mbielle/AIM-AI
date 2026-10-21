#!/usr/bin/env python3
"""Local-only guards and immutable provenance receipts for AIM distribution."""
import argparse
import ctypes
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import subprocess
import sys


def fail(message):
    raise RuntimeError(message)


def guard(paths, all_aim=False):
    if sys.platform != 'darwin':
        fail('The running-process guard requires macOS; refusing to continue')
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
    library.proc_listallpids.restype = ctypes.c_int
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    count = library.proc_listallpids(None, 0)
    if count <= 0:
        fail('Cannot inventory running processes')
    pids = (ctypes.c_int * (count + 1024))()
    actual = library.proc_listallpids(pids, ctypes.sizeof(pids))
    if actual <= 0 or actual >= len(pids):
        fail('Incomplete running-process inventory')
    roots = [str(pathlib.Path(p).resolve()) for p in paths]
    conflicts = []
    for pid in pids[:actual]:
        if pid <= 0 or pid == os.getpid():
            continue
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
            continue  # A process may exit between enumeration and inspection.
        executable = os.fsdecode(buffer.value)
        resolved = str(pathlib.Path(executable).resolve())
        matches = any(resolved == root or resolved.startswith(root + '/') for root in roots)
        if matches or (all_aim and pathlib.Path(executable).name in ('AIMMac', 'AIMAgentHost')):
            conflicts.append({'pid': pid, 'executable': executable})
    if conflicts:
        fail('Refusing to replace/rebuild an active AIM application or helper: ' + json.dumps(conflicts))


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def publish_new(source, destination):
    """Publish a new macOS bundle without a check/rename replacement race."""
    if sys.platform != 'darwin':
        fail('Exclusive bundle publication requires macOS')
    source, destination = pathlib.Path(source).absolute(), pathlib.Path(destination).absolute()
    if source.is_symlink() or not source.is_dir() or destination.parent.resolve() != source.parent.parent.resolve():
        fail('Qualification publication must stay in the same build directory')
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    # SDK sys/stdio.h: RENAME_EXCL = 0x00000004.
    if rename(os.fsencode(source), os.fsencode(destination), 0x4) != 0:
        fail('Exclusive qualification publication refused (errno ' + str(ctypes.get_errno()) + ')')


def inventory(path):
    if path.is_symlink():
        fail('Artifact root must not be a symlink')
    if path.is_file():
        return {'sha256': digest(path), 'bytes': path.stat().st_size}
    files = []
    for member in sorted(path.rglob('*')):
        relative = member.relative_to(path).as_posix()
        if member.is_symlink():
            files.append({'path': relative, 'symlink': os.readlink(member)})
        elif member.is_file():
            files.append({'path': relative, 'sha256': digest(member), 'bytes': member.stat().st_size,
                          'mode': oct(member.stat().st_mode & 0o777)})
        elif not member.is_dir():
            fail('Unsupported artifact member: ' + relative)
    canonical = json.dumps(files, sort_keys=True, separators=(',', ':')).encode()
    return {'inventory_sha256': hashlib.sha256(canonical).hexdigest(), 'files': files}


def command(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True)
    if result.returncode:
        fail('Verification failed: ' + ' '.join(arguments) + '\n' + result.stderr[-8192:])
    return (result.stdout + result.stderr).strip()


def validate_embedded_frameworks(path):
    """A signed bundle can still fail at launch when its portable rpath is missing."""
    executable = path / 'Contents/MacOS/AIMMac'
    if not path.is_dir() or not executable.is_file():
        return
    dependencies = command(['/usr/bin/otool', '-L', str(executable)])
    if not any(line.strip().startswith('@rpath/Sparkle.framework/')
               for line in dependencies.splitlines()):
        return
    framework = path / 'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle'
    if not framework.is_file():
        fail('AIMMac requires the embedded Sparkle framework, which is missing')
    commands = command(['/usr/bin/otool', '-l', str(executable)]).splitlines()
    rpaths = []
    for index, line in enumerate(commands):
        if line.strip() == 'cmd LC_RPATH':
            for detail in commands[index + 1:index + 4]:
                if detail.strip().startswith('path '):
                    rpaths.append(detail.strip()[5:].rsplit(' (offset ', 1)[0])
    if '@executable_path/../Frameworks' not in rpaths:
        fail('AIMMac lacks its portable embedded-framework rpath; patch it before signing')


def signature(path, release):
    validate_embedded_frameworks(path)
    command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(path)])
    details = command(['/usr/bin/codesign', '-d', '--verbose=4', str(path)])
    if release:
        if 'Authority=Developer ID Application:' not in details or 'Timestamp=' not in details:
            fail('Distribution requires a timestamped Developer ID Application signature')
        if path.is_dir() and 'runtime' not in details:
            fail('Distribution app requires hardened runtime')
    if release and path.is_dir():
        team = next((line for line in details.splitlines() if line.startswith('TeamIdentifier=')), None)
        magic = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
                 b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
        for member in path.rglob('*'):
            if member.is_file() and not member.is_symlink():
                with member.open('rb') as handle:
                    header = handle.read(4)
                if header not in magic:
                    continue
                nested = command(['/usr/bin/codesign', '-d', '--verbose=4', str(member)])
                if 'Authority=Developer ID Application:' not in nested or 'Timestamp=' not in nested or not team or team not in nested.splitlines():
                    fail('Nested executable requires timestamped signature from the same team: ' + str(member))
    return details


def matching_receipt(artifact, source):
    recorded = json.loads(pathlib.Path(source).read_text())
    if recorded.get('schema_version') != 1 or recorded.get('contents') != inventory(artifact):
        fail('Artifact contents differ from the supplied versioned receipt')
    return recorded


def receipt(args):
    artifact = pathlib.Path(args.artifact).absolute()
    if not artifact.exists():
        fail('Artifact does not exist')
    result = {'schema_version': 1, 'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'artifact': str(artifact), 'stage': args.stage, 'qualification': 'not_verified_on_clean_mac',
              'contents': inventory(artifact), 'signature': signature(artifact, args.release)}
    if artifact.is_dir():
        with (artifact / 'Contents/Info.plist').open('rb') as handle:
            info = plistlib.load(handle)
        result['bundle'] = {key: info.get(key) for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion')}
    if args.repository:
        repository = pathlib.Path(args.repository).resolve()
        commit = command(['/usr/bin/git', '-C', str(repository), 'rev-parse', 'HEAD'])
        state = command(['/usr/bin/git', '-C', str(repository), 'status', '--porcelain'])
        result['source_repository'] = {'path': str(repository), 'commit': commit,
                                       'dirty': bool(state), 'status_sha256': hashlib.sha256(state.encode()).hexdigest()}
    if args.source_receipt:
        source = pathlib.Path(args.source_receipt)
        result['source_receipt'] = {'path': str(source.absolute()), 'sha256': digest(source)}
    if args.profile:
        result['notary_profile_reference'] = args.profile  # Reference name only, never credentials.
    if args.gatekeeper:
        result['gatekeeper_assessment'] = pathlib.Path(args.gatekeeper).read_text()
    if args.submission:
        source = pathlib.Path(args.submission)
        result['notary_submission'] = json.loads(source.read_text())
        if result['notary_submission'].get('status') != 'Accepted':
            fail('Notary submission has not been accepted')
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('x', encoding='utf-8') as handle:
        os.chmod(output, 0o600)
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write('\n')
    print(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest='mode', required=True)
    check = modes.add_parser('guard')
    check.add_argument('--all-aim', action='store_true')
    check.add_argument('paths', nargs='*')
    publish = modes.add_parser('publish-new')
    publish.add_argument('source')
    publish.add_argument('destination')
    verify = modes.add_parser('verify')
    verify.add_argument('artifact')
    verify.add_argument('--receipt')
    record = modes.add_parser('receipt')
    record.add_argument('artifact')
    record.add_argument('--output', required=True)
    record.add_argument('--stage', choices=['built', 'packaged', 'notarized'], required=True)
    record.add_argument('--release', action='store_true')
    record.add_argument('--source-receipt')
    record.add_argument('--profile')
    record.add_argument('--submission')
    record.add_argument('--gatekeeper')
    record.add_argument('--repository')
    args = parser.parse_args()
    if args.mode == 'guard':
        guard(args.paths, args.all_aim)
    elif args.mode == 'publish-new':
        publish_new(args.source, args.destination)
    elif args.mode == 'verify':
        if args.receipt:
            matching_receipt(pathlib.Path(args.artifact), args.receipt)
        print(signature(pathlib.Path(args.artifact), True))
    else:
        receipt(args)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        print('Distribution refused: ' + str(error), file=sys.stderr)
        sys.exit(2)
