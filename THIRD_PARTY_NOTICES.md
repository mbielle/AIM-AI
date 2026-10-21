# Third-party notices

## Direct transport additions

Apple clients link libdatachannel v0.24.6 (MPL-2.0), Mbed TLS 3.6.6 under Apache-2.0,
libjuice, usrsctp, plog and nlohmann/json. Exact source pins, licenses and build
requirements are in [AIMDirectNative](packages/AIMDirectNative/README.md) and its
`THIRD_PARTY_NOTICES` directory. Preserve MPL-covered sources/notices when
redistributing the native binary; AIM's MIT license does not replace these licenses.
The coordinator uses ws 8.22.0 (MIT), with its original attribution preserved in
[WS-LICENSE](server/direct/WS-LICENSE.txt). Self-hosted coturn/HAProxy/Node images
retain their own licenses and bundled dependency notices. Audit exact distributed
container/binary artifacts separately from the AIM source tree.

AIM's first-party source license does not replace the licenses of dependencies, fonts, artwork, model data, external agents or optional bundled runtimes. This document records the materials identified during the 2026-10-16 extraction. It is an inventory, not a complete notice bundle for an app binary assembled later, and does not certify rights for assets whose provenance is still pending.

The checked-in [asset manifest](docs/ASSET_MANIFEST.json) records source paths,
sizes, SHA-256 hashes, exact source descriptions and hashed license notices for
the extracted artwork/fonts, including SVGs. It distinguishes 181 assets with a
documented license basis, 15 AIM artwork entries confirmed by the owner after
opening the exact images, and 45 pending third-party rights reviews. The
[owner confirmation](docs/assets/notices/AIM_OWNER_CONFIRMATION_2026-10-20_FR.md)
records handmade authorship; attribution Mathieu Bielle and the existing project
MIT notice are retained. Hashes are not permission to redistribute.
The [asset checker and publication gate](docs/ASSET_REVIEW.md) enforce this distinction.

## Notices already retained in this source tree

| Material | Existing notice that must be preserved | Scope and conditions |
| --- | --- | --- |
| Lucide icon artwork in iOS | [Lucide-LICENSE.txt](apps/ios/AIM/Resources/Licenses/Lucide-LICENSE.txt) | ISC; retains the attribution for Lucide contributors and Feather portions. The `blocks.svg` source also carries a Lucide 0.462.0 ISC header. |
| Lobe Icons PNGs in iOS | [LOBE_ICONS_LICENSE.txt](apps/ios/AIM/Resources/ModelLogos/LOBE_ICONS_LICENSE.txt) | Existing notice identifies `logo-*.png` from @lobehub/icons-static-png 1.97.1, copyright 2023 LobeHub, MIT. |
| Lobe Icons PNGs in macOS | [LOBE_ICONS_LICENSE.txt](apps/macos/Sources/AIMMac/Resources/ModelLogos/LOBE_ICONS_LICENSE.txt) | Same existing source and MIT notice; preserve it alongside redistributed artwork. |
| Lora font in iOS | [OFL-Lora.txt](apps/ios/AIM/Resources/Fonts/OFL-Lora.txt) | SIL Open Font License 1.1; copyright 2011 The Lora Project Authors; reserved font name Lora. |
| Lora font in macOS | [OFL.txt](apps/macos/Sources/AIMMac/Resources/Fonts/OFL.txt) | Same OFL notice and reserved-name provisions. The font remains OFL licensed. |

Provider, product and organization logos remain trademarks of their respective owners. The Lobe software/artwork notice does not confer trademark rights. The [iOS logo README](apps/ios/AIM/Resources/ModelLogos/README.md) says the `brand-*.png` files are public GitHub organization avatars. This identifies their general origin; it does not establish permission to redistribute them.
The exception is `brand-huggingface.png`, now an exact copy of the identified
Lobe `logo-huggingface.png`, with source/notice hashes retained in the manifest.
Thirty-two legacy native provider PNGs likewise copy the exact matching local Lobe
variants while retaining their historical resource names. The [replacement table](docs/ASSET_REVIEW.md)
and per-file `copied_from` records identify their scope; this does not license
any of the untouched avatars or external-agent artwork. Other legacy provider PNGs also need an asset-by-asset provenance and rights review before public publication or binary redistribution. Do not assume their licenses from neighboring files or from public availability.

## Downloaded Swift and JavaScript packages

The precise package versions, source pins, declared licenses and known gaps are in [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md). Package-manager checkouts and `node_modules` are not vendored into this source publication. Their own license files remain authoritative and must accompany distributions to the extent required by each license.

The following distinctions affect packaging:

- Supabase Swift, ZIPFoundation and GRDB have MIT license texts; GRDB's SQLite components and SwiftMath's bundled math-font files need their associated notices too.
- Sparkle's LICENSE combines its main MIT text with notices for bundled components, including BSD-licensed bsdiff. Preserve the complete [Sparkle LICENSE](https://github.com/sparkle-project/Sparkle/blob/eef1a539a373c1f1a320624b1130fc5de7b2e100/LICENSE).
- WhisperKit's main MIT license is supplemented by [NOTICES](https://github.com/argmaxinc/WhisperKit/blob/1e2a163736dfa5a198e637ae44c114e1c6d5cc2d/NOTICES) covering incorporated Apache-2.0 Swift Transformers code. FluidAudio's Apache-2.0 license is separate from any speech-model license.
- Apple Swift packages include their own Apache-2.0 licenses, notices and, where applicable, exceptions or embedded cryptography code. Preserve the exact resolved package files rather than inferring one license for the whole graph.
- The website's React/Radix/Motion and related packages have their own notices. `lucide-react` is ISC, class-variance-authority and TypeScript are Apache-2.0. The locked build-tool graph includes MPL-2.0 native/platform packages as well as MIT and other permissive licenses. Generated application source and all downloaded tools are not automatically relicensed MIT.

## Optional runtime distributions

These are optional build inputs or separately installed upstream packages. Their source/build metadata in AIM is not evidence that an approved binary or complete third-party notice bundle is included.

| Runtime | Primary upstream evidence | Required review |
| --- | --- | --- |
| CUA Driver | [Driver component documentation](https://github.com/trycua/cua/blob/main/libs/cua-driver/README.md) describes the default Driver as MIT licensed | The packager requires the supplied Driver license and checks its pinned candidate digest. Validate the exact binary's provenance and notices. The optional cua-perception/OmniParser extension is separately AGPL-3.0-only according to those docs; it is not covered by the Driver's MIT label and is not included by this extraction. |
| llama.cpp | [Upstream LICENSE](https://github.com/ggml-org/llama.cpp/blob/master/LICENSE) is MIT | Preserve the supplied release's LICENSE and the notices of embedded libraries/build options. The builder supplies the exact release; no universal runtime version is asserted here. |
| MLX and Swift LM | [MLX Swift LICENSE](https://github.com/ml-explore/mlx-swift/blob/main/LICENSE), [MLX Swift LM LICENSE](https://github.com/ml-explore/mlx-swift-lm/blob/main/LICENSE) | Upstream main licenses are MIT. Exact resolved dependencies, embedded C/C++ code, tokenizer assets and all license/NOTICE files require a complete reviewed manifest. [The packager blocks MLX without it](apps/macos/docs/OPTIONAL_MLX_LICENSES.md). |
| Swift Transformers / Jinja | [Transformers LICENSE](https://github.com/huggingface/swift-transformers/blob/main/LICENSE), [Jinja LICENSE](https://github.com/huggingface/swift-jinja/blob/main/LICENSE) | Apache-2.0 upstream; retain exact-version notices and separately check model/tokenizer data. The prepared macOS arm64 engine now has a reviewed 12-pin/26-record inventory; other configurations and model/tokenizer data remain separate. |
| Playwright MCP / Playwright | [Playwright MCP LICENSE](https://github.com/microsoft/playwright-mcp/blob/main/LICENSE) is Apache-2.0 | Preserve notices for MCP, Playwright, playwright-core, any bundled Node distribution and downloaded browser engines. Browser engines have additional licenses and third-party notices. |
| OpenClaw / Hermes | Versioned upstream archive and adapter metadata recorded in the Mac source | Review the actual runtime packages and dependency graph, not just the engine's top-level license. OpenClaw's saved lock includes multiple license families and one missing metadata field. No upstream runtime tree was copied here. |

The optional runtime labels above summarize upstream evidence; they are not a claim that every embedded dependency, model or future binary has the same license. Main-branch links can change. The actual distributor must retain the license texts associated with the versions it ships.

### Prepared runtime inputs — 20 October 2026

The [pinned input inventory](docs/assets/notices/runtimes/README_FR.md) records Node22.23.3, the locked Playwright graph and the freshly compiled MLX engine. Node’s full license and seven Playwright license/notice texts are copied before signing; module bytes and notices are fingerprinted. MLX’s exact 12-pin graph, two Cmlx gitlinks and vendored notices were independently reviewed, retaining 26 records and their originals. Full text bundles remain with the prepared inputs and engine product, and must accompany the actual distributed bundle.

These are prepared inputs, not a signed/notarized application acceptance. Node SHASUMS signature was retained but not independently authenticated; HTTPS checksums were verified. Minimum-OS compatibility, any Swift back-deployment library, models, other optional runtimes and the 45 third-party logo rights remain separate gates. No old binary is relabeled using the current graph.

## Models, hosted services and signing

No model weights are licensed by AIM's source license. Model weights, tokenizer files, transcription models and downloaded datasets require their own model-card and license review, including any gating or redistribution restrictions. The local engine's license and the model's license are separate.

Cloudflare, Supabase, Apple, API providers and other hosted services have their own service/developer terms. A source license supplies neither paid API usage nor platform signing/notarization entitlements. Source publication is separate from App Store submission, binary distribution and operation of an official hosted Remote service.

Before distributing a binary, collect the exact upstream LICENSE/NOTICE/font texts and applicable attributions into a reviewable app or accompanying notice bundle, including the optional components actually enabled. Resolve the avatar/logo provenance gaps before claiming full source-asset clearance. Preserve these notices when redistributing this source tree.

## Development-only qualification tools and skills

The project-scoped `swift-testing-expert` (Antoine van der Lee) and `swiftui-pro`
(Paul Hudson) skills retain their upstream license texts in their respective
`.agents/skills` directories. Exact source revisions and file hashes are recorded
in `tools/apple-qa/provenance.json`. Project instructions take precedence over
generic toolchain or installation advice in these skills.

MobileBuildMCP 2.7.1 (Cameron Cooke, MIT) is an optional local development tool,
pinned with its dependency integrity records in `tools/apple-qa/package-lock.json`.
Its CLI skill comes from that package. The tool and its npm dependencies are not
bundled into AIM applications; preserve their package licenses if separately
redistributing a tool installation. npm lifecycle scripts are disabled during the
documented installation and telemetry is disabled for the qualification commands.

## Logo provenance research —20 October 2026

The [dated evidence](docs/assets/RIGHTS_EVIDENCE_2026-10-20_FR.md) and [per-file index](docs/assets/rights-index.json) identify every one of the45 remaining third-party files. The local brand-sources.json gives35 avatar URLs;31 current responses match the retained bytes and4differ. Matching bytes identify a response, not a redistribution license. No retained Hermes/OpenClaw PNG matches a blob in the four official repository trees examined. Their software MIT notices have not been applied to these untraced PNGs. Artwork permission, exact author attribution and trademark use remain separate reviews. No new rights clearance is claimed:45 third-party files and15 AIM ownership confirmations remain pending, and all241 assets are preserved.

## AIM identity confirmation after image presentation

The owner recognized the 15 exact AIM images opened in Preview and confirmed personal handmade creation on 20 October 2026. Their ownership/attribution review is now recorded, with exact hashes, under the unchanged project MIT notice and Mathieu Bielle credit. Current asset counts are 181 documented-license, 15 owner-confirmed-first-party, and 45 pending-third-party-rights. The earlier 60-pending research checkpoint above is historical. No third-party rights or trademark use were cleared by this confirmation.

## Retained third-party logos — documentary milestone 2, 20 October 2026

The [45 per-file reviews](docs/assets/RIGHTS_EVIDENCE_JALON2_2026-10-20_FR.md) retain all artwork and pending rights statuses. The [dated primary-policy summaries](docs/assets/notices/JALON2_POLICY_REVIEW_2026-10-20_FR.md) distinguish conditional published permissions from missing permissions and identify the source, native-app and marketing limits. A conditional connection-menu policy (notably Box) is not a blanket source/fork or marketing license. HubSpot’s Developer Terms refer to further branding requirements. Slack and Venice publish conditional usage routes; these do not automatically identify the exact retained avatars. No third-party logo is relicensed under AIM’s MIT license by this review, and no attribution alone establishes permission. No additional artwork-author credit is asserted without evidence. The 181 documented-license assets, 15 owner-confirmed AIM assets with Mathieu Bielle attribution, and 45 pending third-party assets remain distinct.
