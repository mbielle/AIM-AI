# AIM contributor instructions

Preserve local changes, existing app installations, conversations, provider keys and
pairings. Never replace/close an app in use without permission. Use isolated synthetic
data and separate qualification identities. No paid provider request without explicit
provider and budget authorization. Original-source cleanup is not authority to mutate
production services or publish artifacts. Read applicable app-specific AGENTS.md.

Use one packages/AIMCore; do not fork copies per platform. Keep cloud authentication,
local identity, device authorization, approvals and financial provider metering distinct.
After changes update docs/IMPLEMENTATION_STATUS.md with actual checks and limitations.
A build or mock does not prove a physical device, migration or public deployment.

For the first Mac alpha only, follow docs/qa/DECISION_ALPHA_ET_CHEMIN_PUBLICATION_2026-10-21_FR.md: the deferred exhaustive campaign and QA account are abandoned for this alpha. Preserve the historical 71-control statuses without promoting unexecuted checks. Complete local preparation, owner review and a distinct final publication approval. The full-qualification register remains docs/VALIDATION_AVANT_PUBLICATION_FR.md for its separate scope; software evidence does not establish physical-device or real-provider acceptance.

For regression work use scripts/qa/run.py and docs/qa/AUTONOMY_FR.md. Local tests
use disposable data: run, diagnose, correct and rerun affected checks without
asking at each step. An active owner-authorized device window covers only its
named actions/apps and expires after at most 45 minutes. Other device work waits
without blocking independent code or simulator work. Never convert a missing
prerequisite, empty test selection, dry-run or old-build result into success.

Project skills live in .agents/skills; start Codex in this repository (not the
legacy parent checkout) to discover them. MobileBuildMCP is optional, pinned in
tools/apple-qa: use its local binary with MOBILEBUILDMCP_SENTRY_DISABLED=true;
do not follow the vendor skill's global/latest installation examples. Raw Apple
tools remain the supported fallback. Keep current deployment targets and toolchain
constraints when applying third-party Swift skills; do not migrate them implicitly.
