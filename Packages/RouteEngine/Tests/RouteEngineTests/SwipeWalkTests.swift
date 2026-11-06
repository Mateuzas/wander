import Foundation
import Testing
@testable import RouteEngine

/// Swipe walks (ADR 016, CONTRACTS §2 "Swipe walks", BE-16).
struct SwipeWalkTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let everything = DeckArea.circle(center: Grid.origin, radius: 5000)

    func poi(_ id: String, east: Double, north: Double, category: POICategory = .photo, score: Int = 80,
             tier: Int? = 2, type: String? = nil, signals: Signals? = nil) -> POI {
        var p = Grid.poi(id, east: east, north: north, category: category, score: score)
        p.tier = tier
        p.type = type
        p.signals = signals
        return p
    }

    func ids(_ pois: [POI]) -> [String] { pois.map(\.id) }

    // MARK: Deck

    @Test func deckFiltersKinds() {
        let gem = Signals(photos: 0.2, fame: 0.1, quality: 0.8, independent: true)
        let pois = [
            poi("sight", east: 0, north: 0),
            poi("cafe", east: 300, north: 0, category: .food),
            poi("books", east: 600, north: 0, category: .shop),
            poi("gemShop", east: 900, north: 0, category: .shop, tier: 3, signals: gem),
            poi("famous", east: 0, north: 300, category: .food, tier: 3,
                signals: Signals(photos: 0.2, fame: 0.5, quality: 0.8, independent: true)),
            poi("chain", east: 300, north: 300, category: .food, tier: 3,
                signals: Signals(photos: 0.2, fame: 0.1, quality: 0.8, independent: false)),
            poi("sloppy", east: 600, north: 300, category: .food, tier: 3,
                signals: Signals(photos: 0.2, fame: 0.1, quality: 0.5, independent: true)),
            poi("mustSee", east: 900, north: 300, category: .food, tier: 1, signals: gem),
        ]
        func d(_ kinds: Set<DeckKind>) -> Set<String> {
            Set(ids(deck(pois: pois, area: everything, kinds: kinds, memory: SwipeMemory(), seen: [], now: now)))
        }
        #expect(d([.sights]) == ["sight"])
        #expect(d([.food]) == ["cafe", "famous", "chain", "sloppy", "mustSee"])
        #expect(d([.shops]) == ["books", "gemShop"])
        #expect(d([.hiddenGems]) == ["gemShop"])
        #expect(d([.sights, .hiddenGems]) == ["sight", "gemShop"])
        #expect(d([]).isEmpty)
    }

    @Test func deckOrdersByTierThenSpreadsAcrossCells() {
        let pois = [
            poi("t3", east: 0, north: 0, score: 100, tier: 3),
            poi("a90", east: 10, north: 10, score: 90),
            poi("a89", east: 20, north: 20, score: 89),
            poi("a88", east: 30, north: 30, score: 88),
            poi("b50", east: 1000, north: 1000, score: 50),
            poi("c60", east: -1000, north: 500, score: 60),
            poi("t1", east: 500, north: 0, score: 10, tier: 1),
        ]
        let result = deck(pois: pois, area: everything, kinds: [.sights], memory: SwipeMemory(), seen: [], now: now)
        // Tier 1, then the best of each tier-2 cell, then the next round, then tier 3.
        #expect(ids(result) == ["t1", "a90", "c60", "b50", "a89", "a88", "t3"])
    }

    @Test func deckUsesAffinityAsTiebreak() {
        let pois = [
            poi("a", east: 0, north: 0, type: "church"),
            poi("b", east: 1000, north: 0, type: "mural"),
        ]
        var memory = SwipeMemory()
        #expect(ids(deck(pois: pois, area: everything, kinds: [.sights], memory: memory, seen: [], now: now)) == ["a", "b"])
        memory.record(.love, for: poi("old", east: 0, north: 0, type: "mural"), at: now)
        #expect(memory.affinity(for: pois[1]) > memory.affinity(for: pois[0]))
        #expect(ids(deck(pois: pois, area: everything, kinds: [.sights], memory: memory, seen: [], now: now)) == ["b", "a"])
    }

    @Test func memoryHidesNopesFor90Days() {
        let pois = (0..<4).map { poi("p\($0)", east: Double($0) * 400, north: 0) }
        var memory = SwipeMemory()
        memory.record(.nope, for: pois[0], at: now.addingTimeInterval(-10 * 86_400))
        memory.record(.nope, for: pois[1], at: now.addingTimeInterval(-91 * 86_400))
        memory.record(.like, for: pois[2], at: now)
        #expect(memory.hidden(now: now) == ["p0"])
        let result = deck(pois: pois, area: everything, kinds: [.sights], memory: memory, seen: [], now: now)
        #expect(Set(ids(result)) == ["p1", "p2", "p3"])
        memory.forget("p0")
        #expect(memory.hidden(now: now).isEmpty)
        // Codable round trip.
        let data = try! JSONEncoder().encode(memory)
        #expect(try! JSONDecoder().decode(SwipeMemory.self, from: data) == memory)
    }

    @Test func seenPlacesSinkToTheEnd() {
        let pois = [poi("famous", east: 0, north: 0, tier: 1), poi("detail", east: 500, north: 0, tier: 3)]
        let result = deck(pois: pois, area: everything, kinds: [.sights], memory: SwipeMemory(),
                          seen: ["famous"], now: now)
        #expect(ids(result) == ["detail", "famous"])
    }

    @Test func circleAndBandAreas() {
        let pois = [
            poi("mid", east: 1000, north: 300),
            poi("farSide", east: 1000, north: 600),
            poi("pastEnd", east: 2600, north: 0),
            poi("nearEnd", east: 2300, north: 0),
            poi("nearStart", east: -100, north: 100),
        ]
        let band = DeckArea.band(start: Grid.origin, end: Grid.destination, halfWidth: 500)
        let inBand = deck(pois: pois, area: band, kinds: [.sights], memory: SwipeMemory(), seen: [], now: now)
        #expect(Set(ids(inBand)) == ["mid", "nearEnd", "nearStart"])
        let circle = DeckArea.circle(center: Grid.origin, radius: 1100)
        let inCircle = deck(pois: pois, area: circle, kinds: [.sights], memory: SwipeMemory(), seen: [], now: now)
        #expect(Set(ids(inCircle)) == ["mid", "nearStart"])
    }

    @Test func deckIsDeterministic() {
        var rng = SplitMix64(seed: 7)
        let pois = (0..<80).map { i in
            poi("p\(i)", east: Double.random(in: -900...900, using: &rng), north: Double.random(in: -900...900, using: &rng),
                category: POICategory.allCases[i % 3], score: Int.random(in: 40...60, using: &rng),
                tier: Int.random(in: 1...3, using: &rng))
        }
        let a = deck(pois: pois, area: everything, kinds: Set(DeckKind.allCases), memory: SwipeMemory(), seen: [], now: now)
        let b = deck(pois: pois.shuffled(using: &rng), area: everything, kinds: Set(DeckKind.allCases),
                     memory: SwipeMemory(), seen: [], now: now)
        #expect(a.count == 80)
        #expect(ids(a) == ids(b))
    }

    // MARK: Estimate

    func bruteForceMinutes(start: Coordinate, end: WalkEnd, stops: [POI]) -> Double {
        let est = HaversineWalkingTime()
        var best = Double.infinity
        func permute(_ rest: [POI], _ path: [POI]) {
            if rest.isEmpty {
                var points = [start] + path.map(\.coordinate)
                if case .destination(let d) = end { points.append(d) }
                best = min(best, zip(points, points.dropFirst()).reduce(0) { $0 + est.seconds(from: $1.0, to: $1.1) })
                return
            }
            for i in rest.indices {
                var r = rest
                let next = r.remove(at: i)
                permute(r, path + [next])
            }
        }
        permute(stops, [])
        return best / 60
    }

    @Test func estimateMatchesBruteForceOnSmallSets() {
        var rng = SplitMix64(seed: 11)
        var worst = 1.0, exact = 0, total = 0
        for round in 0..<60 {
            let n = 1 + round % 7
            let stops = (0..<n).map { i in
                poi("s\(i)", east: Double.random(in: -1000...1000, using: &rng),
                    north: Double.random(in: -1000...1000, using: &rng))
            }
            for end in [WalkEnd.anywhere, .destination(Grid.at(east: 800, north: -300))] {
                let estimate = estimateWalkMinutes(start: Grid.origin, end: end, stops: stops)
                let optimum = bruteForceMinutes(start: Grid.origin, end: end, stops: stops)
                #expect(estimate >= optimum - 1e-9)
                worst = max(worst, estimate / optimum)
                if estimate <= optimum + 1e-6 { exact += 1 }
                total += 1
            }
        }
        print("estimate vs brute force: worst \(worst), exact \(exact)/\(total)")
        #expect(worst <= 1.08)   // heuristic: 116/120 exact, worst 5.3% over at seed 11
        #expect(Double(exact) >= 0.95 * Double(total))
    }

    @Test func estimateHandlesEmptyAndEnd() {
        #expect(estimateWalkMinutes(start: Grid.origin, end: .anywhere, stops: []) == 0)
        let toDestination = estimateWalkMinutes(start: Grid.origin, end: .destination(Grid.destination), stops: [])
        #expect(abs(toDestination - 2000 * 1.3 / 1.35 / 60) < 0.1)
    }

    @Test func estimateIsFastFor25Stops() {
        var rng = SplitMix64(seed: 3)
        let stops = (0..<25).map { i in
            poi("s\(i)", east: Double.random(in: -1500...1500, using: &rng), north: Double.random(in: -1500...1500, using: &rng))
        }
        let clock = ContinuousClock()
        var fastest = Duration.seconds(1)
        for _ in 0..<5 {
            let elapsed = clock.measure {
                _ = estimateWalkMinutes(start: Grid.origin, end: .destination(Grid.destination), stops: stops)
            }
            fastest = min(fastest, elapsed)
        }
        print("estimateWalkMinutes, 25 stops: \(fastest)")
        #expect(fastest < .milliseconds(5))
    }

    // MARK: planWalk

    let planner = Planner()
    let provider = HaversineWalkingTime()

    @Test func includesEveryMustVisitAndStretches() async throws {
        let must = [poi("far1", east: 3000, north: 0), poi("far2", east: 0, north: 3000), poi("far3", east: -3000, north: 0)]
        let optional = [poi("near", east: 100, north: 0, score: 100)]
        let walk = try await planner.planWalk(start: Grid.origin, end: .anywhere, mustVisit: must, optional: optional,
                                              budget: 30 * 60, provider: provider)
        #expect(Set(ids(walk.included)) == ["far1", "far2", "far3"])
        #expect(walk.stretched)
        #expect(walk.plan.totalTime > 30 * 60)
        #expect(ids(walk.skipped) == ["near"])
        #expect(walk.mustVisitIDs == ["far1", "far2", "far3"])
    }

    @Test func notStretchedWhenItFits() async throws {
        let must = [poi("a", east: 300, north: 0), poi("b", east: 600, north: 100)]
        let walk = try await planner.planWalk(start: Grid.origin, end: .anywhere, mustVisit: must, optional: [],
                                              budget: 30 * 60, provider: provider)
        #expect(!walk.stretched)
        #expect(ids(walk.included) == ["a", "b"])
        #expect(abs(walk.estimatedMinutes * 60 - walk.plan.totalTime) < 1)
    }

    @Test func fillsBudgetWithBestValuePerMinute() async throws {
        var rng = SplitMix64(seed: 5)
        let optional = (0..<30).map { i in
            poi("o\(i)", east: Double.random(in: -1500...1500, using: &rng), north: Double.random(in: -1500...1500, using: &rng),
                score: Int.random(in: 30...100, using: &rng))
        }
        let must = [poi("m", east: 500, north: 500)]
        let budget: TimeInterval = 60 * 60
        let walk = try await planner.planWalk(start: Grid.origin, end: .anywhere, mustVisit: must, optional: optional,
                                              budget: budget, provider: provider)
        #expect(walk.included.contains { $0.id == "m" })
        #expect(walk.included.count > 4)
        #expect(walk.plan.totalTime <= budget * 1.1)
        #expect(walk.plan.totalTime >= budget * 0.8)
        #expect(!walk.stretched)
        #expect(walk.included.count + walk.skipped.count == 31)
        // Every leftover would break the budget at its cheapest insertion.
        let stops = walk.included
        for poi in walk.skipped {
            var best = Double.infinity
            for k in 0...stops.count {
                var s = stops
                s.insert(poi, at: k)
                best = min(best, planner.estimatedSeconds(start: Grid.origin, end: .anywhere, stops: s))
            }
            #expect(best > budget - 1)
        }
    }

    @Test func prefersHigherValueWhenOnlyOneFits() async throws {
        let optional = [poi("low", east: 0, north: 900, score: 50), poi("high", east: 0, north: -900, score: 90)]
        let walk = try await planner.planWalk(start: Grid.origin, end: .anywhere, mustVisit: [], optional: optional,
                                              budget: 16 * 60, provider: provider)
        #expect(ids(walk.included) == ["high"])
    }

    @Test func respectsTheEndConstraint() async throws {
        let stops = [poi("a", east: 1500, north: 200), poi("b", east: 500, north: -200), poi("c", east: 1000, north: 100)]
        let toDest = try await planner.planWalk(start: Grid.origin, end: .destination(Grid.destination), mustVisit: stops,
                                                optional: [], budget: 60 * 60, provider: provider)
        #expect(ids(toDest.included) == ["b", "c", "a"])
        #expect(toDest.plan.legs.last?.to == Grid.destination)
        #expect(toDest.plan.legs.count == 4)
        #expect(toDest.plan.baseline.to == Grid.destination)

        let open = try await planner.planWalk(start: Grid.origin, end: .anywhere, mustVisit: stops,
                                              optional: [], budget: 60 * 60, provider: provider)
        #expect(open.plan.legs.count == 3)
        #expect(open.plan.legs.last?.to == open.included.last?.coordinate)
        #expect(open.plan.extraTime == open.plan.totalTime)
        // Highlights carry waypoints for walking mode; WalkTracker accepts the plan.
        #expect(open.plan.highlights.filter { $0.role == .waypoint }.count == 3)
        let tracker = WalkTracker(plan: open.plan)
        #expect(tracker.plan == open.plan)
    }

    @Test func passingPlacesBecomeHighlights() async throws {
        let stops = [poi("a", east: 1000, north: 0)]
        let onTheWay = poi("mural", east: 500, north: 10)
        let walk = try await planner.planWalk(start: Grid.origin, end: .anywhere, mustVisit: stops, optional: [],
                                              budget: 60 * 60, passing: [onTheWay], provider: provider)
        #expect(walk.plan.highlights.map(\.poi.id) == ["mural", "a"])
        #expect(walk.plan.highlights.first?.role == .passby)
    }

    @Test func planWalkIsDeterministic() async throws {
        var rng = SplitMix64(seed: 21)
        let optional = (0..<20).map { i in
            poi("o\(i)", east: Double.random(in: -1200...1200, using: &rng), north: Double.random(in: -1200...1200, using: &rng),
                score: Int.random(in: 40...90, using: &rng))
        }
        let must = Array(optional.prefix(2))
        let a = try await planner.planWalk(start: Grid.origin, end: .anywhere, mustVisit: must, optional: optional,
                                           budget: 45 * 60, provider: provider)
        let b = try await planner.planWalk(start: Grid.origin, end: .anywhere, mustVisit: must,
                                           optional: optional.shuffled(using: &rng), budget: 45 * 60, provider: provider)
        #expect(ids(a.included) == ids(b.included))
        #expect(a.plan.totalTime == b.plan.totalTime)
    }

    @Test func slowRealRoutingDropsOptionalNeverMustVisit() async throws {
        var rng = SplitMix64(seed: 9)
        let optional = (0..<15).map { i in
            poi("o\(i)", east: Double.random(in: -1000...1000, using: &rng), north: Double.random(in: -1000...1000, using: &rng),
                score: Int.random(in: 40...90, using: &rng))
        }
        let must = [poi("m1", east: 300, north: 300, score: 10), poi("m2", east: -300, north: 300, score: 10)]
        let slow = SlowDetourWalkingTime(origin: Grid.origin, destination: Grid.origin, factor: 1.6)
        let budget: TimeInterval = 45 * 60
        let walk = try await planner.planWalk(start: Grid.origin, end: .anywhere, mustVisit: must, optional: optional,
                                              budget: budget, provider: slow)
        #expect(!walk.stretched)
        #expect(Set(ids(walk.included)).isSuperset(of: ["m1", "m2"]))
        #expect(walk.plan.totalTime <= budget * 1.1)
        #expect(walk.plan.candidates.contains { $0.status == .rejected(.failedVerification) })
    }

    // MARK: insertCheapest

    @Test func insertCheapestPicksTheMinimalPosition() async throws {
        let stops = [poi("a", east: 500, north: 0), poi("b", east: 1000, north: 0), poi("c", east: 1500, north: 0)]
        for end in [WalkEnd.anywhere, .destination(Grid.destination)] {
            let walk = try await planner.planWalk(start: Grid.origin, end: end, mustVisit: stops, optional: [],
                                                  budget: 60 * 60, provider: provider)
            for coffee in [poi("cafe", east: 1250, north: 80, category: .food),
                           poi("cafe", east: 1800, north: -50, category: .food),
                           poi("cafe", east: 100, north: 300, category: .food)] {
                let result = try await planner.insertCheapest(coffee, into: walk, provider: provider)
                var best = (k: -1, seconds: Double.infinity)
                for k in 0...walk.included.count {
                    var s = walk.included
                    s.insert(coffee, at: k)
                    let seconds = planner.estimatedSeconds(start: Grid.origin, end: end, stops: s)
                    if seconds < best.seconds - 1e-6 { best = (k, seconds) }
                }
                #expect(result.included.firstIndex { $0.id == "cafe" } == best.k)
                #expect(abs(result.plan.totalTime - best.seconds) < 1e-6)
                #expect(result.mustVisitIDs.contains("cafe"))
            }
        }
    }

    @Test func insertCheapestReusesKnownLegs() async throws {
        let stops = [poi("a", east: 500, north: 0), poi("b", east: 1000, north: 0), poi("c", east: 1500, north: 0)]
        let walk = try await planner.planWalk(start: Grid.origin, end: .destination(Grid.destination), mustVisit: stops,
                                              optional: [], budget: 60 * 60, provider: provider)
        let counting = CountingWalkingTime()
        let result = try await planner.insertCheapest(poi("cafe", east: 1250, north: 80, category: .food),
                                                      into: walk, provider: counting)
        #expect(result.included.count == 4)
        #expect(await counting.counter.count <= 2 * planner.config.maxInsertChecks)
        // Already included: unchanged.
        let again = try await planner.insertCheapest(stops[0], into: walk, provider: counting)
        #expect(again == walk)
    }

    @Test func insertIntoEmptyOpenWalk() async throws {
        let walk = try await planner.planWalk(start: Grid.origin, end: .anywhere, mustVisit: [], optional: [],
                                              budget: 30 * 60, provider: provider)
        #expect(walk.included.isEmpty)
        #expect(walk.plan.totalTime == 0)
        let result = try await planner.insertCheapest(poi("cafe", east: 300, north: 0, category: .food),
                                                      into: walk, provider: provider)
        #expect(ids(result.included) == ["cafe"])
        #expect(result.plan.legs.count == 1)
        #expect(result.plan.legs[0].from == Grid.origin)
    }
}
