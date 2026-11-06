# Contracts

Wander has no HTTP API of its own. Its contracts are:
1. the **POI data file** (Backender writes it, Frontender and RouteEngine read it),
2. the **RouteEngine Swift API** (Backender provides it, Frontender calls it),
3. **build and configuration** (DevOps provides it, everyone uses it).

Only the Architect edits this file. Changes are additive and optional unless an ADR says otherwise,
so older data files and app builds keep working.

## 1. POI data file: `App/Wander/Resources/pois-<city>.json`

Machine-readable: [`docs/schema/pois.schema.json`](schema/pois.schema.json) (JSON Schema 2020-12).
Producer: `Data/score.py <city>`. Consumers: `RouteEngine.POIFile` / `POI` (decoder) and `POIStore` (app).
`<city>` is a lowercase ASCII slug from `Data/cities.json` (currently only `vilnius`, ADR 007).

```json
{
  "city": "Vilnius",
  "generated": "2026-11-02",
  "attribution": "© OpenStreetMap contributors",
  "pois": [{
    "id": "osm:way:123456",
    "name": "Vilnius Cathedral",
    "lat": 54.6858, "lon": 25.2877,
    "category": "photo", "score": 88, "kind": "passby",
    "reason": "Neoclassical cathedral at the foot of Gediminas Hill",
    "type": "church",
    "signals": { "photos": 0.95, "fame": 0.9, "quality": 0.8, "independent": true },
    "localName": "Vilniaus arkikatedra bazilika",
    "commonsImage": "Example.jpg",
    "commonsCategory": "Vilnius Cathedral",
    "popular": true
  }]
}
```

| Field | Type | Req. | Rules |
|---|---|---|---|
| `id` | String | ✓ | `osm:(node\|way\|relation):<n>`, stable across runs; used for curation, `seen` lists, caches |
| `name` | String | ✓ | Display name. Sights: English (`Data/names-en/<city>.csv`). Shops and food: their own name |
| `lat`, `lon` | Double | ✓ | WGS84; centroid for ways and relations |
| `category` | `photo` \| `shop` \| `food` | ✓ | Swift `POICategory`. Notable venues (BE-4) use the same categories: stadiums, arenas, theatres, concert halls, zoos, aquariums and theme parks are `photo`; shopping malls are `shop` |
| `score` | Int 0–100 | ✓ | Default blend; used when no weights are given. Shop and food are capped at 70 |
| `kind` | `passby` \| `stop` | ✓ | photo → passby, shop and food → stop |
| `reason` | String | ✓ | Short, concrete, sentence case (PLAN §10); may be `""` |
| `type` | String | – | Most specific OSM value (`mural`, `museum`, `church`, `cafe`, `books`…) |
| `signals` | object | – | `photos`, `fame`, `quality` Double 0–1; `independent` Bool. Inputs to per-user weighting |
| `cuisine` | [String] | – | Food only; OSM values (`italian`, `polish`) |
| `openingHours` | String | – | Shop and food only; raw OSM `opening_hours`; parsed by `OpeningHours` |
| `localName` | String | – | Only when `name` is a translation; for matching Apple places |
| `commonsImage` | String | – | Photo only; Commons file name without `File:`; show it with author and licence |
| `commonsCategory` | String | – | Photo only; Commons category without `Category:`; for the gallery |
| `popular` | Bool | – | Present only when `true`; equals `tier == 1` (ADR 012) |
| `tier` | Int 1–3 | – | Map importance within the category (ADR 012): 1 must-see (top 4%, plus sights with fame ≥ 0.8; sights capped at 25), 2 notable (next 15%), 3 detail. Places under the category score floor aren't in the file |
| `description` | String 20–300 | – | 1–2 factual sentences shown in the place card. **Every popular place has one** when a source exists. Sources only: the lead of the English Wikipedia article (sights, venues), or a sentence composed from OSM facts (cuisine, outdoor seating, diet options, opening hours, start date, architect, heritage). Never invented or paraphrased beyond the source |
| `descriptionSource` | `wikipedia` \| `osm` | – | Present with `description`. `wikipedia` text is CC BY-SA: the app shows "From Wikipedia" with a link |
| `descriptionUrl` | String (https) | – | Required when `descriptionSource` is `wikipedia`: the article URL |

Unknown fields are ignored by the decoder. A new field needs a schema update here first.

_(Illustrative values, not real data.)_

## 2. RouteEngine Swift API (`Packages/RouteEngine`, Foundation only)

**Planning**
- `Planner(config: PlannerConfig = .default)`
- `plans(_ request: PlanRequest, modes: [Mode] = Mode.allCases, provider: WalkingTimeProvider) async throws -> [Mode: WanderPlan]`.
  **The app uses this.** Plans the modes smallest budget first, shares real legs between them, and makes Explorer differ from Relaxed.
- `plan(_ request:provider:distinctFrom:) async throws -> WanderPlan` plans a single mode.
- `PlanRequest(origin:destination:mode:interests:weights:pois:time:timeZone:)`
  - `weights`: `SignalWeights?`, from `WeightPreset` (`balanced`, `photoSpots`, `famousSights`, `hiddenGems`); `nil` means use `score`.
  - `time`: `Date?`. When set, POIs that are closed are rejected.
- `Mode`: `direct` / `relaxed` / `explorer` → extra budget 0 / 10 / 25 min, max stops 0 / 3 / 5.
- `WanderPlan`: `baseline: Leg`, `waypoints: [POI]`, `legs: [Leg]`, `totalTime`, `extraTime` (seconds),
  `highlights: [Highlight]` (`role` `.waypoint` or `.passby`, `distanceAlongRoute`, `distanceFromRoute`),
  `noDetourFit: Bool`, `candidates: [CandidateDebug]` (for the debug overlay), `polyline`, `totalDistance`.
- Errors: `plan`/`plans` rethrow provider errors (no route, network). The app maps them to PLAN §7 copy.

**Walking**
- `WalkTracker(plan:config:)`
  - `mutating update(_ fix: LocationFix) -> WalkUpdate`, `mutating skipNudge()`
  - `updates(for:) -> AsyncThrowingStream<WalkUpdate, Error>`
- `LocationFix(coordinate:horizontalAccuracy:heading:timestamp:)`; fixes worse than 65 m are ignored.
- `WalkUpdate`: `progress`, `routeLength`, `remainingDistance`, `distanceFromRoute`, `stepIndex`, `nextStep`,
  `distanceToNextStep`, `isOffRoute`, `hasArrived`, `nudge: Nudge?` (`highlight`, `distanceAhead`, `side`), `events`.
- `WalkEvent`: `offRoute`, `backOnRoute`, `nudgeShown(Nudge)`, `nudgePassed(id)`, `arrived`.

**Routing provider** (the app implements it; the engine never imports MapKit)
- `protocol WalkingTimeProvider { func leg(from: Coordinate, to: Coordinate) async throws -> Leg }`
- `Leg`: `from`, `to`, `duration` (s), `distance` (m), `polyline: [Coordinate]`, `steps: [RouteStep]` (`instruction`, `distance`).
- `MapKitWalkingTime` (app) must fill `steps` from `MKRoute.steps` and stay under 40 MKDirections requests per rolling minute.

**Changing (ADR 008, phase 3):** Relaxed/Explorer become one engine-chosen "Recommended" route next to Direct.
`Mode` and `PlanRequest.budget` change in ARC-5; until then the API below is current.

**Seen places (BE-1, PR #18):** `PlanRequest(..., seen: Set<String> = [])` takes POI ids the user already
saw today; their value is multiplied by `PlannerConfig.seenFactor`. Zero-cost stops become pass-by
highlights and free their slot. At most 1 food and 1 shop stop per walk, unless that category is the only interest.

## 3. Build and configuration

| Item | Contract |
|---|---|
| Xcode | Newest installed (`scripts/ci-select-xcode.sh`); deployment target iOS 17.0 |
| Bundle id | `com.mateuzas.wander` |
| Signing | `App/Config/Signing.xcconfig` (committed, empty team) includes the git-ignored `Signing.local.xcconfig`, written by `scripts/secrets.sh xcconfig` from SOPS-encrypted `secrets/signing.enc.yaml` (docs/SECRETS.md) |
| Secrets | Never committed in plain text. `scripts/check-secrets.sh` runs in CI |
| CI (every PR) | `RouteEngine tests` (`scripts/test-engine.sh`), `iOS Simulator build`, `Data pipeline compiles`, `Secret scan` |
| Build output | Outside the repo (`~/Library/Caches/wander/`); `~/Desktop` is iCloud-synced and breaks code signing |
| Runtime config | No env vars or URLs to configure; external endpoints are fixed: Commons API `https://commons.wikimedia.org/w/api.php`, Google Maps `https://www.google.com/maps/dir/?api=1` |
| Permissions | `NSLocationWhenInUseUsageDescription` only; no background modes |

## 3b. Published data (ADR 013; phase 4)

| Item | Contract |
|---|---|
| Base URL | `https://mateuzas.github.io/wander/data/v1/` |
| Manifest | `manifest.json`: `schema` (Int, = 1), `generated` (ISO 8601), `cities.<slug>`: `url`, `sha256` (hex), `bytes`, `pois`, `generated` |
| City file | `pois-<slug>.json`, same schema as §1 (`docs/schema/pois.schema.json`) |
| Publish gate | validator passes; per-category count within ±25% of the last publish; no tier-1 loss without a curation row; deterministic |
| App refresh | at most every 6 h at launch or foreground; ETag; sha256 verified; decoded before swapping; fallback to cached, then bundled |
| Breaking schema change | publish under `/v2/`; `/v1/` stays frozen for older apps |

## 4. Naming

- POI ids: `osm:<type>:<n>`. City slugs: lowercase ASCII. Branches: `<area>/<short-name>`.
- Commit subjects: `<area>: <summary>` (AGENTS.md). Task ids: `ARC-n`, `BE-n`, `FE-n`, `OPS-n` (docs/TASKS.md).
- UI copy follows PLAN §10: sentence case, plain verbs, and the same word for the same action.
