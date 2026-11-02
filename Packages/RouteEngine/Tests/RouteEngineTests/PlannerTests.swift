import Foundation
import Testing
@testable import RouteEngine

struct PlannerTests {
    let planner = Planner(config: .selection)
    let provider = HaversineWalkingTime()

    func plan(_ pois: [POI], budget: TimeInterval, interests: Set<POICategory> = Set(POICategory.allCases),
              weights: SignalWeights? = nil,
              planner: Planner = Planner(config: .selection), provider: WalkingTimeProvider = HaversineWalkingTime()) async throws -> WanderPlan {
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

        var config = PlannerConfig.selection
        config.maxWaypoints = 1
        let one = try await plan(spread, budget: 60 * 60, planner: Planner(config: config))
        #expect(one.waypoints.count == 1)
        #expect(one.candidates.contains { $0.status == .rejected(.maxWaypoints) })
    }

    @Test func explorerAllowsFiveStopsRelaxedThree() async throws {
        func modePlan(_ mode: Mode) async throws -> WanderPlan {
            try await Planner(config: .selection).plan(PlanRequest(origin: Grid.origin, destination: Grid.destination,
                                                 mode: mode, pois: spread), provider: HaversineWalkingTime())
        }
        let relaxed = try await modePlan(.relaxed)
        let explorer = try await modePlan(.explorer)
        #expect(relaxed.waypoints.count == 3)
        #expect(explorer.waypoints.count == 5)
        // Five slots allow three of a category (food stays at one).
        for category in POICategory.allCases {
            #expect(explorer.waypoints.filter { $0.category == category }.count <= (category == .photo ? 3 : 1))
        }
    }

    @Test func respectsMinSpacing() async throws {
        // A tight cluster of excellent POIs: only one may be chosen. They run
        // away from the route 50 m apart, so the others stay more than
        // passbyRadius from the detour and don't become free highlights.
        let cluster = (0..<3).map { i in
            Grid.poi("c\(i)", east: 1000, north: 200 + Double(i) * 50, category: POICategory.allCases[i % 3], score: 100)
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

    @Test func atMostOneFoodStopUnlessFoodOnly() async throws {
        // Food is the most valuable thing around, but only one food stop is allowed.
        let food = (0..<4).map { i in
            Grid.poi("f\(i)", east: 300 + Double(i) * 450, north: 150, category: .food, score: 95)
        }
        let sights = (0..<2).map { i in Grid.poi("s\(i)", east: 600 + Double(i) * 700, north: -150, score: 60) }
        let mixed = try await plan(food + sights, budget: 60 * 60)
        #expect(mixed.waypoints.filter { $0.category == .food }.count == 1)
        #expect(mixed.waypoints.count == 3)

        // With a free slot left, the cap is what keeps the other food out.
        var roomy = PlannerConfig.selection
        roomy.maxWaypoints = 4
        let spare = try await plan(food + sights, budget: 60 * 60, planner: Planner(config: roomy))
        #expect(spare.waypoints.filter { $0.category == .food }.count == 1)
        #expect(spare.candidates.contains { $0.poi.category == .food && $0.status == .rejected(.categoryCap) })

        let foodOnly = try await plan(food + sights, budget: 60 * 60, interests: [.food])
        #expect(foodOnly.waypoints.filter { $0.category == .food }.count == 2)

        var config = PlannerConfig.selection
        config.categoryLimits = [:]
        let unlimited = try await plan(food + sights, budget: 60 * 60, planner: Planner(config: config))
        #expect(unlimited.waypoints.filter { $0.category == .food }.count == 2)
    }

    @Test func atMostOneShopUnlessShopsOnly() async throws {
        let shops = (0..<4).map { i in
            Grid.poi("s\(i)", east: 300 + Double(i) * 450, north: 250, category: .shop, score: 95)
        }
        let sights = (0..<2).map { i in Grid.poi("p\(i)", east: 600 + Double(i) * 700, north: -250, score: 60) }
        let mixed = try await plan(shops + sights, budget: 60 * 60)
        #expect(mixed.waypoints.filter { $0.category == .shop }.count == 1)
        let shopsOnly = try await plan(shops + sights, budget: 60 * 60, interests: [.shop])
        #expect(shopsOnly.waypoints.filter { $0.category == .shop }.count == 2)
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

    @Test func prefersHigherValueWithinBudget() async throws {
        // Ranking is by total value, not value per minute: the better place wins
        // when the budget allows it.
        let close = Grid.poi("close", east: 1000, north: 100, score: 60)
        let far = Grid.poi("far", east: 1000, north: 700, score: 70)
        var config = PlannerConfig.selection
        config.maxWaypoints = 1
        let result = try await plan([close, far], budget: 30 * 60, planner: Planner(config: config))
        #expect(result.waypoints.map(\.id) == ["far"])
    }

    @Test func equalValuePrefersLessTime() async throws {
        let close = Grid.poi("close", east: 1000, north: 100, score: 70)
        let far = Grid.poi("far", east: 1000, north: 700, score: 70)
        var config = PlannerConfig.selection
        config.maxWaypoints = 1
        let result = try await plan([close, far], budget: 30 * 60, planner: Planner(config: config))
        #expect(result.waypoints.map(\.id) == ["close"])
        #expect(result.candidates.first { $0.poi.id == "far" }?.status == .rejected(.maxWaypoints))
    }

    @Test func explorerSpendsItsBudgetOnABetterSet() async throws {
        // Three decent places hug the route; a great one needs a ~13 min detour.
        // Relaxed can't afford it; Explorer should trade a near place for it.
        let near = [
            Grid.poi("near0", east: 400, north: 60, category: .photo, score: 50),
            Grid.poi("near1", east: 1000, north: 60, category: .food, score: 50),
            Grid.poi("near2", east: 1600, north: 60, category: .shop, score: 50),
        ]
        let great = Grid.poi("great", east: 1000, north: 1000, category: .photo, score: 95)
        let relaxed = try await plan(near + [great], budget: Mode.relaxed.budget)
        let explorer = try await plan(near + [great], budget: Mode.explorer.budget)
        #expect(relaxed.waypoints.count == 3)
        #expect(!relaxed.waypoints.contains { $0.id == "great" })
        #expect(explorer.waypoints.contains { $0.id == "great" })
        #expect(explorer.extraTime > relaxed.extraTime + 5 * 60)
    }

    // MARK: Weights

    @Test func weightsChooseBySignals() async throws {
        var famous = Grid.poi("famous", east: 1000, north: 150, score: 50)
        famous.signals = Signals(photos: 0.2, fame: 0.9, quality: 0.5, independent: false)
        var photogenic = Grid.poi("photogenic", east: 1000, north: -150, score: 50)
        photogenic.signals = Signals(photos: 0.9, fame: 0.1, quality: 0.5, independent: true)
        var config = PlannerConfig.selection
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

    @Test func stopsOnRouteAreFreeAndLeaveSlotsForDetours() async throws {
        // Cafés right on the fast route used to fill every waypoint slot at ~0 min.
        // cafe0 sits by the start, so it stays on the route whatever the detour.
        let onRoute = (0..<4).map { i in
            Grid.poi("cafe\(i)", east: 30 + Double(i) * 600, north: 10, category: .food, score: 60)
        }
        let detour = Grid.poi("palace", east: 1000, north: 300, score: 90, kind: .passby)
        let result = try await plan(onRoute + [detour], budget: 25 * 60)
        #expect(result.waypoints.map(\.id) == ["palace"])
        let free = result.highlights.filter { $0.role == .passby }.map(\.poi.id)
        #expect(free.contains("cafe0"))
        #expect(result.candidates.first { $0.poi.id == "cafe0" }?.status == .passby)
    }

    @Test func belowMinimumValueIsNeverAWaypoint() async throws {
        let weak = Grid.poi("weak", east: 1000, north: 200, category: .shop, score: 28)
        let result = try await plan([weak], budget: 25 * 60)
        #expect(result.waypoints.isEmpty)
        #expect(result.candidates.first?.status == .rejected(.lowValue))

        var config = PlannerConfig.selection
        config.minWaypointValue = 20
        let lenient = try await plan([weak], budget: 25 * 60, planner: Planner(config: config))
        #expect(lenient.waypoints.map(\.id) == ["weak"])
    }

    @Test func overBudgetBeatsMaxWaypointsInDebug() async throws {
        var config = PlannerConfig.selection
        config.maxWaypoints = 1
        let near = Grid.poi("near", east: 1000, north: 200, score: 90)
        let far = Grid.poi("far", east: 1000, north: 1500, score: 90)
        let result = try await plan([near, far], budget: 5 * 60, planner: Planner(config: config))
        #expect(result.waypoints.map(\.id) == ["near"])
        // "far" cannot fit the budget at all; that is the more useful label.
        #expect(result.candidates.first { $0.poi.id == "far" }?.status == .rejected(.overBudget)
                || result.candidates.first { $0.poi.id == "far" }?.status == .rejected(.outsideCorridor))
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

            let estimated = try await Planner().plan(request, provider: provider)
            #expect(estimated.extraTime <= budget + 1e-6)
            #expect(estimated.waypoints.count <= 3)

            // Real routing slower than the estimate: within the 10% tolerance.
            let noisy = try await Planner().plan(request, provider: NoisyWalkingTime())
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

    // MARK: Top-up and modes

    /// Three stops 600 m off the route: on estimates two fit 10 minutes
    /// (about 8.6 min), all three don't (about 11.9 min).
    var farStops: [POI] {
        [300.0, 1000, 1700].enumerated().map { i, east in
            Grid.poi("f\(i)", east: east, north: 600, category: POICategory.allCases[i], score: 70)
        }
    }

    @Test func topsUpWhenRealRoutesBeatTheEstimate() async throws {
        var off = PlannerConfig.selection
        off.topUpBelow = 0
        let request = PlanRequest(origin: Grid.origin, destination: Grid.destination, budget: 10 * 60,
                                  pois: farStops, maxWaypoints: 5)
        let without = try await Planner(config: off).plan(request, provider: FastWalkingTime())
        let with = try await Planner(config: .selection).plan(request, provider: FastWalkingTime())
        #expect(without.waypoints.count == 2)
        #expect(without.extraTime < 0.7 * 10 * 60)
        #expect(with.waypoints.count == 3)
        #expect(with.extraTime > without.extraTime)
        #expect(with.extraTime <= 10 * 60 * 1.1)
        // The first pick is kept; top-up only adds.
        #expect(Set(without.waypoints.map(\.id)).isSubset(of: Set(with.waypoints.map(\.id))))
    }

    @Test func explorerAddsAStopRelaxedDoesNotHave() async throws {
        let plans = try await Planner(config: .selection).plans(
            PlanRequest(origin: Grid.origin, destination: Grid.destination, mode: .direct, pois: spread),
            provider: HaversineWalkingTime())
        let relaxed = Set(plans[.relaxed]!.waypoints.map(\.id))
        let explorer = Set(plans[.explorer]!.waypoints.map(\.id))
        #expect(!relaxed.isEmpty)
        #expect(!explorer.isSubset(of: relaxed))
        #expect(plans[.direct]!.waypoints.isEmpty)

        // Asked to differ from its own best plan, a mode finds another walk.
        let request = PlanRequest(origin: Grid.origin, destination: Grid.destination, mode: .relaxed, pois: spread)
        let first = try await Planner(config: .selection).plan(request, provider: HaversineWalkingTime())
        let second = try await Planner(config: .selection).plan(request, provider: HaversineWalkingTime(), distinctFrom: [first])
        #expect(!Set(second.waypoints.map(\.id)).isSubset(of: Set(first.waypoints.map(\.id))))
    }

    @Test func keepsTheSameStopsWhenNothingNewFits() async throws {
        // Only two POIs exist; Explorer can't add anything new, and dropping
        // one just to differ would make it worse than Relaxed.
        let two = [Grid.poi("a", east: 500, north: 150), Grid.poi("b", east: 1500, north: -150, category: .shop)]
        let plans = try await Planner(config: .selection).plans(
            PlanRequest(origin: Grid.origin, destination: Grid.destination, mode: .direct, pois: two),
            provider: HaversineWalkingTime())
        #expect(Set(plans[.relaxed]!.waypoints.map(\.id)) == ["a", "b"])
        #expect(Set(plans[.explorer]!.waypoints.map(\.id)) == ["a", "b"])
    }

    @Test func modesShareRealLegs() async throws {
        let request = PlanRequest(origin: Grid.origin, destination: Grid.destination, mode: .direct, pois: spread)
        let together = CountingWalkingTime()
        _ = try await Planner(config: .selection).plans(request, provider: together)
        let separate = CountingWalkingTime()
        for mode in Mode.allCases {
            var r = request
            r.budget = mode.budget
            r.maxWaypoints = mode.maxWaypoints
            _ = try await Planner(config: .selection).plan(r, provider: separate)
        }
        #expect(await together.counter.count < separate.counter.count)
    }

    @Test func modesNeverExceedBudgets() async throws {
        var rng = SplitMix64(seed: 99)
        for _ in 0..<60 {
            let origin = Grid.at(east: .random(in: -1000...1000, using: &rng), north: .random(in: -1000...1000, using: &rng))
            let destination = Grid.at(east: .random(in: 0...3000, using: &rng), north: .random(in: -1500...1500, using: &rng))
            let request = PlanRequest(origin: origin, destination: destination, mode: .direct,
                                      pois: randomPOIs(count: 80, using: &rng))
            for provider in [FastWalkingTime() as WalkingTimeProvider, NoisyWalkingTime(), HaversineWalkingTime()] {
                let plans = try await Planner().plans(request, provider: provider)
                for (mode, plan) in plans {
                    #expect(plan.extraTime <= mode.budget * 1.1 + 1e-6)
                    #expect(plan.waypoints.count <= mode.maxWaypoints)
                }
                let relaxed = Set(plans[.relaxed]!.waypoints.map(\.id))
                let explorer = Set(plans[.explorer]!.waypoints.map(\.id))
                if !relaxed.isEmpty && !explorer.isEmpty && explorer.isSubset(of: relaxed) {
                    // Allowed only when Explorer couldn't add anything: same stops.
                    #expect(explorer == relaxed)
                }
            }
        }
    }

    // MARK: Seen

    @Test func seenPlacesGiveWayToNewOnes() async throws {
        let request = PlanRequest(origin: Grid.origin, destination: Grid.destination, mode: .relaxed, pois: spread)
        let first = try await Planner(config: .selection).plan(request, provider: HaversineWalkingTime())
        var again = request
        again.seen = Set(first.waypoints.map(\.id))
        let second = try await Planner(config: .selection).plan(again, provider: HaversineWalkingTime())
        #expect(!second.waypoints.isEmpty)
        #expect(Set(first.waypoints.map(\.id)).isDisjoint(with: Set(second.waypoints.map(\.id))))
        for poi in first.waypoints {
            let debug = second.candidates.first { $0.poi.id == poi.id }!
            #expect(abs(debug.value - Double(poi.score) * 0.2) < 1e-9)
            #expect(debug.status == .rejected(.seen) || debug.status == .passby)
        }
    }

    // MARK: Freeing stops on the way

    @Test func waypointsAreNeverOnTheWay() async throws {
        let request = PlanRequest(origin: Grid.origin, destination: Grid.destination, mode: .relaxed, pois: spread)
        let kept = try await Planner(config: .selection).plan(request, provider: HaversineWalkingTime())
        let freeing = try await Planner().plan(request, provider: HaversineWalkingTime())

        // Every remaining waypoint costs a real minute or more.
        let stops = [Grid.origin] + freeing.waypoints.map(\.coordinate) + [Grid.destination]
        let h = HaversineWalkingTime()
        for i in freeing.waypoints.indices {
            let detour = h.seconds(from: stops[i], to: stops[i + 1]) + h.seconds(from: stops[i + 1], to: stops[i + 2])
                - h.seconds(from: stops[i], to: stops[i + 2])
            #expect(detour >= 60 - 1e-6)
        }
        // Selection alone would have spent slots on near-free stops.
        #expect(Set(kept.waypoints.map(\.id)) != Set(freeing.waypoints.map(\.id)))
        #expect(!freeing.noDetourFit)
        #expect(freeing.extraTime <= Mode.relaxed.budget * 1.1)
    }

    @Test func freedSlotsGoToTheTopUp() async throws {
        // One slot. "gem" is the most valuable and the estimate puts it 90 s
        // off the way, but real routing (0.6×) does it in ~54 s: it's freed
        // into a highlight and the slot goes to a real detour.
        let gem = Grid.poi("gem", east: 1000, north: 308, score: 95)
        let request = PlanRequest(origin: Grid.origin, destination: Grid.destination, budget: 10 * 60,
                                  pois: [gem] + farStops, maxWaypoints: 1)
        let kept = try await Planner(config: .selection).plan(request, provider: FastWalkingTime())
        #expect(kept.waypoints.map(\.id) == ["gem"])
        let plan = try await Planner().plan(request, provider: FastWalkingTime())
        #expect(plan.waypoints.count == 1)
        #expect(plan.waypoints.first?.id.hasPrefix("f") == true)
        #expect(plan.highlights.contains { $0.poi.id == "gem" && $0.role == .passby })
        #expect(plan.extraTime > kept.extraTime)
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
