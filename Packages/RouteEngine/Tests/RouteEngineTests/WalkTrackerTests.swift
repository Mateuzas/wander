import Foundation
import Testing
@testable import RouteEngine

struct WalkTrackerTests {
    // MARK: Golden-route walks

    /// Seeds for the walks on Recommended golden plans: 10 per route, a
    /// stress run over noise, with and without a course.
    static let walkSeeds = Array(0..<100)

    @Test(arguments: walkSeeds) func noisyWalkAlongGoldenRoute(seed: Int) async throws {
        let plan = try await Golden.recommendedPlan(seed % 10)
        #expect(plan.waypoints.count > 0)
        var tracker = WalkTracker(plan: plan)
        var noise = GPSNoise(rng: SplitMix64(seed: UInt64(seed)), sigma: 8)
        var updates: [WalkUpdate] = []
        let points = samples(along: plan.polyline, every: 1.4)
        for (i, point) in points.enumerated() {
            // Every 50th fix is a bad one: far off and flagged inaccurate.
            let bad = i % 50 == 49
            // Even seeds carry a noisy course (±15°) like CoreLocation's; odd
            // seeds have none, so direction comes from recent fixes.
            var heading: Double?
            if seed % 2 == 0, i + 1 < points.count {
                let next = points[i + 1]
                let bearing = atan2((next.lon - point.lon) * cos(point.lat * .pi / 180), next.lat - point.lat) * 180 / .pi
                heading = (bearing + noise.gaussian() / 8 * 15 + 360).truncatingRemainder(dividingBy: 360)
            }
            let fix = LocationFix(coordinate: bad ? offset(point, east: 120, north: 0) : noise.jitter(point),
                                  horizontalAccuracy: bad ? 150 : 10, heading: heading,
                                  timestamp: Date(timeIntervalSince1970: Double(i)))
            updates.append(tracker.update(fix))
        }
        let events = updates.flatMap(\.events)

        #expect(!events.contains(.offRoute))
        #expect(events.filter { $0 == .arrived }.count == 1)
        #expect(updates.last?.hasArrived == true)
        #expect(abs(updates.last!.progress - updates.last!.routeLength) < 30)

        // Every highlight nudged at most once, each within 60 m ahead when shown.
        let shown = events.compactMap { event -> Nudge? in
            if case .nudgeShown(let nudge) = event { return nudge }
            return nil
        }
        #expect(shown.count >= 3)
        #expect(Set(shown.map(\.highlight.poi.id)).count == shown.count)
        #expect(shown.allSatisfy { $0.distanceAhead <= 60 && $0.distanceAhead > -15 })
        // Waypoints are on the route: no side.
        #expect(shown.filter { $0.highlight.role == .waypoint }.allSatisfy { $0.side == nil })

        // Steps advance to the end (the zero-length "Arrive" sits at the very end).
        // The step only goes back when progress falls well behind its start
        // (hysteresis), so noise at a turn doesn't flicker the instruction.
        #expect(updates.last!.stepIndex >= tracker.steps.count - 2)
        for (before, after) in zip(updates, updates.dropFirst()) where after.stepIndex < before.stepIndex {
            #expect(after.progress <= tracker.steps[before.stepIndex].start - tracker.config.stepHysteresis)
        }
        // Tracked progress stays close to where the walker really is
        // (fixes are 1.4 m apart along the route).
        let errors = updates.enumerated().map { i, u in abs(u.progress - min(Double(i) * 1.4, u.routeLength)) }
        #expect(errors.max()! < 60)
        #expect(Double(errors.filter { $0 < 25 }.count) / Double(errors.count) > 0.99)
    }

    @Test(arguments: walkSeeds) func wrongTurnTriggersOffRouteExactlyOnce(seed: Int) async throws {
        let plan = try await Golden.recommendedPlan(seed % 10)
        var tracker = WalkTracker(plan: plan)
        let route = samples(along: plan.polyline, every: 1.4)

        // Walk off the route (in a direction and for a length worked out from
        // the route, so the walker really ends up more than 120 m from all of
        // it), wait, then walk back to the same spot and carry on.
        let turn = try #require(wrongTurn(off: route, from: route.count * 2 / 5, polyline: plan.polyline))
        let detour = turn.path + Array(repeating: turn.path.last!, count: 20) + turn.path.reversed()

        var noise = GPSNoise(rng: SplitMix64(seed: UInt64(seed) + 100), sigma: 8)
        let points = (Array(route[..<turn.at]) + detour + Array(route[turn.at...])).map { noise.jitter($0) }
        let updates = walk(&tracker, through: points)
        let events = updates.flatMap(\.events)

        #expect(events.filter { $0 == .offRoute }.count == 1)
        #expect(events.filter { $0 == .backOnRoute }.count == 1)
        #expect(events.filter { $0 == .arrived }.count == 1)
        // No new nudges while off route.
        for update in updates where update.isOffRoute {
            #expect(!update.events.contains { if case .nudgeShown = $0 { true } else { false } })
        }
        // Nudges shown once each.
        let shown = events.compactMap { event -> String? in
            if case .nudgeShown(let nudge) = event { return nudge.highlight.poi.id }
            return nil
        }
        #expect(Set(shown).count == shown.count)
        // Before the turn and after rejoining, progress tracks the walker.
        let rejoined = turn.at + detour.count
        let before: [Double] = (0..<turn.at).map { (i: Int) -> Double in
            abs(updates[i].progress - Double(i) * 1.4)
        }
        let after: [Double] = (rejoined..<points.count).map { (i: Int) -> Double in
            abs(updates[i].progress - min(Double(i - detour.count) * 1.4, updates[i].routeLength))
        }
        let errors = before + after
        #expect(errors.max()! < 60)
    }

    // MARK: Off route

    @Test func gpsSpikesDoNotTriggerOffRoute() {
        var tracker = WalkTracker(plan: straightPlan())
        var points = samples(along: [Grid.origin, Grid.destination], every: 1.4)
        // Two consecutive 80 m spikes with good accuracy: below the 3-fix threshold.
        points[200] = offset(points[200], east: 0, north: 80)
        points[201] = offset(points[201], east: 0, north: 80)
        let events = walk(&tracker, through: points).flatMap(\.events)
        #expect(!events.contains(.offRoute))
        #expect(events.filter { $0 == .arrived }.count == 1)
    }

    @Test func inaccurateFixesAreIgnored() {
        var tracker = WalkTracker(plan: straightPlan())
        let first = tracker.update(LocationFix(coordinate: Grid.at(east: 300, north: 0), horizontalAccuracy: 10,
                                               timestamp: Date(timeIntervalSince1970: 0)))
        var last = first
        for i in 1...5 {
            last = tracker.update(LocationFix(coordinate: Grid.at(east: 300, north: 400), horizontalAccuracy: 200,
                                              timestamp: Date(timeIntervalSince1970: Double(i))))
        }
        #expect(!last.isOffRoute)
        #expect(abs(last.progress - first.progress) < 1e-9)
        #expect(abs(first.progress - 300) < 1)
    }

    // MARK: Progress

    @Test func outAndBackDetourDoesNotJumpAhead() {
        // A → up a side street to W and back down it → B. The side street is
        // walked twice; a walker going up must not be matched to the way down.
        let a = Grid.at(east: 0, north: 0), corner = Grid.at(east: 400, north: 0)
        let w = Grid.at(east: 400, north: 300), b = Grid.at(east: 1000, north: 0)
        let legs = [
            Leg(from: a, to: w, duration: 700 / 1.35, distance: 700, polyline: [a, corner, w]),
            Leg(from: w, to: b, duration: 900 / 1.35, distance: 900, polyline: [w, corner, b]),
        ]
        let poi = POI(id: "w", name: "W", lat: w.lat, lon: w.lon, category: .photo, score: 80, kind: .passby)
        let plan = WanderPlan(baseline: Leg(from: a, to: b, duration: 1000 / 1.35, distance: 1000, polyline: [a, b]),
                              waypoints: [poi], legs: legs, totalTime: 1600 / 1.35, extraTime: 600 / 1.35,
                              highlights: [Highlight(poi: poi, role: .waypoint, distanceAlongRoute: 700, distanceFromRoute: 0)],
                              noDetourFit: false, candidates: [])
        var tracker = WalkTracker(plan: plan)
        let updates = walk(&tracker, through: samples(along: plan.polyline, every: 1.4))
        let progress = updates.map(\.progress)
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $1 >= $0 - 0.01 })
        #expect(abs(progress.last! - 1600) < 2)
    }

    // MARK: Steps

    @Test func reportsCurrentAndNextStep() async throws {
        let plan = try await Planner().plan(
            PlanRequest(origin: Grid.at(east: 0, north: 0), destination: Grid.at(east: 600, north: 400),
                        mode: .direct, pois: []), provider: LShapedWalkingTime())
        var tracker = WalkTracker(plan: plan)
        let start = tracker.update(LocationFix(coordinate: Grid.at(east: 100, north: 0), timestamp: Date()))
        #expect(start.nextStep?.instruction == "Turn left")
        #expect(abs(start.distanceToNextStep - 500) < 2)
        #expect(tracker.steps[start.stepIndex].step.instruction == "Head east")

        let after = tracker.update(LocationFix(coordinate: Grid.at(east: 600, north: 100), timestamp: Date()))
        #expect(tracker.steps[after.stepIndex].step.instruction == "Turn left")
        #expect(after.nextStep?.instruction == "Arrive")
        #expect(abs(after.distanceToNextStep - 300) < 2)
    }

    // MARK: Nudges

    @Test func nudgesOneAtATimeWithSides() async throws {
        // Heading east: north is on the left.
        let pois = [
            Grid.poi("left", east: 500, north: 25, kind: .passby),
            Grid.poi("right", east: 520, north: -25, kind: .passby),
            Grid.poi("onRoute", east: 1200, north: 2, kind: .passby),
        ]
        let plan = try await Planner().plan(
            PlanRequest(origin: Grid.origin, destination: Grid.destination, mode: .direct, pois: pois),
            provider: HaversineWalkingTime())
        #expect(plan.highlights.count == 3)
        var tracker = WalkTracker(plan: plan)
        var shown: [(Nudge, Double)] = []
        var maxActive = 0
        for update in walk(&tracker, through: samples(along: plan.polyline, every: 1.4)) {
            for case .nudgeShown(let nudge) in update.events { shown.append((nudge, update.progress)) }
            maxActive = max(maxActive, update.nudge == nil ? 0 : 1)
        }
        #expect(shown.map(\.0.highlight.poi.id) == ["left", "right", "onRoute"])
        #expect(shown.map(\.0.side) == [.left, .right, nil])
        #expect(abs(shown[0].0.distanceAhead - 60) < 2)
        // "right" waits until "left" is passed (by the 15 m margin), so it shows late.
        #expect(shown[1].1 > 500 + 15 - 2)
    }

    @Test func skippedNudgeNeverReturns() {
        let plan = straightPlan(highlights: [("a", 500), ("b", 1500)])
        var tracker = WalkTracker(plan: plan)
        let points = samples(along: [Grid.origin, Grid.destination], every: 1.4)
        var shownIDs: [String] = []
        var afterSkip: [WalkUpdate] = []
        var skipped = false
        for (i, point) in points.enumerated() {
            let update = tracker.update(LocationFix(coordinate: point, timestamp: Date(timeIntervalSince1970: Double(i))))
            for case .nudgeShown(let nudge) in update.events { shownIDs.append(nudge.highlight.poi.id) }
            if !skipped, update.nudge?.highlight.poi.id == "a" {
                tracker.skipNudge()
                skipped = true
                continue
            }
            if skipped { afterSkip.append(update) }
        }
        #expect(shownIDs == ["a", "b"])
        #expect(!afterSkip.contains { $0.nudge?.highlight.poi.id == "a" })
        // Walking back past a skipped highlight doesn't show it again.
        let back = walk(&tracker, through: Array(points[..<400].reversed()),
                        start: Date(timeIntervalSince1970: 10_000))
        #expect(!back.flatMap(\.events).contains { if case .nudgeShown = $0 { true } else { false } })
    }

    @Test func streamsUpdates() async throws {
        let tracker = WalkTracker(plan: straightPlan())
        let points = samples(along: [Grid.origin, Grid.destination], every: 10)
        let fixes = AsyncStream<LocationFix> { continuation in
            for (i, point) in points.enumerated() {
                continuation.yield(LocationFix(coordinate: point, timestamp: Date(timeIntervalSince1970: Double(i) * 7)))
            }
            continuation.finish()
        }
        var count = 0
        var arrived = false
        for try await update in tracker.updates(for: fixes) {
            count += 1
            arrived = arrived || update.hasArrived
        }
        #expect(count == points.count)
        #expect(arrived)
    }

    // MARK: Helpers

    /// Straight 2 km route east with optional pass-by highlights (id, metres along).
    func straightPlan(highlights: [(String, Double)] = []) -> WanderPlan {
        let leg = Leg(from: Grid.origin, to: Grid.destination, duration: 2000 / 1.35, distance: 2000,
                      polyline: [Grid.origin, Grid.destination])
        let hs = highlights.map { id, along in
            Highlight(poi: Grid.poi(id, east: along, north: 20, kind: .passby), role: .passby,
                      distanceAlongRoute: along, distanceFromRoute: 20)
        }
        return WanderPlan(baseline: leg, waypoints: [], legs: [leg], totalTime: leg.duration, extraTime: 0,
                          highlights: hs, noDetourFit: false, candidates: [])
    }
}
