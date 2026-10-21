# Disposable Supabase qualification

This is a development check, not a deployment command. Node 26 and network access
for the pinned Supabase CLI/runtime downloads are required. The experimental native
runtime was exercised on Apple Silicon macOS. Docker remains a separate supported
Supabase development option; the native command/flags may change in future releases.
See the official [runtime guide](https://supabase.com/docs/guides/local-development/docker-and-native-runtimes)
and [CLI release](https://github.com/supabase/cli/releases/tag/v2.121.0).

## Reproduce without an owner account

Run from the repository root in one Terminal. Never substitute a linked project,
existing database or official-service credentials. The preparation script copies
only public functions/migrations/config into a newly created private temporary tree.
It does not copy `.env`, project links or owner credentials, reset another database,
install a global CLI or change the source configuration.

1. Prepare a fresh directory and an isolated CLI invocation:

```sh
umask 077
AIM_LOCAL_STACK="$(node server/scripts/prepare-local-stack.mjs)"
aim_local_cli() {
  env DO_NOT_TRACK=1 SUPABASE_HOME="$AIM_LOCAL_STACK/runtime-home" \
    XDG_CONFIG_HOME="$AIM_LOCAL_STACK/config-home" \
    npm exec --cache "$AIM_LOCAL_STACK/npm-cache" --yes --package=supabase@2.121.0 -- \
    supabase "$@"
}
```

2. Start the disposable stack. The fresh project's migration chain is applied on
   first start. Keep generated local credentials in the redirected private log.
   `--eager` avoids the native runtime's idle shutdown during qualification.

```sh
aim_local_cli start --workdir "$AIM_LOCAL_STACK/project" \
  --runtime native --preparation on-demand --eager \
  --exclude studio,mail,analytics,pooler --output-format json \
  > "$AIM_LOCAL_STACK/start.private.log" 2>&1
```

3. Save its private status, then set only its internal loopback Edge transport.
   Do not paste the status, keys or tokens into issues or chat.

```sh
aim_local_cli status --workdir "$AIM_LOCAL_STACK/project" --output-format json \
  > "$AIM_LOCAL_STACK/status.private.json"
node --input-type=module - "$AIM_LOCAL_STACK" <<'JS'
import { readFile, writeFile } from 'node:fs/promises';
const root = process.argv[2];
const { env } = JSON.parse(await readFile(`${root}/status.private.json`, 'utf8'));
const url = new URL(env.API_URL);
if (!['127.0.0.1', '[::1]'].includes(url.hostname) || url.pathname !== '/' ||
    url.username || url.password || url.search || url.hash) throw Error('Not local');
await writeFile(`${root}/functions.env`,
  `AIM_INTERNAL_SUPABASE_ORIGIN=${url.origin}\n` +
  'AIM_INTERNAL_SUPABASE_ALLOW_HTTP=true\nAIM_PUSH_ENABLED=false\n', { mode: 0o600 });
JS
```

4. Serve the copied functions with the local-only environment. No Apple/provider
   configuration is needed. Gateway JWT checks stay enabled for user endpoints.

```sh
aim_local_cli functions serve --workdir "$AIM_LOCAL_STACK/project" \
  --env-file "$AIM_LOCAL_STACK/functions.env" --output-format stream-json \
  > "$AIM_LOCAL_STACK/functions.private.log" 2>&1 &
```

5. After the function runtime starts, run the qualifier:

```sh
node server/scripts/qualify-local-stack.mjs \
  --status-file "$AIM_LOCAL_STACK/status.private.json" --confirm-disposable \
  > "$AIM_LOCAL_STACK/receipt.json"
cat "$AIM_LOCAL_STACK/receipt.json"
```

The qualifier itself refuses non-numeric-loopback origins before any request.
It generates two synthetic accounts and three sessions without email delivery,
uses no model/APNs request, and removes only marked accounts/objects it created.
Only fixed step codes and the redacted receipt are printed. An uncertain admin
create or failed cleanup returns failure and asks you to keep the disposable
instance for inspection; it never claims that an unknown account was removed.

`ok: true`, no failures and `synthetic_accounts_and_objects_removed` are required.
A failed Realtime phase remains a failure even when independent checks can continue.
The tool closes REST connections to avoid pooled HTTP/WebSocket upgrade interference
observed with this experimental gateway/Node combination. It still requires an
actual authenticated subscription and matching database-change notification.

6. Stop only this temporary instance, whether the checks pass or fail:

```sh
aim_local_cli stop --workdir "$AIM_LOCAL_STACK/project" --output-format json \
  > "$AIM_LOCAL_STACK/stop.private.log" 2>&1
```

Keep a failed instance's directory for diagnosis. Treat its runtime/status/logs as
private even though all credentials and records are synthetic. None belongs in Git.
No public service or native installed application has been modified by these steps.

## Recorded evidence and limits

The integrated candidate passed twice with CLI 2.121.0 native runtime and a fresh
40-migration database: real Auth, owner RLS and foreign-parent denial, scoped account
documents/export, pairing and command authorization, AES-GCM opaque result transport,
authenticated Realtime change, Storage byte round-trip/cross-account denial, Edge
export/deletion confirmation/account isolation, PIN retirement and device/session
revocation. Synthetic data cleanup succeeded. The first attempts failed at the
WebSocket connection and were not counted as successes.

These are synthetic HTTP clients. They do **not** prove native Mac/iPhone execution,
external OAuth/email, APNs, public HTTPS, helper/TCC, installed-data preservation,
existing official database migration or operational scale. Those remain separate
release gates in [the owner checklist](../docs/OWNER_RELEASE_STEPS.md). Client builds continue to require
HTTPS; this loopback-only server check does not weaken their configuration policy.
