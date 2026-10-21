# AIM server

The clients' local mode needs no server. For accounts, synchronization and Remote,
this version implements Supabase Auth, PostgreSQL/RLS, Storage, Realtime and Edge
Functions. Use a managed project or self-host that stack on infrastructure of your
choice. Other server software is not yet implemented.

## New installation

1. Install the Supabase CLI and a compatible local container runtime, or use the
   isolated experimental native recipe in [LOCAL_STACK_QUALIFICATION.md](LOCAL_STACK_QUALIFICATION.md). Node 26 is
   used for the offline TypeScript tests; `npm ci --prefix server` installs the pinned offline test dependencies.
2. From repository root run `supabase start --workdir server`, then
   `supabase db reset --workdir server`. Use this reset ONLY on an empty/disposable
   local instance. It erases that local database. Never use reset against production.
3. The `supabase/migrations` directory is a complete clean-bootstrap chain. It
   contains no AIM billing schema. It requires current Storage operation helpers
   (`storage.allow_any_operation`) and pgcrypto. Older Storage versions fail closed.
4. For a managed new project, review the generated migration plan and apply this
   clean chain only to that empty project. For a self-hosted stack, use the official
   Supabase self-host installation, apply the same chain once and configure its
   API gateway/Edge environment. Expose a valid HTTPS endpoint to the clients.
5. Configure Auth site URL and native redirect allowlist: `aim://auth-callback` and
   `aimmac://auth-callback`. Forks changing schemes must update both client metadata
   and server allowlist. Email/Google/Apple authentication need the operator's own
   SMTP/OAuth configuration. Do not reuse the official app's private identities.
6. Set the project URL and a **publishable/anon** key in each app's private config.
   Mac build scripts accept `AIM_SUPABASE_URL`/`AIM_SUPABASE_PUBLIC_KEY`; iOS uses
   `apps/ios/Config/Secrets.xcconfig` copied from its example. HTTPS is required;
   a LAN address alone does not satisfy the native configuration contract.
7. Configure the server-only values from `.env.example`, then deploy `aim-push`,
   `aim-push-worker`, `aim-release-monitor`, `export-user-data`, `delete-account`
   and `remote-unlock`
   with the supplied gateway verification settings. Never disable user JWT checks
   globally. Worker endpoints require distinct random 256-bit bearer secrets.
8. Test two synthetic accounts/devices: pairing, authorization, encrypted command,
   response, session/device revocation and account separation before public access.

The checked-in bootstrap has been executed in isolated PostgreSQL/PGlite with real
pgcrypto. Supabase platform schemas/functions are minimal fixtures in those tests;
this is **not** a full container-stack, two-device, OAuth or APNs qualification.
A separate disposable native Supabase stack was also started with CLI 2.121.0;
see its exact evidence and limitations in LOCAL_STACK_QUALIFICATION.md. Neither
that synthetic HTTP run nor the SQL fixtures qualify two native devices, external
OAuth, APNs or an official-service upgrade. Complete step 8 with the native apps
before claiming a supported hosted installation. The optional peer-relay migration is
outside the default chain pending its separate two-Mac qualification.

## Optional push and operations

Without Apple configuration, durable events can queue but push delivery remains
disabled. Supply your own Apple push key, team and allowed bundle topic, then
explicitly enable delivery. Client topic syntax is validated; the worker additionally
requires the operator's topic/environment allowlist before claiming work. A fork
cannot use the official app's APNs identity.

Schedule the worker over HTTPS from your scheduler, using its own bearer secret.
Do not put service-role credentials in cron command text. The retained SQL Vault/
pg_net dispatch helpers are optional platform-specific recipes; their old hosted
URL checks do not configure a custom-domain deployment automatically. For custom
hosting use an external scheduler against the configured HTTPS function endpoint.
No cron is installed by bootstrap.

Operations monitoring sends only fixed component/status codes to a configured
HTTPS webhook, with an optional bearer secret. It is disabled without a URL and
contains no fixed email recipient. Monitor service load/egress/queue age externally
and set provider spend alerts. The in-database monitor cannot prove total database
availability; use an independent watchdog. Queue processing is bounded and leased.
Plan retention/cleanup for queue and error tables based on actual usage.

The new website has no AIM billing account page. Historical email unsubscribe links
can keep using the website's explicit compatibility proxy to the existing endpoint.
Do not remove that deployed endpoint while such messages remain in circulation.

## Existing official installation

**Do not replay clean-bootstrap migrations.** Restore a backup to a separate staging
instance first. Review `existing/20261016000100_free_access.sql` against its exact
function definitions. It removes financial admission by delegating to the preserved
security functions and keeps account-bound legacy availability responses temporarily.
It backs up replaced definitions. `existing/rollback-free-access.sql` restores those
functions without deleting user or financial history.

Then review `existing/20261016000200_remote_capacity.sql` for resource admission and
`existing/20261016000300_maintenance_policy_hardening.sql` for the maintenance API,
media policies, explicit native table privileges, parent ownership checks, safe
pairing and native PIN compatibility. The capacity migration is optional; maintenance
hardening requires the reviewed account-session, media and Remote baseline and fails
if required objects are absent. It changes future writes and does not rewrite or
purge financial, account or pairing records. The free-access rollback restores only
financial admission functions; it does not undo the subsequent policy hardening.
Capacity wrappers/tables can remain installed but unused after that rollback. Keep
the pairing fix in place; do not restore the historical cross-account pairing bug.
Review the complete rollback plan on the restored copy before applying anything.
These are ordered, one-time migrations, not rerunnable configuration scripts.

Before applying, confirm that no old offers can be purchased, retain financial
archives, and disable/retire obsolete checkout/portal routes deliberately using the
410 compatibility response. Disable provider event destinations before retiring
webhooks, to avoid repeated delivery failures. Audit secret consumers across other
services (including ads/referral) before removing a secret; they are not automatically
part of this repository. No deployed settings or secrets were changed here.

## Checks

```sh
npm ci --prefix server
npm --prefix server test
npm --prefix server run test:database
npm --prefix server run test:types
```

The database test proves free admission plus wrong secret/token, revoked device and
session, cross-account RLS, operations privileges, and existing-installation transition/
rollback. It makes no network requests. Export/delete handlers check current Auth
user and session liveness before reading service credentials; account deletion also
requires matching email plus `SUPPRIMER`. Exports are bounded, exclude Keychain and
binary attachments, and fail explicitly instead of silently truncating large data.
The 25 MiB export budget is enforced while streaming each page. Auth responses are
limited to 64 KiB and deletion Storage-path lists to 10 MiB before privileged access;
oversized accounts need operator-assisted export/deletion rather than partial success.
Fresh installs default to 120 new ordinary commands per minute and 500 pending/ack
commands per account. Authenticated retries of the same command do not count twice;
only explicit stop/cancel and permission/question replies bypass resource bounds,
while still passing the underlying authorization policy. Reads such as settings,
folder listings and detail requests share these bounds.
Operators can adjust the private settings table after measuring load.
`aim_service_capacity()` exposes aggregate queue statistics to service-role only.
For existing installations the separate capacity migration is optional and reviewed
after free_access; neither migration has been applied to the official service.

The native table grants are explicit: users may read their machines, devices,
commands and key envelopes; device updates allow only revocation. Commands, machine
registration and device pairing remain RPC-only. Session/message/transfer writes
also require parents from the same account and matching machines. No client role
receives `TRUNCATE`, machine-secret writes or direct command insertion.

`remote-unlock` is a native legacy compatibility endpoint for `pin-set`, `pin-verify`
and `lock`. It uses the caller's Auth JWT and the database's live-session/device
checks; it never reads a service-role key. PIN hashing and five-attempt/15-minute
lockout reuse the existing bcrypt SQL helpers, and only token hashes are stored.
PIN changes need an existing same-device token. Current native clients migrate to
session-bound device-v2 authorization: PIN operations then return
`legacy_security_retired`; `lock` remains available for grant cleanup. Browser
WebAuthn/passkey operations are not restored or advertised here.

The optional `optional/functions/file-processor` provides bounded plain-text,
Markdown, CSV and JSON extraction with Auth/session checks. It is outside the default
deployment and does not implement PDF, Office, OCR or provider processing. Its README
explains how to stage it deliberately. Native iOS supported imports now extract locally, show the extracted text for review,
and upload that reviewed snapshot through a separate API. They do not need this
optional handler. No server-based advanced document processing is provided.
The former `oauth-connector` broker is not restored: Notion/Slack/GitHub/Canva linking
needs a separately reviewed OAuth implementation and operator configuration. Legacy
`generated-images`/`generated-videos` Storage buckets are not created by the default
chain; the native `account-media` bucket is present. This repository does not host
paid model inference.

The offline handler tests include the optional text processor. Database checks use
actual authenticated SQL roles on both a fresh chain and an independent pre-free
baseline plus existing-installation migrations. They cover explicit privileges,
cross-account pairing and parent writes, Storage policy evaluation, read-command
limits, bcrypt/token/lockout behavior, revoked sessions and retained financial
fixture history. The platform schemas in those databases are minimal test fixtures;
these checks do not qualify the live Supabase services or native devices.

## Private Edge-to-gateway transport

Public/native configuration still requires a bare HTTPS origin. If a self-hosted
Edge runtime receives an internal HTTP gateway address, explicitly set both
`AIM_INTERNAL_SUPABASE_ORIGIN` and `AIM_INTERNAL_SUPABASE_ALLOW_HTTP=true` in the
**server** environment. Only loopback/private IPv4, loopback IPv6 and operator
controlled internal hostnames are accepted for HTTP. Hostname validation does not
resolve or certify DNS: the operator must keep that network and DNS private.
Never place these settings in a native client or use public HTTP as a workaround.
Unset them for the normal HTTPS configuration. Auth, session liveness, grants and
JWT verification are preserved on both transports. Redirects are refused.

RPC responses are limited to 2 MiB, PIN responses/Auth to 64 KiB and session
confirmation to 64 bytes before parsing. An HTTP 200 session response must contain
JSON `true`; malformed/false values do not admit account maintenance.
