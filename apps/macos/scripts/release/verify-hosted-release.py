#!/usr/bin/env python3
"""Read public HTTPS artifacts after owner upload; never publish, install or access accounts."""
import argparse, hashlib, json, pathlib, re, subprocess, tempfile, time
import urllib.parse, urllib.request, xml.etree.ElementTree as ET
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
FEED_LIMIT = 4 * 1024 * 1024
DMG_LIMIT = 2 * 1024 * 1024 * 1024

def https(url):
    value = urllib.parse.urlsplit(url)
    if value.scheme != 'https' or not value.hostname or value.username or value.password or value.fragment or value.query:
        raise ValueError('Public HTTPS URL without credentials, query or fragment required')
    return url

class HTTPSRedirects(urllib.request.HTTPRedirectHandler):
    max_redirections = 5
    max_repeats = 2
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        https(newurl)  # Reject downgrade before urllib follows it.
        return super().redirect_request(request, fp, code, msg, headers, newurl)

def fetch(url, destination, expected_sha, limit, allowed_types, expected_size=None, opener=None, timeout=30, deadline=None):
    https(url)
    opener = opener or urllib.request.build_opener(HTTPSRedirects())
    deadline = deadline or time.monotonic()+300
    request = urllib.request.Request(url, headers={'User-Agent': 'AIM-release-verifier/1', 'Accept-Encoding': 'identity'})
    with opener.open(request, timeout=timeout) as response:
        https(response.geturl())
        if response.status != 200: raise ValueError('Expected HTTP 200 full artifact')
        mime = response.headers.get_content_type().lower()
        if mime not in allowed_types: raise ValueError('Unexpected MIME type: '+mime)
        if response.headers.get('Content-Encoding', 'identity').lower() not in ['identity', '']:
            raise ValueError('Encoded response cannot be compared to immutable bytes')
        content_length = response.headers.get('Content-Length')
        if content_length is not None:
            declared = int(content_length)
            if declared < 0 or declared > limit or (expected_size is not None and declared != expected_size):
                raise ValueError('Declared response size differs from expected artifact')
        total = 0; digest = hashlib.sha256()
        with destination.open('xb') as handle:
            while True:
                if time.monotonic() > deadline: raise TimeoutError('Overall download deadline exceeded')
                block = response.read(1024 * 1024)
                if not block: break
                total += len(block)
                if total > limit: raise ValueError('Response exceeds permitted size')
                digest.update(block); handle.write(block)
        if expected_size is not None and total != expected_size: raise ValueError('Downloaded byte count mismatch')
        if digest.hexdigest() != expected_sha: raise ValueError('Hash mismatch: reused filename, stale or altered artifact')
        return {'bytes': total, 'sha256': digest.hexdigest(), 'mime': mime, 'final_url': response.geturl()}

def target_url(production_url, base_url):
    https(production_url)
    if base_url is None: return production_url
    https(base_url)
    base = urllib.parse.urlsplit(base_url)
    if base.path not in ['', '/']: raise ValueError('Preview base URL must be an HTTPS origin')
    return urllib.parse.urlunsplit((base.scheme, base.netloc, urllib.parse.urlsplit(production_url).path, '', ''))

def parse_feed(data, configuration, name, size):
    tree = ET.fromstring(data)
    if tree.tag != 'rss' or tree.find('channel') is None: raise ValueError('RSS XML required; SPA HTML refused')
    items = [item for item in tree.findall('./channel/item') if item.findtext(SPARKLE+'version') == configuration['application_build']]
    if len(items) != 1: raise ValueError('Exactly one item for reviewed build required')
    item = items[0]; enclosure = item.find('enclosure')
    expected_url = configuration['sparkle_feed_url'].rsplit('/', 1)[0]+'/'+urllib.parse.quote(name)
    if enclosure is None or enclosure.get('url') != expected_url or enclosure.get('length') != str(size):
        raise ValueError('Signed enclosure URL/name/size differs from production contract')
    if item.findtext(SPARKLE+'shortVersionString') != configuration['application_version']:
        raise ValueError('Feed version mismatch')
    embedded = re.search(rb'<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: ([0-9]+)\s*-->\s*$', data)
    if not embedded: raise ValueError('Embedded XML signature absent')
    length = int(embedded.group(2))
    if data[length:].strip() != embedded.group(0).strip(): raise ValueError('Unsigned trailing content refused')
    return expected_url, enclosure.get(SPARKLE+'edSignature', ''), embedded.group(1).decode(), length

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--configuration', type=pathlib.Path, required=True)
    p.add_argument('--feed-receipt', type=pathlib.Path, required=True)
    p.add_argument('--artifact-receipt', type=pathlib.Path, required=True)
    p.add_argument('--output-directory', type=pathlib.Path, required=True, help='New local evidence directory; refuses overwrite')
    p.add_argument('--base-url', help='HTTPS preview origin for fetching only; signed enclosure must retain exact production URL')
    p.add_argument('--timeout', type=int, default=30)
    p.add_argument('--maximum-seconds', type=int, default=300)
    a = p.parse_args()
    if not 1 <= a.timeout <= 60 or not 1 <= a.maximum_seconds <= 900: raise ValueError('Bounded timeout required')
    if a.output_directory.exists() or a.output_directory.is_symlink(): raise ValueError('Output directory must be new')
    configuration = json.loads(a.configuration.read_text()); feed_receipt = json.loads(a.feed_receipt.read_text()); artifact = json.loads(a.artifact_receipt.read_text())
    if artifact.get('stage') != 'notarized' or artifact.get('notary_submission', {}).get('status') != 'Accepted': raise ValueError('Reviewed notarized receipt required')
    if hashlib.sha256(a.artifact_receipt.read_bytes()).hexdigest() != feed_receipt['artifact_receipt_sha256']: raise ValueError('Feed/artifact receipt chain mismatch')
    name = pathlib.Path(artifact['artifact']).name
    if not name.endswith('.dmg'): raise ValueError('DMG receipt required')
    size = artifact['contents']['bytes']
    if not isinstance(size, int) or not 0 < size <= DMG_LIMIT: raise ValueError('Bounded expected artifact size required')
    feed_url = target_url(configuration['sparkle_feed_url'], a.base_url)
    production_download = configuration['sparkle_feed_url'].rsplit('/', 1)[0]+'/'+urllib.parse.quote(name)
    download_url = target_url(production_download, a.base_url)
    a.output_directory.mkdir(parents=False, exist_ok=False)
    deadline = time.monotonic()+a.maximum_seconds
    feed_path = a.output_directory/'appcast.xml'; dmg_path = a.output_directory/name
    feed_result = fetch(feed_url, feed_path, feed_receipt['feed_sha256'], FEED_LIMIT, {'application/xml', 'text/xml', 'application/rss+xml'}, timeout=a.timeout, deadline=deadline)
    expected_url, archive_signature, feed_signature, length = parse_feed(feed_path.read_bytes(), configuration, name, size)
    artifact_result = fetch(download_url, dmg_path, artifact['contents']['sha256'], size, {'application/octet-stream', 'application/x-apple-diskimage', 'application/x-diskcopy'}, expected_size=size, timeout=a.timeout, deadline=deadline)
    with tempfile.TemporaryDirectory(prefix='aim-hosted-public-signature-') as cache:
        for file, signature, signed_length in [(feed_path, feed_signature, length), (dmg_path, archive_signature, size)]:
            subprocess.run(['/usr/bin/swift', '-module-cache-path', cache, str(ROOT/'scripts/release/verify-sparkle-signature.swift'), str(file), configuration['sparkle_public_key'], signature, str(signed_length)], check=True, timeout=60, stdout=subprocess.DEVNULL)
    result = {'schema_version': 1, 'verified_at': datetime.now(timezone.utc).isoformat(), 'preview': a.base_url is not None, 'production_enclosure_url': expected_url, 'feed': feed_result, 'artifact': artifact_result, 'feed_receipt_sha256': hashlib.sha256(a.feed_receipt.read_bytes()).hexdigest(), 'artifact_receipt_sha256': hashlib.sha256(a.artifact_receipt.read_bytes()).hexdigest(), 'signatures_verified_with_public_key': True, 'download_only': True, 'installed': False, 'published': False, 'update_round_trip': 'not_inferred'}
    with (a.output_directory/'hosted-verification.json').open('x') as handle: json.dump(result, handle, indent=2); handle.write('\n')
    print(json.dumps(result, indent=2))

if __name__ == '__main__': main()
