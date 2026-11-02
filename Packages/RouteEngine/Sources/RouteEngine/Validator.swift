import Foundation

/// Real-route verification (PLAN.md section 6, step 5). All routing goes
/// through the `WalkingTimeProvider`.
struct Validator {
    var config: PlannerConfig
    var scorer: Scorer

    struct Result {
        var waypoints: [POI]
        var legs: [Leg]
        /// Waypoints dropped because real routing went over budget.
        var dropped: [POI]
    }

    private struct LegKey: Hashable {
        var from: Coordinate
        var to: Coordinate
    }

    func verify(origin: Coordinate, destination: Coordinate, waypoints: [POI], baseline: Leg,
                budget: TimeInterval, provider: WalkingTimeProvider) async throws -> Result {
        guard !waypoints.isEmpty else { return Result(waypoints: [], legs: [baseline], dropped: []) }

        let limit = baseline.duration + budget * (1 + config.verificationTolerance)
        var cache: [LegKey: Leg] = [LegKey(from: origin, to: destination): baseline]
        var kept = waypoints
        var dropped: [POI] = []

        for attempt in 0...config.maxVerificationRetries {
            let stops = [origin] + kept.map(\.coordinate) + [destination]
            var legs: [Leg] = []
            for i in 1..<stops.count {
                let key = LegKey(from: stops[i - 1], to: stops[i])
                if let leg = cache[key] {
                    legs.append(leg)
                } else {
                    let leg = try await provider.leg(from: key.from, to: key.to)
                    cache[key] = leg
                    legs.append(leg)
                }
            }
            let total = legs.reduce(0) { $0 + $1.duration }
            if total <= limit { return Result(waypoints: kept, legs: legs, dropped: dropped) }
            guard attempt < config.maxVerificationRetries, kept.count > 1 else { break }
            let weakest = weakestIndex(origin: origin, destination: destination, waypoints: kept)
            dropped.append(kept.remove(at: weakest))
        }
        // Still over budget: fall back to the fast route (step 6).
        return Result(waypoints: [], legs: [baseline], dropped: dropped + kept)
    }

    /// Index of the waypoint with the lowest `value / extraTime`, where extra
    /// time is its estimated marginal cost in the current route.
    private func weakestIndex(origin: Coordinate, destination: Coordinate, waypoints: [POI]) -> Int {
        let estimator = config.estimator
        let stops = [origin] + waypoints.map(\.coordinate) + [destination]
        var weakest = 0
        var weakestRatio = Double.infinity
        for i in waypoints.indices {
            let a = stops[i], p = stops[i + 1], b = stops[i + 2]
            let marginal = estimator.seconds(from: a, to: p) + estimator.seconds(from: p, to: b)
                - estimator.seconds(from: a, to: b)
            let ratio = scorer.ratio(waypoints[i], extraTime: marginal)
            if ratio < weakestRatio {
                weakestRatio = ratio
                weakest = i
            }
        }
        return weakest
    }
}
