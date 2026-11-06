# ADR 014: Overture Maps Places as the second place source (niche and new places)

**Status:** proposed (Architect, 2026-11-06). Phase 4 step 2, BE-7. Research: docs/research/vilnius-sources.md.

**Context.** OSM misses small and new places. In the Vilnius bbox, Overture release 2026-10-21.0 has 25,220 places,
10,998 with confidence > 0.7, about 23k sourced from Meta pages (where new cafés and bars appear first). The licence is
open (CDLA-Permissive-2.0, plus per-source terms). It's GeoParquet on S3, updated monthly.

**Decision.**
- **Extraction (monthly, DevOps, OPS-8):** a workflow with a pinned `duckdb` reads the latest Overture release for each city's
  `bbox` (anonymous S3) and writes a compact `Data/sources/overture/<city>.json`: id, names (primary, local), lat/lon,
  `basic_category`/`taxonomy`, confidence, brand, websites, socials, addresses, operating_status and sources' update times.
  It opens a PR with the refreshed file, so changes are reviewable. The nightly pipeline reads that file and stays stdlib-only.
- **Selection (Backender, BE-7):**
  - confidence ≥ 0.7; skip if `operating_status` says closed; skip branded (chain) entries
  - category mapping:
    - food: restaurant, cafe, coffee_shop, bakery, bar, pub, wine_bar, cocktail_bar, ice_cream…
    - shop: tourist-browsable kinds matching our allowlist (books, records, vintage, gifts, art, crafts…)
    - photo: art_gallery, music_venue and similar venues
  - everything else ignored
- **Dedupe with OSM:** same normalised name within 60 m, or a strong name similarity within 25 m, counts as one place.
  The OSM record wins; the match adds `"overture"` to `sources` and fills missing website or social links. Unmatched
  Overture places become new POIs with id `ovt:<overture id>`.
- **Scoring:** existing formulas. Fame 0 unless Wikidata-linked. Quality from completeness (website, socials, address,
  phone). Photos from the existing Commons tiles. Independent = no brand. Overture-only places then go through the same
  floors and tiers as everyone else (ADR 012), so they add depth at street zoom without crowding the city view.
- **New places:** the pipeline keeps a first-seen date per id in its cache; ids first seen in the last 60 days get
  `new: true` (for a later "New" badge).
- **Attribution:** the app's credit line adds "Overture Maps Foundation".
- **Gate:** the first publish with Overture grows counts beyond ±25%. `publish_gate.py --allow-growth` is used once,
  by a manual dispatch input, and the summary shows it.

**Consequences.** Many more food and drink places at street level; quality still depends on completeness signals until
ratings exist. Ids for Overture-only places are stable per Overture GERS id.
