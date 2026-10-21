#!/usr/bin/env python3
"""Assemble a fresh qualification successor from verified existing resources; never launch."""
import argparse, hashlib, importlib.util, json, pathlib, plistlib, shutil, subprocess, tempfile
spec=importlib.util.spec_from_file_location('distribution',pathlib.Path(__file__).with_name('distribution-tools.py'))
d=importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
def run(args, **kw): return subprocess.run(args,check=True,**kw)
def entitlements(bundle): return run(['/usr/bin/codesign','-d','--entitlements',':-',str(bundle)],capture_output=True).stdout
def certificate(bundle, directory, label):
    prefix=str(directory/label)
    run(['/usr/bin/codesign','-d','--extract-certificates='+prefix,str(bundle)],capture_output=True)
    return hashlib.sha1(pathlib.Path(prefix+'0').read_bytes()).hexdigest().upper()
def native_package(root):
    return root.parents[1] / 'packages' / 'AIMDirectNative'

def prepare_build_directory(root):
    directory = root / 'build'
    if directory.is_symlink(): d.fail('Qualification build directory must not be a symlink')
    directory.mkdir(exist_ok=True)
    return directory

def regular_files(directory):
    if not directory.is_dir() or directory.is_symlink():
        d.fail('Required source directory is missing or unsafe: ' + str(directory))
    files = []
    for path in sorted(directory.rglob('*')):
        if path.is_symlink(): d.fail('Source provenance refuses symlinks: ' + str(path))
        if path.is_file(): files.append(path)
    if not files: d.fail('Required source directory is empty: ' + str(directory))
    return files

def native_publication_inputs(native):
    return [native / 'dependencies.lock.json', native / 'README.md'] + regular_files(native / 'THIRD_PARTY_NOTICES') + regular_files(native / 'patches')

def source_inputs(root):
    """Record all three actual packages, permission inputs and pinned native bytes."""
    core = root.parents[1] / 'packages' / 'AIMCore'
    native = native_package(root)
    manifests = [package / 'Package.swift' for package in (root, core, native)]
    for manifest in manifests:
        if not manifest.is_file() or manifest.is_symlink():
            d.fail('Required source manifest is missing or unsafe: ' + str(manifest))
    paths = list(manifests)
    for package in (root, core, native):
        paths += [path for path in regular_files(package / 'Sources') if path.suffix == '.swift']
    paths += [root / 'Config/Info.plist', root / 'Config/AgentHostInfo.plist', native / 'Artifacts/build-receipt.json']
    paths += native_publication_inputs(native)
    paths += regular_files(native / 'Artifacts/AIMDataChannel.xcframework')
    for path in paths:
        if not path.is_file() or path.is_symlink(): d.fail('Required source input is missing or unsafe: ' + str(path))
    return sorted(set(paths))

def qualification_info(previous, current, build_version, role):
    """Permission declarations may evolve; qualification identity never does."""
    info = dict(previous)
    if role == 'main':
        description = current.get('NSLocalNetworkUsageDescription')
        services = current.get('NSBonjourServices')
        if not isinstance(description, str) or not description.strip(): d.fail('Current local-network usage description is missing')
        if not isinstance(services, list) or not services or not all(isinstance(value, str) and value for value in services): d.fail('Current Bonjour services are missing')
        info['NSLocalNetworkUsageDescription'] = description
        info['NSBonjourServices'] = list(services)
    info['CFBundleVersion'] = build_version
    info['CFBundleDisplayName'] = 'AIM Continuity Test ' + build_version
    return info

def copy_native_publication_inputs(native, destination):
    """Ship exact upstream notices, pinned revisions and our MPL patch source."""
    inputs = native_publication_inputs(native)
    if destination.exists(): shutil.rmtree(destination)
    for source in inputs:
        target = destination / source.relative_to(native)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    expected = {source.relative_to(native).as_posix(): d.digest(source) for source in inputs}
    actual = {path.relative_to(destination).as_posix(): d.digest(path) for path in regular_files(destination)}
    if actual != expected: d.fail('Native third-party publication inputs changed while copying')
    return expected

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-app',type=pathlib.Path,required=True)
    p.add_argument('--output-app',type=pathlib.Path,required=True)
    p.add_argument('--expected-namespace',required=True)
    p.add_argument('--identity',required=True,help='Existing signing certificate SHA1')
    p.add_argument('--build-version',required=True)
    p.add_argument('--binary-directory',type=pathlib.Path,required=True,help='Already rebuilt current binaries; guarded against active executables')
    a=p.parse_args(); a.source_app=a.source_app.resolve(); a.output_app=a.output_app.absolute(); a.binary_directory=a.binary_directory.resolve(); root=pathlib.Path(__file__).resolve().parents[1]
    paths = source_inputs(root)
    if a.output_app.exists() or a.output_app.with_suffix('.qualification.json').exists() or a.output_app.parent.resolve()!= (root/'build').resolve(): d.fail('Output must be new and inside repository build/')
    if not a.expected_namespace.startswith('com.aimai.macos.qualification.'): d.fail('Qualification namespace required')
    d.guard([a.output_app,a.binary_directory])
    run(['/usr/bin/codesign','--verify','--deep','--strict',str(a.source_app)])
    before=d.inventory(a.source_app)
    binaries={name:d.digest(a.binary_directory/name) for name in ['AIMMac','AIMAgentHost']}
    oldmain=a.source_app/'Contents'; oldhelper=oldmain/'Library/LoginItems/AIMAgentHost.app/Contents'
    for folder,expected in [(oldmain,a.expected_namespace),(oldhelper,a.expected_namespace+'.agenthost')]:
        info=plistlib.loads((folder/'Info.plist').read_bytes())
        if info['CFBundleIdentifier']!=expected: d.fail('Source namespace mismatch')
    sources={str(f):d.digest(f) for f in paths}
    native = native_package(root)
    build = prepare_build_directory(root)
    with tempfile.TemporaryDirectory(prefix='.qualification-resume-',dir=build) as scratch:
        if certificate(a.source_app,pathlib.Path(scratch),'source-cert') != a.identity.upper() or certificate(oldhelper.parent,pathlib.Path(scratch),'helper-source-cert') != a.identity.upper(): d.fail('Existing source certificate differs from selected identity')
        stage=pathlib.Path(scratch)/a.output_app.name; shutil.copytree(a.source_app,stage,symlinks=True)
        main=stage/'Contents'; helper=main/'Library/LoginItems/AIMAgentHost.app/Contents'
        for folder,old,name,role in [(main,oldmain,'AIMMac','main'),(helper,oldhelper,'AIMAgentHost','helper')]:
            shutil.copy2(a.binary_directory/name,folder/'MacOS'/name)
            previous=plistlib.loads((folder/'Info.plist').read_bytes())
            current=plistlib.loads((root/'Config'/('Info.plist' if role=='main' else 'AgentHostInfo.plist')).read_bytes())
            info=qualification_info(previous,current,a.build_version,role)
            (folder/'Info.plist').write_bytes(plistlib.dumps(info))
            for resource in a.binary_directory.glob('*.bundle'):
                dest=folder/'Resources'/resource.name
                if dest.exists(): shutil.rmtree(dest)
                shutil.copytree(resource,dest,symlinks=True)
            ep=pathlib.Path(scratch)/(role+'.entitlements');ep.write_bytes(entitlements(old.parent))
            relative='@executable_path/../Frameworks' if role=='main' else '@executable_path/../../../../../Frameworks'
            load=run(['/usr/bin/otool','-l',str(folder/'MacOS'/name)],capture_output=True,text=True).stdout
            if relative not in load: run(['/usr/bin/install_name_tool','-add_rpath',relative,str(folder/'MacOS'/name)])
        native_publication = copy_native_publication_inputs(native, main/'Resources/ThirdParty/AIMDirectNative')
        for engine in ['hermes','openclaw']:
            dest=main/'Resources/AgentBridges'/engine
            if dest.exists(): shutil.rmtree(dest)
            shutil.copytree(root/'scripts/adapters'/engine,dest,symlinks=True)
        for bundle,role in [(helper.parent,'helper'),(stage,'main')]:
            run(['/usr/bin/codesign','--force','--sign',a.identity,'--options','runtime','--timestamp=none','--entitlements',str(pathlib.Path(scratch)/(role+'.entitlements')),str(bundle)])
            if plistlib.loads(entitlements(bundle))!=plistlib.loads((pathlib.Path(scratch)/(role+'.entitlements')).read_bytes()): d.fail('Entitlements changed')
        run(['/usr/bin/codesign','--verify','--deep','--strict',str(stage)])
        if certificate(stage,pathlib.Path(scratch),'candidate-cert') != a.identity.upper(): d.fail('Candidate certificate changed')
        if d.inventory(a.source_app)!=before or any(d.digest(pathlib.Path(f))!=sha for f,sha in sources.items()) or any(d.digest(a.binary_directory/name)!=sha for name,sha in binaries.items()): d.fail('Source inputs changed during assembly')
        d.guard([a.output_app,a.binary_directory]);d.publish_new(stage,a.output_app)
    receipt={'schema_version':1,'candidate':str(a.output_app),'source_app':str(a.source_app),'source_inventory':before['inventory_sha256'],'candidate_inventory':d.inventory(a.output_app),'namespace':a.expected_namespace,'signing_identity':a.identity,'sources':sources,'binaries':binaries,'launched':False,'physical_qualification':'pending','production_release':False,
        'direct_transport':{'package':str(native),'artifact_receipt_sha256':d.digest(native/'Artifacts/build-receipt.json'),
            'publication_files':native_publication,
            'publication_inventory':d.inventory(a.output_app/'Contents/Resources/ThirdParty/AIMDirectNative')},
        'permission_declarations':{key:plistlib.loads((a.output_app/'Contents/Info.plist').read_bytes())[key] for key in ['NSBonjourServices','NSLocalNetworkUsageDescription']}}
    with a.output_app.with_suffix('.qualification.json').open('x') as f:json.dump(receipt,f,indent=2)
    print(a.output_app)
if __name__=='__main__':main()
