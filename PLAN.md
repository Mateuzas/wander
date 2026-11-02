# Wander (working title): iPhone MVP plan

A walking map for tourists. It works like any map app (pick a destination, get a route), but instead of only the fastest route it offers routes that pass interesting things: photo spots, independent shops, food places. It also keeps the user looking up while walking.

This document is meant to be handed to a coding agent. Sections 1-3 are the "why and what", 4-9 are the build spec, 10 is the design spec, 11-12 are milestones and a kickoff prompt.

---

## 1. Product definition

**One-line pitch:** Get where you're going, but walk past the good stuff.

**Target user:** A tourist on foot in a city they don't know, going to a specific destination, with no tight deadline.

**Core insight:** Tourists navigate heads-down in the phone and miss what's around them. The product has two jobs:
1. Plan a route that passes interesting places within a time budget the user chooses.
2. While walking, surface what's nearby so the user looks up.

**Differentiator:** It is not a trip planner. The user already knows where they're going. We make the walk there better.

### MVP scope (in)
- One city, curated POI data bundled in the app (no backend)
- Destination search, current location as the start by default
- Three modes: Direct, Relaxed, Explorer (detour budgets)
- Route comparison: fast route vs Wander route, shown on the map with a plain summary
- Walking mode: live position, next turn, "up ahead" nudges for nearby highlights
- Hand-off to Google Maps / Apple Maps for full turn-by-turn if the user prefers

### MVP scope (out, deliberately)
- Multiple cities, accounts, backend, sync
- Reviews/ratings from paid APIs (Google Places etc.)
- Safety/"shady street" avoidance (unreliable data, ethically messy; revisit as "prefer lively streets" later)
- Voice guidance, background location, Apple Watch, Android
- Personalization beyond a simple interest filter

---

## 2. Key technical decisions (and why)

| Decision | Choice | Reason |
|---|---|---|
| Platform | Native iOS, SwiftUI, iOS 17+ | Only device available; SwiftUI MapKit API (iOS 17) is enough |
| Map + routing | Apple MapKit (`MKDirections` walking) | Free, no API key, good walking routes, no server to run |
| Backend | None for MVP | POI data for one city is a few thousand rows; bundle it as JSON. Removes ops work entirely |
| POI data | OpenStreetMap + Wikidata + Wikimedia Commons photo density | Free, open, enough for photo spots and independent shops |
| Routing approach | Candidate-waypoint orienteering heuristic on top of normal walking routes | Far simpler than modifying a routing graph, good enough to validate the idea |
| Dependencies | None third-party | Fewer moving parts for a solo dev |

**Why not a custom routing graph now:** The "right" long-term solution is a self-hosted engine (GraphHopper custom models or Valhalla) where street quality and POI proximity are edge weights. That's a v2 project. The waypoint approach lets us test whether people want these routes before we build infrastructure.

**Known limitation of this approach:** `MKDirections` chooses the path between waypoints, so we can't control street character (lively vs. dull) between them. Acceptable for MVP.

**Environment note:** iOS builds need macOS + Xcode. Run the coding agent locally on the Mac, not in a Linux sandbox. Real-device testing needs the iPhone connected (free provisioning works but expires every 7 days; the paid Apple Developer account at $99/yr is needed for TestFlight).

---

## 3. Success criteria for the MVP

Quantitative (checked on 10 real A→B walks in the pilot city):
- Explorer route stays within budget ±10% of the stated extra time
- Explorer routes include at least 2 highlights on at least 8 of 10 pairs
- No route includes a waypoint that is unreachable on foot or clearly not worth it (zero tolerance, this is the trust-killer)

Qualitative (field test with 3-5 people):
- After the walk, ask: "Did you see something you would have missed?"
- Ask: "Would you choose this over the fast route next time?"
- Track how often testers pick Relaxed/Explorer over Direct

If testers don't pick the Wander route, the idea needs rethinking before any more building.

---

## 4. Architecture

```
┌────────────────────────── iPhone app ──────────────────────────┐
│                                                                │
│  Views (SwiftUI)                                               │
│    MapScreen · PlanSheet · WalkCard · HighlightList            │
│        │                                                       │
│  State (@Observable)                                           │
│    PlannerModel · WalkModel                                    │
│        │                                                       │
│  Services                                                      │
│    LocationService   (CoreLocation)                            │
│    SearchService     (MKLocalSearch)                           │
│    WalkingTimeProvider  ◄── protocol                           │
│        ├─ MapKitWalkingTime   (MKDirections, used in app)      │
│        └─ HaversineWalkingTime (fast, offline, used in tests)  │
│    POIStore          (loads bundled pois.json)                 │
│        │                                                       │
│  RouteEngine (pure Swift package, no UIKit/MapKit imports)     │
│    CandidateFilter · Scorer · GreedyInserter · Validator       │
│                                                                │
└────────────────────────────────────────────────────────────────┘

Offline data pipeline (Python, run on the Mac, output committed to repo):
  Overpass/OSM ─► enrich (Wikidata, Commons) ─► score ─► pois.json
```

**Important design rule:** `RouteEngine` must be a standalone Swift package that depends only on Foundation. It takes coordinates, POIs and a `WalkingTimeProvider`, and returns a plan. That makes it unit-testable with `swift test` from the command line, with no simulator and no network.

### Suggested repo layout
```
wander/
  Data/
    fetch_osm.py
    enrich.py
    score.py
    curation.csv          # manual exclude/boost overrides
    pois.json             # generated, bundled into the app
  Packages/
    RouteEngine/          # Swift package + tests
  App/
    Wander.xcodeproj
    Wander/
      DesignSystem/       # colors, type, components
      Models/
      Services/
      Views/
      Resources/pois.json
  PLAN.md
```

---

## 5. Data pipeline (Python, offline)

Pick **one pilot city**. Your own home city is the easiest to test in repeatedly, but you also need real "tourist" ground truth, so ideally the city where this idea came from. Start with the one you can walk in most often.

### 5.1 Fetch from OSM (Overpass API)
Within the city's bounding box, pull nodes/ways/relations with:

| Category | OSM tags |
|---|---|
| photo | `tourism=attraction\|viewpoint\|artwork\|museum\|gallery`, `historic=*`, `man_made=tower\|lighthouse\|bridge` (notable only), `leisure=park` (named, large), `natural=*` viewpoints |
| shop | `shop=*` (exclude supermarkets/convenience/chemist etc.), prefer those **without** `brand` or `brand:wikidata` |
| food | `amenity=cafe\|restaurant\|bar\|ice_cream\|pub`, `shop=bakery\|pastry\|deli` with `name`, no `brand` |

Keep: `osm_id`, `name`, `lat/lon` (centroid for ways), `category`, tags needed for scoring, `wikidata`, `wikipedia`, `opening_hours`, `website`.
Drop anything without a `name`.

### 5.2 Enrich
- **Wikidata:** for entries with a `wikidata` tag, fetch the number of sitelinks (a good "how famous is this" signal).
- **Wikimedia Commons:** geosearch for files within ~50 m of each POI; the count is the photo-density signal. (Avoid Flickr for a commercial product: its API terms restrict commercial use.)

### 5.3 Score (0-100)
Start simple and tunable. Put the weights in one config at the top of `score.py`.

```
landmark  = log-scaled sitelinks + bonus for tourism/historic tags
photo     = percentile rank of Commons file count within the city
unique    = 1 if no brand/brand:wikidata tag else 0   (shops, food)
quality   = data completeness (has opening_hours, website, cuisine...)

photo cat : 0.45*photo + 0.45*landmark + 0.10*quality
shop cat  : 0.50*unique + 0.30*quality + 0.20*photo
food cat  : 0.50*unique + 0.30*quality + 0.20*photo
```

**Be honest about food/shops:** OSM cannot tell you whether a café is *good*, only that it's independent and well-mapped. That's a known MVP weakness, which is why the next step exists.

### 5.4 Manual curation (do not skip)
Sort by score, review the top ~300 by hand. Add rows to `curation.csv`:
```
osm_id, action (exclude|boost|rename), value, note
```
Remove junk (parking-lot "attractions", closed places, duplicates), boost the true gems, and write a short human `reason` for the top items ("Street art, popular photo spot"). Quality beats coverage; this hour of curation is worth more than any weight tuning.

### 5.5 Output schema (`pois.json`)
```json
{
  "city": "Vilnius",
  "generated": "2026-10-20",
  "pois": [
    {
      "id": "osm:node:123",
      "name": "Name",
      "lat": 54.68,
      "lon": 25.28,
      "category": "photo",
      "score": 82,
      "kind": "passby",
      "reason": "Short human-readable reason",
      "type": "mural",
      "signals": { "photos": 0.82, "fame": 0.40, "quality": 0.6, "independent": true },
      "cuisine": ["italian"],
      "openingHours": "Mo-Sa 10:00-20:00"
    }
  ]
}
```
`kind`: `passby` (visible from the street, costs no dwell time: landmarks, murals, viewpoints) or `stop` (shops and food, optional to enter).

Additions agreed after the first data run (2026-11-02):
- One file per city: `pois-<city>.json` (Łódź first, then Vilnius).
- `name` is English for sights (reviewed in `Data/names-en/<city>.csv`); shops and food keep their own names.
- `type`: most specific OSM value (`mural`, `museum`, `church`, `cafe`, `books`, …).
- `signals`: raw 0–1 inputs so the app can weight them **per user** (e.g. photo hunter vs. classic sightseer vs. hidden gems). `photos` = Commons photo-density percentile in the city, `fame` = log-scaled Wikipedia sitelinks, `quality` = OSM data completeness, `independent` = no brand tag. `score` stays as the default blend. A `rating` signal is reserved for later; no free source has ratings, and Google's terms forbid storing them.
- Optional: `cuisine` (food only), `openingHours` (raw OSM syntax, shops and food only).

### 5.6 Licensing
OSM data is ODbL: show "© OpenStreetMap contributors" in the app (about screen is fine). Apple Maps attribution is handled by MapKit.

---

## 6. The route algorithm (RouteEngine)

### Inputs
- `origin`, `destination` (coordinates)
- `budget` (extra minutes allowed): Direct = 0, Relaxed = 10, Explorer = 25 (constants, easy to tune)
- `interests`: set of categories (default: all)
- `pois`: array from the store
- `time`: current local time (to drop shops/food outside simple opening windows)
- `provider`: a `WalkingTimeProvider`

### Output
`WanderPlan`: ordered waypoints, per-leg routes (polyline + steps), total time, extra time vs. baseline, highlights (POIs passed or visited).

### Steps
1. **Baseline.** Ask the provider for the walking route origin→destination. This gives `T0` and the fast polyline.
2. **Pass-by freebies.** Any `passby` POI within ~40 m of the baseline polyline is already on the route. Mark it as a highlight at zero cost (this alone often makes Direct mode feel smarter).
3. **Corridor filter.** Keep candidates where the straight-line estimate satisfies
   `(d(A,p) + d(p,B) − d(A,B)) × 1.3 / walkingSpeed ≤ budget`
   (1.3 = rough street tortuosity, walking speed ≈ 1.35 m/s). Cheap, no network.
4. **Greedy insertion** (cost-benefit heuristic for the orienteering problem):
   - Maintain `route = [A, B]`.
   - For each candidate and each insertion position, estimate the extra time using the haversine provider.
   - Pick the (candidate, position) with the best `value / extraTime` where `value = score × interestWeight`.
   - Insert it if total estimated time ≤ `T0 + budget`. Repeat.
   - Constraints: max 3 waypoints (keeps routes sane and Google Maps hand-off simple), min 150 m between chosen waypoints, max 2 of the same category, no waypoint that makes the route backtrack more than 60° against the A→B direction.
5. **Verify with real routing.** Run `MapKitWalkingTime` for each leg (A→w1, w1→w2, …, wn→B). If the real total exceeds `T0 + budget × 1.1`, drop the waypoint with the lowest `value / extraTime` and re-verify (max 2 retries).
6. **Fall back gracefully.** If nothing fits, return the baseline route with the freebies and a flag `noDetourFit = true`.

### API-limit note
`MKDirections` is rate-limited (on the order of 50 requests/minute at time of writing; verify in current Apple docs). Steps 3-4 use only offline math; real requests happen only in steps 1 and 5, so a plan costs about 4-6 requests.

### Testing (required)
- Unit tests with synthetic grids and fixed POIs using `HaversineWalkingTime`:
  - budget 0 returns baseline, never adds waypoints
  - respects max waypoints, min spacing, category cap
  - never exceeds budget (property-style test with random inputs)
  - deterministic: same input gives same output
- **Debug overlay in the app:** a developer toggle that draws all candidate POIs, their scores, and which were chosen/rejected (with the reason). This is how you'll tune the algorithm by eye.
- Keep a `golden_routes.json` of ~10 real A→B pairs from the pilot city and print a summary table of each plan for manual review.

---

## 7. Screens and flows

### 7.1 Map (home)
- Full-bleed map, muted style, user location dot
- Bottom sheet with search field "Where to?"; recent destinations below
- No tab bar, no navigation bar

### 7.2 Plan (destination chosen)
- Sheet shows the destination name
- Mode control: **Direct / Relaxed / Explorer** with minutes ("+0 min", "+10 min", "+25 min")
- Result summary, plain language: "24 min total · 12 min more than direct · 4 highlights"
- Map shows the fast route (thin, dashed, grey) and the Wander route (thick, solid, accent) with a bead on each highlight
- Interest chips (all on by default): Sights, Shops, Food
- Primary button: **Start walk**
- Secondary: **Open in Google Maps** / **Open in Apple Maps**

### 7.3 Highlight list (sheet expanded)
Each row: category glyph, name, one-line reason, distance along the route. Tapping a row focuses the map on it. Swipe to remove a highlight; the route recalculates.

### 7.4 Walking mode
- Top card (always visible): next turn instruction and distance (from `MKRoute.Step`)
- "Up ahead" card appears when a highlight is within ~60 m ahead: name, reason, "on your left/right" if computable from heading, **Skip** action. At most one nudge at a time, never repeated for the same POI
- Light haptic when a nudge appears. No sound
- Screen stays awake during the walk (`isIdleTimerDisabled`), "When in use" location permission only
- **Reroute** if the user is more than ~50 m off route; **End walk** button
- Arrival state: "You've arrived at {name}."

### 7.5 Settings / about (minimal)
Units, interest defaults, attribution, version, a "Send feedback" mail link.

### Empty and error states
- No detour fits: "Nothing interesting fits this time. Try Explorer for a longer detour."
- No route: "Couldn't find a walking route to this place. Try a different destination."
- Location denied: "Wander needs your location to start from where you are. You can still pick a start point on the map."
- Offline: "No connection. Routes need internet; saved places still show."

---

## 8. Permissions and platform details
- `NSLocationWhenInUseUsageDescription`: "Wander uses your location to plan walks from where you are and to show what's nearby."
- No background modes in the MVP
- Support Dark Mode, Dynamic Type, VoiceOver, Reduce Motion
- Min iOS 17. Check the target iPhone's iOS version in Settings > General > About before starting
- Swift 5.9+, `@Observable` macro, SwiftUI `Map` with `MapPolyline` and `Annotation`

---

## 9. Hand-off links
Google Maps URL (supports waypoints; verify the current waypoint limit in Google's Maps URLs docs):
```
https://www.google.com/maps/dir/?api=1
  &origin={lat,lon}&destination={lat,lon}
  &waypoints={lat,lon}|{lat,lon}&travelmode=walking
```
Apple Maps hand-off supports a destination only, so the Apple Maps option opens the first leg. Say so in the UI ("Opens the first stop").

---

## 10. Design spec

Direction: **quiet, glanceable, heads-up.** The map is the product, so the UI stays out of its way. One memorable element: the **Wander route with its beads**, a bold line with small category beads strung along it, drawn in as a single motion when a plan appears. Everything else is calm and disciplined.

### Why not the usual look
Default generated apps cluster around cream + serif + terracotta, or black + neon accent, or identical rounded cards with soft shadows. A map app has a more specific constraint: its colors must not collide with the base map and must not be confused with the blue "navigation route" that people already know. So the route color is **violet-indigo, deliberately not blue**, so it reads as "something different from the fast route."

### Color tokens
| Token | Light | Dark | Role |
|---|---|---|---|
| `surface` | #F3F5F6 | #161B22 | Sheet background |
| `surfaceRaised` | #FFFFFF | #1F2630 | Cards, selected control |
| `ink` | #18212C | #EDF0F3 | Primary text |
| `inkMuted` | #5E6A78 | #9AA6B4 | Secondary text, fast route line |
| `wander` | #5B3DF5 | #8C7BFF | Wander route, primary button, selection |
| `sights` | #E9A21B | #F2B53D | Photo/sight beads |
| `shops` | #1C9E8B | #35BBA7 | Shop beads |
| `food` | #E5532D | #F06A45 | Food beads |

Rules:
- Category colors appear **only** on beads and their glyphs, never as large fills, which keeps the route as the loudest thing on screen.
- Fast route vs Wander route are distinguished by **line style as well as color** (thin dashed vs thick solid), so they stay distinguishable for color-blind users.
- Use a muted base map: `.mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))` so only *our* highlights show, not Apple's POIs.
- Text contrast at least 4.5:1 against its background in both themes.

### Typography
- One family: **Instrument Sans** (open license; bundle the variable font), falling back to SF Pro. Use `Font.custom(_, size:, relativeTo:)` so Dynamic Type works.
- Numerals: tabular figures for minutes and distances so they don't jump while updating.
- No all-caps labels, no eyebrow text above headings, sentence case everywhere.

| Style | Size / weight | Use |
|---|---|---|
| Stat | 34 / 600, tabular | Total minutes in the plan summary |
| Title | 24 / 600 | Destination name |
| Heading | 18 / 600 | Highlight names |
| Body | 16 / 400 | Reasons, instructions |
| Caption | 13 / 500 | Distances, secondary details |

Line length under ~70 characters (it's a phone; this mostly takes care of itself).

### Layout
- Everything left-aligned. Map full-bleed under the sheet.
- Bottom sheet with three detents: peek (~120 pt, search or summary), medium (~45%), large (list).
- Sheet corner radius is the system default; do not add shadows or borders on cards. Separate rows with spacing, not dividers. Use one divider only above the primary button area if needed.
- 16 pt screen margins, 8 pt spacing grid, minimum 44 × 44 pt touch targets.

```
Plan state (medium detent)
┌──────────────────────────────┐
│          [ map ]             │
│   ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄       │  fast: thin, dashed, grey
│   ━━●━━━━●━━━━●━━━━━━        │  wander: thick, violet, beads
│                              │
├──────────────────────────────┤
│  Old Town Hall               │
│  Direct   Relaxed  Explorer  │  segmented control
│  +0 min   +10 min  +25 min   │
│                              │
│  36 min                      │  stat
│  12 more than direct         │
│  4 highlights                │
│                              │
│  [        Start walk       ] │
│  Open in Google Maps         │
└──────────────────────────────┘

Walking state
┌──────────────────────────────┐
│ ↰  Turn left onto Pylimo     │  top card: next step, distance
│    120 m                     │
│                              │
│          [ map ]             │
│                              │
│ ┌──────────────────────────┐ │
│ │ ● Mural on Stiklių       │ │  nudge card, only when relevant
│ │   Street art · on your   │ │
│ │   right, 40 m   [Skip]   │ │
│ └──────────────────────────┘ │
└──────────────────────────────┘
```

### Components
- **Segmented control:** three options, selected pill uses `surfaceRaised` with `wander` text; no heavy fills.
- **Primary button:** full-width, `wander` fill, white text, 52 pt tall, label "Start walk". One primary button per screen.
- **Bead:** 22 pt circle, category color fill, white SF Symbol glyph (`camera`, `bag`, `fork.knife`). Selected: scales to 30 pt with a white ring.
- **Highlight row:** bead glyph, name (Heading), reason (Body, muted), distance (Caption, trailing).
- **Nudge card:** raised surface, bead on the left, two lines of text, one text button.

### Motion (use sparingly)
- **One signature moment:** when a plan is computed, the Wander line draws from start to destination (trim animation, ~0.9 s), and each bead pops in as the line passes it. Nothing else animates on its own.
- Motion that answers a touch is fine: sheet detent changes, bead selection, nudge card slide in/out.
- Respect Reduce Motion: replace the draw-in with a simple fade.

### Copy rules
- Plain verbs, sentence case, no filler or apologies in errors; say what happened and what to do.
- Same word for the same action everywhere: "Start walk" starts a "walk"; ending shows "Walk ended".
- Highlight reasons are short, concrete, human ("Street art, popular photo spot"), never marketing.
- Suggested button/label set: "Where to?", "Direct", "Relaxed", "Explorer", "Start walk", "End walk", "Skip", "Open in Google Maps".

### Accessibility
VoiceOver labels on every bead and card ("Photo spot, Mural on Stiklių, 40 metres ahead on your right"), Dynamic Type up to AX3 without clipped text, Reduce Motion, haptics are additive (never the only signal).

---

## 11. Milestones (rough, solo, part-time)

| # | Milestone | Done when | Est. |
|---|---|---|---|
| 0 | Setup | Xcode project runs on the iPhone; repo layout in place | 1 day |
| 1 | Data pipeline | `pois.json` generated for the pilot city; top 300 reviewed with curation file | 3-4 days |
| 2 | RouteEngine package | `swift test` passes; golden routes print plausible plans using the haversine provider | 3-4 days |
| 3 | App shell | Map, location, destination search, design tokens and fonts in place | 3 days |
| 4 | Planning UI | Real plans via MapKit; compare fast vs Wander routes; mode switch; highlight list; debug overlay | 4-5 days |
| 5 | Walking mode | Live progress, next-turn card, nudges, reroute, end walk | 4-5 days |
| 6 | Polish + field test | Dark mode, accessibility pass, empty/error states, 3-5 real walks with testers, notes collected | 1-2 weeks |

About 4-6 weeks part-time. **Gate after milestone 2:** look at the golden routes honestly. If the plans don't look like walks you'd want, fix the scoring/data before building any UI.

---

## 12. Kickoff prompt for the coding agent

> Build the iPhone app described in `PLAN.md`, one milestone at a time, starting with milestone 0. Constraints: SwiftUI, iOS 17+, no third-party dependencies, MapKit for map and walking routes, `RouteEngine` as a standalone Swift package with unit tests that run via `swift test`. Follow section 10 for all visual decisions (tokens, type, layout, copy) and do not add styling beyond it. After each milestone: run the tests, build for the simulator, list what works and what doesn't, and stop so I can review before the next milestone. Ask me before making any decision that changes scope or architecture. For milestone 1, write the Python pipeline but let me choose the pilot city first.

---

## 13. Open questions to settle before building
1. Pilot city (decides the OSM bounding box and where you test).
2. App name (working title "Wander"; check App Store and domain availability before attaching to it).
3. Whether to publish via TestFlight (needs the paid developer account) or keep it on your own phone for the first rounds.
