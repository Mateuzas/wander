# Wander

[![CI](https://github.com/Mateuzas/wander/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Mateuzas/wander/actions/workflows/ci.yml)

Get where you're going, but walk past the good stuff. iPhone MVP; full spec in [PLAN.md](PLAN.md).

## Layout

- `App/` – SwiftUI app (`Wander.xcodeproj`, iOS 17+)
- `Packages/RouteEngine/` – Foundation-only routing package
- `Data/` – offline Python pipeline producing `pois.json` (milestone 1)

## Commands

```sh
./scripts/test-engine.sh                 # RouteEngine tests (works with or without full Xcode)
scripts/install-device.sh [--launch]    # build Debug and install on the connected iPhone
python3 scripts/validate-pois.py         # check pois-*.json against docs/schema/pois.schema.json
open App/Wander.xcodeproj                # needs Xcode 16+ (tested with 27.1)
xcodebuild -project App/Wander.xcodeproj -scheme Wander \
  -destination 'generic/platform=iOS Simulator' build
```

## Docs

- [PLAN.md](PLAN.md): product spec · [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) · [docs/CONTRACTS.md](docs/CONTRACTS.md) · [docs/TASKS.md](docs/TASKS.md) · [docs/adr/](docs/adr/)
- How work is split: [AGENTS.md](AGENTS.md) (roles and ownership) and [ARCHITECT.md](ARCHITECT.md) (protocol)
- [docs/BRAND.md](docs/BRAND.md) · [docs/SECRETS.md](docs/SECRETS.md) · [docs/ROADMAP.md](docs/ROADMAP.md)

Map data © OpenStreetMap contributors (ODbL).
