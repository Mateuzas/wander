import Foundation
import RouteEngine

/// Adds a user-chosen stop to an existing plan (PLAN.md §7.3 follow-up, M4 brief item 6).
///
/// RouteEngine has no input for "this POI must be a waypoint", so this inserts
/// it at the cheapest position, routes the changed legs for real, and keeps it
/// only if the walk stays within Recommended's limits: the engine's
/// `recommendedMaxExtra` cap (with its verification tolerance) and 5 stops.
enum PlanEditor {
    enum Outcome {
        case added(WanderPlan)
        case doesntFit
        case full
    }

    static var config: PlannerConfig { .default }

    /// Most stops a Recommended walk may have (contract: "at most 5 stops").
    static var maxStops: Int { Mode.recommended.maxWaypoints }

    /// Cheapest insertion index for `poi` among the plan's waypoints, and its
    /// estimated extra seconds (haversine, like the engine's estimate).
    static func bestInsertion(of poi: POI, in plan: WanderPlan) -> (index: Int, extra: TimeInterval) {
        let estimator = config.estimator
        let stops = [plan.baseline.from] + plan.waypoints.map(\.coordinate) + [plan.baseline.to]
        var best = (index: 0, extra: TimeInterval.infinity)
        for i in 0..<(stops.count - 1) {
            let a = stops[i], b = stops[i + 1]
            let extra = estimator.seconds(from: a, to: poi.coordinate) + estimator.seconds(from: poi.coordinate, to: b)
                - estimator.seconds(from: a, to: b)
            if extra < best.extra { best = (i, extra) }
        }
        return best
    }

    /// Real-time limit for a Recommended plan: baseline plus the recommended
    /// cap, with the engine's verification tolerance.
    static func limit(for plan: WanderPlan) -> TimeInterval {
        plan.baseline.duration + config.recommendedMaxExtra * (1 + config.verificationTolerance)
    }

    /// Quick offline check, for deciding whether to offer "Add to walk".
    static func estimateFits(_ poi: POI, in plan: WanderPlan) -> Bool {
        plan.totalTime + bestInsertion(of: poi, in: plan).extra <= limit(for: plan)
    }

    static func adding(_ poi: POI, to plan: WanderPlan, pois: [POI],
                       interests: Set<POICategory>, provider: WalkingTimeProvider) async throws -> Outcome {
        guard plan.waypoints.count < maxStops else { return .full }
        var waypoints = plan.waypoints
        waypoints.insert(poi, at: bestInsertion(of: poi, in: plan).index)

        let stops = [plan.baseline.from] + waypoints.map(\.coordinate) + [plan.baseline.to]
        var legs: [Leg] = []
        for i in 1..<stops.count {
            legs.append(try await provider.leg(from: stops[i - 1], to: stops[i]))
        }
        let total = legs.reduce(0) { $0 + $1.duration }
        guard total <= limit(for: plan) else { return .doesntFit }

        var result = WanderPlan(
            baseline: plan.baseline, waypoints: waypoints, legs: legs, totalTime: total,
            extraTime: total - plan.baseline.duration, highlights: [], noDetourFit: false,
            candidates: plan.candidates.map { record in
                var record = record
                if record.poi.id == poi.id { record.status = .waypoint }
                return record
            })
        result.highlights = highlights(along: result.polyline, waypoints: waypoints, pois: pois, interests: interests)
        return .added(result)
    }

    /// Waypoints plus POIs within the pass-by radius of `line`, ordered along it.
    static func highlights(along line: [Coordinate], waypoints: [POI], pois: [POI],
                           interests: Set<POICategory>) -> [Highlight] {
        let waypointIDs = Set(waypoints.map(\.id))
        var result: [Highlight] = []
        for poi in pois where interests.contains(poi.category) || waypointIDs.contains(poi.id) {
            let near = RouteGeometry.nearest(poi.coordinate, on: line)
            if waypointIDs.contains(poi.id) {
                result.append(Highlight(poi: poi, role: .waypoint, distanceAlongRoute: near.along, distanceFromRoute: near.distance))
            } else if near.distance <= config.passbyRadius {
                result.append(Highlight(poi: poi, role: .passby, distanceAlongRoute: near.along, distanceFromRoute: near.distance))
            }
        }
        return result.sorted { ($0.distanceAlongRoute, $0.poi.id) < ($1.distanceAlongRoute, $1.poi.id) }
    }
}
