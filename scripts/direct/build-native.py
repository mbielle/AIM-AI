#!/usr/bin/env python3
"""Build pinned upstream sources into Apple's static XCFramework. No signing/accounts."""
import argparse, hashlib, json, os, pathlib, shutil, subprocess
ROOT = pathlib.Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'packages/AIMDirectNative'
PINS = json.loads((PACKAGE / 'dependencies.lock.json').read_text())
def run(args): subprocess.run([str(x) for x in args], check=True)
def source(cache, name, fetch):
    path = cache / (name + '-src'); pin = PINS[name]
    if not path.exists():
        if not fetch: raise SystemExit('Source missing; pass --fetch: ' + str(path))
        path.mkdir(parents=True); run(['git', '-C', path, 'init'])
        run(['git', '-C', path, 'remote', 'add', 'origin', pin['repository']])
        run(['git', '-C', path, 'fetch', '--depth', '1', 'origin', pin['commit']])
        run(['git', '-C', path, 'checkout', '--detach', pin['commit']])
        run(['git', '-C', path, 'submodule', 'update', '--init', '--recursive', '--depth', '1'])
    actual = subprocess.check_output(['git', '-C', path, 'rev-parse', 'HEAD'], text=True).strip()
    if actual != pin['commit']: raise SystemExit('Unexpected source commit: ' + name)
    dirty = subprocess.check_output(['git', '-C', path, 'status', '--porcelain', '--untracked-files=no'], text=True)
    if dirty: raise SystemExit('Tracked source modifications refused: ' + name)
    return path

def prepare_datachannel(cache, original):
    patches = PINS.get('patches', [])
    for patch in patches:
        if hashlib.sha256((PACKAGE/patch['file']).read_bytes()).hexdigest() != patch['sha256']: raise SystemExit('Patch hash mismatch')
    digest = hashlib.sha256(''.join(x['sha256'] for x in patches).encode()).hexdigest()[:12]
    prepared = cache / ('libdatachannel-aim-' + digest)
    def verify_prepared(path):
        modified = {name:digest for patch in patches for name,digest in patch.get('modifiedFiles', {}).items()}
        expected = set()
        for file in original.rglob('*'):
            relative = file.relative_to(original)
            if '.git' in relative.parts or '.build' in relative.parts or not file.is_file(): continue
            name = str(relative); expected.add(name)
            required = modified.get(name) or hashlib.sha256(file.read_bytes()).hexdigest()
            candidate = path/relative
            if not candidate.is_file() or hashlib.sha256(candidate.read_bytes()).hexdigest() != required:
                raise SystemExit('Prepared source differs from pinned source + reviewed patch: '+name)
        actual = {str(x.relative_to(path)) for x in path.rglob('*') if x.is_file()}
        if actual != expected: raise SystemExit('Unexpected files in prepared source')
    if prepared.exists():
        verify_prepared(prepared); return prepared
    temporary = cache / ('libdatachannel-aim-' + digest + '.preparing')
    if temporary.exists(): raise SystemExit('Incomplete prepared source; inspect it before retrying: '+str(temporary))
    shutil.copytree(original, temporary, ignore=shutil.ignore_patterns('.git', '.build'))
    for patch in patches:
        file = PACKAGE / patch['file']
        if hashlib.sha256(file.read_bytes()).hexdigest() != patch['sha256']: raise SystemExit('Patch hash mismatch')
        run(['patch', '-p1', '--batch', '--forward', '-d', temporary, '-i', file])
    verify_prepared(temporary)
    temporary.rename(prepared)
    return prepared

def main():
    p = argparse.ArgumentParser(); p.add_argument('--cache', type=pathlib.Path, required=True)
    p.add_argument('--cmake', default='cmake'); p.add_argument('--fetch', action='store_true')
    p.add_argument('--platforms', default='macos-arm64,macos-x86_64,ios-arm64,sim-arm64,sim-x86_64')
    p.add_argument('--jobs', type=int, default=4); p.add_argument('--assemble', action='store_true')
    a = p.parse_args(); cache = a.cache.resolve(); cache.mkdir(parents=True, exist_ok=True)
    sources = {n: source(cache, n, a.fetch) for n in ('libdatachannel','mbedtls')}
    datachannel = prepare_datachannel(cache, sources['libdatachannel'])
    products = []
    for platform in a.platforms.split(','):
        system, arch = platform.split('-', 1)
        if system not in ('macos','ios','sim') or arch not in ('arm64','x86_64'): raise SystemExit('Invalid target')
        build = cache / platform; prefix = build / 'tls-install'; build.mkdir(exist_ok=True)
        flags = ['-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES='+arch,
                 '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON']
        if system == 'macos': flags += ['-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0']
        else: flags += ['-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_SYSROOT='+('iphoneos' if system == 'ios' else 'iphonesimulator'), '-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0']
        tls = build / 'tls'; rtc = build / ('rtc-' + datachannel.name)
        config = build / 'aim-mbedtls-config.h'
        upstream_config = (sources['mbedtls']/'include/mbedtls/mbedtls_config.h').read_text()
        if '//#define MBEDTLS_SSL_DTLS_SRTP' not in upstream_config: raise SystemExit('Review upstream TLS configuration')
        config.write_text(upstream_config.replace('//#define MBEDTLS_SSL_DTLS_SRTP', '#define MBEDTLS_SSL_DTLS_SRTP'))
        run([a.cmake, '-S', sources['mbedtls'], '-B', tls, *flags, '-DCMAKE_INSTALL_PREFIX='+str(prefix), '-DMBEDTLS_CONFIG_FILE='+str(config), '-DENABLE_PROGRAMS=OFF','-DENABLE_TESTING=OFF','-DUSE_SHARED_MBEDTLS_LIBRARY=OFF'])
        run([a.cmake, '--build', tls, '--parallel', str(a.jobs)])
        run([a.cmake, '--install', tls])
        shutil.copy2(config, prefix/'include/mbedtls/mbedtls_config.h')
        run([a.cmake, '-S', datachannel, '-B', rtc, *flags, '-DCMAKE_PREFIX_PATH='+str(prefix), '-DMbedTLS_INCLUDE_DIR='+str(prefix/'include'), '-DMbedTLS_LIBRARY='+str(prefix/'lib/libmbedtls.a'), '-DMbedCrypto_LIBRARY='+str(prefix/'lib/libmbedcrypto.a'), '-DMbedX509_LIBRARY='+str(prefix/'lib/libmbedx509.a'), '-DUSE_MBEDTLS=ON', '-DNO_MEDIA=ON', '-DNO_WEBSOCKET=ON','-DNO_EXAMPLES=ON','-DNO_TESTS=ON','-DBUILD_SHARED_LIBS=OFF','-DRTC_UPDATE_VERSION_HEADER=OFF'])
        run([a.cmake, '--build', rtc, '--target', 'datachannel', '--parallel', str(a.jobs)])
        libraries = [rtc/'libdatachannel.a', rtc/'deps/libjuice/libjuice.a', rtc/'deps/usrsctp/usrsctplib/libusrsctp.a'] + [prefix/'lib'/n for n in ('libmbedtls.a','libmbedx509.a','libmbedcrypto.a')]
        for lib in libraries:
            if not lib.exists(): raise SystemExit('Missing expected library: '+str(lib))
        product = build / 'libAIMDataChannel.a'; run(['xcrun','libtool','-static','-o',product,*libraries])
        products.append((platform, product))
    headers = cache / 'headers'; (headers/'rtc').mkdir(parents=True, exist_ok=True)
    for name in ('rtc.h','version.h'):
        shutil.copy2(datachannel/'include/rtc'/name, headers/'rtc'/name)
    (headers/'AIMDataChannel.h').write_text('#define RTC_STATIC 1\n#define RTC_ENABLE_MEDIA 0\n#define RTC_ENABLE_WEBSOCKET 0\n#include "rtc/rtc.h"\n')
    (headers/'module.modulemap').write_text('module AIMDataChannel { header "AIMDataChannel.h" export * }\n')
    if a.assemble:
        # XCFramework requires one universal library per platform variant.
        arguments = []
        for group in ('macos','ios','sim'):
            libs = [lib for name,lib in products if name.startswith(group+'-')]
            if not libs: continue
            universal = cache / ('libAIMDataChannel-'+group+'.a')
            if len(libs) == 1: shutil.copy2(libs[0],universal)
            else: run(['xcrun','lipo','-create',*libs,'-output',universal])
            arguments += ['-library', universal, '-headers', headers]
        output = PACKAGE/'Artifacts/AIMDataChannel.xcframework'
        if output.exists(): raise SystemExit('Refusing to overwrite an existing XCFramework; remove only your reviewed build artifact explicitly')
        output.parent.mkdir(parents=True, exist_ok=True)
        run(['xcrun','xcodebuild','-create-xcframework',*arguments,'-output',output])
        receipt = {'schema':1,'sources':PINS,'platforms':[name for name,_ in products],'toolchain':{'cmake':subprocess.check_output([a.cmake,'--version'],text=True).splitlines()[0],'xcode':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),'clang':subprocess.check_output(['xcrun','clang','--version'],text=True).splitlines()[0]},'files':[]}
        for file in sorted(output.rglob('*')):
            if file.is_file(): receipt['files'].append({'path':str(file.relative_to(output)), 'sha256':hashlib.sha256(file.read_bytes()).hexdigest()})
        (output.parent/'build-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    notices = PACKAGE/'THIRD_PARTY_NOTICES'; notices.mkdir(exist_ok=True)
    for name,path in sources.items():
        candidates = [path/'LICENSE',path/'LICENSE.txt']
        license_path = next((x for x in candidates if x.exists()),None)
        if license_path: shutil.copy2(license_path,notices/(name+'.txt'))
    for name in ('libjuice','usrsctp','plog','json'):
        path = sources['libdatachannel']/'deps'/name
        candidate = next((x for x in (path/'LICENSE',path/'LICENSE.md',path/'LICENSE.txt',path/'LICENSE.MIT') if x.exists()),None)
        if not candidate: raise SystemExit('Missing license for '+name)
        shutil.copy2(candidate,notices/(name+'.txt'))
if __name__ == '__main__': main()
