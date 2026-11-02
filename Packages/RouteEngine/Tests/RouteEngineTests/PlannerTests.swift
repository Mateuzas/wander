import Foundation
import Testing
@testable import RouteEngine

struct PlannerTests {
    let planner = Planner()
    let provider = HaversineWalkingTime()

    func plan(_ pois: [POI], budget: TimeInterval, interests: Set<POICategory> = Set(POICategory.allCases),
              weights: SignalWeights? = nil,
              planner: Planner = Planner(), provider: WalkingTimeProvider = HaversineWalkingTime()) async throws -> WanderPlan {
        let request = PlanRequest(origin: Grid.origin, destination: Grid.destination,
                                  budget: budget, interests: interests, weights: weights, pois: pois)
        return try await planner.plan(request, provider: provider)
    }

    /// Many attractive POIs spread around the corridor.
    var spread: [POI] {
        var pois: [POI] = []
        for i in 0..<10 {
            let east = 100 + Double(i) * 200
            pois.append(Grid.poi("n\(i)", east: east, north: 250, category: POICategory.allCases[i % 3], score: 90))
            pois.append(Grid.poi("s\(i)", east: east, north: -250, category: POICategory.allCases[(i + 1) % 3], score: 85))
        }
        return pois
    }

    // MARK: Budget 0

    @Test func budgetZeroReturnsBaseline() async throws {
        let onRoute = Grid.poi("mural", east: 1000, north: 20, kind: .passby)
        let result = try await plan(spread + [onRoute], budget: Mode.direct.budget)
        #expect(result.waypoints.isEmpty)
        #expect(result.legs == [result.baseline])
        #expect(result.extraTime == 0)
        #expect(result.noDetourFit == false)
        #expect(result.highlights.map(\.poi.id) == ["mural"])
        #expect(result.highlights.first?.role == .passby)
        #expect(result.candidates.first { $0.poi.id == "n0" }?.status == .rejected(.noBudget))
    }

    @Test func budgetZeroMakesOneProviderCall() async throws {
        let counting = CountingWalkingTime()
        _ = try await plan(spread, budget: 0, provider: counting)
        #expect(await counting.counter.count == 1)
    }

    // MARK: Constraints

    @Test func respectsMaxWaypoints() async throws {
        let result = try await plan(spread, budget: 60 * 60)
        #expect(result.waypoints.count == 3)

        var config = PlannerConfig()
        config.maxWaypoints = 1
        let one = try await plan(spread, budget: 60 * 60, planner: Planner(config: config))
        #expect(one.waypoints.count == 1)
        #expect(one.candidates.contains { $0.status == .rejected(.maxWaypoints) })
    }

    @Test func respectsMinSpacing() async throws {
        // A tight cluster of excellent POIs: only one may be chosen.
        let cluster = (0..<6).map { i in
            Grid.poi("c\(i)", east: 1000 + Double(i) * 20, north: 200, category: POICategory.allCases[i % 3], score: 100)
        }
        let result = try await plan(cluster, budget: 30 * 60)
        #expect(result.waypoints.count == 1)
        #expect(result.candidates.contains { $0.status == .rejected(.tooClose) })

        let wide = try await plan(spread, budget: 60 * 60)
        for (i, a) in wide.waypoints.enumerated() {
            for b in wide.waypoints.dropFirst(i + 1) {
                #expect(a.coordinate.distance(to: b.coordinate) >= 150)
            }
        }
    }

    @Test func respectsCategoryCap() async throws {
        let photos = (0..<8).map { i in Grid.poi("p\(i)", east: 200 + Double(i) * 220, north: 150, score: 95) }
        let result = try await plan(photos, budget: 60 * 60)
        #expect(result.waypoints.count == 2)
        #expect(result.candidates.contains { $0.status == .rejected(.categoryCap) })

        let mixed = try await plan(spread, budget: 60 * 60)
        for category in POICategory.allCases {
            #expect(mixed.waypoints.filter { $0.category == category }.count <= 2)
        }
    }

    @Test func rejectsBacktracking() async throws {
        // Directly behind the origin: the A→p leg points backwards.
        let behind = Grid.poi("behind", east: -400, north: 0, score: 100)
        let result = try await plan([behind], budget: 30 * 60)
        #expect(result.waypoints.isEmpty)
        #expect(result.noDetourFit)
        #expect(result.candidates.first?.status == .rejected(.backtracks))
    }

    @Test func respectsInterests() async throws {
        let result = try await plan(spread, budget: 60 * 60, interests: [.photo, .food])
        #expect(!result.waypoints.isEmpty)
        #expect(!result.waypoints.contains { $0.category == .shop })
        let shop = result.candidates.first { $0.poi.category == .shop }
        #expect(shop?.status == .rejected(.notInInterests))
        #expect(shop?.value == 0)
    }

    @Test func filtersOutsideCorridor() async throws {
        let far = Grid.poi("far", east: 1000, north: 3000, score: 100)
        let result = try await plan([far], budget: 10 * 60)
        #expect(result.candidates.first?.status == .rejected(.outsideCorridor))
        #expect(result.noDetourFit)
    }

    @Test func noDetourFitWhenNothingFits() async throws {
        let result = try await plan([], budget: 25 * 60)
        #expect(result.noDetourFit)
        #expect(result.legs == [result.baseline])
    }

    @Test func prefersBetterValueForTime() async throws {
        let close = Grid.poi("close", east: 1000, north: 100, score: 60)
        let far = Grid.poi("far", east: 1000, north: 700, score: 70)
        var config = PlannerConfig()
        config.maxWaypoints = 1
        let result = try await plan([close, far], budget: 30 * 60, planner: Planner(config: config))
        #expect(result.waypoints.map(\.id) == ["close"])
    }

    // MARK: Weights

    @Test func weightsChooseBySignals() async throws {
        var famous = Grid.poi("famous", east: 1000, north: 150, score: 50)
        famous.signals = Signals(photos: 0.2, fame: 0.9, quality: 0.5, independent: false)
        var photogenic = Grid.poi("photogenic", east: 1000, north: -150, score: 50)
        photogenic.signals = Signals(photos: 0.9, fame: 0.1, quality: 0.5, independent: true)
        var config = PlannerConfig()
        config.maxWaypoints = 1
        let one = Planner(config: config)

        let photoHunter = try await plan([famous, photogenic], budget: 30 * 60,
                                         weights: SignalWeights(photos: 1), planner: one)
        #expect(photoHunter.waypoints.map(\.id) == ["photogenic"])
        let sightseer = try await plan([famous, photogenic], budget: 30 * 60,
                                       weights: SignalWeights(fame: 1), planner: one)
        #expect(sightseer.waypoints.map(\.id) == ["famous"])
    }

    @Test func weightedValueScaleAndFallback() {
        let weights = SignalWeights(photos: 0.5, fame: 0.25, independent: 0.25)
        let signals = Signals(photos: 0.8, fame: 0.4, quality: 1, independent: true)
        #expect(abs(weights.value(of: signals)! - 100 * (0.4 + 0.1 + 0.25)) < 1e-9)
        #expect(SignalWeights().value(of: signals) == nil)

        let scorer = Scorer(config: PlannerConfig(), interests: [.photo], weights: weights)
        var withSignals = Grid.poi("a", east: 0, north: 0, score: 10)
        withSignals.signals = signals
        #expect(abs(scorer.value(withSignals) - 75) < 1e-9)
        #expect(scorer.value(Grid.poi("b", east: 0, north: 0, score: 42)) == 42)
        #expect(scorer.value(Grid.poi("c", east: 0, north: 0, category: .food, score: 42)) == 0)
    }

    @Test func zeroValueIsNeverAWaypoint() async throws {
        var chain = Grid.poi("chain", east: 1000, north: 150, category: .food, score: 70)
        chain.signals = Signals(photos: 0, fame: 0, quality: 0.5, independent: false)
        let result = try await plan([chain], budget: 30 * 60, weights: SignalWeights(fame: 1, independent: 1))
        #expect(result.waypoints.isEmpty)
        #expect(result.candidates.first?.status == .rejected(.noValue))
    }

    // MARK: Budget

    @Test func neverExceedsBudget() async throws {
        var rng = SplitMix64(seed: 42)
        for _ in 0..<150 {
            let origin = Grid.at(east: .random(in: -1000...1000, using: &rng), north: .random(in: -1000...1000, using: &rng))
            let destination = Grid.at(east: .random(in: 0...3000, using: &rng), north: .random(in: -1500...1500, using: &rng))
            let budget = Double.random(in: 0...(30 * 60), using: &rng)
            let pois = randomPOIs(count: 60, using: &rng)
            let request = PlanRequest(origin: origin, destination: destination, budget: budget, pois: pois)

            let estimated = try await planner.plan(request, provider: provider)
            #expect(estimated.extraTime <= budget + 1e-6)
            #expect(estimated.waypoints.count <= 3)

            // Real routing slower than the estimate: within the 10% tolerance.
            let noisy = try await planner.plan(request, provider: NoisyWalkingTime())
            #expect(noisy.extraTime <= budget * 1.1 + 1e-6)
        }
    }

    @Test func dropsWaypointsThatFailVerification() async throws {
        let slow = SlowDetourWalkingTime(origin: Grid.origin, destination: Grid.destination, factor: 3)
        let result = try await plan(spread, budget: 10 * 60, provider: slow)
        #expect(result.extraTime <= 10 * 60 * 1.1)
        #expect(result.candidates.contains { $0.status == .rejected(.failedVerification) })
        if result.waypoints.isEmpty { #expect(result.noDetourFit) }
    }

    @Test func eachModeStaysWithinItsBudget() async throws {
        for mode in Mode.allCases {
            let result = try await plan(spread, budget: mode.budget)
            #expect(result.extraTime <= mode.budget + 1e-6)
            #expect(abs(result.totalTime - result.baseline.duration - result.extraTime) < 1e-6)
        }
    }

    // MARK: Determinism

    @Test func isDeterministic() async throws {
        var rng = SplitMix64(seed: 7)
        let pois = randomPOIs(count: 200, using: &rng)
        let first = try await plan(pois, budget: Mode.explorer.budget)
        let second = try await plan(pois, budget: Mode.explorer.budget)
        #expect(first == second)

        // Input order must not change the route either.
        let shuffled = try await plan(pois.reversed(), budget: Mode.explorer.budget)
        #expect(shuffled.waypoints == first.waypoints)
        #expect(shuffled.legs == first.legs)
    }

    // MARK: Output

    @Test func highlightsAreOrderedAlongRouteAndDebugCoversEveryPOI() async throws {
        let mural = Grid.poi("mural", east: 300, north: 10, kind: .passby)
        let pois = spread + [mural]
        let result = try await plan(pois, budget: Mode.explorer.budget)
        let along = result.highlights.map(\.distanceAlongRoute)
        #expect(along == along.sorted())
        #expect(Set(result.highlights.filter { $0.role == .waypoint }.map(\.poi.id)) == Set(result.waypoints.map(\.id)))
        #expect(result.candidates.map(\.poi.id) == pois.map(\.id))
        #expect(result.candidates.filter { $0.status == .waypoint }.count == result.waypoints.count)
        #expect(result.legs.count == result.waypoints.count + 1)
        #expect(result.legs.first?.from == Grid.origin)
        #expect(result.legs.last?.to == Grid.destination)
    }

    @Test func modeBudgets() {
        #expect(Mode.direct.budget == 0)
        #expect(Mode.relaxed.budget == 600)
        #expect(Mode.explorer.budget == 1500)
    }
}
