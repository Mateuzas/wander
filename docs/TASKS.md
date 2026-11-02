# Tasks

Status: `todo` · `in progress` · `blocked` · `done`. Only the Architect edits this file.
Every task ends with a PR into `main` and the checks in AGENTS.md. "Phone check" means the
Architect installs the build on the user's iPhone and the user confirms.

## Done (milestones 0–5 and field-test round 1)

| Milestone | PRs |
|---|---|
| M0 setup, M1 Łódź data, M2 RouteEngine | #1, #2 |
| CI, secrets (SOPS/age) | #3, #4 |
| M3 app shell, M4 planning UI, M5 walk engine and walking UI | #5, #7, #8, #9 |
| Place details: map style, Apple place card, Commons photos, local names | #10–#13 |
| Popular sights, photo gallery, ✕ on card, branding (icon, logo, mark) | #14–#16 |
| Architect protocol docs; seen places and free stops (BE-1); popular per category (BE-3); install script and schema CI (OPS-1, OPS-2); launch screen, Directions, stable beads (FE-6, FE-5, FE-1) | #17–#22 |

## Architect

| Id | Task | Status | Done when |
|---|---|---|---|
| ARC-1 | Turn Łódź field-test notes into curation rows and briefs | in progress | each reported place has a `curation.csv` row or a task |
| ARC-2 | Decide distribution: keep 7-day free installs or pay for the Apple Developer Program (TestFlight) | todo (user decision) | decision recorded as an ADR |

## Backender (`Packages/RouteEngine/`, `Data/`)

| Id | Task | Status | Inputs | Done when | Depends on |
|---|---|---|---|---|---|
| BE-1 | Zero-cost stops become pass-by highlights and free their slot; `PlanRequest.seen: Set<String>` cuts their value (×0.2); 1 shop per walk; golden-routes "walk in sequence" mode reporting repeats | done | CONTRACTS §2 (pending) | tests pass; before/after golden table in the PR; Relaxed never equals Direct when a detour fits | – |
| BE-3 | Popular places in every category: top `POPULAR_SHARE` (5%) of each category by score, minimum 1, plus sights with fame ≥ 0.6; `curation.csv` `popular` overrides still win | done | CONTRACTS §1 | Łódź: popular counts roughly proportional to category sizes; schema check passes; README updated | – |
| BE-4 | Notable venues: stadiums, arenas, theatres, concert halls, zoos, aquariums, theme parks → `photo`; shopping malls → `shop`. Notable = Wikipedia/Wikidata link or footprint ≥ 150 m (Manufaktura has no Wikidata tag) | in progress | CONTRACTS §1 | venues on the map; English names for new sights; schema check passes | – |
| BE-2 | Vilnius data: run the pipeline, draft `names-en/vilnius.csv`, first-pass curation, review CSV | todo | `Data/cities.json` | `pois-vilnius.json` validates against the schema; top 20 sights spot-checked; golden routes for 10 Vilnius pairs | after the Łódź test |

## Frontender (`App/`)

| Id | Task | Status | Done when | Depends on |
|---|---|---|---|---|
| FE-1 | Stable beads on zoom: at most one ordinary bead per screen cell (≈ 44 pt grid), keep beads already shown when the set changes, popular always shown | done | zooming in and out doesn't make middle beads vanish while corner ones appear (phone check) | – |
| FE-2 | Redesign the Sights / Shops / Food interest chips within PLAN §10 | todo | user approves on the phone | – |
| FE-3 | Per-day "seen" list (highlights passed, skipped or visited), passed as `PlanRequest.seen` | todo (after #18) | a second walk on the same day prefers new places | BE-1 |
| FE-5 | "Directions" on every place card: tap → that place becomes the destination and a plan is made from the current location (like Google Maps). Hidden while walking | done | works for sights, food and shops (phone check) | – |
| FE-6 | Branded launch: static iOS launch screen (surface colour + Wander mark from the brand kit), then a short SwiftUI hand-off (≤ 0.8 s fade, Reduce Motion respected, never blocks startup) | done | cold start shows the brand, not a blank map (phone check) | – |
| FE-7 | Long-press the map → dropped pin with a name from reverse geocoding and "Directions" (same path as FE-5); debug overlay toggle moves off long-press to the plan sheet; VoiceOver "Drop pin at map centre" action | in progress | long-press anywhere plans a walk there (phone check) | – |
| FE-4 | M6 polish: dark mode pass, Dynamic Type to AX3, VoiceOver labels (PLAN §10), §7 empty and error states, Settings/About with OSM and Commons attribution (§7.5) | todo | checklist in the PR; phone check | – |

## DevOps (`.github/`, `scripts/`, `secrets/`, `App/Config/`)

| Id | Task | Status | Done when | Depends on |
|---|---|---|---|---|
| OPS-1 | `scripts/install-device.sh`: build Debug for the connected iPhone (derived data outside the repo, `-allowProvisioningUpdates`) and install with `devicectl`; clear errors when the phone is locked or not paired | done | one command installs `main` on the user's phone | – |
| OPS-2 | CI job validating every `App/Wander/Resources/pois-*.json` against `docs/schema/pois.schema.json` (stdlib-only validator in `scripts/`) | done | a broken file fails the PR; the current Łódź file passes | – |
| OPS-3 | TestFlight pipeline (archive, upload, secrets via SOPS) | blocked | builds reach TestFlight from CI or one command | ARC-2 (paid account) |
