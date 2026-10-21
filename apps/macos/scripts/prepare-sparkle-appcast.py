#!/usr/bin/env python3
"""Prepare a new signed Sparkle feed locally; never upload or generate keys."""
import argparse, importlib.util, json, pathlib, plistlib, shutil, subprocess, urllib.parse, xml.etree.ElementTree as ET
spec = importlib.util.spec_from_file_location('distribution', pathlib.Path(__file__).with_name('distribution-tools.py'))
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
def https(value):
    u = urllib.parse.urlsplit(value)
    if u.scheme != 'https' or not u.hostname or u.username or u.password or u.fragment:
        raise argparse.ArgumentTypeError('An HTTPS URL without credentials or fragment is required')
    return value

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--artifact', type=pathlib.Path, required=True)
    p.add_argument('--receipt', type=pathlib.Path, required=True)
    p.add_argument('--app', type=pathlib.Path, required=True, help='Exact signed app used to package the DMG')
    p.add_argument('--app-receipt', type=pathlib.Path, required=True)
    p.add_argument('--feed-url', type=https, required=True)
    history = p.add_mutually_exclusive_group(required=True)
    history.add_argument('--previous-feed', type=pathlib.Path, help='Exact existing RSS feed to preserve')
    history.add_argument('--initial-feed', action='store_true', help='Explicit first feed; no historical items are invented')
    p.add_argument('--output-directory', type=pathlib.Path, required=True)
    p.add_argument('--download-url-prefix', type=https, required=True)
    p.add_argument('--account', required=True, help='Existing Sparkle private key Keychain account; no key generation')
    p.add_argument('--public-key', required=True, help='Expected existing SUPublicEDKey')
    p.add_argument('--sparkle-bin', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1]/'.build/artifacts/sparkle/Sparkle/bin')
    a = p.parse_args()
    receipt = d.matching_receipt(a.artifact, a.receipt)
    if receipt.get('stage') != 'notarized' or receipt.get('notary_submission', {}).get('status') != 'Accepted' or not receipt.get('gatekeeper_assessment'):
        d.fail('Exact notarized artifact receipt with Accepted submission and Gatekeeper assessment required')
    app_receipt = d.matching_receipt(a.app, a.app_receipt)
    if app_receipt.get('stage') != 'built': d.fail('Built app receipt required')
    chain = receipt
    seen = set()
    while chain.get('source_receipt'):
        ref = chain['source_receipt']; path = pathlib.Path(ref['path'])
        if str(path) in seen or d.digest(path) != ref['sha256']: d.fail('Broken provenance receipt chain')
        seen.add(str(path)); chain = json.loads(path.read_text())
    if chain != app_receipt: d.fail('DMG receipt does not trace to the supplied exact app receipt')
    info = plistlib.loads((a.app/'Contents/Info.plist').read_bytes())
    if info.get('SUPublicEDKey') != a.public_key or info.get('SUFeedURL') != a.feed_url: d.fail('App Sparkle configuration differs from intended feed/key')
    d.signature(a.app, True)
    if a.artifact.suffix != '.dmg': d.fail('Use the notarized DMG distribution artifact')
    subprocess.run(['xcrun','stapler','validate',str(a.artifact)],check=True)
    if a.initial_feed:
        # generate_appcast inserts prefixed nodes into the existing RSS root.
        # An empty seed must declare the prefix before the first item exists.
        old = ET.Element('rss', {'version': '2.0', 'xmlns:sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'})
        channel = ET.SubElement(old, 'channel')
        ET.SubElement(channel, 'title').text = 'AIM AI updates'
        ET.SubElement(channel, 'link').text = a.feed_url
        ET.SubElement(channel, 'description').text = 'Official AIM AI macOS updates'
        old_bytes = ET.tostring(old, encoding='utf-8', xml_declaration=True)
    else:
        old_bytes = a.previous_feed.read_bytes(); old = ET.fromstring(old_bytes)
    if old.tag != 'rss' or old.find('channel') is None: d.fail('Existing feed must be RSS XML; HTML or SPA fallbacks are not history')
    def versions(tree):
        result = set()
        for item in tree.findall('./channel/item'):
            enclosure = item.find('enclosure')
            version = item.findtext('{http://www.andymatuschak.org/xml-namespaces/sparkle}version')
            if not version and enclosure is not None: version = enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}version')
            if not version: d.fail('Feed item missing Sparkle version')
            result.add(version)
        return result
    prior = versions(old)
    build = info.get('CFBundleVersion')
    if not isinstance(build, str) or not build.isdigit(): d.fail('Reviewed official integer build required')
    if build in prior or any(version.isdigit() and int(version) >= int(build) for version in prior):
        d.fail('New update build must exceed existing integer builds; never replace a published version')
    for item in old.findall('./channel/item'):
        enclosure = item.find('enclosure')
        if enclosure is not None: https(enclosure.get('url',''))
    public = subprocess.run([str(a.sparkle_bin/'generate_keys'),'--account',a.account,'-p'],check=True,capture_output=True,text=True).stdout.strip()
    if public != a.public_key: d.fail('Existing Keychain public key does not match expected app key')
    before = d.inventory(a.artifact)
    a.output_directory.mkdir(parents=True, exist_ok=False)
    (a.output_directory/('initial-feed-seed.xml' if a.initial_feed else 'previous-appcast.xml')).write_bytes(old_bytes)
    feed = a.output_directory/'appcast.xml'; feed.write_bytes(old_bytes)
    archives = a.output_directory/'archives'; archives.mkdir()
    shutil.copy2(a.artifact, archives/a.artifact.name)
    subprocess.run([str(a.sparkle_bin/'generate_appcast'),'--account',a.account,'--download-url-prefix',a.download_url_prefix,'--maximum-versions','0','--maximum-deltas','0','-o',str(feed),str(archives)],check=True)
    current = ET.parse(feed).getroot()
    if not prior.issubset(versions(current)): d.fail('Previous feed versions disappeared; refusing publication')
    def enclosure_contracts(tree):
        return {(item.findtext('{http://www.andymatuschak.org/xml-namespaces/sparkle}version') or entry.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}version'),
                 entry.get('url'), entry.get('length'), entry.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'))
                for item in tree.findall('./channel/item') for entry in item.findall('enclosure')}
    if not enclosure_contracts(old).issubset(enclosure_contracts(current)):
        d.fail('Previous download URLs, byte lengths or signatures changed; refusing publication')
    new_items = [item for item in current.findall('./channel/item') if item.findtext('{http://www.andymatuschak.org/xml-namespaces/sparkle}version') == build]
    if len(new_items) != 1: d.fail('Exactly one new item for the reviewed build required')
    new_item = new_items[0]; enclosure = new_item.find('enclosure')
    expected_url = a.download_url_prefix.rstrip('/')+'/'+urllib.parse.quote(a.artifact.name)
    if enclosure is None or enclosure.get('url') != expected_url or enclosure.get('length') != str(a.artifact.stat().st_size) or not enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'):
        d.fail('Generated item must identify the exact signed DMG URL, byte length and EdDSA signature')
    if new_item.findtext('{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString') != info.get('CFBundleShortVersionString'):
        d.fail('Generated marketing version differs from the signed app')
    for item in current.findall('./channel/item'):
        enclosure = item.find('enclosure')
        if enclosure is not None: https(enclosure.get('url',''))
    subprocess.run([str(a.sparkle_bin/'sign_update'),'--account',a.account,str(feed)],check=True)
    subprocess.run([str(a.sparkle_bin/'sign_update'),'--account',a.account,'--verify',str(feed)],check=True)
    if d.inventory(a.artifact) != before or (a.previous_feed and a.previous_feed.read_bytes() != old_bytes): d.fail('Inputs changed during generation')
    (a.output_directory/'appcast-receipt.json').write_text(json.dumps({'schema_version':1,'artifact':str(a.artifact.resolve()),'artifact_receipt_sha256':d.digest(a.receipt),'feed_sha256':d.digest(feed),'initial_feed':a.initial_feed,'previous_feed_sha256':d.digest(a.previous_feed) if a.previous_feed else None,'preserved_versions':sorted(prior),'uploaded':False},indent=2))
    print(feed)
if __name__ == '__main__': main()
