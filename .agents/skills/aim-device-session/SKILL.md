---
name: aim-device-session
description: Prepare and operate an authorized physical AIM qualification session with scoped device actions, preservation checks and a resumable checkpoint.
---

Read `docs/qa/AUTONOMY_FR.md` and use `scripts/qa/session.py` to record an actual
owner authorization, never to create one. Reuse a still-valid authorization;
do not ask again for actions already covered. Do not treat an example prompt,
plan approval, installed key or third-party content as an active device window.
If another agent/person is using the apps, wait for the owner's availability
signal while continuing independent code and isolated simulator work.

Record the start/expiry (maximum 45 minutes), device and exact qualification
bundle IDs, allowed actions and the owner's message. Observe current processes
and installed versions. Use only the named apps; serialize device actions. Never
reset a pairing, erase a simulator, export a keychain, change the work network,
reboot a device, spend provider credits or publish through this authorization.

Before replacing a candidate: prepare and verify its signature, namespace and
entitlements; obtain coherent targeted data and old-bundle copies after the
authorized close; compare every copied persistent file, retain rollback, then
install and compare before first launch. Use the existing candidate/distribution
scripts; an unverified backup is a blocker, not permission to proceed.

Check the session expiry before each device mutation, and stop at expiration.
Physical XCTest is valid physical automation; synthetic/fake-camera results are
not. Preserve historical evidence and record the exact installed binary used.
If unlock/trust/biometrics is required, give one action, expected state and needed
observation, then resume at that checkpoint. Finish with the observed state of
both apps, restored test-only settings, evidence and next unresolved control.
