# Model logos

Place model or provider logos in this directory. The application loads them at
runtime without requiring one asset-catalog entry per model.

Supported formats: `png`, `webp`, `jpg`, `jpeg`, and `pdf`.

Use a lowercase slug for the filename. Spaces and punctuation become hyphens.
The resolver tries, in order:

1. the complete model identifier;
2. the provider name;
3. the displayed model name.

Examples:

- `gpt-5-6-terra.png`
- `openai.png`
- `anthropic.png`
- `moonshot.png`
- `qwen.png`
- `z-ai.png`
- `sakana.png`

Prefer a transparent background and a square canvas. The app supplies the
rounded container and padding. A typographic initial remains visible until the
corresponding image is added.

## Shared brand registry (Continuity Test 20)

`AIMBrandRegistry` resolves exact model creator, provider and connector identities.
The creator mapping matches the Mac mapping; monochrome artwork follows the theme.
`brand-*.png` are public organization avatars fetched from the GitHub organizations
already referenced by the curated connector catalogue and Mac provider list.
They are bundled to remain immediately available offline; no credentials were used.
Their redistribution rights remain pending; public availability is not permission.
Exception: `brand-huggingface.png` is now an exact copy of the already bundled
`logo-huggingface.png` Lobe artwork, under the adjacent MIT notice. The source and
notice hashes are recorded in `docs/ASSET_MANIFEST.json` at repository root.
Twenty legacy provider PNG resources also now copy their exact same-provider Lobe
variants, keeping the existing filenames and lookup aliases. See the manifest
`copied_from` entries and `docs/ASSET_REVIEW.md` for the exact mapping. This does not
clear the remaining connector/avatar/external-agent artwork.
Additional HTTPS registry icons use a coalesced memory/disk bitmap cache.
