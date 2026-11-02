import Foundation

/// Greedy cost-benefit insertion on offline estimates (PLAN.md section 6, step 4).
struct GreedyInserter {
    var config: PlannerConfig
    var scorer: Scorer

    struct Result {
        /// Chosen waypoints in walking order.
        var waypoints: [POI]
        /// Estimated extra seconds over the direct estimate.
        var estimatedExtra: TimeInterval
        /// Best estimated extra seconds per evaluated candidate, by POI id.
        var bestExtra: [String: TimeInterval]
        /// Why each unchosen candidate was left out, by POI id.
        var rejected: [String: RejectionReason]
    }

    private struct Insertion {
        var poi: POI
        var position: Int
        var extra: TimeInterval
        var ratio: Double
    }

    func run(origin: Coordinate, destination: Coordinate, candidates: [POI], budget: TimeInterval) -> Result {
        let estimator = config.estimator
        let projection = LocalProjection(origin: origin)
        let direction = projection.point(destination) - projection.point(origin)

        var route: [Coordinate] = [origin, destination]
        var waypoints: [POI] = []
        var extra: TimeInterval = 0
        var pool = candidates
        var chosenExtra: [String: TimeInterval] = [:]

        func backtracks(_ from: Coordinate, _ to: Coordinate) -> Bool {
            let leg = projection.point(to) - projection.point(from)
            guard length(leg) >= config.minLegForBacktrackCheck,
                  let angle = angleDegrees(leg, direction) else { return false }
            return angle > config.maxLegDeviation
        }

        /// Cheapest insertion positions for `poi` in the current route.
        func evaluate(_ poi: POI) -> (fitting: Insertion?, cheapest: TimeInterval, anyInBudget: Bool) {
            var fitting: Insertion?
            var cheapest = TimeInterval.infinity
            var anyInBudget = false
            let p = poi.coordinate
            for position in 1..<route.count {
                let a = route[position - 1], b = route[position]
                let added = estimator.seconds(from: a, to: p) + estimator.seconds(from: p, to: b)
                    - estimator.seconds(from: a, to: b)
                cheapest = min(cheapest, added)
                guard extra + added <= budget else { continue }
                anyInBudget = true
                guard !backtracks(a, p), !backtracks(p, b) else { continue }
                let ratio = scorer.ratio(poi, extraTime: added)
                if fitting == nil || ratio > fitting!.ratio {
                    fitting = Insertion(poi: poi, position: position, extra: added, ratio: ratio)
                }
            }
            return (fitting, cheapest, anyInBudget)
        }

        func blocked(_ poi: POI) -> RejectionReason? {
            if waypoints.count >= config.maxWaypoints { return .maxWaypoints }
            if waypoints.filter({ $0.category == poi.category }).count >= config.maxPerCategory {
                return .categoryCap
            }
            if waypoints.contains(where: { $0.coordinate.distance(to: poi.coordinate) < config.minWaypointSpacing }) {
                return .tooClose
            }
            return nil
        }

        while waypoints.count < config.maxWaypoints {
            var best: Insertion?
            for poi in pool where blocked(poi) == nil {
                guard let option = evaluate(poi).fitting else { continue }
                // Pool is sorted by id and positions are scanned in order, so a
                // strict comparison keeps ties deterministic.
                if best == nil || option.ratio > best!.ratio { best = option }
            }
            guard let pick = best else { break }
            route.insert(pick.poi.coordinate, at: pick.position)
            waypoints.insert(pick.poi, at: pick.position - 1)
            extra += pick.extra
            chosenExtra[pick.poi.id] = pick.extra
            pool.removeAll { $0.id == pick.poi.id }
        }

        var bestExtra = chosenExtra
        var rejected: [String: RejectionReason] = [:]
        for poi in pool {
            let evaluation = evaluate(poi)
            bestExtra[poi.id] = evaluation.cheapest
            // Over budget first: a POI that could never fit is better explained by
            // that than by whichever cap happened to be reached.
            if !evaluation.anyInBudget {
                rejected[poi.id] = .overBudget
            } else if let reason = blocked(poi) {
                rejected[poi.id] = reason
            } else {
                rejected[poi.id] = .backtracks
            }
        }
        return Result(waypoints: waypoints, estimatedExtra: extra, bestExtra: bestExtra, rejected: rejected)
    }
}
