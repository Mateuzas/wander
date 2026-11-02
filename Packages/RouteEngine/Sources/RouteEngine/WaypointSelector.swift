import Foundation

/// Chooses waypoints on offline estimates (PLAN.md section 6, step 4).
///
/// Maximises the total value of the waypoints within the budget, with less
/// extra time as the tie-break. Ranking by value per minute instead let
/// near-free places fill every slot and left Explorer's budget unused.
/// A beam search over waypoint sets (at most `maxWaypoints` deep) keeps this
/// cheap: about `beamWidth × candidates × maxWaypoints` insertion estimates.
struct WaypointSelector {
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

    /// A partial plan: waypoints in walking order between origin and destination.
    private struct State {
        var route: [Coordinate]
        var waypoints: [POI]
        var extra: TimeInterval
        var value: Double
        /// Waypoint ids sorted, so the same set in another order is one state.
        var key: String

        /// Higher value first, then less time, then ids for determinism.
        func isBetter(than other: State) -> Bool {
            if value != other.value { return value > other.value }
            if extra != other.extra { return extra < other.extra }
            return key < other.key
        }
    }

    private struct Insertion {
        var position: Int
        var extra: TimeInterval
    }

    func run(origin: Coordinate, destination: Coordinate, candidates: [POI], budget: TimeInterval,
             maxWaypoints: Int) -> Result {
        let estimator = config.estimator
        let projection = LocalProjection(origin: origin)
        let direction = projection.point(destination) - projection.point(origin)
        let values = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, scorer.value($0)) })

        func backtracks(_ from: Coordinate, _ to: Coordinate) -> Bool {
            let leg = projection.point(to) - projection.point(from)
            guard length(leg) >= config.minLegForBacktrackCheck,
                  let angle = angleDegrees(leg, direction) else { return false }
            return angle > config.maxLegDeviation
        }

        /// Cheapest insertion of `poi` into `state` that fits the budget and
        /// doesn't backtrack, plus diagnostics for the debug overlay.
        func evaluate(_ poi: POI, in state: State) -> (fitting: Insertion?, cheapest: TimeInterval, anyInBudget: Bool) {
            var fitting: Insertion?
            var cheapest = TimeInterval.infinity
            var anyInBudget = false
            let p = poi.coordinate
            for position in 1..<state.route.count {
                let a = state.route[position - 1], b = state.route[position]
                let added = estimator.seconds(from: a, to: p) + estimator.seconds(from: p, to: b)
                    - estimator.seconds(from: a, to: b)
                cheapest = min(cheapest, added)
                guard state.extra + added <= budget else { continue }
                anyInBudget = true
                guard !backtracks(a, p), !backtracks(p, b) else { continue }
                if fitting == nil || added < fitting!.extra {
                    fitting = Insertion(position: position, extra: added)
                }
            }
            return (fitting, cheapest, anyInBudget)
        }

        func blocked(_ poi: POI, in state: State) -> RejectionReason? {
            if state.waypoints.count >= maxWaypoints { return .maxWaypoints }
            if state.waypoints.filter({ $0.category == poi.category }).count
                >= config.waypointCap(for: poi.category, interests: scorer.interests, maxWaypoints: maxWaypoints) {
                return .categoryCap
            }
            if state.waypoints.contains(where: { $0.coordinate.distance(to: poi.coordinate) < config.minWaypointSpacing }) {
                return .tooClose
            }
            return nil
        }

        let empty = State(route: [origin, destination], waypoints: [], extra: 0, value: 0, key: "")
        var best = empty
        var beam = [empty]
        for _ in 0..<maxWaypoints {
            var children: [String: State] = [:]
            for state in beam {
                for poi in candidates where blocked(poi, in: state) == nil
                    && !state.waypoints.contains(where: { $0.id == poi.id }) {
                    guard let insertion = evaluate(poi, in: state).fitting else { continue }
                    var child = state
                    child.route.insert(poi.coordinate, at: insertion.position)
                    child.waypoints.insert(poi, at: insertion.position - 1)
                    child.extra += insertion.extra
                    child.value += values[poi.id] ?? 0
                    child.key = child.waypoints.map(\.id).sorted().joined(separator: "|")
                    if let existing = children[child.key], !child.isBetter(than: existing) { continue }
                    children[child.key] = child
                }
            }
            guard !children.isEmpty else { break }
            beam = Array(children.values.sorted { $0.isBetter(than: $1) }.prefix(config.beamWidth))
            if beam[0].isBetter(than: best) { best = beam[0] }
        }

        // Extra time each chosen waypoint added when it was inserted is not
        // tracked per beam step, so report its marginal cost in the final route.
        var bestExtra: [String: TimeInterval] = [:]
        for (i, poi) in best.waypoints.enumerated() {
            let a = best.route[i], p = best.route[i + 1], b = best.route[i + 2]
            bestExtra[poi.id] = estimator.seconds(from: a, to: p) + estimator.seconds(from: p, to: b)
                - estimator.seconds(from: a, to: b)
        }
        let chosen = Set(best.waypoints.map(\.id))
        var rejected: [String: RejectionReason] = [:]
        for poi in candidates where !chosen.contains(poi.id) {
            let evaluation = evaluate(poi, in: best)
            bestExtra[poi.id] = evaluation.cheapest
            // Over budget first: a POI that could never fit is better explained by
            // that than by whichever cap happened to be reached.
            if !evaluation.anyInBudget {
                rejected[poi.id] = .overBudget
            } else if let reason = blocked(poi, in: best) {
                rejected[poi.id] = reason
            } else if evaluation.fitting == nil {
                rejected[poi.id] = .backtracks
            } else {
                rejected[poi.id] = .outvalued
            }
        }
        return Result(waypoints: best.waypoints, estimatedExtra: best.extra, bestExtra: bestExtra, rejected: rejected)
    }
}
