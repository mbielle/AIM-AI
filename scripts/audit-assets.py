#!/usr/bin/env python3
"""Hash/provenance inventory; ordinary checks allow pending rights, release checks do not."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tempfile
import unittest

MANIFEST = 'docs/ASSET_MANIFEST.json'
SKIP = {'.git', '.build', '.swiftpm', 'node_modules', 'dist', 'build', 'DerivedData', '__pycache__'}
KINDS = {**dict.fromkeys(['.png', '.jpg', '.jpeg', '.webp', '.gif', '.svg', '.ico', '.icns', '.pdf'], 'image'),
         **dict.fromkeys(['.ttf', '.otf', '.woff', '.woff2'], 'font'),
         **dict.fromkeys(['.mp4', '.mov', '.webm', '.mp3', '.wav'], 'media')}
PENDING = {'pending-owner-attribution', 'pending-third-party-rights', 'pending-provenance-review'}
RESOLVED = {'documented-license', 'owner-confirmed-first-party', 'documented-permission'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(path):
    return isinstance(path, str) and path == str(PurePosixPath(path)) and not path.startswith('/') and '..' not in PurePosixPath(path).parts


class Inventory:
    def __init__(self, root, tracked=False):
        self.root, self.tracked = Path(root).resolve(), tracked
        if tracked:
            top = subprocess.check_output(['git', '-C', str(self.root), 'rev-parse', '--show-toplevel'], text=True).strip()
            if Path(top).resolve() != self.root:
                raise ValueError('tracked inventory requires a repository at the selected root')
            self.paths = sorted(p.decode('utf-8') for p in subprocess.check_output(['git', '-C', str(self.root), 'ls-files', '-z']).split(b'\0') if p)
        else:
            self.paths = []
            for directory, folders, files in os.walk(self.root, followlinks=False):
                folders[:] = sorted(f for f in folders if f not in SKIP and not (Path(directory)/f).is_symlink())
                self.paths.extend((Path(directory)/f).relative_to(self.root).as_posix() for f in sorted(files))
            self.paths.sort()

    def read(self, path):
        if not safe_path(path):
            raise ValueError('unsafe manifest path')
        if self.tracked:
            mode = subprocess.check_output(['git', '-C', str(self.root), 'ls-files', '-s', '--', path], text=True).split()[0]
            if mode == '120000':
                raise ValueError('symlink requires review')
            return subprocess.check_output(['git', '-C', str(self.root), 'show', ':' + path])
        target = self.root/path
        if target.is_symlink():
            raise ValueError('symlink requires review')
        if not target.resolve().is_relative_to(self.root):
            raise ValueError('path escapes root')
        return target.read_bytes()

    def assets(self):
        return [p for p in self.paths if Path(p).suffix.lower() in KINDS]


def unresolved(path):
    return {'status': 'pending-provenance-review', 'source': 'New or changed asset: exact source and rights evidence required.', 'license': None, 'notices': []}


def refresh(inventory):
    try:
        previous = json.loads(inventory.read(MANIFEST))
    except FileNotFoundError:
        previous = {'assets': []}
    old = {a['path']: a for a in previous['assets']}
    assets = []
    for path in inventory.assets():
        data = inventory.read(path)
        entry = {'path': path, 'kind': KINDS[Path(path).suffix.lower()], 'bytes': len(data), 'sha256': digest(data)}
        entry['provenance'] = old.get(path, {}).get('provenance', unresolved(path)) if old.get(path, {}).get('sha256') == entry['sha256'] else unresolved(path)
        assets.append(entry)
    return {'version': 2, 'scope': 'Local image/font/media files outside generated trees; inline source artwork and optional runtime/model notices require separate owner review.', 'assets': assets}


def validate(inventory, release=False):
    findings, pending = [], []
    manifest = json.loads(inventory.read(MANIFEST))
    if manifest.get('version') != 2 or not isinstance(manifest.get('assets'), list):
        return [(MANIFEST, 'unsupported-manifest')], []
    entries = manifest['assets']
    paths = [a.get('path') for a in entries]
    if len(set(paths)) != len(paths):
        findings.append((MANIFEST, 'duplicate-asset'))
    actual = set(inventory.assets())
    for path in sorted(actual - set(paths)):
        findings.append((path, 'asset-not-in-manifest'))
    for entry in entries:
        path = entry.get('path')
        if not safe_path(path):
            findings.append((MANIFEST, 'unsafe-asset-path'))
            continue
        if path not in actual:
            findings.append((path, 'manifest-asset-missing'))
            continue
        try:
            data = inventory.read(path)
            if entry.get('sha256') != digest(data) or entry.get('bytes') != len(data):
                findings.append((path, 'asset-changed'))
            if entry.get('kind') != KINDS[Path(path).suffix.lower()]:
                findings.append((path, 'asset-kind-mismatch'))
            provenance = entry.get('provenance', {})
            status = provenance.get('status')
            if status in PENDING:
                pending.append(path)
            elif status not in RESOLVED:
                findings.append((path, 'ambiguous-rights-status'))
            elif not provenance.get('source') or not provenance.get('license') or not provenance.get('notices'):
                findings.append((path, 'missing-rights-evidence'))
            if status in RESOLVED:
                for notice in provenance.get('notices', []):
                    if digest(inventory.read(notice['path'])) != notice.get('sha256'):
                        findings.append((path, 'notice-changed'))
                if status == 'owner-confirmed-first-party':
                    if not provenance.get('attribution') or not provenance.get('review_evidence'):
                        findings.append((path, 'missing-owner-attribution-or-review'))
                    else:
                        evidence = provenance['review_evidence']
                        if digest(inventory.read(evidence['path'])) != evidence.get('sha256'):
                            findings.append((path, 'owner-review-evidence-changed'))
                if status == 'documented-permission':
                    if not provenance.get('permission_evidence'):
                        findings.append((path, 'missing-permission-evidence'))
                    else:
                        evidence = provenance['permission_evidence']
                        if digest(inventory.read(evidence['path'])) != evidence.get('sha256'):
                            findings.append((path, 'permission-evidence-changed'))
                if 'copied_from' in provenance:
                    source = provenance['copied_from']
                    if digest(inventory.read(source['path'])) != source.get('sha256') or source.get('sha256') != entry.get('sha256'):
                        findings.append((path, 'replacement-source-mismatch'))
        except (OSError, ValueError, KeyError, IndexError, subprocess.CalledProcessError):
            findings.append((path, 'unreadable-asset-or-evidence'))
    if release:
        findings.extend((path, 'rights-review-pending') for path in pending)
    return sorted(set(findings)), pending


class AssetAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root/'docs').mkdir()
        (self.root/'art.png').write_bytes(b'synthetic image fixture')
        (self.root/'NOTICE').write_text('Fixture permission notice')
        self.write(refresh(Inventory(self.root)))

    def tearDown(self):
        self.temp.cleanup()

    def write(self, value):
        (self.root/MANIFEST).write_text(json.dumps(value))

    def resolved(self):
        value = json.loads((self.root/MANIFEST).read_text())
        value['assets'][0]['provenance'] = {'status':'documented-license', 'source':'Fixture upstream', 'license':'MIT', 'notices':[{'path':'NOTICE','sha256':digest((self.root/'NOTICE').read_bytes())}]}
        self.write(value)
        return value

    def test_pending_allows_development_but_blocks_publication(self):
        self.assertEqual(validate(Inventory(self.root))[0], [])
        self.assertIn(('art.png','rights-review-pending'), validate(Inventory(self.root), True)[0])

    def test_documented_exact_asset_and_notice_pass_release(self):
        self.resolved()
        self.assertEqual(validate(Inventory(self.root), True)[0], [])
        (self.root/'NOTICE').write_text('changed permission')
        self.assertIn(('art.png','notice-changed'), validate(Inventory(self.root))[0])

    def test_new_changed_missing_and_ambiguous_assets_fail(self):
        value = self.resolved()
        (self.root/'new.svg').write_text('<svg/>')
        (self.root/'art.png').write_bytes(b'changed fixture')
        findings = validate(Inventory(self.root))[0]
        self.assertIn(('new.svg','asset-not-in-manifest'),findings)
        self.assertIn(('art.png','asset-changed'),findings)
        (self.root/'art.png').unlink()
        self.assertIn(('art.png','manifest-asset-missing'),validate(Inventory(self.root))[0])
        (self.root/'art.png').write_bytes(b'synthetic image fixture')
        value['assets'][0]['provenance']['status'] = 'complete'
        self.write(value)
        self.assertIn(('art.png','ambiguous-rights-status'),validate(Inventory(self.root))[0])

    def test_refresh_cannot_carry_rights_forward_to_changed_bytes(self):
        self.resolved()
        (self.root/'art.png').write_bytes(b'changed fixture')
        self.write(refresh(Inventory(self.root)))
        self.assertIn(('art.png','rights-review-pending'),validate(Inventory(self.root),True)[0])

    def test_copy_evidence_must_match_exact_replacement_bytes(self):
        value=self.resolved()
        value['assets'][0]['provenance']['copied_from']={'path':'NOTICE','sha256':digest((self.root/'NOTICE').read_bytes())}
        self.write(value)
        self.assertIn(('art.png','replacement-source-mismatch'),validate(Inventory(self.root))[0])

    def test_owner_and_permission_decisions_require_unchanged_review_receipts(self):
        for status, field, missing, changed in [
            ('owner-confirmed-first-party', 'review_evidence', 'missing-owner-attribution-or-review', 'owner-review-evidence-changed'),
            ('documented-permission', 'permission_evidence', 'missing-permission-evidence', 'permission-evidence-changed')
        ]:
            value = self.resolved()
            proof = value['assets'][0]['provenance']
            proof.update(status=status, attribution='Fixture author')
            self.write(value)
            self.assertIn(('art.png', missing), validate(Inventory(self.root), True)[0])
            receipt = self.root/'review.md'
            receipt.write_text('Synthetic exact asset review receipt')
            proof[field] = {'path':'review.md', 'sha256':digest(receipt.read_bytes())}
            self.write(value)
            self.assertEqual(validate(Inventory(self.root), True)[0], [])
            receipt.write_text('Changed review receipt')
            self.assertIn(('art.png', changed), validate(Inventory(self.root), True)[0])

    def test_generated_symlink_is_not_followed_and_asset_symlink_fails(self):
        (self.root/'node_modules').symlink_to(self.root/'docs',target_is_directory=True)
        self.assertEqual(Inventory(self.root).assets(),['art.png'])
        (self.root/'art.png').unlink()
        (self.root/'art.png').symlink_to(self.root/'NOTICE')
        self.assertIn(('art.png','unreadable-asset-or-evidence'),validate(Inventory(self.root))[0])

    def test_tracked_checks_index_bytes_not_working_tree(self):
        self.resolved()
        subprocess.run(['git','init','-q',str(self.root)],check=True)
        subprocess.run(['git','-C',str(self.root),'add','.'],check=True)
        (self.root/'art.png').write_bytes(b'unstaged different asset')
        self.assertEqual(validate(Inventory(self.root,True),True)[0],[])
        self.assertIn(('art.png','asset-changed'),validate(Inventory(self.root))[0])


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1])
    parser.add_argument('--check',action='store_true',help='Check hashes/evidence without blocking documented pending reviews (default)')
    parser.add_argument('--release',action='store_true',help='Also fail every pending rights/owner review; no generic override')
    parser.add_argument('--refresh',action='store_true',help='Write current inventory; changed/new assets revert to pending review')
    parser.add_argument('--tracked',action='store_true',help='Read the indexed manifest/assets/evidence blobs, not working-tree content')
    parser.add_argument('--self-test',action='store_true')
    args=parser.parse_args()
    if args.self_test:
        return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(AssetAuditTests)).wasSuccessful() else 1
    try:
        if args.refresh and (args.tracked or args.release):
            raise ValueError('--refresh cannot combine with --tracked or --release')
        inventory=Inventory(args.root,args.tracked)
        if args.refresh:
            (inventory.root/MANIFEST).write_text(json.dumps(refresh(inventory),indent=2)+'\n')
        findings,pending=validate(inventory,args.release)
        for path,rule in findings:
            print(f'{path}: {rule}')
        print(f'Asset audit: {len(inventory.assets())} assets; {len(pending)} pending provenance/rights reviews; {len(findings)} findings; inventory={"index" if args.tracked else "working-tree"}.')
        return 1 if findings else 0
    except (OSError,ValueError,KeyError,subprocess.CalledProcessError) as error:
        print(f'Asset audit setup failed: {type(error).__name__}',file=sys.stderr)
        return 2


if __name__=='__main__':
    sys.exit(main())
