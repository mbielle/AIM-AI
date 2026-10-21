---
name: aim-verify
description: Run and interpret AIM regression checks after a code change, preserving the distinction between software, simulator, app and physical-device evidence.
---

Use the transition repository containing `scripts/qa/run.py`. Read
`docs/qa/AUTONOMY_FR.md` for commands and report semantics. For an owner gate,
look up its ID in `docs/qa/controls.json`; the owner register remains authoritative.

Choose the smallest relevant check. `quick --target software` runs Core Remote
regressions; `--component macos` selects Mac checks. `--controls L03,L04` selects
supporting suites for those gates. Use `--target simulator` for real XCTest UI
execution on a separate simulator; a build is not test execution. No physical
device/app is implied by the simulator or the native probe.

Use `--dry-run` to preview commands. Exit 2 means prerequisites or unexecuted
checks remain, never success. Inspect `report.json`, the sanitized log and any
xcresult before making claims. An empty test selection, source drift, missing
receipt or timeout cannot be reported as passed. A release run cannot grant
publication approval or modify the owner register.

For a defect: reproduce, diagnose the failing boundary, correct the cause, then
rerun the failed check and affected regressions. Continue authorized reversible
work without asking at each step. At most three correction attempts for the same
failure and 45 minutes per session; stop earlier at an actual authorization or
environment boundary. A retry without a corrective hypothesis is not progress.
Do not weaken assertions, delete failures, relabel fixtures as live inference or
repeat tests until a lucky pass. Keep independent checks moving when possible.

Report changed behavior, actual checks/evidence level, remaining gate and precise
next action. Update `docs/IMPLEMENTATION_STATUS.md`; Mac continuity work also uses
the applicable app instructions. Do not invent human-time or interruption metrics.
