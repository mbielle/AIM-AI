# Local project sources

`ProjectSourceStore` is a portable, device-only library rooted in the directory of
one local/account storage identity. Its API has no credentials or networking.
Callers must capture the active project and profile store before a submission and
reject results after an identity/project generation change.

## Retention and limits

Each new source retains its complete imported text and, when supplied, its original
bytes in UUID-named payload files. Metadata and a SQLite FTS5 chunk index live in
`project-sources-v2/index.sqlite`. Names are display metadata, never filesystem
paths. UI records contain a UTF-8-safe preview of at most 4 KB; `readText` and
`readOriginal` return retained contents, not that preview.

Technical bounds are 1,000 sources per project, 10,000 per profile, 100 MB original
per source, 8 MB extracted text per source, and 500 MB per profile including
payloads and allocated index pages. Imports fail as a whole when a bound is hit;
there is no silent text truncation. A temporary import copy, index rollback journal
and transaction payload can require additional bounded free disk during an import.
The retained compatibility JSON (at most 8 MB) is outside the new library quota.
SQLite also has a hard maximum page count. Native Office archive/XML/image safety
budgets remain in force independently of the extracted-text ceiling.

Index mutations use SQLite transactions with full synchronization. Payloads are
written atomically with complete file protection on iOS. Failed imports remove
only their own newly generated payload directory. A deletion first renames its
payload into a recoverable tombstone; initialization restores an interrupted
pre-commit deletion or finishes a committed deletion. Unknown/corrupt databases,
missing payloads, unsupported schema versions and symlink payloads fail closed;
no fallback reaches another profile or uploads local data. Interrupted-import
orphans remain private and count toward quota, rather than being silently deleted.

## Compatibility migration

The first open reads legacy `project-documents.json` with its original 8-MB bound.
All entries must validate before the migration transaction can commit. Existing
IDs, project IDs, import dates, text, original-size metadata and each `useInChat`
choice are preserved. In particular a private CV with `useInChat: false` remains
excluded; migration never treats prior import as fresh permission. The old store
never retained original binaries, so these records truthfully report
`hasOriginal: false` and cannot fabricate an original download.

The legacy JSON is never rewritten or removed, and successful migration is marked
transactionally so it does not run twice. It is a compatibility backup: deleting a
migrated source from the new library does not erase that preserved backup. An
owner-controlled explicit backup cleanup/export workflow is not implemented here.
No real installed library was read or migrated during development.

New imports are searchable by default. This makes picking a local project source
the explicit import action; a second Keep Copy dialog is unnecessary. Disabling a
source excludes it from search and chunk tools without deleting its retained copy.
No cloud synchronization or profile-archive export of project-source binaries is
implemented by this library.

## Query retrieval and citations

`search(projectID:query:)` applies the project and enabled-source filters in SQL
before selecting ranked results. It uses local FTS5 with case/accent folding,
French/English stop words and CJK single-character/bigram tokens. Chunks contain at
most 2 KB of text with 384-byte overlap, preserving terms at chunk boundaries.
Filenames also participate in matching. This is lexical retrieval, not semantic
search: synonym-only or vague questions can return no results.

An empty/no-match query returns no excerpts. Queries are capped at 8 KB and 64
normalized unique terms. At most eight chunks from four sources fit a 24-KB
context budget including citation headers. Each excerpt exposes source UUID,
name, zero-based chunk index, text and `source:<uuid>#<one-based-chunk>` citation.
Model-visible tool results also carry a readable `displayCitation`. Internal IDs
stay available to tool arguments, while answer instructions request filenames.
`ProjectSourceCitationPresentation` projects only recognized metadata-backed
references for display/copy/speech after timeline slicing. It preserves stored
text, code blocks, links and unknown locators.

`readChunk(sourceID:chunkIndex:projectID:)` rechecks the active project and enabled
flag, returning one bounded cited chunk. Full-text/original reads are explicit
local presentation APIs, not model tools. Reference text is untrusted data and
never grants authority to run tools.

The iOS facade exposes `sourceStore`, `files`, `readText`, `readOriginal`,
`setUse`, `delete` and asynchronous `attachments(for:query:)`. The latter runs
search off the main actor, propagates cancellation and groups cited chunks into
at most four document attachments. Its old no-query overload returns nothing;
whole project texts are never automatically inserted into a message. Native Chat
attachment limits remain unchanged: default extraction is 20 MB source / 64 KB
text / 100 PDF pages; explicit project extraction permits 100 MB / 8 MB / 1,000
pages, with a 120-second PDF deadline. Local OCR remains best-effort; no paid OCR,
links, formulas or macros execute.

`NativeChatProject` additionally persists `isPinned` and `memoryScope` (`default`
or `projectOnly`). Old JSON missing these keys decodes as false/default. Unknown
scope values fail decoding rather than silently enabling broader memory. Actual
memory routing belongs to the caller, not document storage.

## Synthetic verification

The initial focused Core run passed 18 tests (10 source retrieval, six native
attachment, two project snapshot). It covers retained large text/originals beyond
legacy limits, migration and private CV opt-out, independent profiles/projects,
disabled source/chunk denial, French/Japanese matching, bounded relevant excerpts,
corrupt-byte preservation, transactional quotas/deletion and cancelled import.
Additional metadata/overlap/recovery regression checks are recorded in the final
handoff; this document does not certify physical iPhone import or installed-data
migration.

Final focused run: **24 tests, zero failures** (13 source retrieval/storage,
three project metadata, six native attachment and two project snapshot tests).
Log: `/private/tmp/aim-core-project-source-final-tests.log`. Exact command from the
repository root, after creating the private test home/cache directories:

```sh
env CFFIXED_USER_HOME=/private/tmp/aim-core-source-tests-home \
  CLANG_MODULE_CACHE_PATH=/private/tmp/aim-clean-checkout-modules \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/aim-clean-checkout-modules \
  AIM_TEST_INSTALLATION_ID=2123456789abcdef0123456789abcdef \
  swift test --package-path packages/AIMCore \
  --scratch-path /private/tmp/aim-clean-checkout-core \
  --cache-path /private/tmp/aim-clean-checkout-package-cache \
  --disable-sandbox --disable-automatic-resolution \
  --filter 'ProjectSourceRetrievalTests|NativeChatProjectTests|NativeAttachmentTests|ProjectFileSnapshotTests'
```

These are targeted checks, not a full-suite/device qualification. iOS
`LocalExperienceTests` were updated to the new retention/query contract and to
assert that profile archive copies preserve pin/memory-scope metadata; the app
integration build/test result belongs to the coordinating iOS check.

The iOS `addPrepared(_:projectID:)` import facade performs payload writing and
indexing in a detached worker, forwards cancellation to that worker, then loads
lightweight metadata off the main actor before publishing UI records. A cancelled
operation rolls back before COMMIT. Cancellation arriving after a successful
COMMIT cannot undo that durable copy: the store returns the committed record
without a later cancellation-sensitive read, and the facade refreshes the retained
source even if its initiating view has disappeared. Two additional iOS regression
tests cover asynchronous retention/refresh and an already-cancelled import; their
execution is part of the coordinating iOS check.

After the asynchronous-import commit-boundary adjustment, the focused
`ProjectSourceRetrievalTests` filter passed again: **13 tests, zero failures**,
`/private/tmp/aim-core-project-source-async-followup-tests.log`, using the same
isolated command/environment above with only that filter. This is a follow-up run,
not 13 additional distinct tests.
