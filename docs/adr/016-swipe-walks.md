# ADR 016: Swipe walks replace Direct and Recommended routes

**Status:** accepted (user approved building it, 2026-11-07; iterated in two rounds; open points resolved by the Architect below). Supersedes ADR 008 (Direct + Recommended) and the moods
(FE-18). Builds on ADR 015: every card has a photo and a hook, so places can be judged at a glance.

## The flow

1. **What's this walk:** the user picks the kinds of places to swipe: Sights, Food, Shops, Hidden gems (multi-select).
2. **Area:** a time preset (30 min, 1 h, 2 h) plus a map circle the user can adjust. End: **anywhere** (the walk ends
   at the last place) or **a destination** (picked with "Where to?"; the area becomes a band between the user and the
   destination, sized by the time). The start is always the user's location (or a dropped pin).
3. **Swipe deck:** cards show photo, name, hook and walking minutes from the start.
   - **Gestures and buttons:** left = nope, right = like, up = love.
   - **Order:** must-see first, then notable, spread across the area (not one street), adjusted by the user's swipe
     memory.
   - **Dealing stops automatically** when the estimated walk of loved + liked places fills the chosen time; a live
     counter ("38 of 60 min") shows progress. "Done" ends earlier.
4. **The walk:**
   - every loved place is included; if they don't fit, the walk stretches and says so ("Your loved places need
     1 h 20; walk extended")
   - liked places fill the remaining time, best first
   - the engine orders the stops into the shortest sensible walk (with the end constraint)
   - optional add-ons "Add coffee" / "Add a shop" insert the best open candidate where it adds the least time (the food
     nearby pick rules)
   - summary: "1 h 05 · 3 loved · 3 liked"; then "Start walk"
5. **Walking mode:** unchanged (turn card, Up ahead nudges, reroute, arrival).

## Removed
Direct and Recommended routes, the mood row, Relaxed/Explorer remnants. Plain directions go to Google Maps or Apple Maps
via the existing hand-off. Search stays, to set a destination or find a place.

## Swipe memory (on the phone)
Reactions are stored locally per place id with a date. A nope hides the place from decks for 90 days. Loved and liked
kinds and types boost similar places in future deck ordering. A loved or liked place that was walked counts as "seen"
(engine `seen`). No account. Crowd sharing is a separate decision (ADR 017).

## Engine changes (RouteEngine, Backender)
- New planning entry point: `plan(start:, end: .anywhere | .destination(Coordinate), mustVisit: [POI], optional: [POI],
  budget:, provider:)`. Every must-visit place is included (the budget stretches), optional places are added best value
  per minute until the budget, and the order comes from a deterministic heuristic (nearest insertion + 2-opt), verified
  with real legs as today.
- Add-on insertion: `insertCheapest(poi, into: plan)`.
- Deck support (pure, testable): `deck(area:, kinds:, memory:) -> [POI]` ordered as above, and
  `estimateMinutes(selection:)` for the live counter (haversine with the existing tortuosity, refined after real legs).
- `PlannerConfig` keeps the time and walking constants; the value-per-minute logic stays for ranking optional places.

## Resolved by the Architect (2026-11-07; easy to revisit after the phone test)
- **Place card and food nearby:** "Directions" becomes **"Walk here"**: a walk with `end = destination(place)` and no swipes (the same
  engine, not the old Direct mode). While a swipe walk is being built, the card offers **"Add to walk"**
  (`mustVisit`). Google/Apple Maps hand-off stays.
- **Undo:** one level ("Undo last swipe").
- **Too few places:** when the deck runs out before the time is full: "That's everything worth seeing here", plus
  "Widen the area".
- **Presets:** 30 min (circle ≈ 600 m), 1 h (≈ 1 km), 2 h (≈ 1.6 km); adjustable 300 m to 3 km. A destination gives a
  band ±(radius/2) around the start–destination line.
- **Hidden gems** kind: tier 2–3, independent, quality ≥ 0.6, fame < 0.3, any category.
- **Time shown:** walking time (no dwell estimate in v1), so "1 h" means about an hour of walking between stops.
