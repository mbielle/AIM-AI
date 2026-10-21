#!/usr/bin/env python3
"""Conservative, value-redacting publication audit; standard library only.

Exit 0: no findings. Exit 1: review findings. Exit 2: inventory failure.
--self-test runs isolated synthetic fixtures, never repository or network writes.
"""
from __future__ import annotations

import argparse
import hashlib
from dataclasses import asdict, dataclass
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
import unittest

GENERATED_DIRS = frozenset({'.git', '.build', 'node_modules', 'dist'})
# Public project contact and upstream ws copyright attribution (WS-LICENSE.txt).
PUBLIC_EMAILS = frozenset({'contact@aim-ai.tech', 'einaros@gmail.com'})
EXAMPLE_DOMAINS = frozenset({'example.com', 'example.org', 'example.net', 'example.test', 'test.invalid', 'localhost'})
# No literal keys or private instance identifiers are stored in this scanner.
CONTENT_RULES = (
    ('provider-secret', re.compile(r'\b(?:sk-(?:proj-|svcacct-|ant-|or-v1-)?[A-Za-z0-9_-]{20,}|xai-[A-Za-z0-9_-]{20,}|gsk_[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{20,}|AIza[A-Za-z0-9_-]{30,})\b')),
    ('service-secret', re.compile(r'\b(?:sk_(?:live|test)_[A-Za-z0-9]{16,}|whsec_[A-Za-z0-9]{16,}|sb_secret_[A-Za-z0-9_-]{16,}|sbp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{16,})\b')),
    ('repository-token', re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,})\b')),
    ('aws-access-key', re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b')),
    ('embedded-jwt', re.compile(r'\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\b')),
    ('user-home-path', re.compile(r'(?<![A-Za-z0-9])(?:/' + r'Users/[^\s/"\'<>\\]+|/' + r'home/[^\s/"\'<>\\]+|[A-Za-z]:\\Users\\[^\s\\"\'<>]+)')),
    ('project-instance', re.compile(r'\b[a-z0-9]{20}\.supabase\.(?:co|in)\b|(?:lovable\.dev/projects/)[a-fA-F0-9-]{36}\b')),
    ('project-configuration', re.compile(r'''(?:project[_-]?(?:id|ref)|SUPABASE_PROJECT_REF)["']?\s*[:=]\s*["'][a-z0-9]{20}["']|(?:account_id|zone_id)["']?\s*[:=]\s*["'][a-f0-9]{32}["']''')),
    ('apple-signing-identity', re.compile(r'(?:DEVELOPMENT_TEAM\s*=\s*"?[A-Z0-9]{10}\b|(?:Apple Development|Apple Distribution|Developer ID Application):\s+[^\n"\']+\([A-Z0-9]{10}\))')),
    ('embedded-credential-url', re.compile(r'https?://[^\s/@:]+:[^\s/@]+@')),
)
PRIVATE_KEY = re.compile(r'-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----(?:[A-Za-z0-9+/=\r\n]|\\n){40,}-----END (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----')
EMAIL = re.compile(r'(?<![\w.+-])[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}(?![\w.-])')
LITERAL_SECRET = re.compile(r'''(?ix)\b(?:[a-z0-9_]*(?:api[_-]?key|secret|password|access[_-]?token|refresh[_-]?token|service[_-]?role[_-]?key)[a-z0-9_]*)["']?\s*[:=]\s*["']([^"'\n]{12,})["']''')
PLACEHOLDER = re.compile(r'(?i)(?:^\s*$|example|placeholder|replace[_ -]?me|your[_ -]|sample|dummy|fake|changeme|not[_ -]?a[_ -]?secret|\$\{|\$\(|^\$|^<|^https?://|^0+$|^x+$)')


# Exact synthetic security fixtures reviewed for this extraction. No test directory is exempt.
# Hashes cover the complete UTF-8 source line, excluding the line ending.
REVIEWED_FIXTURES = {
    ('packages/AIMCore/Tests/AIMCoreTests/Chat/SourceFaviconStoreTests.swift', 'embedded-credential-url', '4e71be07964f2377e50c02dd8aa787c74de82e2168448d1d8ea52d4df71d0c16'): 'Synthetic hostile CDN URL userinfo verifies icon rejection; never used for network authentication.',
    ('packages/AIMCore/Tests/AIMCoreTests/Chat/SourceCitationTests.swift', 'embedded-credential-url', 'f172d6ccc92e661cb7842dbd1167c5f2f3c5a97cfbb692f9edb23ec65efd846a'): 'Deliberate synthetic example.com URL userinfo verifies credential rejection; never used for network authentication.',
    ('packages/AIMCore/Tests/AIMCoreTests/Chat/WebActivityPresentationTests.swift', 'embedded-credential-url', '73a8150d0d7d27f6c89f67297bfc2e9dd594b1a79379a9540dce71da4c5d0183'): 'Deliberate synthetic example.com URL userinfo verifies credential rejection; never used for network authentication.',
    ('apps/macos/Tests/AIMAgentKitTests/AgentMemorySaveToolTests.swift', 'provider-secret', '4b86adc0edea62456737763fc6caad9c73196b1437e7f85eaef2cddcc52c870b'): 'Synthetic provider-shaped token used to test secret detection or redaction; never used for network authentication.',
    ('apps/macos/Tests/AIMApplicationTests/MissionHostCheckTests.swift', 'embedded-credential-url', '5a27246523fdc8992a0542560ead6837630a65b95df309043299bd89a15a7454'): 'Deliberate synthetic URL userinfo used to verify credential rejection/redaction; no network request is authorized.',
    ('apps/macos/Tests/AIMApplicationTests/PerplexityAgentWireTests.swift', 'embedded-credential-url', '4528e8f1ca241672572735e1c028735ab1a30c7c43d7c23918657bfa8eb5a55c'): 'Deliberate synthetic URL userinfo used to verify credential rejection/redaction; no network request is authorized.',
    ('apps/macos/Tests/AIMApplicationTests/ProjectSourceIndexTests.swift', 'provider-secret', '9cf6b85ac0437486b13832ae5aa8666c0036f4c5d22a501fac5d80d4a5931ee3'): 'Synthetic provider-shaped token used to test secret detection or redaction; never used for network authentication.',
    ('apps/macos/Tests/AIMApplicationTests/ProjectSourceIndexTests.swift', 'provider-secret', '14157a1a43eb641fef08191536d67d8010a88248cdf45179ad23c1f365f93f54'): 'Synthetic provider-shaped token used to test secret detection or redaction; never used for network authentication.',
    ('apps/macos/Tests/AIMApplicationTests/SkillLearningTests.swift', 'provider-secret', '909427d82c01b92a7c29dfa75a6eedba859165985439ab7513c8e81e74fd419c'): 'Synthetic provider-shaped token used to test secret detection or redaction; never used for network authentication.',
    ('apps/macos/Tests/AIMMacPlatformTests/AgentBrowserToolTests.swift', 'embedded-credential-url', '98c4e7c686cf77e59e7edafd91f67551bd7f35cb42f1b8ce8e0f316feb1febf7'): 'Deliberate synthetic URL userinfo used to verify credential rejection/redaction; no network request is authorized.',
    ('apps/macos/Tests/AIMMacPlatformTests/AgentMCPBuilderTests.swift', 'provider-secret', '6e254ff07d061d30654ca8107535ef8daf6dc5151ce105cd474bfa4c9efcb12e'): 'Synthetic provider-shaped token used to test secret detection or redaction; never used for network authentication.',
    ('apps/macos/Tests/AIMMacPlatformTests/AgentWebFetchToolTests.swift', 'embedded-credential-url', '899d150ca37fdcf42229273c4537eb543138cd63d20bc6ecc75f6ab00eab51bd'): 'Deliberate synthetic URL userinfo used to verify credential rejection/redaction; no network request is authorized.',
    ('apps/macos/Tests/AIMMacPlatformTests/GitPushTests.swift', 'embedded-credential-url', '0317614fdd2f0c993098cc907395bc91d3654993e869785be529b955de7a26ff'): 'Deliberate synthetic URL userinfo used to verify credential rejection/redaction; no network request is authorized.',
    ('apps/macos/Tests/AIMMacPlatformTests/PreviewAddressTests.swift', 'embedded-credential-url', '2ea20cc501e2d563aeb86579366bbf54d1c0ce9eb34e1bbdfa65779b9519c2b0'): 'Deliberate synthetic URL userinfo used to verify credential rejection/redaction; no network request is authorized.',
    ('apps/macos/scripts/release/test_verify_hosted_release.py', 'embedded-credential-url', 'a955655cd3a91d64dfd75247a2b61a30c6c6407934bd6157c04d2be414254653'): 'Deliberate synthetic URL userinfo used to verify credential rejection/redaction; no network request is authorized.',
    ('packages/AIMCore/Tests/AIMCoreTests/Chat/CoherentConversationTests.swift', 'embedded-credential-url', 'c8e0d1ca70432abcc2e3a935e3afc240c085b2c9b9ac917a477e56f9e5a41178'): 'Deliberate synthetic URL userinfo used to verify credential rejection/redaction; no network request is authorized.',
    ('packages/AIMCore/Tests/AIMCoreTests/Chat/NativeWebSearchTests.swift', 'embedded-credential-url', '22812b58ca08440e51fc5a3adc5275488209e410a004fbdfa0ac26412cd6c29e'): 'Deliberate synthetic URL userinfo used to verify credential rejection/redaction; no network request is authorized.',
    ('packages/AIMCore/Tests/AIMCoreTests/Chat/Round23EvidenceTests.swift', 'provider-secret', '366c66de6b4ac74f603c4de282878e1aa4d2b1821b09d03c7265f78da92e2dbd'): 'Synthetic provider-shaped token used to test secret detection or redaction; never used for network authentication.',
    ('packages/AIMCore/Tests/AIMCoreTests/Chat/Round23EvidenceTests.swift', 'provider-secret', 'b67f53a9555e47e1844cb8d698b18c3ff195df6751b76c1d14ebec29dbddca3f'): 'Synthetic provider-shaped token used to test secret detection or redaction; never used for network authentication.',
    ('packages/AIMCore/Tests/AIMCoreTests/ConnectorRegistryTests.swift', 'embedded-credential-url', '852a67fa918049935df87a4d57451873aac21c7daef308a5b8f20a93ce9b9dc5'): 'Deliberate synthetic URL userinfo used to verify credential rejection/redaction; no network request is authorized.',
    ('packages/AIMCore/Tests/AIMCoreTests/MediaRound20Tests.swift', 'embedded-credential-url', 'b98ca7f41a04a87c0b065432f9569d2ff0e9222bf0b43cbe9c7247935ec4ea1c'): 'Deliberate synthetic URL userinfo used to verify credential rejection/redaction; no network request is authorized.',
    ('website/tests/website.test.mjs', 'embedded-credential-url', '45b189d3f958c99cd02f389b8a618224399cf1bcc5290a9a1f2ef3d0596a6253'): 'Deliberate synthetic URL userinfo used to verify credential rejection/redaction; no network request is authorized.',
}


@dataclass(frozen=True, order=True)
class Finding:
    path: str
    line: int
    rule: str


def path_rules(path: str) -> list[str]:
    p = PurePosixPath(path)
    name = p.name.lower()
    parts = [part.lower() for part in p.parts]
    rules = []
    if (name == '.env' or name.startswith('.env.')) and not any(name.endswith('.' + suffix) for suffix in ('example', 'sample', 'template')):
        rules.append('environment-file')
    if name.endswith(('.p8', '.p12', '.pfx', '.mobileprovision', '.provisionprofile', '.keychain', '.keychain-db')) or name in {'id_rsa', 'id_ed25519', 'credentials', '.netrc', '.npmrc'}:
        rules.append('credential-or-signing-artifact')
    if name.endswith(('.pem', '.key')):
        rules.append('key-material-review')
    if any(part.endswith(('.app', '.xcarchive')) for part in parts) or name.endswith(('.dmg', '.ipa', '.pkg', '.dSYM'.lower())):
        rules.append('built-release-artifact')
    if name.endswith(('.zip', '.tar', '.tgz', '.tar.gz', '.7z', '.rar', '.tar.xz')):
        rules.append('archive-review')
    if any(part in {'__pycache__', '.pytest_cache', '.swiftpm', '.wrangler', '.cache', '.ds_store', 'deriveddata', 'xcuserdata', 'backups', 'backup', '.open-source-transition'} for part in parts) or name.endswith(('.pyc', '.bak', '.backup', '.bkp', '.orig', '.swp', '.swo', '.xcuserstate')):
        rules.append('cache-or-backup-artifact')
    if name.endswith(('.sqlite', '.sqlite3', '.db', '.sqlite-wal', '.sqlite-shm', '.har', '.trace', '.log')) or name in {'cookies', 'login data', 'history', 'local state'}:
        rules.append('private-runtime-data')
    return rules


def credential_literal(value: str) -> bool:
    """Catch opaque literals, while avoiding schema keys, labels and string interpolation."""
    if len(value) < 20 or PLACEHOLDER.search(value) or re.search(r'[\s.()\\]', value):
        return False
    categories = sum((any(c.islower() for c in value), any(c.isupper() for c in value), any(c.isdigit() for c in value)))
    entropy = -sum((value.count(c) / len(value)) * math.log2(value.count(c) / len(value)) for c in set(value))
    return categories >= 2 and entropy >= 3.3


def scan_text(path: str, text: str, public_emails: frozenset[str]) -> list[Finding]:
    findings = {Finding(path, text.count('\n', 0, match.start()) + 1, 'private-key') for match in PRIVATE_KEY.finditer(text)}
    for number, line in enumerate(text.splitlines(), 1):
        for rule, pattern in CONTENT_RULES:
            matches = list(pattern.finditer(line))
            if rule == 'user-home-path':
                matches = [match for match in matches if match.group().replace('\\', '/').rstrip('/').rsplit('/', 1)[-1] != 'example']
            if matches:
                findings.add(Finding(path, number, rule))
        for match in EMAIL.finditer(line):
            address = match.group().lower()
            domain = address.rsplit('@', 1)[1]
            image_scale = bool(re.search(r'@[23]x\.(?:png|jpg|jpeg|webp|pdf)$', address))
            if not image_scale and address not in public_emails and domain not in EXAMPLE_DOMAINS and not domain.endswith(('.example', '.test', '.invalid')):
                findings.add(Finding(path, number, 'personal-email-review'))
        for match in LITERAL_SECRET.finditer(line):
            # Report a rule only. The captured value is never returned or logged.
            if credential_literal(match.group(1)):
                findings.add(Finding(path, number, 'literal-secret-review'))
    return sorted(findings)


def inventory(root: Path, mode: str) -> tuple[list[str], str]:
    own_git = (root / '.git').exists()
    if mode == 'tracked' and not own_git:
        raise ValueError('tracked mode requires a Git repository at the selected root')
    if mode != 'all' and own_git:
        args = ['git', '-C', str(root), 'ls-files', '-z', '--cached']
        if mode != 'tracked':
            args += ['--others', '--exclude-standard']
        result = subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return sorted(set(os.fsdecode(item) for item in result.stdout.split(b'\0') if item)), 'tracked' if mode == 'tracked' else 'tracked-and-untracked-not-ignored'
    files = []
    for directory, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in GENERATED_DIRS)
        for dirname in tuple(dirs):
            if (Path(directory) / dirname).is_symlink():
                files.append((Path(directory) / dirname).relative_to(root).as_posix())
                dirs.remove(dirname)
        for name in sorted(names):
            files.append((Path(directory) / name).relative_to(root).as_posix())
    return sorted(files), 'filesystem-excluding-generated'


def audit(root: Path, mode: str = 'auto', public_emails: frozenset[str] = PUBLIC_EMAILS, strict_fixtures: bool = False, reviewed_fixtures=None) -> dict:
    files, method = inventory(root, mode)
    indexed = {}
    if mode == 'tracked':
        listing = subprocess.run(['git', '-C', str(root), 'ls-files', '--stage', '-z'], check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        for record in listing.stdout.split(b'\0'):
            if not record:
                continue
            metadata, name = record.split(b'\t', 1)
            file_mode, object_id, stage = metadata.split()
            indexed[os.fsdecode(name)] = (file_mode, object_id, stage)
    findings = set()
    approved = []
    reviewed_fixtures = REVIEWED_FIXTURES if reviewed_fixtures is None else reviewed_fixtures
    stats = {'files_considered': 0, 'text_files_scanned': 0, 'binary_files_not_content_scanned': 0, 'generated_paths_skipped': 0}
    for relative in files:
        parts = PurePosixPath(relative).parts
        if not parts or any(part == '..' for part in parts) or PurePosixPath(relative).is_absolute():
            findings.add(Finding('[invalid-path]', 0, 'unsafe-inventory-path'))
            continue
        if any(part in GENERATED_DIRS for part in parts):
            stats['generated_paths_skipped'] += 1
            # A tracked generated path is still a publication finding, although content is excluded.
            if method.startswith('tracked'):
                findings.add(Finding(relative, 0, 'tracked-generated-artifact'))
            continue
        stats['files_considered'] += 1
        for rule in path_rules(relative):
            findings.add(Finding(relative, 0, rule))
        file = root / relative
        entry = indexed.get(relative)
        if entry and entry[2] != b'0':
            findings.add(Finding(relative, 0, 'unmerged-index-entry'))
            continue
        if (entry and entry[0] == b'120000') or (not entry and file.is_symlink()):
            findings.add(Finding(relative, 0, 'symlink-review'))
            continue
        if entry and entry[0] == b'160000':
            findings.add(Finding(relative, 0, 'submodule-review'))
            continue
        if not entry and not file.exists():
            # Deleted tracked files are not part of the working tree publication candidate.
            continue
        if not entry and not file.is_file():
            findings.add(Finding(relative, 0, 'nonregular-file-review'))
            continue
        try:
            size = int(subprocess.run(['git', '-C', str(root), 'cat-file', '-s', os.fsdecode(entry[1])], check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout) if entry else file.stat().st_size
            if size > 16 * 1024 * 1024:
                findings.add(Finding(relative, 0, 'large-file-review'))
                continue
            data = subprocess.run(['git', '-C', str(root), 'cat-file', 'blob', os.fsdecode(entry[1])], check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout if entry else file.read_bytes()
        except (OSError, ValueError, subprocess.SubprocessError):
            findings.add(Finding(relative, 0, 'file-read-failed'))
            continue
        if b'\0' in data:
            stats['binary_files_not_content_scanned'] += 1
            continue
        try:
            text = data.decode('utf-8-sig')
        except UnicodeError:
            stats['binary_files_not_content_scanned'] += 1
            continue
        stats['text_files_scanned'] += 1
        lines = text.splitlines()
        for finding in scan_text(relative, text, public_emails):
            digest = hashlib.sha256(lines[finding.line - 1].encode('utf-8')).hexdigest()
            key = (relative, finding.rule, digest)
            # Exceptions apply only to reviewed exact line hashes and these two fixture rules.
            # Personal paths/emails, private key blocks, project IDs and signing data cannot be exempted.
            fixture_path = '/Tests/' in relative or '/tests/' in relative or '/test_' in relative
            reason = reviewed_fixtures.get(key) if not strict_fixtures and fixture_path and finding.rule in {'provider-secret', 'embedded-credential-url'} else None
            if reason:
                approved.append({**asdict(finding), 'reason': reason})
            else:
                findings.add(finding)
    return {'inventory': method, **stats, 'reviewed_fixture_matches': approved, 'findings': [asdict(item) for item in sorted(findings)]}


class ScannerTests(unittest.TestCase):
    def fixture(self, files):
        temporary = tempfile.TemporaryDirectory(prefix='aim-publication-test-')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        for name, content in files.items():
            file = root / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(content if isinstance(content, bytes) else content.encode())
        return root

    def test_synthetic_sensitive_values_are_redacted(self):
        key = 'sk-' + 'SYNTHETIC1234567890' * 2
        home = '/' + 'Users/' + 'fixture-person/private.txt'
        email = 'fixture-person' + '@mail.invalidhost.com'
        project = 'https://' + 'abcdefghijklmnopqrst' + '.supabase.co'
        root = self.fixture({'fixture.txt': '\n'.join([key, home, email, project, '-----BEGIN ' + 'PRIVATE KEY-----' + '\n' + 'A' * 64 + '\n-----END ' + 'PRIVATE KEY-----'])})
        report = audit(root)
        self.assertEqual({f['rule'] for f in report['findings']}, {'provider-secret', 'user-home-path', 'personal-email-review', 'project-instance', 'private-key'})
        rendered = json.dumps(report)
        for value in [key, home, email, project]: self.assertNotIn(value, rendered)
        self.assertEqual([f['line'] for f in report['findings']], [1, 2, 3, 4, 5])

    def test_public_contacts_and_examples(self):
        root = self.fixture({'.env.example': 'API_KEY="your-provider-key"\nCONTACT="contact@aim-ai.tech"\nuser@example.test'})
        self.assertFalse(audit(root)['findings'])

    def test_xcconfig_escaped_project_url_is_not_hidden(self):
        host = 'abcdefghijklmnopqrst' + '.supabase.co'
        root = self.fixture({'Settings.xcconfig': 'URL = https:/$()/' + host})
        findings = audit(root)['findings']
        self.assertEqual(findings, [{'path': 'Settings.xcconfig', 'line': 1, 'rule': 'project-instance'}])
        self.assertNotIn(host, json.dumps(findings))

    def test_generated_trees_are_excluded(self):
        root = self.fixture({'node_modules/pkg/.env': 'hidden', '.build/private.key': 'hidden', 'dist/test.txt': 'hidden', '.git/private': 'hidden', 'ok.txt': 'ok'})
        report = audit(root, 'all')
        self.assertEqual(report['files_considered'], 1)
        self.assertFalse(report['findings'])

    def test_signing_cache_backup_and_runtime_artifacts(self):
        root = self.fixture({'secret.p12': b'\0test', 'backup/state.sqlite': b'\0test', '.env.local': 'value', 'xcuserdata/test.xcuserstate': 'x', 'build/test.dmg': b'\0data'})
        rules = {f['rule'] for f in audit(root)['findings']}
        self.assertTrue({'credential-or-signing-artifact', 'cache-or-backup-artifact', 'private-runtime-data', 'environment-file', 'built-release-artifact'} <= rules)

    def test_symlinks_are_reported_and_never_followed(self):
        root = self.fixture({'ok.txt': 'ok'})
        (root / 'outside').symlink_to(root.parent, target_is_directory=True)
        report = audit(root)
        self.assertIn({'path': 'outside', 'line': 0, 'rule': 'symlink-review'}, report['findings'])

    def test_literal_credentials_and_examples(self):
        sensitive = 'credential-' + '0123456789abcdef'
        root = self.fixture({'fixture.txt': 'API_KEY="' + sensitive + '"\nSECRET="your-secret-goes-here"'})
        findings = audit(root)['findings']
        self.assertEqual(findings, [{'path': 'fixture.txt', 'line': 1, 'rule': 'literal-secret-review'}])
        self.assertNotIn(sensitive, json.dumps(findings))

    def test_repository_boundary_and_tracked_generated_file(self):
        root = self.fixture({'ok.txt': 'ok', 'dist/generated.txt': 'generated'})
        subprocess.run(['git', 'init', '-q', str(root)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['git', '-C', str(root), 'add', 'ok.txt', 'dist/generated.txt'], check=True, stdout=subprocess.DEVNULL)
        report = audit(root, 'tracked')
        self.assertEqual(report['inventory'], 'tracked')
        self.assertIn({'path': 'dist/generated.txt', 'line': 0, 'rule': 'tracked-generated-artifact'}, report['findings'])

    def test_tracked_mode_reads_staged_blobs_not_cleaned_working_tree(self):
        key = 'sk-' + 'SYNTHETIC1234567890' * 2
        root = self.fixture({'fixture.txt': key})
        subprocess.run(['git', 'init', '-q', str(root)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['git', '-C', str(root), 'add', 'fixture.txt'], check=True, stdout=subprocess.DEVNULL)
        (root / 'fixture.txt').unlink()
        self.assertIn('provider-secret', {f['rule'] for f in audit(root, 'tracked')['findings']})

    def test_reviewed_fixture_requires_exact_hash_path_and_rule(self):
        key = 'sk-' + 'fixture-1234567890abcdef' * 2
        root = self.fixture({'component/Tests/Fixture.swift': key, 'component/Tests/Other.swift': key})
        digest = hashlib.sha256(key.encode()).hexdigest()
        baseline = {('component/Tests/Fixture.swift', 'provider-secret', digest): 'Synthetic regression fixture.'}
        report = audit(root, reviewed_fixtures=baseline)
        self.assertEqual(len(report['reviewed_fixture_matches']), 1)
        self.assertEqual(len(report['findings']), 1)
        self.assertEqual(len(audit(root, strict_fixtures=True, reviewed_fixtures=baseline)['findings']), 2)
        (root / 'component/Tests/Fixture.swift').write_text(key + 'changed')
        self.assertEqual(len(audit(root, reviewed_fixtures=baseline)['findings']), 2)

    def test_personal_data_can_never_be_fixture_exempted(self):
        value = '/' + 'Users/' + 'private-person'
        root = self.fixture({'component/Tests/Fixture.swift': value})
        baseline = {('component/Tests/Fixture.swift', 'user-home-path', hashlib.sha256(value.encode()).hexdigest()): 'Cannot exempt personal data.'}
        self.assertEqual(len(audit(root, reviewed_fixtures=baseline)['findings']), 1)
        (root / 'component/Tests/Fixture.swift').write_text('/' + 'Users/' + 'example/Documents')
        self.assertFalse(audit(root)['findings'])

    def test_generated_directory_symlink_is_not_followed(self):
        root = self.fixture({'ok.txt': 'ok'})
        (root / 'node_modules').symlink_to(root.parent, target_is_directory=True)
        self.assertEqual(audit(root)['files_considered'], 1)

    def test_instance_assignments_and_oversized_files_are_not_silently_skipped(self):
        root = self.fixture({'config.toml': 'project_id = "' + 'abcdefghijklmnopqrst' + '"'})
        with (root / 'oversized.txt').open('wb') as stream:
            stream.truncate(16 * 1024 * 1024 + 1)
        rules = {finding['rule'] for finding in audit(root)['findings']}
        self.assertEqual(rules, {'project-configuration', 'large-file-review'})

    def test_missing_git_fails_tracked_mode(self):
        root = self.fixture({'ok.txt': 'ok'})
        with self.assertRaises(ValueError): inventory(root, 'tracked')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--tracked', action='store_true', help='scan only tracked files in a repository rooted exactly at --root')
    mode.add_argument('--all-files', action='store_true', help='scan the filesystem, including ignored files except generated trees')
    parser.add_argument('--format', choices=('text', 'json'), default='text')
    parser.add_argument('--allow-public-email', action='append', default=[], help='explicitly reviewed additional public contact or upstream attribution address')
    parser.add_argument('--strict-fixtures', action='store_true', help='also report reviewed synthetic attack fixtures; use when reviewing the allowlist')
    parser.add_argument('--self-test', action='store_true', help='run synthetic temporary-fixture tests')
    args = parser.parse_args(argv)
    if args.self_test:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ScannerTests))
        return 0 if result.wasSuccessful() else 1
    root = args.root.resolve()
    if not root.is_dir():
        print('Publication audit failed: selected root is not a directory.', file=sys.stderr)
        return 2
    try:
        report = audit(root, 'tracked' if args.tracked else 'all' if args.all_files else 'auto', PUBLIC_EMAILS | frozenset(value.lower() for value in args.allow_public_email), args.strict_fixtures)
    except (ValueError, OSError, subprocess.SubprocessError):
        print('Publication audit failed: repository inventory could not be read.', file=sys.stderr)
        return 2
    if args.format == 'json':
        print(json.dumps(report, indent=2, ensure_ascii=True))
    else:
        for finding in report['findings']:
            # Never emit source content or matching values, even in error messages.
            print(f"{finding['path']}:{finding['line']}: {finding['rule']}")
        print(f"Publication audit: {report['text_files_scanned']} text files scanned; {report['binary_files_not_content_scanned']} binary files not content-scanned; {len(report['reviewed_fixture_matches'])} reviewed exact fixture matches; {len(report['findings'])} findings; inventory={report['inventory']}.")
    return 1 if report['findings'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
