# Notes for agents and contributors

Read [PLAN.md](PLAN.md) first: it is the spec. Work one milestone at a time and
stop for review after each. Ask before changing scope or architecture.

## Repo map

- `App/` – SwiftUI app. `project.pbxproj` is hand-written (objectVersion 77,
  synced folders); new files under `App/Wander/` are picked up automatically.
- `Packages/RouteEngine/` – Foundation-only routing package, tested with `swift test`.
- `Data/` – Python (stdlib only) POI pipeline; see `Data/README.md`.
- `scripts/` – helper scripts (`test-engine.sh` builds outside the iCloud-synced Desktop).

## Commit conventions

- One logical change per commit; keep the tree building where practical.
- Subject: `<area>: <imperative summary>` under ~72 chars.
  Areas: `app`, `engine`, `data`, `scripts`, `ci`, `docs`.
  Example: `data: score and curate POIs, export pois-<city>.json`
- Body (optional): why the change was made, anything non-obvious, and the
  milestone it belongs to (e.g. `Milestone 1`).
- Don't commit caches, build output, or `xcuserdata` (see `.gitignore`).
