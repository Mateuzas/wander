import Foundation

/// Plans Wander routes (PLAN.md section 6).
public struct Planner: Sendable {
    public var config: PlannerConfig

    public init(config: PlannerConfig = .default) {
        self.config = config
    }

    /// Builds a plan. Real routing goes only through `provider`; detours are
    /// estimated offline with `config.estimator`.
    public func plan(_ request: PlanRequest, provider: WalkingTimeProvider) async throws -> WanderPlan {
        let scorer = Scorer(config: config, interests: request.interests, weights: request.weights)

        // 1. Baseline.
        let baseline = try await provider.leg(from: request.origin, to: request.destination)

        // 2–3. Freebies and corridor.
        let filtered = CandidateFilter(config: config, scorer: scorer).filter(request, baseline: baseline)

        // 4. Choose the most valuable waypoint set on estimates.
        let maxWaypoints = request.maxWaypoints ?? config.maxWaypoints
        let inserted = WaypointSelector(config: config, scorer: scorer).run(
            origin: request.origin, destination: request.destination,
            candidates: filtered.candidates, budget: request.budget, maxWaypoints: maxWaypoints)

        // 5–6. Verify with real routing, fall back to the baseline.
        let verified = try await Validator(config: config, scorer: scorer).verify(
            origin: request.origin, destination: request.destination,
            waypoints: inserted.waypoints, baseline: baseline,
            budget: request.budget, provider: provider)

        let totalTime = verified.legs.reduce(0) { $0 + $1.duration }
        var plan = WanderPlan(
            baseline: baseline, waypoints: verified.waypoints, legs: verified.legs,
            totalTime: totalTime, extraTime: totalTime - baseline.duration,
            highlights: [], noDetourFit: request.budget > 0 && verified.waypoints.isEmpty,
            candidates: [])

        // Highlights: waypoints plus pass-by POIs along the final route.
        let line = MeasuredPolyline(plan.polyline, projection: LocalProjection(origin: request.origin))
        let waypointIDs = Set(verified.waypoints.map(\.id))
        var passbyIDs: Set<String> = []
        for poi in request.pois where request.interests.contains(poi.category)
            && filtered.rejected[poi.id] != .closed {
            let near = line.nearest(to: poi.coordinate)
            if waypointIDs.contains(poi.id) {
                plan.highlights.append(Highlight(poi: poi, role: .waypoint,
                                                 distanceAlongRoute: near.along, distanceFromRoute: near.distance))
            } else if near.distance <= config.passbyRadius {
                passbyIDs.insert(poi.id)
                plan.highlights.append(Highlight(poi: poi, role: .passby,
                                                 distanceAlongRoute: near.along, distanceFromRoute: near.distance))
            }
        }
        plan.highlights.sort {
            ($0.distanceAlongRoute, $0.poi.id) < ($1.distanceAlongRoute, $1.poi.id)
        }

        // Debug record per POI.
        let freebieIDs = Set(filtered.freebies.map(\.poi.id))
        let droppedIDs = Set(verified.dropped.map(\.id))
        plan.candidates = request.pois.map { poi in
            let status: CandidateStatus
            if waypointIDs.contains(poi.id) {
                status = .waypoint
            } else if passbyIDs.contains(poi.id) {
                status = .passby
            } else if let reason = filtered.rejected[poi.id] {
                status = .rejected(reason)
            } else if freebieIDs.contains(poi.id) {
                status = .rejected(.bypassedByDetour)
            } else if droppedIDs.contains(poi.id) {
                status = .rejected(.failedVerification)
            } else {
                status = .rejected(inserted.rejected[poi.id] ?? .overBudget)
            }
            return CandidateDebug(poi: poi, value: scorer.value(poi),
                                  estimatedExtraTime: inserted.bestExtra[poi.id], status: status)
        }
        return plan
    }
}

/// Tunable planner constants (PLAN.md section 6).
public struct PlannerConfig: Hashable, Sendable {
    /// Metres. A POI this close to the route is a free highlight, whatever its kind.
    public var passbyRadius: Double = 40
    /// Waypoints when the request doesn't say (`PlanRequest.maxWaypoints`).
    public var maxWaypoints: Int = 3
    /// 0–100. A POI must be worth at least this much to bend the route for it
    /// (PLAN.md section 3: no stops that are clearly not worth it). Free
    /// highlights on the route are not affected.
    public var minWaypointValue: Double = 35
    /// Metres between any two chosen waypoints.
    public var minWaypointSpacing: Double = 150
    /// Waypoints of one category.
    public var maxPerCategory: Int = 2
    /// Tighter per-category caps for variety: by default one food stop per walk,
    /// so the same few top-scoring restaurants don't take two of three slots.
    /// Waived when the request's interests are only that category.
    public var categoryLimits: [POICategory: Int] = [.food: 1]
    /// Degrees. A leg whose heading differs from the A→B heading by more than
    /// this counts as backtracking.
    public var maxLegDeviation: Double = 120
    /// Metres. Shorter legs are not checked for backtracking (headings are noisy).
    public var minLegForBacktrackCheck: Double = 100
    /// Real routing may exceed the budget by this fraction before dropping a waypoint.
    public var verificationTolerance: Double = 0.1
    public var maxVerificationRetries: Int = 2
    /// Seconds. Floor for extra time in `value / extraTime` (used to pick which
    /// waypoint to drop when verification fails), so POIs right on
    /// the route don't get an infinite ratio.
    public var minExtraTimeForRatio: TimeInterval = 30
    /// Partial waypoint sets kept per step of the selection search. Higher is
    /// closer to the best set and slower.
    public var beamWidth: Int = 16
    /// Offline estimator for the corridor filter and insertion.
    public var estimator: HaversineWalkingTime = HaversineWalkingTime()

    public static let `default` = PlannerConfig()

    /// Waypoint cap for `category` given the request's interests and how many
    /// waypoints the plan may have. With more slots the cap grows (3 of 5), so
    /// a long walk isn't forced to fill slots with categories it values less.
    func waypointCap(for category: POICategory, interests: Set<POICategory>, maxWaypoints: Int) -> Int {
        let base = max(maxPerCategory, (maxWaypoints + 1) / 2)
        guard interests != [category], let limit = categoryLimits[category] else { return base }
        return min(base, limit)
    }

    public init() {}
}
