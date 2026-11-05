# Architecture

Wander is an iPhone app for tourists walking to a known destination. It plans a walking route that
passes interesting places (sights, independent shops, food) within a time budget, then guides the walk
and nudges the walker to look up. Product spec: [PLAN.md](../PLAN.md). This file describes what is
built; PLAN §4 was the original sketch.

## Phase 0 answers (constraints)

| Question | Answer |
|---|---|
| Users | Tourists on foot in an unfamiliar city, going somewhere specific, not in a hurry |
| Platform | Native iOS (SwiftUI), iOS 17 minimum; tested on an iPhone 17 Pro Max, iOS 27 |
| Server | **None** (ADR 001). The protocol's defaults for containers and health endpoints don't apply |
| Auth / accounts | None. No personal data leaves the phone except routing requests to Apple |
| Cities | Vilnius only (ADR 007; Łódź was the 2026-11 field test); one data file per city |
| Distribution | Free provisioning from Xcode (7-day installs) for now; TestFlight later (DevOps) |

## Components

```
┌──────────────────────────── iPhone app (App/, Frontender) ─────────────────────────────┐
│ Views        MapScreen · HomeSheet · PlanSheet · POIDetail · WalkViews · MapStyleControl│
│ Models       PlannerModel · WalkModel · PlanEditor · RouteProfile · RecentDestinations  │
│ Services     LocationService (CoreLocation) · SearchService (MKLocalSearch)             │
│              MapKitWalkingTime (MKDirections, implements WalkingTimeProvider)           │
│              POIStore (bundled pois-<city>.json) · PlaceInfoService (Apple place card,  │
│              Commons photos) · Connectivity · HandOff (Google/Apple Maps URLs)          │
│ DesignSystem PLAN §10 tokens, Instrument Sans, Bead, ModeControl, WanderMark, brand     │
│          │ Swift API (docs/CONTRACTS.md §2)                                             │
│ RouteEngine (Packages/RouteEngine, Backender): Foundation only                         │
│   Planner (filter → score → select → verify → top-up) · WalkTracker · OpeningHours      │
│   WeightPreset · HaversineWalkingTime (offline estimates, tests)                        │
└─────────────────────────────────────────────────────────────────────────────────────────┘
        ▲ pois-<city>.json (docs/CONTRACTS.md §1, docs/schema/pois.schema.json)
┌───────┴───────────── offline pipeline (Data/, Backender; run on the Mac) ──────────────┐
│ fetch_osm.py  Overpass → named POIs, categorised (photo/shop/food)                      │
│ enrich.py     Wikidata (fame, English label, P18 image, P373 category)                  │
│               Commons geotagged-photo density (tiled bbox search)                       │
│ score.py      signals → score, curation.csv, names-en/<city>.csv → JSON + review CSV    │
└─────────────────────────────────────────────────────────────────────────────────────────┘
External at runtime: Apple MapKit (map, search, walking directions, place cards),
Wikimedia Commons API (photos, read-only), Google/Apple Maps via URL hand-off.
Planned: nightly data job publishing static files (ADR 010), Live Activity navigation (ADR 009). See ROADMAP.md.
```

## Data flow

1. **Build time:** `Data/` turns OSM and Wikimedia data into `pois-<city>.json`, which is committed and bundled.
2. **Plan:** the user picks a destination → `PlannerModel` calls `Planner.plans(...)` for Direct, Relaxed and
   Explorer together → the engine estimates offline, then verifies real legs through
   `MapKitWalkingTime` (about 4–10 MKDirections requests per trip; legs are shared between modes).
3. **Walk:** `WalkModel` feeds CoreLocation fixes to `WalkTracker` → turn card, "Up ahead" nudges,
   off-route → reroute through the remaining stops, arrival.
4. **Place details:** tap a bead → `PlaceInfoService` matches an Apple place by `localName ?? name`
   within 60 m (or shows nothing), and shows Commons photos from `commonsImage` and `commonsCategory`.

## Tech choices

| Choice | Why |
|---|---|
| SwiftUI + MapKit | Free, no API keys, good walking routes; the user's only device is an iPhone |
| No third-party dependencies | Fewer moving parts for a solo project |
| Foundation-only RouteEngine | Unit-testable with `swift test`, with no simulator or network (ADR 002) |
| Python stdlib pipeline | Runs anywhere; no virtualenv |
| Bundled per-city JSON | No server to run; a city is ~250 KB (ADR 001) |
| Raw signals plus a default score | Lets the app weight per user (route styles) without new data (ADR 004) |
| GitHub Actions on macOS | Engine tests, iOS build and pipeline compile on every PR |
| SOPS/age for signing secrets | The team ID stays out of a public repo (docs/SECRETS.md) |

## Non-goals (for now)

A server, accounts, sync, reviews from paid APIs (Google Places), "safe street" routing, voice guidance,
background location, Android, Apple Watch, and cities beyond the ones with data files. See PLAN §1 and ADR 001
for how multi-city support would come later (static per-area files on a CDN).

## Known limits

- MKDirections picks the path between waypoints, so street character isn't controlled.
- Shop and food quality comes from OSM data completeness, not from ratings.
- Apple place cards often don't match famous sights (Apple uses yet another name for them).
- Visual QA happens only on the user's phone (simulator screenshots are black on this Mac).
