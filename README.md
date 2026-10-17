# Wander

Get where you're going, but walk past the good stuff. iPhone MVP; full spec in [PLAN.md](PLAN.md).

## Layout

- `App/` – SwiftUI app (`Wander.xcodeproj`, iOS 17+)
- `Packages/RouteEngine/` – Foundation-only routing package
- `Data/` – offline Python pipeline producing `pois.json` (milestone 1)

## Commands

```sh
./scripts/test-engine.sh                 # RouteEngine tests (works with or without full Xcode)
open App/Wander.xcodeproj                # needs Xcode 16+
xcodebuild -project App/Wander.xcodeproj -scheme Wander \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Map data © OpenStreetMap contributors (ODbL).
