# RouteEngine

Foundation-only route planner for Wander (PLAN.md section 6).

- Tests: `scripts/test-engine.sh` from the repo root.
- Golden routes: from this folder,
  `swift run --scratch-path ~/Library/Caches/wander/RouteEngine golden-routes [golden_routes.json] [--pois path]`
  prints a plan summary for each A→B pair in every mode, using the offline haversine provider.
  By default it reads the POI file named in `golden_routes.json`, relative to that file.
  Options: `--weights photos=1,fame=0.5` (value by signals instead of score),
  `--time 2026-11-07T14:00` (local time in the file's time zone; skips closed POIs).
  More: `--preset <name>`, `--streets` (verify on L-shaped streets), `--passes`,
  `--sequence` (one day of walks: earlier Explorer stops count as seen).
