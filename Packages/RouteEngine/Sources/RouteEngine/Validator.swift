import Foundation

/// Real-route verification (PLAN.md section 6, step 5). All routing goes
/// through the `WalkingTimeProvider`, via a `LegStore`.
struct Validator {
    var config: PlannerConfig
    var scorer: Scorer

    struct Result {
        var waypoints: [POI]
        var legs: [Leg]
        /// Waypoints dropped because real routing went over budget.
        var dropped: [POI]
    }

    func verify(origin: Coordinate, destination: Coordinate, waypoints: [POI], baseline: Leg,
                budget: TimeInterval, store: LegStore, taken: TakenStops = TakenStops()) async throws -> Result {
        guard !waypoints.isEmpty else { return Result(waypoints: [], legs: [baseline], dropped: []) }

        let limit = baseline.duration + budget * (1 + config.verificationTolerance)
        var kept = waypoints
        var dropped: [POI] = []

        for attempt in 0...config.maxVerificationRetries {
            let legs = try await store.legs(origin: origin, waypoints: kept, destination: destination)
            let total = legs.reduce(0) { $0 + $1.duration }
            if total <= limit { return Result(waypoints: kept, legs: legs, dropped: dropped) }
            guard attempt < config.maxVerificationRetries, kept.count > 1 else { break }
            let weakest = weakestIndex(origin: origin, destination: destination, waypoints: kept, taken: taken)
            dropped.append(kept.remove(at: weakest))
        }
        // Still over budget: fall back to the fast route (step 6).
        return Result(waypoints: [], legs: [baseline], dropped: dropped + kept)
    }

    /// Index of the waypoint with the lowest `value / extraTime`, where extra
    /// time is its estimated marginal cost in the current route. Drops that
    /// would leave a `taken` plan's stops (or a subset) are avoided when
    /// another drop is possible.
    private func weakestIndex(origin: Coordinate, destination: Coordinate, waypoints: [POI],
                              taken: TakenStops) -> Int {
        let estimator = config.estimator
        let stops = [origin] + waypoints.map(\.coordinate) + [destination]
        let ranked = waypoints.indices.map { i -> (index: Int, ratio: Double) in
            let a = stops[i], p = stops[i + 1], b = stops[i + 2]
            let marginal = estimator.seconds(from: a, to: p) + estimator.seconds(from: p, to: b)
                - estimator.seconds(from: a, to: b)
            return (i, scorer.ratio(waypoints[i], extraTime: marginal))
        }.sorted { ($0.ratio, $0.index) < ($1.ratio, $1.index) }
        let allowed = ranked.first { candidate in
            var rest = waypoints
            rest.remove(at: candidate.index)
            return taken.isEmpty || taken.isNew(rest)
        }
        return (allowed ?? ranked[0]).index
    }
}

/// Order-independent identity of a waypoint set: the same stops in another
/// order are the same walk for comparing modes.
func waypointKey(_ waypoints: [POI]) -> String {
    waypoints.map(\.id).sorted().joined(separator: "|")
}

/// Stop sets of plans to differ from (`plan(_:provider:distinctFrom:)`). A
/// set is new only if it has a stop none of them has: the same stops, or a
/// subset of them, would be the same walk or a worse one.
struct TakenStops: Sendable {
    var sets: [Set<String>] = []

    init(_ plans: [[POI]] = []) {
        sets = plans.filter { !$0.isEmpty }.map { Set($0.map(\.id)) }
    }

    mutating func add(_ waypoints: [POI]) {
        if !waypoints.isEmpty { sets.append(Set(waypoints.map(\.id))) }
    }

    func isNew(_ waypoints: [POI]) -> Bool {
        let ids = Set(waypoints.map(\.id))
        return !sets.contains { ids.isSubset(of: $0) }
    }

    var isEmpty: Bool { sets.isEmpty }
}
