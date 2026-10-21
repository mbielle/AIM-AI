# Optional legacy project-file processor

This clean replacement implements a bounded subset of the native legacy
`SupabaseCloudContentService.uploadProjectFile` contract. It is not part of the
default function deployment. Current native document attachments and direct
device MCP OAuth do not require this service.

POST JSON uses `{file:base64,fileName,fileType,forceOCR:false}`. The historical
`forceOcr` spelling is also recognized, but neither enables OCR. Maximum decoded
file size is 20 MiB, matching the native uploader; the streamed JSON body is
bounded to 28 MiB before parsing. UTF-8 plain text/code/data up to 120,000
characters returns `{status:"ok",extractedText,usedOcr:false,fileName,originalType}`.
No result is silently truncated.

Images return `needs_ocr/image_requires_ocr`. All PDFs return
`needs_ocr/unsupported_pdf`: no parser is installed, so this service cannot
distinguish scanned PDFs from text PDFs. Forced OCR returns
`needs_ocr/ocr_unavailable`. Office documents return `error/unsupported_office`;
HTML, RTF and other unsupported formats return `error/unsupported_type`.
The native caller preserves these statuses on the project file rather than
claiming extraction succeeded. Advanced PDF/Office extraction is unimplemented.

The handler requires a real Supabase bearer, validates `/auth/v1/user`, and then
calls the public `aim_maintenance_session` RPC wrapping `aim_require_live_session`.
Apply the main server's authentication/session and native-maintenance migrations
first. Missing, revoked or unverifiable sessions fail closed. Configure only
`SUPABASE_URL` (a bare HTTPS origin) and `SUPABASE_ANON_KEY`. No service-role key,
provider key, storage/database content mutation, OCR API, private AIM service or
model request is used. The only outbound requests are those two fixed paths on
the configured Supabase origin, with redirects forbidden and a ten-second timeout.
There is no browser CORS interface; the supported caller is the native client.

The `index.ts` Deno entry and `handler.ts` reuse the main server's bounded-body
helper by relative path. A distributor opting in must stage this directory as
`supabase/functions/file-processor` and preserve the shared helper, changing that
one import to `../_shared/request-body.ts` in its staged bundle. This is a source
staging step, not an instruction to deploy or alter an existing hosted project.
No deployment or live credentials were used during implementation.

Run isolated mocks from this directory with Node 26 or newer:

```sh
node --test handler.test.mjs
```

The isolated run passed 12 tests, with zero failures or exclusions. TypeScript
checking also passed with the following command from `server` (dependencies
installed there); no live function deployment was tested:

```sh
node_modules/.bin/tsc --noEmit --strict --skipLibCheck --target ES2022 \
  --module ESNext --moduleResolution Bundler --allowImportingTsExtensions \
  --lib ESNext,DOM optional/functions/file-processor/handler.ts \
  optional/functions/file-processor/index.ts supabase/tests/deno-runtime.d.ts
```

The legacy `oauth-connector` broker is deliberately not restored. Its old
hardcoded web callbacks reject the native callback; signed readable state lacks
expiry/single-use consumption and embeds a PKCE verifier; provider tokens were
stored in client-readable connector configuration. A future broker needs exact
configured callbacks, expiring single-use server-held state, session revocation
checks, a private credential vault and distributor-owned provider app registration.
Direct device MCP OAuth remains a separate native capability.
