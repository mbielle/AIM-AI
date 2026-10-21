# Publication audit

Source-candidate audit for the 2026-10-16 open-source extraction. This records a repeatable static check and its limits. It is not a release qualification, full security audit, forensic review of original private repositories, or complete license clearance.

## Run the checks

The scanner is [scripts/audit-publication.py](../scripts/audit-publication.py), implemented with Python's standard library. It makes no network requests and writes no repository files. Tests use disposable temporary fixtures only.

```sh
python3 scripts/audit-publication.py --self-test
python3 scripts/audit-publication.py --all-files
python3 scripts/audit-publication.py --all-files --format json
# After creating/staging the new public repository:
python3 scripts/audit-publication.py --tracked
```

The default mode scans the working tree of a repository rooted exactly at the selected directory, including untracked files that are not ignored. Before Git initialization it scans the filesystem. It never silently adopts an enclosing private repository. `--all-files` includes ignored files too, apart from generated trees. `--tracked` requires a Git repository at the selected root and reads the actual indexed blobs; removing or cleaning a working-tree file does not conceal a staged secret. Re-run tracked mode after staging the final source and before creating a commit or public remote.

Exit status 0 means no unreviewed pattern findings, 1 means review findings, and 2 means inventory setup failed. Each finding contains only relative filename, line and rule. Source excerpts and matching values are never printed. Line 0 denotes a path/inventory finding. JSON also reports scan counts and exact reviewed fixture matches. A value-redacting scanner output may be included in review evidence; do not attach raw files that triggered findings.

## Coverage

The content rules detect common provider/service/repository credential shapes, AWS access IDs, embedded JWTs, actual PEM private-key blocks, opaque hardcoded credential literals, credentials in URLs, home-directory paths, non-example email addresses, private deployment project references and Apple signing identities. Filename rules identify environment files, private keys/signing profiles, runtime databases/logs/browser state, app/release binaries, and cache/backup artifacts.

`.git`, `.build`, `node_modules` and `dist` are not content-scanned. Directory symlinks are never followed, including a `node_modules` symlink. A generated path that is actually indexed is still reported as a publication finding. Other symlinks and submodules require review. UTF-8 text is scanned without excluding whole source or test directories. Binary/non-UTF-8 assets are counted rather than searched as text; filename rules still apply.
The separate [asset audit](ASSET_REVIEW.md) pins image/font/media and SVG bytes,
source descriptions and notice hashes. `./scripts/check-publication.sh` checks
indexed blobs with both scanners and rejects all pending asset rights/owner reviews. Files over 16 MiB require review and are not content-scanned.

The known public contact already published in the website is an explicit email exception. Standard example domains and the exact synthetic username `example` in home-path fixtures are accepted. Additional public contacts require an explicit `--allow-public-email` argument and owner review; this option is not a justification to publish someone's private address.

These are pattern rules, not proof that every possible credential or private datum is absent. Encodings, image/document metadata, archives, custom token formats, low-entropy passwords, arbitrary identifiers and ordinary personal names can escape these checks. Binary assets and unknown file provenance still need owner review. The scanner does not search Git history, keychains, production dashboards or files outside the selected candidate root. A new repository should be initialized from the sanitized source rather than copying an old `.git` directory.

## Extraction evidence

The scanner's 14 temporary-fixture tests passed. They verify value redaction, placeholder handling, signing/cache/data filename checks, no symlink traversal, generated-directory exclusion, indexed generated-file rejection, exact fixture hashes, changed-fixture detection, staged-blob inspection, escaped xcconfig project hosts, large-file review and repository-boundary behavior.

At the final staged pass, 1505 candidate files were considered: 1273 UTF-8 text files scanned and 232 binary/non-UTF-8 files counted. There were 0 unreviewed scanner findings and 19 reviewed exact synthetic fixture matches. The indexed blobs were scanned with tracked mode after staging; rerun it whenever source or index contents change. The binary count is not an asset-rights or metadata clearance.

Original home usernames and email-like strings in ten authorized Mac/core test files were replaced with explicit example fixtures while retaining matching assertions. The Mac owner removed a historical distribution identity configuration and replaced qualification/example paths and signing markers. These were staged-copy changes; the original working repositories were preserved. The scanner did not connect to a provider, sign an app, use a real private key, unsubscribe an address or mutate a hosted account.

## Deliberate attack/redaction fixtures

Security regression tests intentionally contain provider-shaped dummy keys and URL userinfo. Their static forms are retained when they are the test input itself. The only permitted fixture exceptions are `provider-secret` and `embedded-credential-url`, restricted by exact relative file, rule and SHA-256 of the entire UTF-8 source line without its newline. All other rules, including genuine private-key blocks, personal email/home paths, deployment references and signing data, remain non-exemptible through the fixture mechanism.

Provider-key fixtures exercise detection/redaction or persistence boundaries using synthetic values; they never authenticate a network request. URL-userinfo fixtures test credential rejection/redaction with synthetic credentials; their presence authorizes no request. No whole test file or directory is exempt. Changing any allowed line, moving it to another file, or introducing another sensitive rule produces an unreviewed finding. Maintainers must review a reason and exact hash before changing the allowlist in the scanner.

```sh
# Review the raw pattern findings, including deliberate fixtures:
python3 scripts/audit-publication.py --all-files --strict-fixtures
```

The following exact hashes are the reviewed baseline. The original matching values are intentionally not reproduced here.

| Fixture file | Rule | Complete source-line SHA-256 |
| --- | --- | --- |
| `apps/macos/Tests/AIMAgentKitTests/AgentMemorySaveToolTests.swift` | `provider-secret` | `4b86adc0edea62456737763fc6caad9c73196b1437e7f85eaef2cddcc52c870b` |
| `apps/macos/Tests/AIMApplicationTests/MissionHostCheckTests.swift` | `embedded-credential-url` | `5a27246523fdc8992a0542560ead6837630a65b95df309043299bd89a15a7454` |
| `apps/macos/Tests/AIMApplicationTests/PerplexityAgentWireTests.swift` | `embedded-credential-url` | `4528e8f1ca241672572735e1c028735ab1a30c7c43d7c23918657bfa8eb5a55c` |
| `apps/macos/Tests/AIMApplicationTests/ProjectSourceIndexTests.swift` | `provider-secret` | `9cf6b85ac0437486b13832ae5aa8666c0036f4c5d22a501fac5d80d4a5931ee3` |
| `apps/macos/Tests/AIMApplicationTests/ProjectSourceIndexTests.swift` | `provider-secret` | `14157a1a43eb641fef08191536d67d8010a88248cdf45179ad23c1f365f93f54` |
| `apps/macos/Tests/AIMApplicationTests/SkillLearningTests.swift` | `provider-secret` | `909427d82c01b92a7c29dfa75a6eedba859165985439ab7513c8e81e74fd419c` |
| `apps/macos/Tests/AIMMacPlatformTests/AgentBrowserToolTests.swift` | `embedded-credential-url` | `98c4e7c686cf77e59e7edafd91f67551bd7f35cb42f1b8ce8e0f316feb1febf7` |
| `apps/macos/Tests/AIMMacPlatformTests/AgentMCPBuilderTests.swift` | `provider-secret` | `6e254ff07d061d30654ca8107535ef8daf6dc5151ce105cd474bfa4c9efcb12e` |
| `apps/macos/Tests/AIMMacPlatformTests/AgentWebFetchToolTests.swift` | `embedded-credential-url` | `899d150ca37fdcf42229273c4537eb543138cd63d20bc6ecc75f6ab00eab51bd` |
| `apps/macos/Tests/AIMMacPlatformTests/GitPushTests.swift` | `embedded-credential-url` | `0317614fdd2f0c993098cc907395bc91d3654993e869785be529b955de7a26ff` |
| `apps/macos/Tests/AIMMacPlatformTests/PreviewAddressTests.swift` | `embedded-credential-url` | `2ea20cc501e2d563aeb86579366bbf54d1c0ce9eb34e1bbdfa65779b9519c2b0` |
| `apps/macos/scripts/release/test_verify_hosted_release.py` | `embedded-credential-url` | `a955655cd3a91d64dfd75247a2b61a30c6c6407934bd6157c04d2be414254653` |
| `packages/AIMCore/Tests/AIMCoreTests/Chat/CoherentConversationTests.swift` | `embedded-credential-url` | `c8e0d1ca70432abcc2e3a935e3afc240c085b2c9b9ac917a477e56f9e5a41178` |
| `packages/AIMCore/Tests/AIMCoreTests/Chat/NativeWebSearchTests.swift` | `embedded-credential-url` | `22812b58ca08440e51fc5a3adc5275488209e410a004fbdfa0ac26412cd6c29e` |
| `packages/AIMCore/Tests/AIMCoreTests/Chat/Round23EvidenceTests.swift` | `provider-secret` | `366c66de6b4ac74f603c4de282878e1aa4d2b1821b09d03c7265f78da92e2dbd` |
| `packages/AIMCore/Tests/AIMCoreTests/Chat/Round23EvidenceTests.swift` | `provider-secret` | `b67f53a9555e47e1844cb8d698b18c3ff195df6751b76c1d14ebec29dbddca3f` |
| `packages/AIMCore/Tests/AIMCoreTests/ConnectorRegistryTests.swift` | `embedded-credential-url` | `852a67fa918049935df87a4d57451873aac21c7daef308a5b8f20a93ce9b9dc5` |
| `packages/AIMCore/Tests/AIMCoreTests/MediaRound20Tests.swift` | `embedded-credential-url` | `b98ca7f41a04a87c0b065432f9569d2ff0e9222bf0b43cbe9c7247935ec4ea1c` |
| `website/tests/website.test.mjs` | `embedded-credential-url` | `45b189d3f958c99cd02f389b8a618224399cf1bcc5290a9a1f2ef3d0596a6253` |

## Remaining publication and binary-release gates

- Review the final staged file list and re-run `--tracked`; this document is not approval to create a public remote or upload files.
- Confirm first-party ownership and the chosen license. Retain [third-party notices](../THIRD_PARTY_NOTICES.md) and resolve the documented non-Lobe avatar/logo provenance gaps before claiming all source assets are cleared.
- Inspect binary/image/font metadata and any additional assets manually; the text scanner does not certify them.
- For every binary distribution, assemble exact dependency/runtime license and NOTICE bundles, including browser engines, Node, Swift packages, optional agents, CUA, llama.cpp, MLX and model/tokenizer data actually shipped. The optional MLX packaging branch requires its separately reviewed complete license inventory.
- Keep source checks, automated tests, app permissions, actual Mac/iPhone interaction, release signing/notarization, update-feed qualification and public website/backend deployment as separate evidence gates. None is implied by a clean publication-pattern scan.

No public publication, dashboard change, production migration or public download activation is performed by this scanner or documented as completed here.
