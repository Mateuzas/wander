import Foundation

/// Steps 2 and 3 of PLAN.md section 6: pass-by freebies and the corridor filter.
struct CandidateFilter {
    var config: PlannerConfig
    var scorer: Scorer

    struct Result {
        /// POIs already on the fast route (any kind), with their route position.
        var freebies: [(poi: POI, distance: Double, along: Double)]
        /// POIs worth trying as waypoints, sorted by id for determinism.
        var candidates: [POI]
        /// Everything else, by POI id.
        var rejected: [String: RejectionReason]
    }

    func filter(_ request: PlanRequest, baseline: Leg) -> Result {
        let projection = LocalProjection(origin: request.origin)
        let line = MeasuredPolyline(baseline.polyline, projection: projection)
        let estimator = config.estimator
        let direct = estimator.seconds(from: request.origin, to: request.destination)

        var result = Result(freebies: [], candidates: [], rejected: [:])
        for poi in request.pois {
            guard request.interests.contains(poi.category) else {
                result.rejected[poi.id] = .notInInterests
                continue
            }
            if isClosed(poi, request) {
                result.rejected[poi.id] = .closed
                continue
            }
            // Anything already on the fast route is a free highlight, shops and food
            // included: otherwise on-route stops fill every waypoint slot at ~0 min.
            let near = line.nearest(to: poi.coordinate)
            if near.distance <= config.passbyRadius {
                result.freebies.append((poi, near.distance, near.along))
                continue
            }
            guard request.budget > 0 else {
                result.rejected[poi.id] = .noBudget
                continue
            }
            let value = scorer.value(poi)
            guard value > 0 else {
                result.rejected[poi.id] = .noValue
                continue
            }
            guard value >= config.minWaypointValue else {
                result.rejected[poi.id] = request.seen.contains(poi.id) ? .seen : .lowValue
                continue
            }
            let via = estimator.seconds(from: request.origin, to: poi.coordinate)
                + estimator.seconds(from: poi.coordinate, to: request.destination)
            // Wider than the budget: real routes often beat the estimate, and a
            // top-up after verification may then afford farther stops. The
            // selector still holds every set to the budget.
            if via - direct <= request.budget * config.corridorSlack {
                result.candidates.append(poi)
            } else {
                result.rejected[poi.id] = .outsideCorridor
            }
        }
        result.candidates.sort { $0.id < $1.id }
        return result
    }

    /// Closed only when the hours parse and say so; unparseable hours keep the POI.
    private func isClosed(_ poi: POI, _ request: PlanRequest) -> Bool {
        guard let time = request.time, let raw = poi.openingHours,
              let hours = OpeningHours(raw) else { return false }
        return !hours.isOpen(at: time, in: request.timeZone)
    }
}
