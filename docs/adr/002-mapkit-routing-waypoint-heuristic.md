# ADR 002: MapKit walking routes plus a waypoint heuristic in a Foundation-only engine

**Status:** accepted (PLAN §2, §6).

**Decision.** Routes are normal MKDirections walking routes through up to 3 (Relaxed) or 5 (Explorer)
chosen stops. Stop selection is an offline orienteering heuristic in `RouteEngine`, which never imports
MapKit; real routing comes through the `WalkingTimeProvider` protocol.

**Why.** No routing server, and the engine stays testable with `swift test`. **Cost:** street character
between stops isn't controlled. A self-hosted router (GraphHopper or Valhalla) is a v2 option.
