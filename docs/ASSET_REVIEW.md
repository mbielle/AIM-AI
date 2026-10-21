# Asset provenance and full-qualification publication gate

> First Mac alpha, 21 October 2026: the [specific owner decision](qa/DECISION_ALPHA_ET_CHEMIN_PUBLICATION_2026-10-21_FR.md) preserves all logos and all 45 documentary states below, without a new audit campaign. This document and its checker retain their conservative full-review results; no pending right is marked resolved. The first-alpha preparation and owner review follow the separate decision, and the historical gates below are not new campaigns to run for that alpha.

The [manifest](ASSET_MANIFEST.json) inventories 241 local image/font/media files:
233 binary files plus eight SVG sources. It records each exact path, kind, byte
count, SHA-256, source description and review status. An asset hash identifies a
file; it does not grant permission or establish its author.

The current inventory has 181 assets with an existing documented license basis:
170 Lobe PNGs (including the 34 exact replacements), seven Lucide SVGs and
two Lora fonts, plus the two pinned SwiftUI skill icons under the retained MIT notice. Each entry pins the relevant retained notice by path and SHA-256.
After the owner recognized the 15 exact AIM app/site images opened in Preview on
20 October 2026, those 15 entries are `owner-confirmed-first-party`, attributed to
Mathieu Bielle under the unchanged project MIT notice. The
[owner review receipt](assets/notices/AIM_OWNER_CONFIRMATION_2026-10-20_FR.md) records
the handmade origin and exact hashes. The 45 remaining third-party artwork entries
still need source/rights evidence and remain explicit release gates. The Google sign-in imageset now contains the same identified Lobe Google PNG
used by the existing Mac sign-in interface; its catalog name is preserved. No unknown logo is called MIT based on a nearby file.

## Meaning of the statuses

| Status | Meaning | Public-source gate |
| --- | --- | --- |
| `documented-license` | This exact imported artwork/font is covered by its identified retained notice | Allowed by this inventory check; applicable trademark and distribution conditions still apply |
| `pending-third-party-rights` | An avatar/provider/agent image lacks exact redistribution evidence | Blocked |
| `pending-owner-attribution` | AIM artwork needs the owner's author/ownership confirmation | Blocked; this is not an assertion that the work belongs to a third party |
| `pending-provenance-review` | New or changed bytes have no current review | Blocked |
| `owner-confirmed-first-party` | Owner review recorded for this exact file, with attribution, license and retained notice | Allowed after explicit documented review |
| `documented-permission` | A separately documented permission and retained notice cover this exact file | Allowed after explicit documented review |

These are source-publication decisions. They do not certify a complete binary
notice bundle, model-weight rights or all trademark uses. The manifest scope does
not discover every illustration embedded in source code. First-party ownership
review still covers the mascot, wordmark, layout and other original source artwork.
Optional runtime/browser/model inventories remain separate release gates.

## Checks

```sh
# Contributor checks: metadata must match; unresolved rights remain visible, not a CI failure.
python3 scripts/audit-assets.py --self-test
python3 scripts/audit-assets.py --check

# Deliberately refresh after adding/removing/replacing an asset.
# New or changed bytes lose any previous resolved status and become pending.
python3 scripts/audit-assets.py --refresh

# Maintainer gate after staging the exact intended public source and evidence.
./scripts/check-publication.sh
```

The maintainer command first checks the indexed source for private-data patterns,
then reads the indexed asset manifest, artwork and notice files and fails on every
pending review. It does not publish, upload, create a remote, or mutate the index.
The current candidate intentionally fails the rights gate until the 45 remaining third-party reviews are
resolved. Ordinary development/build checks remain usable while that work is pending.

The asset checker also fails on missing/new assets, changed bytes or notices,
duplicate paths, ambiguous statuses, unreadable/symlink assets and a replacement
whose source bytes no longer match. It skips generated trees and never follows a
`node_modules` directory symlink. There is no generic “all cleared” switch. To resolve
an entry, preserve its exact hash, record an identified source, the applicable
license and hashed notice/evidence, and obtain the relevant owner/rights review.
For `owner-confirmed-first-party`, add author attribution and a hashed `review_evidence` receipt; for
`documented-permission`, identify the hashed exact `permission_evidence`. Review the diff.

## Minimal replacements made in the candidate

- iOS `brand-huggingface.png` now contains the exact bytes of the existing
  `logo-huggingface.png` from Lobe. The native registry identifies both as Hugging
  Face; resource names and mappings are unchanged. The manifest pins that source
  and MIT notice, and retains the trademark caveat. Other avatars were not deleted.
- An additional 32 provider PNG resources (20 iOS, 12 Mac) now copy exact matching
  local Lobe variants. The resource names stay unchanged, including the historical
  hyphen/underscore aliases used by dynamic lookups. The native provider/creator
  registries were checked before choosing these mappings:

  | Original provider resource identity | Exact local Lobe source identity |
  | --- | --- |
  | Alibaba, ByteDance, DeepSeek, Gemini, Meta, Minimax, Mistral, OpenRouter, Qwen | Same named `logo-*` variant |
  | `chatgpt-black` / `chatgpt_black` | `logo-openai` (the OpenAI provider identity) |
  | `claude` | `logo-anthropic` (the Anthropic provider identity) |
  | `grok-black` / `grok_black` | `logo-grok` |
  | `moonshot-black` / `moonshot_black` | `logo-moonshot` |
  | `perplexity-black` / `perplexity_black` | `logo-perplexity` |
  | `zai-black` / `zai_black` | `logo-zai` |

  Every exact path/source/notice hash is recorded in the manifest. Distinct products
  or connectors without an exact identified local variant, including Gmail/Drive/
  Calendar/Notion/Slack and the remaining external-agent artwork, were preserved
  with pending review rather than silently mapped to a different identity.
- The Google sign-in imageset payload is an exact copy of existing `logo-google.png`.
  Its only native caller uses `Image("GoogleLogo")`, which is unchanged; `Contents.json`
  references the new PNG and no longer requests vector preservation. The old untraced
  SVG was removed from the candidate after checking the catalog and caller. The iOS
  resource compilation must be rechecked after this substitution; no new physical
  sign-in or screenshot is claimed.
- The landing's inherited embedded Apple glyph had no retained attribution/source.
  Both Mac download buttons now use the existing `lucide-react` Monitor icon, under
  Lucide's ISC notice. This is a neutral platform icon; no new logo was drawn.

The original artwork remains in the previously created private archive. No original
repository or published app was modified by these candidate-source substitutions.

## Recherche documentaire du20 octobre 2026

Les45 fichiers tiers ont maintenant une fiche individuelle dans [la preuve datée](assets/RIGHTS_EVIDENCE_2026-10-20_FR.md) et [l’index](assets/rights-index.json). Le `brand-sources.json` local a permis de retrouver les35 URL précises :31 réponses sont identiques aux octets AIM,4diffèrent. Cela enrichit la provenance sans établir les droits de redistribution. Pour Hermes/OpenClaw, aucun blob exact dans les quatre arbres officiels consultés (main et versions runtime AIM) ; leurs licences MIT logicielles ne sont donc pas appliquées aux PNG inconnus. Bilan inchangé :181 documentés,45 tiers pending,15 AIM pending. Toutes les ressources sont conservées ; aucun retrait/remplacement n’est proposé par ce lot.

## Après ouverture et confirmation propriétaire

Le 20 octobre 2026, le propriétaire a reconnu les 15 variantes du logo AIM et confirmé leur création personnelle à la main. Bilan courant : 181 assets avec licence documentée, 15 confirmés de première main, 45 tiers en attente. Toutes les images sont conservées. Les nombres de 60 pending et 15 confirmations manquantes mentionnés dans les checkpoints de recherche ci-dessus sont historiques. La confirmation ne résout aucun droit tiers ni autre contrôle de publication.

## Complément jalon2 — 20 octobre 2026

Les [45 fiches actualisées](assets/RIGHTS_EVIDENCE_JALON2_2026-10-20_FR.md) distinguent source, binaire Mac, binaire iOS et présentation. Bilan inchangé : 181 licences documentées, 15 créations AIM confirmées (Mathieu Bielle), 45 tiers pending. Le guide développeur Box couvre sous conditions le menu de connexion cloud ; le besoin de nouvel accord n’est pas systématique, mais variante exacte, contexte bientôt et copies source/forks restent à relier. HubSpot §6 ouvre une voie conditionnelle renvoyant au guide qui demande une approbation pour company logo/sprocket. Slack/Venice et les autres usages publiés ne sont pas traités comme exigeant toujours un accord écrit. Cloudflare et Microsoft gardent leurs obstacles précis. Les anciens classements 30/4/11 restent historiques ; aucun statut de permission/licence n’a été résolu. Les [résumés de politiques et empreintes](assets/notices/JALON2_POLICY_REVIEW_2026-10-20_FR.md) complètent les preuves antérieures sans les modifier.

## Targeted final logo-rights review — 21 October 2026

The [final 45-file matrix](assets/RIGHTS_FINAL_REVIEW_2026-10-21_FR.md) adds bounded official-source and rasterization evidence, including pinned OpenClaw carapace guidance. It proposes zero third-party status promotions: all 45 stay pending; the 196 other entries remain unchanged. Box's published cloud-menu route remains conditional rather than a mandatory new letter. MIT metadata in nearby packages does not become a blanket logo licence. Attribution proposals are separate and do not modify bundled notices or candidate 56. The frozen public export v2 remains unchanged; this documentation is a proposed future-export diff pending independent review.

Final owner instruction: the owner confirms all 45 logos are official and already verified. Identity and visual-provenance comparison is stopped; no future general identity-review lot is proposed. Pending redistribution-rights documentation is distinct from this accepted identity confirmation and from a legal prohibition.
