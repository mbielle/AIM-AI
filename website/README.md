# AIM website

Standalone extraction of the existing AIM landing page. The animated hero, mascot, product story, feature panels, illustrative mockups and responsive navigation are retained. Only their reachable source dependencies are included. The previous chat, credits, advertising, administration, account and subscription web app is excluded; there is no user-agent fallback into it.

AIM is presented as free and open source, with user-funded provider API usage and supported local inference on Mac. Remote still needs an account, backend, device pairing and an awake Mac. The official service can apply capacity and cost limits. This site does not promise serverless Remote, unlimited hosted services, or local inference on iPhone.

## Develop and verify

Requires Node.js 22.12+ (or a newer supported Node LTS) and npm. This directory has one npm lockfile and exact direct dependency versions.

```sh
npm ci
npm test
npm run build
npm run dev
```

`npm test` exercises public links, route exclusion, free product copy, dependency boundaries, R2 release allowlists, hashes, content types, HEAD/range responses, feed protection and unsubscribe compatibility using stubbed network calls. It never performs a live unsubscribe. `npm run build` includes strict TypeScript checking.

The public routes are `/`, `/guide`, `/legal`, `/privacy`, `/terms`, `/cookies` and `/unsubscribe`. Unknown browser routes display a missing-page message. `/account` and auth callbacks have no role in this informational website: account sign-in and billing dependencies are absent. App authentication belongs to the apps and configured backend.

## Distribution is disabled by default

No binary, update feed, public iPhone URL or internal TestFlight invitation is copied or enabled. Sample product interfaces are explicitly illustrative. Provisional private media captures were excluded. The following settings must be supplied only after qualification and owner approval:

- `VITE_AIM_PUBLIC_RELEASE_APPROVED=true`
- `VITE_AIM_MAC_DOWNLOAD_PATH=/downloads/<approved filename>.dmg`
- `VITE_AIM_MAC_DOWNLOAD_SHA256=<64 lowercase hex digits>`

These are public build-time values. The button remains unavailable unless all three are valid. A hash in client configuration alone does not establish release qualification or verify a downloaded file.

For Cloudflare Pages, deploy `dist/` together with the adjacent `functions/` directory and configure a dedicated release-only R2 binding named `AIM_RELEASE_BUCKET`. The default example does not provision any resources. Copy `wrangler.example.toml` into your own deployment configuration only after choosing infrastructure.

Server configuration uses the existing safety contract:

| Setting | Meaning |
| --- | --- |
| `AIM_RELEASE_MAC_FILENAME` / `AIM_RELEASE_MAC_SHA256` | Current approved DMG name and digest |
| `AIM_RELEASE_MAC_ARCHIVES` | Optional JSON map of retained approved DMG names to digests |
| `AIM_RELEASE_FEED_SHA256` | Separately reviewed update feed digest |

Objects are stored at `updates/<filename>.dmg` and `updates/appcast.xml`; their `customMetadata.sha256` must match the approved digest, and their content type must match the DMG or XML allowlist. `/downloads/` is an alias for approved DMG keys only. The middleware returns 404 when the binding is missing and never falls back to static files or SPA HTML. HEAD and bounded single byte ranges are supported. Object identity is checked between head and body retrieval. The deployment process must independently hash the bytes and verify signatures/notarization before applying trusted metadata; the request handler trusts the release administrator's hash metadata.

Keep an approved older archive available while a published update feed still references it. Check that the feed contains only qualified downloads before setting its hash. Do not activate client links ahead of the server allowlist.

## Source repository

Set `VITE_AIM_SOURCE_URL` only after choosing and approving the actual public source
repository. There is no default or inferred GitHub destination. The source link
appears in the hero, project menu/footer and setup guide only for an explicit HTTPS
URL without credentials, query strings or fragments. Loopback/private hosts and
example/placeholder destinations are rejected. This validates the URL shape; the
owner must verify that the repository exists, is the intended public source and
contains the build instructions. Unconfigured social accounts have no inactive
placeholder buttons.

The binary download still requires its independent release approval, exact path
and SHA-256. Configuring source does not enable a binary, iPhone invitation or feed.

## Optional support

Set `VITE_AIM_SUPPORT_URL` to an owner-validated external HTTPS support page to show the optional support links. Empty, invalid or non-HTTPS values show no support link. No beneficiary, payment account, product advantage or donor status is invented. Payment handling, if any, belongs to the explicitly chosen external provider.

## Email unsubscribe compatibility

`/unsubscribe?token=…` asks for explicit confirmation before posting to the same-origin `/api/unsubscribe` Pages Function. The page neither validates nor sends the token on load. The isolated proxy preserves the prior monitor endpoint, with recovery-endpoint fallback only on its historical HTTP 400 signal:

1. `aim-monitor-unsubscribe`
2. `handle-email-unsubscribe` for older recovery links

Configure `AIM_EMAIL_SERVICE_URL` to your upstream HTTPS origin and, only if required by your deployed functions, `AIM_EMAIL_PUBLIC_API_KEY` to its public API key. These are runtime configuration, never source constants. No production project URL or key was copied. The proxy is unconfigured and returns 503 by default. Tokenless or malformed requests fail; GET has no mutation. Verify both real token formats on an isolated email test deployment before replacing an existing unsubscribe domain. This repository does not migrate historical email records or promise an undeployed backend has these functions.

Suppress query strings and bodies containing unsubscribe tokens from hosting logs. The unsubscribe page sets no-referrer and noindex headers. Review the upstream function's token verification and service configuration for your deployment.

## Before public publication

The operator identity (AIM.AI SASU, registry/address, publication director and contact) is retained from the existing website, rather than invented. The operator must confirm its continued applicability. The legal pages were rewritten for this free informational site and explicitly identify the deployment facts that require validation: operator, hosting, log retention, email service and app/server data handling. Third-party software licenses and notices are separate and must be reviewed for redistribution.
The [asset review inventory](../docs/ASSET_REVIEW.md) distinguishes documented
licenses from pending author/rights reviews. `../scripts/check-publication.sh` remains the conservative full asset-review checker;
it reports the 45 unchanged documentary states. For the first Mac alpha, the
[owner alpha decision](../docs/qa/DECISION_ALPHA_ET_CHEMIN_PUBLICATION_2026-10-21_FR.md)
defines the separate review/publication path. No pending state is promoted or hidden.

This extraction does not deploy the website, modify DNS, change production accounts, publish any artifacts or send emails. The existing public domain's previously observed maintenance state is not evidence that this local version is live.
