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
`<city>` is a lowercase ASCII slug from `Data/cities.json` (`lodz`, `vilnius`).

```json
{
  "city": "Łódź",
  "generated": "2026-11-02",
  "attribution": "© OpenStreetMap contributors",
  "pois": [{
    "id": "osm:way:283202330",
    "name": "St Stanislaus Kostka Cathedral",
    "lat": 51.748928, "lon": 19.459686,
    "category": "photo", "score": 83, "kind": "passby",
    "reason": "Neo-Gothic cathedral at the south end of Piotrkowska",
    "type": "church",
    "signals": { "photos": 0.881, "fame": 0.793, "quality": 0.6, "independent": true },
    "localName": "Archikatedra pw. Świętego Stanisława Kostki",
    "commonsImage": "Lodz katedra (dron).jpg",
    "commonsCategory": "Łódź Cathedral",
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
| `popular` | Bool | – | Present only when `true`. Any category: the top 5% of **that category** by score (at least 1 when the category is non-empty), plus sights with fame ≥ 0.6; overridable in `curation.csv` (BE-3) |

Unknown fields are ignored by the decoder. A new field needs a schema update here first.

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

## 4. Naming

- POI ids: `osm:<type>:<n>`. City slugs: lowercase ASCII. Branches: `<area>/<short-name>`.
- Commit subjects: `<area>: <summary>` (AGENTS.md). Task ids: `ARC-n`, `BE-n`, `FE-n`, `OPS-n` (docs/TASKS.md).
- UI copy follows PLAN §10: sentence case, plain verbs, and the same word for the same action.
