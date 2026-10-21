#!/usr/bin/env python3
"""Pick the Hermes/OpenClaw versions AIM may ship (UpstreamAgentCatalog.swift).

Rule chosen by Mathieu (2026-10-10): the latest official stable release (Hermes: GitHub
releases that are neither draft nor prerelease; OpenClaw: npm versions without a
pre-release suffix, never `beta`), published at least 7 days ago. The script prints each
candidate with its archive digest; a candidate ships only after the bridge contract
(scripts/adapters/test_bridge_protocol.py), the installer's import checks and one real
mission (`--agent-qualification external-live`) pass.

Usage: scripts/agents/vet-upstream.py [--days 7] [--download DIR]
"""
import argparse, base64, datetime, hashlib, json, pathlib, re, urllib.request

def get(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'aim-vet-upstream', 'Accept': 'application/json'})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)

def old_enough(stamp, days):
    published = datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00'))
    return datetime.datetime.now(datetime.timezone.utc) - published >= datetime.timedelta(days=days)

def hermes(days):
    for release in get('https://api.github.com/repos/NousResearch/hermes-agent/releases?per_page=30'):
        if release['draft'] or release['prerelease'] or not old_enough(release['published_at'], days):
            continue
        tag = release['tag_name']
        return {'engine': 'hermes', 'tag': tag, 'name': release['name'], 'published': release['published_at'],
                'url': f'https://codeload.github.com/NousResearch/hermes-agent/zip/refs/tags/{tag}',
                'archiveFolder': 'hermes-agent-' + tag.lstrip('v'), 'digest': 'sha256 (download to compute)'}

def openclaw(days):
    data = get('https://registry.npmjs.org/openclaw')
    stable = [v for v in data['versions'] if re.fullmatch(r'\d+\.\d+\.\d+', v) and v in data['time']]
    stable = [v for v in stable if old_enough(data['time'][v], days)]
    # The highest version, not the newest upload: OpenClaw also publishes an older extended-stable line.
    version = max(stable, key=lambda v: tuple(int(part) for part in v.split('.')))
    dist = data['versions'][version]['dist']
    return {'engine': 'openclaw', 'version': version, 'published': data['time'][version], 'url': dist['tarball'],
            'digest': dist['integrity'].removeprefix('sha512-'), 'latest_tag': data['dist-tags'].get('latest')}

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--days', type=int, default=7); parser.add_argument('--download')
    args = parser.parse_args()
    for candidate in (hermes(args.days), openclaw(args.days)):
        if args.download and candidate['engine'] == 'hermes':
            folder = pathlib.Path(args.download); folder.mkdir(parents=True, exist_ok=True)
            target = folder / (candidate['tag'] + '.zip')
            urllib.request.urlretrieve(candidate['url'], target)
            candidate['digest'] = hashlib.sha256(target.read_bytes()).hexdigest()
        print(json.dumps(candidate, indent=2))

if __name__ == '__main__':
    main()
