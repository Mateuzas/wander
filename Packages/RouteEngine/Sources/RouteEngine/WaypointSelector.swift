import Foundation

/// Chooses waypoints on offline estimates (PLAN.md section 6, step 4).
///
/// Maximises the total value of the waypoints within the budget, minus
/// `costPerMinute` for each estimated extra minute (Recommended), with less
/// extra time as the tie-break. Ranking by value per minute instead let
/// near-free places fill every slot and left long budgets unused.
/// A beam search over waypoint sets (at most `maxWaypoints` deep) keeps this
/// cheap: about `beamWidth × candidates × maxWaypoints` insertion estimates.
struct WaypointSelector {
    var config: PlannerConfig
    var scorer: Scorer
    /// Value points charged per estimated extra minute (Recommended's
    /// `minValuePerMinute`). Zero maximises plain value within the budget.
    var costPerMinute: Double = 0

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
        /// `value` minus `costPerMinute` × extra minutes.
        var net: Double = 0

        /// Higher net value first, then less time, then ids for determinism.
        func isBetter(than other: State) -> Bool {
            if net != other.net { return net > other.net }
            if extra != other.extra { return extra < other.extra }
            return key < other.key
        }
    }

    private struct Insertion {
        var position: Int
        var extra: TimeInterval
    }

    /// Picks waypoints for `budget` (in estimated seconds). `initial` waypoints
    /// stay in the route (topping up a verified plan). With `taken` (smaller
    /// modes' stops), the result has a stop none of them has whenever such a
    /// set fits; otherwise the overall best is returned.
    func run(origin: Coordinate, destination: Coordinate, candidates: [POI], budget: TimeInterval,
             maxWaypoints: Int, initial: [POI] = [], taken: TakenStops = TakenStops()) -> Result {
        let estimator = config.estimator
        let projection = LocalProjection(origin: origin)
        let direction = projection.point(destination) - projection.point(origin)
        var values = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, scorer.value($0)) })
        for poi in initial { values[poi.id] = scorer.value(poi) }

        func backtracks(_ from: Coordinate, _ to: Coordinate) -> Bool {
            let leg = projection.point(to) - projection.point(from)
            guard length(leg) >= config.minLegForBacktrackCheck,
                  let angle = angleDegrees(leg, direction) else { return false }
            return angle > config.maxLegDeviation
        }

        /// Cheapest insertion of `poi` into `state` that fits the budget and
        /// doesn't backtrack, plus diagnostics for the debug overlay.
        func evaluate(_ poi: POI, in state: State)
            -> (fitting: Insertion?, cheapest: TimeInterval, anyInBudget: Bool, onTheWay: Bool) {
            var fitting: Insertion?
            var cheapest = TimeInterval.infinity
            var anyInBudget = false
            var onTheWay = false
            let p = poi.coordinate
            for position in 1..<state.route.count {
                let a = state.route[position - 1], b = state.route[position]
                let added = estimator.seconds(from: a, to: p) + estimator.seconds(from: p, to: b)
                    - estimator.seconds(from: a, to: b)
                cheapest = min(cheapest, added)
                guard state.extra + added <= budget else { continue }
                anyInBudget = true
                guard !backtracks(a, p), !backtracks(p, b) else { continue }
                // Under `freeBelow` it's on the way: not worth a slot.
                if config.freeBelow > 0 && added < config.freeBelow {
                    onTheWay = true
                    continue
                }
                if fitting == nil || added < fitting!.extra {
                    fitting = Insertion(position: position, extra: added)
                }
            }
            return (fitting, cheapest, anyInBudget, onTheWay)
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

        let startRoute = [origin] + initial.map(\.coordinate) + [destination]
        let startExtra = zip(startRoute, startRoute.dropFirst()).reduce(0) { $0 + estimator.seconds(from: $1.0, to: $1.1) }
            - estimator.seconds(from: origin, to: destination)
        var start = State(route: startRoute, waypoints: initial, extra: startExtra,
                          value: initial.reduce(0) { $0 + (values[$1.id] ?? 0) }, key: waypointKey(initial))
        start.net = start.value - costPerMinute * start.extra / 60
        var best = start
        // Best set with a stop the `taken` plans don't have, for when the
        // overall best is (inside) one of theirs.
        var bestNew: State? = taken.isNew(start.waypoints) ? start : nil
        var beam = [start]
        for _ in 0..<max(0, maxWaypoints - initial.count) {
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
                    child.key = waypointKey(child.waypoints)
                    child.net = child.value - costPerMinute * child.extra / 60
                    if let existing = children[child.key], !child.isBetter(than: existing) { continue }
                    children[child.key] = child
                }
            }
            guard !children.isEmpty else { break }
            let ranked = children.values.sorted { $0.isBetter(than: $1) }
            beam = Array(ranked.prefix(config.beamWidth))
            if beam[0].isBetter(than: best) { best = beam[0] }
            if let fresh = ranked.first(where: { taken.isNew($0.waypoints) }),
               bestNew.map({ fresh.isBetter(than: $0) }) ?? true {
                bestNew = fresh
            }
        }
        // Never repeat a `taken` walk while a set with something new fits.
        if !taken.isEmpty, !taken.isNew(best.waypoints), let bestNew { best = bestNew }

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
            } else if evaluation.fitting == nil && evaluation.onTheWay {
                rejected[poi.id] = .onTheWay
            } else if evaluation.fitting == nil {
                rejected[poi.id] = .backtracks
            } else {
                rejected[poi.id] = .outvalued
            }
        }
        return Result(waypoints: best.waypoints, estimatedExtra: best.extra, bestExtra: bestExtra, rejected: rejected)
    }
}
