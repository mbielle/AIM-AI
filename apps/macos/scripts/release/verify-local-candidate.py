#!/usr/bin/env python3
"""Verify local release provenance and Sparkle signatures; no account, network or app launch."""
import argparse, importlib.util, json, pathlib, plistlib, re, subprocess, tempfile
import xml.etree.ElementTree as ET
import urllib.parse

root = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('distribution', root/'scripts/distribution-tools.py')
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'

def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['app', 'app-receipt', 'artifact', 'receipt', 'feed', 'feed-receipt', 'configuration']:
        p.add_argument('--'+name, type=pathlib.Path, required=True)
    p.add_argument('--output', type=pathlib.Path, help='New local evidence file; existing files are never overwritten')
    a = p.parse_args()
    configuration = json.loads(a.configuration.read_text())
    app = d.matching_receipt(a.app, a.app_receipt)
    artifact = d.matching_receipt(a.artifact, a.receipt)
    if app.get('stage') != 'built' or artifact.get('stage') != 'notarized': d.fail('Built app and exact notarized DMG receipts required')
    if artifact.get('notary_submission', {}).get('status') != 'Accepted' or 'source=Notarized Developer ID' not in artifact.get('gatekeeper_assessment', ''):
        d.fail('Accepted notarization and recorded Gatekeeper acceptance required')
    chain = artifact; seen = set()
    while chain.get('source_receipt'):
        reference = chain['source_receipt']; path = pathlib.Path(reference['path'])
        if str(path) in seen or d.digest(path) != reference['sha256']: d.fail('Broken receipt chain')
        seen.add(str(path)); chain = json.loads(path.read_text())
    if chain != app: d.fail('DMG receipt does not descend from this exact app receipt')
    details = d.signature(a.app, True); dmg_signature = d.signature(a.artifact, True)
    if 'Notarization Ticket=stapled' not in dmg_signature: d.fail('DMG has no attached notarization ticket')
    team = 'TeamIdentifier='+configuration['team']
    if team not in details.splitlines() or team not in dmg_signature.splitlines(): d.fail('Signing team mismatch')
    info = plistlib.loads((a.app/'Contents/Info.plist').read_bytes())
    helper = plistlib.loads((a.app/'Contents/Library/LoginItems/AIMAgentHost.app/Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.aimai.macos' or helper.get('CFBundleIdentifier') != 'com.aimai.macos.agenthost': d.fail('Official namespace mismatch')
    for entry in [info, helper]:
        if entry.get('CFBundleVersion') != configuration['application_build'] or entry.get('CFBundleShortVersionString') != configuration['application_version']: d.fail('Reviewed version mismatch')
    if info.get('SUFeedURL') != configuration['sparkle_feed_url'] or info.get('SUPublicEDKey') != configuration['sparkle_public_key']: d.fail('Sparkle configuration mismatch')
    recorded_feed = json.loads(a.feed_receipt.read_text())
    if recorded_feed['feed_sha256'] != d.digest(a.feed) or recorded_feed['artifact_receipt_sha256'] != d.digest(a.receipt): d.fail('Feed receipt mismatch')
    tree = ET.fromstring(a.feed.read_bytes())
    if tree.tag != 'rss' or tree.find('channel') is None: d.fail('RSS feed required')
    items = [item for item in tree.findall('./channel/item') if item.findtext(SPARKLE+'version') == configuration['application_build']]
    if len(items) != 1: d.fail('Exactly one feed item for this build required')
    item = items[0]; enclosure = item.find('enclosure')
    expected_url = configuration['sparkle_feed_url'].rsplit('/', 1)[0]+'/'+urllib.parse.quote(a.artifact.name)
    if enclosure is None or enclosure.get('url') != expected_url or enclosure.get('length') != str(a.artifact.stat().st_size): d.fail('Feed download URL/size mismatch')
    if item.findtext(SPARKLE+'shortVersionString') != configuration['application_version']: d.fail('Feed marketing version mismatch')
    archive = a.feed.parent/'archives'/a.artifact.name
    if not archive.is_file() or d.inventory(archive) != artifact['contents']: d.fail('Upload archive differs from the exact notarized DMG')
    feed_bytes = a.feed.read_bytes()
    embedded = re.search(rb'<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: ([0-9]+)\s*-->\s*$', feed_bytes)
    if not embedded: d.fail('Embedded Sparkle feed signature absent')
    feed_length = int(embedded.group(2))
    if feed_bytes[feed_length:].strip() != embedded.group(0).strip(): d.fail('Unexpected unsigned content after signed feed')
    # CryptoKit verifies only with the public key; no Keychain/private key access.
    with tempfile.TemporaryDirectory(prefix='aim-signature-verify-') as cache:
        for file, signature, length in [(a.feed, embedded.group(1).decode(), feed_length), (a.artifact, enclosure.get(SPARKLE+'edSignature', ''), a.artifact.stat().st_size)]:
            subprocess.run(['/usr/bin/swift', '-module-cache-path', cache, str(root/'scripts/release/verify-sparkle-signature.swift'), str(file), configuration['sparkle_public_key'], signature, str(length)], check=True, stdout=subprocess.DEVNULL)
    result = {'schema_version': 1, 'app': str(a.app.resolve()), 'app_inventory_sha256': app['contents']['inventory_sha256'], 'artifact': str(a.artifact.resolve()), 'artifact_sha256': artifact['contents']['sha256'], 'artifact_bytes': artifact['contents']['bytes'], 'feed_sha256': d.digest(a.feed), 'upload_archive_verified': True, 'version': configuration['application_version'], 'build': configuration['application_build'], 'download_url': expected_url, 'public_key_signatures_verified': True, 'notary_submission': artifact['notary_submission']['id'], 'gatekeeper': 'recorded_acceptance_verified_by_artifact_hash_only', 'network_accessed': False, 'launched': False, 'published': False, 'physical_qualification': 'not_inferred'}
    if a.output:
        with a.output.open('x') as handle: json.dump(result, handle, indent=2); handle.write('\n')
    print(json.dumps(result, indent=2))

if __name__ == '__main__': main()
