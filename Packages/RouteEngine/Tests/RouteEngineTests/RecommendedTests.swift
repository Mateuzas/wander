import Foundation
import Testing
@testable import RouteEngine

/// Real routing slower by `factor` on every leg that starts or ends at `slow`.
struct SlowStopWalkingTime: WalkingTimeProvider {
    var slow: Coordinate
    var factor: Double

    func leg(from: Coordinate, to: Coordinate) async throws -> Leg {
        var leg = try await HaversineWalkingTime().leg(from: from, to: to)
        if from == slow || to == slow { leg.duration *= factor }
        return leg
    }
}

/// Recommended mode: the engine picks the extra time (CONTRACTS §2, ADR 008).
struct RecommendedTests {
    func recommended(_ pois: [POI], config: PlannerConfig = .selection,
                     provider: WalkingTimeProvider = HaversineWalkingTime()) async throws -> WanderPlan {
        try await Planner(config: config).plan(
            PlanRequest(origin: Grid.origin, destination: Grid.destination, mode: .recommended, pois: pois),
            provider: provider)
    }

    /// Many attractive POIs spread around the corridor, some far off it.
    var spread: [POI] {
        var pois: [POI] = []
        for i in 0..<10 {
            let east = 100 + Double(i) * 200
            pois.append(Grid.poi("n\(i)", east: east, north: 250, category: POICategory.allCases[i % 3], score: 90))
            pois.append(Grid.poi("s\(i)", east: east, north: -250, category: POICategory.allCases[(i + 1) % 3], score: 85))
            pois.append(Grid.poi("far\(i)", east: east, north: 900, category: .photo, score: 95))
        }
        return pois
    }

    @Test func staysWithinTheCap() async throws {
        // Without the worth-it charge the selection fills the cap: still never over it.
        var greedy = PlannerConfig.selection
        greedy.minValuePerMinute = 0
        for provider in [HaversineWalkingTime() as WalkingTimeProvider, NoisyWalkingTime(), FastWalkingTime()] {
            for config in [PlannerConfig.selection, greedy, PlannerConfig()] {
                let plan = try await recommended(spread, config: config, provider: provider)
                #expect(plan.extraTime <= config.recommendedMaxExtra * (1 + config.verificationTolerance) + 1e-6)
                #expect(plan.waypoints.count <= 5)
            }
        }
        // A smaller cap is respected too.
        var tight = PlannerConfig.selection
        tight.recommendedMaxExtra = 5 * 60
        let plan = try await recommended(spread, config: tight)
        #expect(plan.extraTime <= 5 * 60 * 1.1 + 1e-6)
        #expect(!plan.waypoints.isEmpty)
    }

    @Test func choosesLessThanTheCapWhenMoreIsNotWorthIt() async throws {
        var greedy = PlannerConfig.selection
        greedy.minValuePerMinute = 0
        let filled = try await recommended(spread, config: greedy)
        let chosen = try await recommended(spread)
        #expect(chosen.extraTime < filled.extraTime)
        #expect(!chosen.waypoints.isEmpty)
    }

    @Test func usesAWorthItStopWhenOneExists() async throws {
        // Never worse than Direct: a stop well worth its minutes is visited.
        let gem = Grid.poi("gem", east: 1000, north: 300, score: 90)
        let plans = try await Planner(config: .selection).plans(
            PlanRequest(origin: Grid.origin, destination: Grid.destination, mode: .direct, pois: [gem]),
            provider: HaversineWalkingTime())
        #expect(plans[.direct]!.waypoints.isEmpty)
        #expect(plans[.recommended]!.waypoints.map(\.id) == ["gem"])
        #expect(!plans[.recommended]!.noDetourFit)
        #expect(plans[.recommended]!.extraTime > 0)
    }

    @Test func prunesALowValueDistantStop() async throws {
        // On estimates "far" is worth it (60 points for ~4 min); real routing
        // to it is 1.4× slower, so it costs ~18 min: under the cap, but only
        // ~3 points a minute. It is dropped; "good" stays.
        let good = Grid.poi("good", east: 1000, north: 300, score: 90)
        let far = Grid.poi("far", east: 1500, north: -500, category: .shop, score: 60)
        let slow = SlowStopWalkingTime(slow: far.coordinate, factor: 1.4)

        let onEstimates = try await recommended([good, far])
        #expect(Set(onEstimates.waypoints.map(\.id)) == ["good", "far"])

        let plan = try await recommended([good, far], provider: slow)
        #expect(plan.waypoints.map(\.id) == ["good"])
        #expect(plan.candidates.first { $0.poi.id == "far" }?.status == .rejected(.notWorthIt))
        #expect(plan.legs.count == 2)
        #expect(abs(plan.totalTime - plan.legs.reduce(0) { $0 + $1.duration }) < 1e-6)

        // Alone, it leaves nothing worth a detour: the plan is Direct.
        let alone = try await recommended([far], provider: slow)
        #expect(alone.waypoints.isEmpty)
        #expect(alone.noDetourFit)
        #expect(alone.legs == [alone.baseline])
        #expect(alone.candidates.first?.status == .rejected(.notWorthIt))
    }

    @Test func noDetourFitWhenNothingIsWorthIt() async throws {
        // 40 points for ~9 minutes: under 6 a minute. The on-route mural is
        // still listed, exactly as on Direct.
        let distant = Grid.poi("distant", east: 1000, north: 800, score: 40)
        let mural = Grid.poi("mural", east: 1000, north: 20, kind: .passby)
        let plans = try await Planner(config: .selection).plans(
            PlanRequest(origin: Grid.origin, destination: Grid.destination, mode: .direct, pois: [distant, mural]),
            provider: HaversineWalkingTime())
        let direct = plans[.direct]!, recommended = plans[.recommended]!
        #expect(recommended.waypoints.isEmpty)
        #expect(recommended.noDetourFit)
        #expect(recommended.extraTime == 0)
        #expect(recommended.legs == direct.legs)
        #expect(recommended.highlights == direct.highlights)
        #expect(recommended.highlights.map(\.poi.id) == ["mural"])
    }

    @Test func everyStopIsWorthItsRealMinutes() async throws {
        var rng = SplitMix64(seed: 2026)
        let config = PlannerConfig()
        let h = HaversineWalkingTime()
        for _ in 0..<30 {
            let origin = Grid.at(east: .random(in: -1000...1000, using: &rng), north: .random(in: -1000...1000, using: &rng))
            let destination = Grid.at(east: .random(in: 0...3000, using: &rng), north: .random(in: -1500...1500, using: &rng))
            let request = PlanRequest(origin: origin, destination: destination, mode: .recommended,
                                      pois: randomPOIs(count: 80, using: &rng))
            let plan = try await Planner(config: config).plan(request, provider: h)
            #expect(plan.extraTime <= config.recommendedMaxExtra * 1.1 + 1e-6)
            #expect(plan.noDetourFit == plan.waypoints.isEmpty)
            let stops = [origin] + plan.waypoints.map(\.coordinate) + [destination]
            for (i, poi) in plan.waypoints.enumerated() {
                let marginal = h.seconds(from: stops[i], to: stops[i + 1]) + h.seconds(from: stops[i + 1], to: stops[i + 2])
                    - h.seconds(from: stops[i], to: stops[i + 2])
                let perMinute = Double(poi.score) / (max(marginal, config.minExtraTimeForRatio) / 60)
                #expect(perMinute >= config.minValuePerMinute - 1e-9)
            }
        }
    }

    @Test func isDeterministic() async throws {
        var rng = SplitMix64(seed: 11)
        let pois = randomPOIs(count: 200, using: &rng)
        for provider in [HaversineWalkingTime() as WalkingTimeProvider, NoisyWalkingTime()] {
            let first = try await recommended(pois, config: PlannerConfig(), provider: provider)
            let second = try await recommended(pois, config: PlannerConfig(), provider: provider)
            #expect(first == second)
            let shuffled = try await recommended(pois.reversed(), config: PlannerConfig(), provider: provider)
            #expect(shuffled.waypoints == first.waypoints)
            #expect(shuffled.extraTime == first.extraTime)
        }
    }

    @Test func defaults() {
        #expect(PlannerConfig.default.recommendedMaxExtra == 25 * 60)
        #expect(PlannerConfig.default.minValuePerMinute == 6)
    }
}
