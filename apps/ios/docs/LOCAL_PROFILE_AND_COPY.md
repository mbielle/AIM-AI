# Local profiles and reviewed account copies

AIM opens a persistent local profile when no account is selected. Its ID is stored in the installation's secure store. A missing or damaged identity is not replaced silently. Account profiles retain their existing account UUIDs, chat directories and credential namespaces.

Local Chat, projects, preferences and memory persist without Supabase. A local identity does not authenticate to cloud or Remote services. Connecting a cloud account opens a separate profile; returning to local reloads the local context and does not adopt account data. There is no implicit local-to-account merge.

## Copy selected local content to an account

1. In the local profile, open Settings → Import / Copy profile data.
2. Expand the conversation and project selectors. Select only the desired items. Select related projects if their grouping should be retained.
3. Review the selected conversation/project counts and the attachment limitations, then choose **Save selected copy to Files**. The source remains unchanged.
4. Connect the destination cloud account, open its Settings → Import / Copy profile data, and choose the saved JSON.
5. Review the document counts and individually select the conversations/projects to copy. Nothing is imported or uploaded by opening the file or changing this selection.
6. Choose **Review copy to account**. The final alert identifies the destination and counts, and explains that normal synchronization can upload the copy. Confirm with **Copy and allow account sync**, or cancel.

The import first writes the complete selected copy atomically to destination storage. Each conversation, message and project receives a new ID; existing destination data is never merged or overwritten. Only then is normal account synchronization scheduled. Failed synchronization leaves a persisted local destination copy and reports through the existing synchronization status; a successful local copy alone does not prove server delivery. Re-importing intentionally produces another copy.

## Included and excluded content

Included: conversation text, timestamps, model/provider labels, project name/instructions, inline document text/images and retained prepared video frames/transcripts. Attachments are validated with existing native attachment rules. Projects without conversations may be copied; conversations whose projects are not selected become ungrouped.

Excluded: original video/source files, generated media referenced by external IDs, tool actions/timelines, active jobs/turn state, machine identities/permissions, activity/cost history, memory, preferences and stored provider credentials. The preview reports excluded generated-media references/actions from the source archive. User-authored text is copied as selected, including any sensitive text the user put into a conversation or document. The archive does not separately collect provider keys or other secure-store values.

The JSON document is limited to 32 MB, each portable conversation to 16 MB, up to 5,000 conversations and 1,000 projects. Unsupported or invalid content fails before mutation. Existing AIM/ChatGPT/Claude text JSON imports also use the reviewed copy flow and receive new destination IDs.

No original conversation, file, project or credential is moved or deleted by this workflow. This document workflow is the supported selective local-to-account migration path; it does not claim to migrate the full external media graph.

## Qualification performed

On 2026-10-16, a newly created iPhone 17 Pro simulator (iOS 27.0) ran seven `LocalExperienceTests` with zero failures and three targeted UI tests with zero failures. Unit coverage includes persisted local preferences/memory, profile isolation, rejecting Remote commands locally, document/image/prepared-video attachment retention, project-reference remapping, preserving existing destination data, rejecting invalid input, and deferring mocked account writes until an explicit import commit. The UI checks cover local startup without server configuration, reaching the reviewed copy interface, and the optional unconfigured-cloud explanation.

The simulator used local ad hoc signing (`CODE_SIGN_IDENTITY=-`, no development team). An earlier unsigned run correctly could not access secure storage and showed the local-profile-unavailable state. No production fallback or fake authenticated user was added to make the tests pass. Simulator execution does not qualify physical-device Keychain/biometrics, the Files provider interaction end to end, or successful delivery to a real account server. Those remain separate checks.
