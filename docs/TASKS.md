# Tasks

Status: `todo` · `in progress` · `blocked` · `done`. Only the Architect edits this file.
Every task ends with a PR into `main` and the checks in AGENTS.md. "Phone check" means the
Architect installs the build on the user's iPhone and the user confirms. Work goes **one feature at a time**
in roadmap order ([ROADMAP.md](ROADMAP.md)).

## Done

| What | PRs |
|---|---|
| M0 setup, M1 data, M2 RouteEngine | #1, #2 |
| CI, secrets (SOPS/age) | #3, #4 |
| M3 app shell, M4 planning UI, M5 walk engine and walking UI | #5, #7, #8, #9 |
| Place details: map style, Apple place card, Commons photos, local names | #10–#13 |
| Popular sights, photo gallery, ✕ on card, branding (icon, logo, mark) | #14–#16 |
| Architect docs; seen places and free stops (BE-1); popular per category (BE-3); install script and schema CI (OPS-1, OPS-2); launch screen, Directions, stable beads (FE-6, FE-5, FE-1) | #17–#22 |
| Round 3 docs; notable venues (BE-4); long-press pin with Directions (FE-7) | #23, #24, #25 |

## Phase 1: Vilnius baseline and map basics (in progress)

| Id | Owner | Task | Status | Done when |
|---|---|---|---|---|
| BE-2 | Backender | Vilnius data (`pois-vilnius.json`, English names, first-pass curation, city-wide venues); drop all Łódź data; 10 Vilnius golden routes (ADR 007) | in progress | schema check passes; famous Vilnius sights present; golden table in the PR |
| FE-8 | Frontender | Current-location button (recentre; second tap follows heading) | in progress | phone check |
| FE-9 | Frontender | Heading cone on the user dot | in progress | phone check: you can tell which way you face |
| FE-10 | Frontender | The walk's places stay tappable during a walk (card over the walk UI; Skip) | in progress | phone check |
| FE-11 | Frontender | Separate food icons by kind (restaurant, café, bar, bakery, ice cream), category colour kept | in progress | phone check |
| FE-12 | Frontender | App city is Vilnius; no Łódź code left | in progress | merges together with BE-2 |
| ARC-3 | Architect | Docs: Vilnius only; remove Łódź references | in progress | – |

## Next phases (briefed one at a time, in order)

| Id | Owner | Task | Phase |
|---|---|---|---|
| ARC-4 | Architect | Map selection policy: ADR 012 (score floors, tiers, zoom layering) | done |
| BE-5 | Backender | Floors and `tier` in the pipeline; `POI.tier` in the engine (ADR 012) | in progress |
| FE-13 | Frontender | Zoom layering by tier (ADR 012) | in progress |
| OPS-7 | DevOps | CI runs only the jobs a change needs (path-based), skipped jobs still pass | in progress |
| ARC-5 | Architect | Direct + Recommended contract (CONTRACTS §2); filters approved as they are (interests + style) | done |
| BE-6 | Backender | Engine: `Mode` = direct/recommended, engine-chosen extra time with a cap, worth-it pruning, golden targets | in progress |
| FE-18 | Frontender | Plan sheet moods (one single-select row) | done (#42) |
| FE-19 | Frontender | Food nearby flow (CONTRACTS §2): type, then cuisine, then closest good open place; Food & drink mood removed | todo (after FE-15) |
| FE-20 | Frontender | Recents as a compact island with the last 3 searches | todo (after FE-15) |
| ARC-7 | Architect | Source research (docs/research/vilnius-sources.md): Overture for places; vilnius-events.lt then bilietai.lt for events; crawl what robots.txt allows (user) | done |
| BE-14 | Backender | Photos for every place: Commons, Mapillary (facing the place), website og:image; best per place (ADR 015) | todo |
| BE-15 | Backender | Grounded AI hooks via the Anthropic SDK (Batch, structured output, cached by hash); gate: no hook or photo means removed (ADR 015) | todo |
| OPS-9 | DevOps | Secrets ANTHROPIC_API_KEY and MAPILLARY_TOKEN in nightly-data; pinned deps; `--allow-shrink` dispatch input | todo |
| FE-22 | Frontender | Card and bead preview show hook and photo with credit; schema now requires both | todo |
| BE-12 | Backender | (done, #45) WalkTracker robustness on Recommended plans (5 stops): golden route 4 seed 13 has a 65 m progress error (bound 60 m); the wrong-turn test geometry fails on routes 1 and 7. Fix the tracker rather than loosening bounds; test fixtures back on real Recommended plans | todo (before phase 6) |
| FE-14 | Frontender | Plan sheet: Direct / Recommended (+N min), chips and style menu; Relaxed/Explorer removed | in progress |
| ARC-6 | Architect | Nightly data design: ADR 013 (Actions → GitHub Pages, manifest, gate, app refresh) | done |
| OPS-5 | DevOps | Nightly workflow, caches, publish gate, GitHub Pages deploy (ADR 013) | todo |
| BE-13 | Backender | Pipeline unattended mode: name fallback, "needs review" report, gate checks as a script | todo |
| FE-15 | Frontender | App fetches manifest and city file, verifies, caches, falls back; "Places updated" line | todo |
| OPS-8 | DevOps | Monthly Overture extraction workflow (pinned duckdb) → PR with Data/sources/overture/<city>.json (ADR 014) | todo |
| BE-7 | Backender | Overture places: selection, OSM dedupe, scoring, `sources`/`website`/`instagram`/`new`, `--allow-growth` gate flag (ADR 014) | todo |
| BE-8 | Backender | Vilnius events scraper, daily; event schema | 4 |
| BE-11 | Backender | Michelin Guide places (stars, Bib Gourmand, selected) as a separate, clearly marked layer; check the source terms first (prefer open data such as Wikidata over scraping the guide site) | 4 |
| BE-9 | Backender | Engine tuning on fresh data; FE-3 "seen" memory | 5 |
| FE-16 / OPS-6 | Frontender / DevOps | Live Activity navigation (Dynamic Island, Lock Screen), widget target, background location during walks (ADR 009) | 6 |
| – | all | Social "hangout" mode (ADR 011) | 7 |

## Backlog

| Id | Owner | Task | Status |
|---|---|---|---|
| FE-4 | Frontender | Polish: dark mode, Dynamic Type to AX3, VoiceOver, §7 states, Settings/About with attributions | todo |
| OPS-4 | DevOps | `install-device.sh` treats a Wi-Fi-paired phone ("available (paired)") as installable | todo |
| ARC-2 | Architect | Distribution decision: 7-day free installs or Apple Developer Program (TestFlight) | todo (user) |
| OPS-3 | DevOps | TestFlight pipeline | blocked by ARC-2 |
