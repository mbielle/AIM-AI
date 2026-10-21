---
name: aim-remote-qa
description: Diagnose and qualify AIM Mac-iPhone Remote connection, catalog parity, permissions and recovery using isolated identities and traceable evidence.
---

Read `docs/qa/AUTONOMY_FR.md`, then the relevant control in
`docs/qa/controls.json`. Start at the observed checkpoint and preserve existing
pairs. Use synthetic sessions/files and separate qualification installations.

Trace profile → device/pair → installed app/version → selected execution target →
transport → decrypted snapshot → model route → command ID → effect/result.
A green connection indicator alone proves neither readable history nor execution.
Compare the catalog returned through the actual host/client services, including
provider route, not only model display names.

Use `python3 scripts/qa/run.py --suite smoke --target apps` for the isolated app
pilot, and `--suite remote --target native --probe PATH` for native supporting
checks. Read the report: native-process evidence never qualifies the two apps;
the simulator app pilot never qualifies the physical camera or Internet route.
The qualification provider is deterministic, free and explicitly identified as
such. It replaces the model boundary, never Remote encryption or permissions.

On mismatch, preserve both results and diagnose publication/revision/selection
before changing data. On revoked permission, verify host refusal and no effect;
do not regrant access to make a test pass. On uncertain command outcome, retain
the original ID and check the actual effect before any retry. On reconnect
failure, inspect saved selection and voluntary-disconnect intention before
proposing re-pairing. Device locks and missing runtimes are preparation issues.

Keep invitation/secret files private and out of evidence. Sanitized receipts carry
run/check/command identifiers and facts, not API keys, QR tokens or personal text.
At most three corrective attempts per failure and 45 minutes per session.
Keep physical LAN, real local/API inference and off-LAN/TURN gates separate.
