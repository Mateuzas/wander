import Foundation

/// Plans Wander routes (PLAN.md section 6).
public struct Planner: Sendable {
    public var config: PlannerConfig

    public init(config: PlannerConfig = .default) {
        self.config = config
    }

    /// Builds a plan. Real routing goes only through `provider`; detours are
    /// estimated offline with `config.estimator`. When a set fits that has a
    /// stop none of the `distinctFrom` plans has, the plan uses one (see `plans`).
    public func plan(_ request: PlanRequest, provider: WalkingTimeProvider,
                     distinctFrom others: [WanderPlan] = []) async throws -> WanderPlan {
        try await plan(request, store: LegStore(provider: provider), taken: TakenStops(others.map(\.waypoints)))
    }

    /// Plans several modes for one trip, smallest budget first. Each plan
    /// includes a stop the smaller modes don't have whenever one fits, so
    /// Relaxed and Explorer don't show the same walk. Real legs are shared,
    /// so the baseline and common legs cost one provider request each.
    /// `request.budget` and `request.maxWaypoints` are replaced per mode.
    public func plans(_ request: PlanRequest, modes: [Mode] = Mode.allCases,
                      provider: WalkingTimeProvider) async throws -> [Mode: WanderPlan] {
        let store = LegStore(provider: provider)
        var plans: [Mode: WanderPlan] = [:]
        var taken = TakenStops()
        for mode in modes.sorted(by: { $0.budget < $1.budget }) {
            var modeRequest = request
            modeRequest.budget = mode.budget
            modeRequest.maxWaypoints = mode.maxWaypoints
            let plan = try await plan(modeRequest, store: store, taken: taken)
            plans[mode] = plan
            taken.add(plan.waypoints)
        }
        return plans
    }

    func plan(_ request: PlanRequest, store: LegStore, taken: TakenStops) async throws -> WanderPlan {
        let scorer = Scorer(config: config, interests: request.interests, weights: request.weights)
        let estimator = config.estimator
        let selector = WaypointSelector(config: config, scorer: scorer)
        let validator = Validator(config: config, scorer: scorer)
        let maxWaypoints = request.maxWaypoints ?? config.maxWaypoints

        // 1. Baseline.
        let baseline = try await store.leg(from: request.origin, to: request.destination)

        // 2–3. Freebies and corridor.
        let filtered = CandidateFilter(config: config, scorer: scorer).filter(request, baseline: baseline)

        // 4. Choose the most valuable waypoint set on estimates.
        var inserted = selector.run(
            origin: request.origin, destination: request.destination,
            candidates: filtered.candidates, budget: request.budget,
            maxWaypoints: maxWaypoints, taken: taken)

        // 5–6. Verify with real routing, fall back to the baseline.
        var verified = try await validator.verify(
            origin: request.origin, destination: request.destination,
            waypoints: inserted.waypoints, baseline: baseline,
            budget: request.budget, store: store, taken: taken)

        // 7. Free stops that turn out to be on the way (real detour under
        // `freeBelow`): they become free highlights and give their slot back.
        var freed: [POI] = []
        var freeChecks = 0
        func freeOnTheWay() async throws {
            let result = try await freeNearlyFree(origin: request.origin, destination: request.destination,
                                                  waypoints: verified.waypoints, legs: verified.legs,
                                                  store: store, checksLeft: config.maxFreeChecks - freeChecks)
            verified.waypoints = result.waypoints
            verified.legs = result.legs
            freed += result.freed
            freeChecks += result.checks
        }
        try await freeOnTheWay()

        // 8. Top up: real routes often beat the estimate, leaving budget unused.
        // While the verified walk uses under `topUpBelow` of its budget, add
        // stops sized with the estimate recalibrated to the real legs, and keep
        // them only if real routing still fits.
        var tried = Set(verified.dropped.map(\.id)).union(freed.map(\.id))
        for _ in 0..<config.maxTopUpRounds where request.budget > 0 && verified.waypoints.count < maxWaypoints {
            let realTotal = verified.legs.reduce(0) { $0 + $1.duration }
            let realExtra = realTotal - baseline.duration
            guard realExtra < config.topUpBelow * request.budget else { break }
            let stops = [request.origin] + verified.waypoints.map(\.coordinate) + [request.destination]
            let estimatedTotal = zip(stops, stops.dropFirst()).reduce(0) { $0 + estimator.seconds(from: $1.0, to: $1.1) }
            let estimatedExtra = estimatedTotal - estimator.seconds(from: request.origin, to: request.destination)
            let scale = realTotal > 0 ? estimatedTotal / realTotal : 1   // estimated seconds per real second
            let more = selector.run(
                origin: request.origin, destination: request.destination,
                candidates: filtered.candidates.filter { !tried.contains($0.id) },
                budget: estimatedExtra + (request.budget - realExtra) * scale,
                maxWaypoints: maxWaypoints, initial: verified.waypoints, taken: taken)
            let added = more.waypoints.filter { poi in !verified.waypoints.contains { $0.id == poi.id } }
            // The selector already prefers sets with a stop smaller modes lack.
            guard !added.isEmpty else { break }
            let legs = try await store.legs(origin: request.origin, waypoints: more.waypoints,
                                            destination: request.destination)
            let extra = legs.reduce(0) { $0 + $1.duration } - baseline.duration
            if extra <= request.budget * (1 + config.verificationTolerance) {
                verified = Validator.Result(waypoints: more.waypoints, legs: legs, dropped: verified.dropped)
                inserted.rejected = more.rejected
                for (id, seconds) in more.bestExtra { inserted.bestExtra[id] = seconds }
                try await freeOnTheWay()
            } else {
                verified.dropped += added
            }
            tried.formUnion(added.map(\.id))
            tried.formUnion(freed.map(\.id))
        }

        let totalTime = verified.legs.reduce(0) { $0 + $1.duration }
        var plan = WanderPlan(
            baseline: baseline, waypoints: verified.waypoints, legs: verified.legs,
            totalTime: totalTime, extraTime: totalTime - baseline.duration,
            highlights: [], noDetourFit: request.budget > 0 && verified.waypoints.isEmpty && freed.isEmpty,
            candidates: [])

        // Highlights: waypoints plus pass-by POIs along the final route.
        let line = MeasuredPolyline(plan.polyline, projection: LocalProjection(origin: request.origin))
        let waypointIDs = Set(verified.waypoints.map(\.id))
        let freedIDs = Set(freed.map(\.id))
        var passbyIDs: Set<String> = []
        for poi in request.pois where request.interests.contains(poi.category)
            && filtered.rejected[poi.id] != .closed {
            let near = line.nearest(to: poi.coordinate)
            if waypointIDs.contains(poi.id) {
                plan.highlights.append(Highlight(poi: poi, role: .waypoint,
                                                 distanceAlongRoute: near.along, distanceFromRoute: near.distance))
            } else if near.distance <= config.passbyRadius || freedIDs.contains(poi.id) {
                // Freed stops are under a minute off the way, even if the route
                // doesn't pass within `passbyRadius`.
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

    /// Removes waypoints whose real detour is under `freeBelow`, one at a
    /// time, checking the cheapest-looking first. Each check costs one leg
    /// (the walk without that stop), up to `checksLeft`.
    private func freeNearlyFree(origin: Coordinate, destination: Coordinate, waypoints: [POI], legs: [Leg],
                                store: LegStore, checksLeft: Int)
        async throws -> (waypoints: [POI], legs: [Leg], freed: [POI], checks: Int) {
        let estimator = config.estimator
        var waypoints = waypoints, legs = legs, freed: [POI] = [], checks = 0
        var changed = true
        while changed && checks < checksLeft {
            changed = false
            let stops = [origin] + waypoints.map(\.coordinate) + [destination]
            let order = waypoints.indices.map { i -> (index: Int, estimate: Double) in
                (i, estimator.seconds(from: stops[i], to: stops[i + 1])
                    + estimator.seconds(from: stops[i + 1], to: stops[i + 2])
                    - estimator.seconds(from: stops[i], to: stops[i + 2]))
            }.filter { $0.estimate < config.freeCheckEstimate }.sorted { ($0.estimate, $0.index) < ($1.estimate, $1.index) }
            for (i, _) in order where checks < checksLeft {
                checks += 1
                let bypass = try await store.leg(from: stops[i], to: stops[i + 2])
                // Free only if skipping the stop doesn't lengthen the walk: with
                // real routing, the leg past a stop can be slower than via it.
                let detour = legs[i].duration + legs[i + 1].duration - bypass.duration
                if detour >= 0 && detour < config.freeBelow {
                    freed.append(waypoints.remove(at: i))
                    legs.replaceSubrange(i...(i + 1), with: [bypass])
                    changed = true
                    break
                }
            }
        }
        return (waypoints, legs, freed, checks)
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
    /// Corridor filter width as a multiple of the budget (wider than 1 so a
    /// top-up can reach stops that only fit once real times are known).
    public var corridorSlack: Double = 1.5
    /// Seconds. A verified waypoint whose real detour is under this is on the
    /// way anyway: it becomes a free highlight and its slot is freed.
    public var freeBelow: TimeInterval = 60
    /// Seconds. Only waypoints whose estimated detour is under this are
    /// checked against real routing for `freeBelow` (each check is a request).
    public var freeCheckEstimate: TimeInterval = 180
    /// Most extra provider requests per plan for those checks.
    public var maxFreeChecks: Int = 8
    /// Top up a verified plan while it uses less than this share of its budget.
    public var topUpBelow: Double = 0.7
    /// Most top-up attempts per plan (each one costs a few provider requests).
    public var maxTopUpRounds: Int = 3
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
