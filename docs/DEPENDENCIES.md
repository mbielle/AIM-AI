# Dependency inventory

## Native direct transport and coordinator — 2026-10-17

`packages/AIMDirectNative/dependencies.lock.json` pins libdatachannel v0.24.6
(`6b1e2e6`) and Mbed TLS 3.6.6 (`0bebf8b8`); Git submodules pin libjuice,
usrsctp, plog and nlohmann/json. `scripts/direct/build-native.py` builds static
Mac arm64/x86_64, iPhone arm64 and simulator arm64/x86_64 slices. Generated
XCFrameworks stay ignored; build them before opening the native projects.
MPL-2.0 and Apache-2.0 obligations/notices are documented in the package README.

`server/direct/package-lock.json` pins ws 8.22.0 (MIT). Node, HAProxy and coturn
deployment images are digest-pinned in Dockerfile/Compose and retain their licenses.
Local testing compiled coturn 4.7.0 from upstream source; the separate coturn 4.18
container deployment still requires Linux validation. No new paid search SDK is
embedded: Exa/Brave adapters use HTTPS with profile-owned credentials. Current
orchestration is Chat only with tool-capable Anthropic/OpenRouter routes;
Agent/Code reject this route explicitly.

Static inventory for the open-source extraction, 2026-10-16. Lockfiles and manifests are the version authority. This inventory does not establish compatibility, vulnerability absence, release qualification, or complete license compliance for a binary assembled later.

## Swift graphs

The iOS Xcode project refers to the local `packages/AIMCore` package. The macOS package uses the same local core. The MLX executable is an optional separate package, not an unconditional dependency of the main application. The manifests declare Swift tools 6.2; app platform declarations are iOS 17 and macOS 14, with the shared core also declaring macOS 13.

The four resolved files contain 53 pin entries, representing 29 distinct identity/version/revision combinations. Some transitive versions differ between graphs; this table preserves those differences. The graph must be re-resolved and tested deliberately when manifests change.

| Package | Resolved version | Used by | License evidence / remaining review | Exact source |
| --- | --- | --- | --- | --- |
| eventsource | 1.5.1 | optional MLX | Exact pin license review pending | [source at pin](https://github.com/mattt/EventSource/tree/86b5096ac59ab46e66bd1f6377c604bc1dab0bc2) |
| fluidaudio | 0.17.5 | macOS | Apache-2.0 | [source at pin](https://github.com/FluidInference/FluidAudio/tree/0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7) |
| grdb.swift | 7.11.1 | macOS | MIT; SQLite notices also apply | [source at pin](https://github.com/groue/GRDB.swift/tree/b83108d10f42680d78f23fe4d4d80fc88dab3212) |
| mlx-swift | 0.32.3 | optional MLX | MIT upstream; exact runtime notices pending | [source at pin](https://github.com/ml-explore/mlx-swift/tree/19601207e9a0de51e03ee6ec0c3c5f3784275075) |
| mlx-swift-lm | 3.32.3 | optional MLX | MIT upstream; exact runtime notices pending | [source at pin](https://github.com/ml-explore/mlx-swift-lm/tree/3b339ad6e3b3f44c8121ecff5131c7fd55e075e6) |
| sparkle | 2.10.0 | macOS | MIT plus bundled BSD/other notices; retain full upstream LICENSE | [source at pin](https://github.com/sparkle-project/Sparkle/tree/eef1a539a373c1f1a320624b1130fc5de7b2e100) |
| supabase-swift | 2.55.2 | AIMCore, iOS, macOS | MIT | [source at pin](https://github.com/supabase/supabase-swift/tree/40344fb3a7007d772218c6ddf6bca9febd8cb226) |
| swift-argument-parser | 1.8.2 | macOS | Apache-2.0 | [source at pin](https://github.com/apple/swift-argument-parser/tree/6a52f3251125d74daf04fcbd5e6f08a75d074382) |
| swift-asn1 | 1.7.3 | AIMCore, iOS, macOS, optional MLX | Apache-2.0 | [source at pin](https://github.com/apple/swift-asn1/tree/3b6410f7dee09eb33cdd26260c5fd47fda19b0e2) |
| swift-clocks | 1.1.1 | AIMCore, iOS, macOS | MIT | [source at pin](https://github.com/pointfreeco/swift-clocks/tree/82440fa0a8b1c381a6d1e8e0fc7bbba53ec63204) |
| swift-cmark | 0.8.0 | AIMCore, iOS | MIT plus bundled notices | [source at pin](https://github.com/swiftlang/swift-cmark/tree/924936d0427cb25a61169739a7660230bffa6ea6) |
| swift-cmark | 0.9.0 | macOS | MIT plus bundled notices | [source at pin](https://github.com/swiftlang/swift-cmark/tree/08ddb528923cc1a6527e02b7a1aee9e516ca749a) |
| swift-collections | 1.7.1 | optional MLX | Exact pin license/exception review pending | [source at pin](https://github.com/apple/swift-collections/tree/98ef3c98609a1e31b7e157b5b619579001a789d6) |
| swift-concurrency-extras | 1.4.1 | AIMCore, iOS, macOS | MIT | [source at pin](https://github.com/pointfreeco/swift-concurrency-extras/tree/5fa253428866f2360c3754e88537f700ed2656b5) |
| swift-crypto | 4.5.2 | AIMCore, iOS, macOS, optional MLX | Apache-2.0 plus bundled cryptography notices | [source at pin](https://github.com/apple/swift-crypto/tree/da9d28d69ebe3894b18376c8f2395c2f37b8448f) |
| swift-http-types | 1.8.0 | AIMCore, iOS, macOS | Apache-2.0 | [source at pin](https://github.com/apple/swift-http-types/tree/bff4b6903cdc99dda49649dd52f46c11cfd3ed50) |
| swift-huggingface | 0.12.0 | optional MLX | Exact pin license review pending | [source at pin](https://github.com/huggingface/swift-huggingface/tree/0ece9a1ef443309d26a69af9897ee8ad82f43a9a) |
| swift-issue-reporting | 2.1.0 | AIMCore, iOS | MIT | [source at pin](https://github.com/pointfreeco/swift-issue-reporting/tree/71c7c9a761d1ca6ed4ccb6ced040fe1c1a39e8e7) |
| swift-issue-reporting | 2.1.1 | macOS | MIT | [source at pin](https://github.com/pointfreeco/swift-issue-reporting/tree/75b000cea2ca6d7527a57e1b9cc0bdf21a9abe9f) |
| swift-jinja | 2.5.1 | optional MLX | Apache-2.0 upstream; exact runtime notices pending | [source at pin](https://github.com/huggingface/swift-jinja/tree/4588064a20f3fc093c95f2f7d3359999bf30cae5) |
| swift-markdown | 0.8.0 | AIMCore, iOS, macOS | Apache-2.0 | [source at pin](https://github.com/swiftlang/swift-markdown/tree/3c6f9523da3a1ec2fd829673e472d95b8097a3b8) |
| swift-numerics | 1.1.1 | optional MLX | Exact pin license/exception review pending | [source at pin](https://github.com/apple/swift-numerics/tree/0c0290ff6b24942dadb83a929ffaaa1481df04a2) |
| swift-syntax | 603.0.2 | optional MLX | Exact pin license/exception review pending | [source at pin](https://github.com/swiftlang/swift-syntax/tree/79e4b74a295b6eb74a8b585e3a39d29e70c1dbd1) |
| swift-transformers | 1.3.4 | optional MLX | Apache-2.0 upstream; exact runtime notices pending | [source at pin](https://github.com/huggingface/swift-transformers/tree/c21fdcde390313a6d98d8e33a346f2c3486c3ab0) |
| swiftmath | 1.7.3 | AIMCore, iOS, macOS | MIT; inspect bundled math-font notices | [source at pin](https://github.com/mgriebling/SwiftMath/tree/fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7) |
| whisperkit | 1.1.0 | macOS | MIT plus Apache-2.0 derived code in NOTICES | [source at pin](https://github.com/argmaxinc/WhisperKit/tree/1e2a163736dfa5a198e637ae44c114e1c6d5cc2d) |
| xctest-dynamic-overlay | 1.13.1 | AIMCore, iOS, macOS | MIT | [source at pin](https://github.com/pointfreeco/xctest-dynamic-overlay/tree/d9308ad679143c26a30dec52daefe82f54af2b82) |
| yyjson | 0.12.0 | optional MLX | MIT upstream; exact runtime notices pending | [source at pin](https://github.com/ibireme/yyjson/tree/8b4a38dc994a110abaec8a400615567bd996105f) |
| zipfoundation | 0.9.20 | AIMCore, iOS, macOS | MIT | [source at pin](https://github.com/weichsel/ZIPFoundation/tree/22787ffb59de99e5dc1fbfe80b19c97a904ad48d) |

The main/core license descriptions were checked against existing local upstream checkout license texts at their recorded revisions where available. The MLX license families were checked against primary upstream files; entries marked pending have not received an exact-version, embedded-code and full-notice review. Apache projects may include additional notices and exceptions; preserve their actual files rather than replacing them with this table.

## Website JavaScript

`website/package.json` has 8 browser dependencies and 9 build/typecheck dependencies. One npm lockfile is used. The public app has no Supabase client, account router, billing SDK, analytics SDK or advertising SDK.

| Package | Exact direct version | Role | Declared license |
| --- | --- | --- | --- |
| `@radix-ui/react-accordion` | 1.2.1 | browser | MIT |
| `class-variance-authority` | 0.7.1 | browser | Apache-2.0 |
| `clsx` | 2.1.1 | browser | MIT |
| `lucide-react` | 0.462.0 | browser | ISC |
| `motion` | 12.42.2 | browser | MIT |
| `react` | 18.3.1 | browser | MIT |
| `react-dom` | 18.3.1 | browser | MIT |
| `tailwind-merge` | 2.5.4 | browser | MIT |
| `@tailwindcss/postcss` | 4.3.3 | build/typecheck | MIT |
| `@types/node` | 22.20.5 | build/typecheck | MIT |
| `@types/react` | 18.3.12 | build/typecheck | MIT |
| `@types/react-dom` | 18.3.1 | build/typecheck | MIT |
| `@vitejs/plugin-react-swc` | 4.3.3 | build/typecheck | MIT |
| `postcss` | 8.5.30 | build/typecheck | MIT |
| `tailwindcss` | 4.3.3 | build/typecheck | MIT |
| `typescript` | 5.6.3 | build/typecheck | Apache-2.0 |
| `vite` | 8.3.4 | build/typecheck | MIT |

The lock contains 131 package-location records across platforms and optional native tool bindings; this is not an installed-runtime package count. Declared license metadata counts: 0BSD: 1; Apache-2.0: 6; Apache-2.0 AND MIT: 11; BSD-3-Clause: 1; ISC: 2; MIT: 84; MPL-2.0: 24; Missing lock metadata: 2. The two absent lock fields were resolved from installed package metadata: class-variance-authority is Apache-2.0 and lucide-react is ISC. MPL-2.0 entries are build-tool/native-platform components; AIM's own MIT license does not relicense them. A distributor that bundles build tools or native dependencies must retain the applicable licenses and satisfy their terms.

Clean installation, the 16 website contract tests and strict TypeScript/production build were exercised during extraction. The registry audit reported zero findings for that tested website dependency snapshot after updating the inherited build tools; rerun it for a release. This statement does not cover the unrelated native/adapter graphs.

## Server tests and runtime

`server/package.json` pins `@electric-sql/pglite` 0.5.10 (Apache-2.0) for local database tests and TypeScript 5.6.3 (Apache-2.0) for static checks. Its lock contains two dependency records. The currently retained Edge Function source uses platform APIs and local imports rather than a bundled third-party JavaScript SDK. Supabase, PostgreSQL, Deno/Edge Runtime and optional Cloudflare hosting are deployment dependencies with their own distributions and service terms; they are not made MIT by the application license. The one-time source formatting used Prettier 3.6.2 as a development tool, without adding or bundling it as a runtime dependency.

## Optional supplied runtimes

| Component | Source/configuration in this tree | Version/provenance | Distribution state |
| --- | --- | --- | --- |
| Playwright MCP | `apps/macos/Vendor/PlaywrightMCP/package.json`, `pnpm-lock.yaml` | @playwright/mcp 0.0.82; playwright/playwright-core 1.64.0-alpha-1789764292000 | Manifest/lock only; no node_modules/browser/runtime copied |
| CUA Driver | `apps/macos/scripts/build-app.sh`, `AIM_CUA_DRIVER_PATH` | 0.28.2 candidate digest checked by packager | Optional external binary input; supplied license required |
| llama.cpp | `AIM_LLAMA_CPP_DIR` | Builder-supplied release, no universal version pin in this source | Optional external binary input; supplied LICENSE required |
| MLX engine | `apps/macos/Vendor/AIMMLXEngine` | Pins listed above | First-party wrapper source retained; runtime and complete upstream license bundle must be supplied separately |
| Node.js | `AIM_NODE_RUNTIME` | Builder-supplied self-contained official runtime | Optional external runtime; Node and bundled-library notices required when distributed |
| Hermes | `UpstreamAgentCatalog.swift` and adapter scripts | 0.21.5, upstream archive tag v2026.9.24 | Adapter/source metadata only; review installed upstream package and Python dependency licenses |
| OpenClaw | `UpstreamAgentCatalog.swift`, adapter scripts and saved npm lock | 2026.9.8 | Adapter/source metadata only; no upstream node_modules copied |

Playwright's browser engines have their own extensive notices, separate from the Apache-2.0 Playwright code. A bundle containing Node, browser engines, CUA, llama.cpp, MLX or external agents needs its own exact artifact inventory. It is not enough to copy the top-level license of a launcher.

The OpenClaw lock has 560 package-location records. Its metadata spans (MIT AND Zlib), (MIT OR GPL-3.0-or-later), 0BSD, Apache-2.0, Artistic-2.0, BSD-2-Clause, BSD-3-Clause, BlueOak-1.0.0, CC-BY-3.0, CC0-1.0, ISC, MIT, MIT AND MPL-2.0, MIT OR Apache, MPL-2.0, Missing lock metadata, Unlicense. This includes MPL, CC-BY, Artistic and dual-license choices; it is not an all-MIT dependency tree. One nested `qrcode-terminal` record has no license field. A lockfile is provenance metadata, not an adjudication of those license choices or an approval to redistribute a runtime. Collect the exact installed package notices when qualifying that optional distribution.

## Models, fonts and other data

No GGUF, safetensors, ONNX, compiled Core ML model or model package was present in the scanned public candidate. Model/tokenizer downloads and transcription models remain separate data artifacts. Check each model repository's license, acceptable-use terms, attribution, gating, and redistribution rights before bundling or mirroring it. A runtime's MIT/Apache license does not grant model-weight rights.

Lora fonts retain SIL OFL 1.1 notices and the reserved font-name provisions. Lucide artwork retains ISC attribution (including the upstream Feather portions). Lobe logo files retain their provided MIT notice; trademark rights and the provenance of other organization avatars/logos remain separate. See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Remaining release work

- Assemble an exact binary SBOM/notice bundle for every enabled optional runtime and its native/embedded dependencies.
- Satisfy the fail-closed [MLX license inventory gate](../apps/macos/docs/OPTIONAL_MLX_LICENSES.md) before supplying an MLX runtime.
- Resolve the 60 remaining per-asset reviews and run the [staged publication gate](ASSET_REVIEW.md); public downloadability alone is insufficient.
- Recheck resolver consistency, security advisories and model/data terms for the versions actually shipped.
- Preserve upstream LICENSE/NOTICE/font texts in source and in the resulting app/site distribution where their terms require them.
