# ADR 013: Nightly data job: GitHub Actions publishing to GitHub Pages; app downloads with a bundled fallback

**Status:** proposed (Architect, 2026-11-06), implementing ADR 010. Phase 4, step 1 (pipeline skeleton). New sources
(Overture or Foursquare places, Vilnius events, Michelin) plug into it later as separate features.

**Decision.**
- **Job:** `.github/workflows/nightly-data.yml`, cron 02:30 UTC plus manual dispatch. It runs the existing pipeline for
  every city in `Data/cities.json` (Vilnius only): fetch_osm → enrich → wikipedia → score. The Overpass, Wikidata,
  Commons and Wikipedia caches persist between runs in the Actions cache, so each night re-fetches only what changed.
  One Overpass request per city per night.
- **Gate:** publish only if all of these hold:
  - the file passes `scripts/validate-pois.py`
  - POI count per category is within ±25% of the last published file
  - no tier-1 place disappeared without a curation row
  - the run is deterministic: re-running score on the same inputs gives the same bytes
  On failure, keep the previous file and fail the workflow (red run equals an alert).
- **Unattended names:** sights without a row in `names-en/<city>.csv` fall back to the Wikidata English label, then to the
  local name. They're listed in the run's "needs review" summary; nothing is auto-committed to the repo.
- **Hosting:** GitHub Pages of this public repo (free, static, HTTPS, CDN). Layout:
  `https://mateuzas.github.io/wander/data/v1/manifest.json` and `.../data/v1/pois-<city>.json`. `v1` is the schema
  major version; a breaking schema change publishes to `v2` and old apps keep reading `v1`.
- **Manifest:** `{ "schema": 1, "generated": "<ISO8601>", "cities": { "vilnius": { "url": "...", "sha256": "...",
  "bytes": N, "pois": N, "generated": "<ISO8601>" } } }`
- **App:** at launch and on foreground, at most every 6 h, fetch the manifest (ETag / If-None-Match). If the city's sha256
  differs from the cached one, download the file, verify sha256, decode with `POIFile`, and only then atomically replace the
  cached copy in Application Support. Load order: valid cached download, then the bundled file. Never block the UI.
  Offline means the cached or bundled file, with no error UI. A Settings/About line shows "Places updated <date>".
- **Bundled file:** still committed (refreshed by a normal PR when useful), so a fresh install works offline.

**Why.** No server or database to run, and fits ADR 001's "static files" path. Pages is free for a public repo, and the
data is open (OSM ODbL, Wikimedia), so publishing it is fine with attribution, which the app already shows.

**Open.** Event sources for Vilnius (user to list them) and the second place source (BE-7) come next, as their own ADRs.
