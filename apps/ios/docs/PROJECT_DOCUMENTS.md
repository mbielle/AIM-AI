# iPhone project workspace and local sources

Tapping a native project opens its own Chats / Sources workspace. Conversations
are scoped by project ID. The shared conversation composer starts a project draft
without moving the previously opened conversation. A project menu edits name,
memory scope and instructions, pins it, or confirms deletion. Deletion detaches
chats rather than erasing their history; a persistent sync tombstone prevents a
stale project from reappearing. Local source payloads remain recoverable privately.

Sources are added directly from Files, Photos, Camera or typed text. Extraction
happens on-device; success commits both the original and extracted text before
showing the source. No additional 'keep local copy' or 'include in chat' dialog is
required. The source can be previewed, excluded or deleted afterward. Previously
excluded sources remain excluded during migration. Google Drive is accessed only
through its installed Files provider; a native Slack source connector is absent.

See [Core storage and retrieval](../../../packages/AIMCore/docs/PROJECT_SOURCE_RETRIEVAL.md)
for quotas, index, migration and cancellation. The previous 20-source / 128-KB
project caps and four-enabled-file cap are removed. Technical bounds remain:
1,000 sources/project, 500 MB/profile including index and retained payloads,
100 MB/original, 8 MB/extracted text. A query selects bounded relevant excerpts;
not every imported file is attached to every message. No embedding API is used.

Supported tool routes can search and read project chunks using real source IDs.
Other routes receive a bounded local relevance selection, not an advertised tool
capability they do not implement. Existing provider admission, approvals and budgets
remain enforced. Tools cannot expand a strict budget that has no verified upper
bound. Hosted web search separately offers an estimated-budget mode with explicit
coverage notices; it does not grant unbounded project-source/skill tool loops.
Readable citations use observed source names while preserving internal locators
and original history. Source context is untrusted reference material, not system instructions.
The local library does not upload itself; excerpts deliberately sent in account
conversations can be synchronized as conversation history. Original sources are
not part of the profile-copy archive. Voice/Remote do not gain access to this local
source library through this feature. Removing a source does not rewrite historical
messages that already contained it.

## Qualification boundaries

The user confirmed on 17 October that projects/instructions and documents/extracted
text survive restart on both physical qualification apps, and that import/cancel
works on iPhone. Those observations concern the earlier candidate. The new project
workspace, storage migration and tool retrieval require new device validation.
Automated evidence is recorded in docs/IMPLEMENTATION_STATUS.md. See also
[visual review checklist](../../../docs/UX_REVIEW_CHECKLIST.md).
