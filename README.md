# AIM

Native AI workspace for macOS and iPhone, created by Mathieu Bielle.

AIM's features are free. Bring your own provider credentials or use a compatible
local model on your Mac. Providers may charge for inference. No AIM subscription,
trial, purchase or restore step is needed.

**Mac Apple Silicon alpha:** [download the first preview](https://github.com/mbielle/AIM-AI/releases/tag/v0.1.0-alpha.1).
See [alpha status and known limits](docs/IMPLEMENTATION_STATUS.md). The historical
71-control full-qualification campaign is distinct from this alpha decision.

On Mac, eligible users may connect through the official open-source Sign in with
ChatGPT flow, with their consent, granted permissions and plan limits. Existing
credentials without validated identity metadata require an explicit new registration and are
preserved until the user chooses what to do. This does not enable local ChatGPT
sign-in on iPhone.
Pour reprendre le chantier en français, lire [le point de reprise](docs/REPRISE-FR.md).

## Repository

- `apps/macos`: native workspace, tools, durable agent runtime and Mac Remote host.
- `apps/ios`: native Chat/Projects, local profile and optional Remote client.
- `packages/AIMCore`: one shared package for domain types, protocols and adapters.
- `packages/AIMDirectNative`: pinned libdatachannel build and native WebRTC/LAN transport.
- `server`: clean Supabase bootstrap, isolated database tests and existing-installation transition.
- `website`: standalone landing, legal drafts, optional support link and download routes.

Local Chat/Code/Agent on Mac and native Chat/Projects on iPhone do not require an
AIM account. Sign in voluntarily for cloud synchronization and Remote. A local
profile is not an authenticated cloud account. Profiles stay separate; importing
content requires an explicit reviewed copy. This does not port Mac execution to iOS.
Remote needs an awake/reachable Mac. Direct pairing is implemented for local profiles,
with LAN signalling and optional self-hosted Internet coordination/TURN; Supabase
Remote remains separate. Native-app and real-network qualification are still open.
See [Direct setup](docs/DIRECT_REMOTE_FR.md) and [coordinator deployment](server/direct/README.md).

## Develop

Requirements: Apple Silicon Mac, macOS 14+, Xcode with Swift 6.2 or newer; Node 22.12+
(or Node 26 to run TypeScript server tests directly). The iOS deployment target is
17+. Simulator builds need no private Apple certificate or AIM backend credentials.
Dependency downloads require network access on the first build. Mac/iOS also need
CMake 3.31+ and the native XCFramework built from pinned sources (no private binary).

```sh
./scripts/check.sh core
python3 scripts/direct/build-native.py --cache /tmp/aim-direct-build --fetch --assemble
./scripts/check.sh macos
./scripts/check.sh ios-build
npm ci --prefix server
npm --prefix server test
npm --prefix server run test:database
npm ci --prefix website
npm --prefix website test
npm --prefix website run build
```

A local Mac app bundle can be built with `apps/macos/scripts/build-app.sh debug`.
This builds but does not install or launch. Optional browser/local-model engines
have separate dependency and license requirements. Official signed releases use
the private maintainer configuration, not credentials from this repository.

For iOS, open `apps/ios/AIM.xcodeproj`. Simulator Keychain tests require local
ad-hoc signing (`Sign to Run Locally`); no Apple account or distribution certificate.
For a cloud build copy `Config/Secrets.xcconfig.example` to `Secrets.xcconfig` inside
that app and use only your own project's public URL/key. Never add a service-role
key, provider key or Apple private key to a client bundle.

See [architecture](docs/ARCHITECTURE.md), [self-hosting](server/README.md),
[disposable server qualification](server/LOCAL_STACK_QUALIFICATION.md),
[contributing](CONTRIBUTING.md), [security](SECURITY.md) and
[third-party notices](THIRD_PARTY_NOTICES.md).

MIT covers AIM's original source. Third-party code, fonts, model weights and brand
assets retain their own terms. No optional external agent runtime is relicensed by
this repository. Support is voluntary and confers no additional product access;
the website hides its support link until the recipient and URL are configured.
