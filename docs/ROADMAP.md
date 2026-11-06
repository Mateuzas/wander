# Roadmap

The MVP works end to end (Łódź field test, 2026-11-02/04). From here on we work **one feature at a time**: each
feature is briefed, built, phone-checked by the user and merged before the next one starts. The goal is quality and
fresh data, not more surface.

Ids refer to [TASKS.md](TASKS.md). Decisions are in [adr/](adr/).

## 1. Vilnius baseline and map basics (in progress)
- **BE-2:** Vilnius data; Łódź dropped (ADR 007).
- **FE-8 to FE-12:** current-location button, heading cone on your dot, places tappable during a walk, separate food icons (restaurant, café, bar, bakery, ice cream), app city set to Vilnius.

## 2. Fewer, better places on the map (feedback #8)
The map shows too many places, and quality drops. Design a selection policy before more data arrives:
- a default "worth it" layer: popular places plus the best places per area, with a much stricter score floor
- more detail only on zoom-in or through filters
- clutter measured on the phone at three zoom levels, then tuned

## 3. Route options: Direct and Recommended (feedback #5, ADR 008)
- Direct keeps its on-the-way highlights.
- Recommended: the engine decides the extra time, shaped by filters.
- The filter set is iterated with the user (FE-2 chip redesign folds in here).
- The engine API changes from a fixed budget to an engine-chosen one, with a cap.

## 4. Fresh and niche data, nightly (feedback #4, ADR 010)
Split into separate features:
1. **Nightly pipeline skeleton:** a scheduled job, a static-file host, the app downloading the file with a bundled fallback.
2. **More and newer places:** an extra open source alongside OSM (candidates: Overture Maps Places, Foursquare OS Places), with dedupe against OSM and freshness signals.
3. **Vilnius events:** scrape the agenda sites the user names, daily; event schema; events on the map with dates.
4. **Michelin Guide places** (BE-11): starred, Bib Gourmand and selected restaurants as their own layer. Check the source terms before any scraping.
5. **Source discovery for new cities:** an open problem; research later.

## 4b. Swipe walks (ADR 016) and crowd ratings (ADR 017)
- After the hooks and photos batch: choose kinds → area by time → swipe deck (love, like, nope) until the time is full →
  engine orders the walk → optional coffee or shop add-on → walk. Replaces Direct, Recommended and moods.
- Then crowd ratings: anonymous swipe counts to a small server, blended into scoring.

## 5. Perfect the engine
With fresh data in place: recommendation quality, variety, "seen" memory (FE-3), and time budgets learned from walks.

## 6. Walking: Live Activity navigation (feedback #6, ADR 009)
Dynamic Island and Lock Screen show turn arrows and distance; they expand near a place with its name and type.
Background location during walks only. This needs a widget extension target (DevOps and Frontender together).

## 7. Social "hangout" mode (ADR 011)
Accounts, saying you'll attend an event, seeing who else goes, Instagram handles. Last.

## Always on
- Accessibility and polish (FE-4).
- DevOps: Wi-Fi-aware install script (OPS-4), TestFlight when the account decision is made (ARC-2, OPS-3).
