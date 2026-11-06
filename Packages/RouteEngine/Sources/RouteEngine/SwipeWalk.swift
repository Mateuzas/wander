import Foundation

// Swipe walks (ADR 016, CONTRACTS §2 "Swipe walks").

/// Where a swipe walk ends.
public enum WalkEnd: Hashable, Sendable {
    /// The walk ends at the last place (an open path).
    case anywhere
    /// The walk ends at a fixed point.
    case destination(Coordinate)

    var coordinate: Coordinate? {
        if case .destination(let c) = self { return c }
        return nil
    }
}

/// The user's reaction to a deck card.
public enum Reaction: String, Codable, Hashable, Sendable {
    case love, like, nope
}

/// Reactions stored on the phone per place id (ADR 016, "Swipe memory").
public struct SwipeMemory: Codable, Hashable, Sendable {
    /// One remembered reaction. Category and type are kept so affinity works
    /// without the place being in the current data file.
    public struct Entry: Codable, Hashable, Sendable {
        public var reaction: Reaction
        public var date: Date
        public var category: POICategory?
        public var type: String?
        /// Food only, from `POI.cuisine`.
        public var cuisine: [String]?

        public init(reaction: Reaction, date: Date, category: POICategory? = nil, type: String? = nil,
                    cuisine: [String]? = nil) {
            self.reaction = reaction
            self.date = date
            self.category = category
            self.type = type
            self.cuisine = cuisine
        }
    }

    /// Days a nope hides a place from decks.
    public static let nopeDays: Double = 90

    /// Reactions by POI id; the latest reaction wins.
    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// Remembers `reaction` to `poi` at `date`, replacing any earlier one.
    public mutating func record(_ reaction: Reaction, for poi: POI, at date: Date) {
        entries[poi.id] = Entry(reaction: reaction, date: date, category: poi.category, type: poi.type,
                                cuisine: poi.cuisine)
    }

    /// Forgets the reaction to `poiId` (one-level undo).
    public mutating func forget(_ poiId: String) {
        entries[poiId] = nil
    }

    /// Ids of places noped within the last 90 days.
    public func hidden(now: Date) -> Set<String> {
        let cutoff = now.addingTimeInterval(-Self.nopeDays * 24 * 3600)
        return Set(entries.filter { $0.value.reaction == .nope && $0.value.date > cutoff }.map(\.key))
    }

    /// 0–1 boost from loved and liked places of the same type and category.
    /// Days for a reaction's weight in `affinity` to halve.
    public static let affinityHalfLifeDays: Double = 60
    /// Bounds of `affinity`, so it stays a tiebreak and never outweighs tier order.
    public static let affinityRange: ClosedRange<Double> = -0.3...0.5

    /// Boost for `poi` from past reactions to similar places, in `affinityRange`,
    /// measured at the newest reaction's date. See `affinity(for:now:)`.
    public func affinity(for poi: POI) -> Double {
        affinity(for: poi, now: entries.values.map(\.date).max() ?? .distantPast)
    }

    /// Boost for `poi` from past reactions to other places (ADR 016). Each love
    /// (weight 1) or like (0.5) adds 0.25 for the same `type`, 0.15 for a shared
    /// cuisine (food) and 0.05 for the same category; each nope on the same type
    /// subtracts 0.1. Weights halve every `affinityHalfLifeDays`. The sum is
    /// clamped to `affinityRange`. Order-independent, so deterministic.
    public func affinity(for poi: POI, now: Date) -> Double {
        let cuisines = Set(poi.cuisine ?? [])
        var boost = 0.0
        for (id, entry) in entries where id != poi.id {
            let ageDays = max(0, now.timeIntervalSince(entry.date) / 86_400)
            let decay = pow(0.5, ageDays / Self.affinityHalfLifeDays)
            let sameType = poi.type != nil && entry.type == poi.type
            switch entry.reaction {
            case .nope:
                if sameType { boost -= 0.1 * decay }
            case .love, .like:
                let weight = (entry.reaction == .love ? 1.0 : 0.5) * decay
                if sameType { boost += 0.25 * weight }
                if poi.category == .food, !cuisines.isDisjoint(with: entry.cuisine ?? []) { boost += 0.15 * weight }
                if entry.category == poi.category { boost += 0.05 * weight }
            }
        }
        return min(Self.affinityRange.upperBound, max(Self.affinityRange.lowerBound, boost))
    }
}

/// The kinds of places a deck can deal (ADR 016, step 1).
public enum DeckKind: String, CaseIterable, Codable, Hashable, Sendable {
    case sights, food, shops, hiddenGems
}

/// The area a deck is dealt from.
public enum DeckArea: Hashable, Sendable {
    /// Radius in metres.
    case circle(center: Coordinate, radius: Double)
    /// Places within `halfWidth` metres of the start–end segment.
    case band(start: Coordinate, end: Coordinate, halfWidth: Double)

    /// The point grid cells and distances are measured from.
    var origin: Coordinate {
        switch self {
        case .circle(let center, _): center
        case .band(let start, _, _): start
        }
    }

    public func contains(_ c: Coordinate) -> Bool {
        switch self {
        case .circle(let center, let radius):
            return center.distance(to: c) <= radius
        case .band(let start, let end, let halfWidth):
            let projection = LocalProjection(origin: start)
            let a = projection.point(start), b = projection.point(end), p = projection.point(c)
            let ab = b - a
            let len2 = dot(ab, ab)
            let t = len2 > 0 ? min(1, max(0, dot(p - a, ab) / len2)) : 0
            return length(p - (a + t * ab)) <= halfWidth
        }
    }
}

extension DeckKind {
    /// Whether `poi` belongs to this kind. Hidden gems: tier 2–3, independent,
    /// quality ≥ 0.6, fame < 0.3, any category (ADR 016, "Resolved").
    public func matches(_ poi: POI) -> Bool {
        switch self {
        case .sights: return poi.category == .photo
        case .food: return poi.category == .food
        case .shops: return poi.category == .shop
        case .hiddenGems:
            guard (2...3).contains(poi.deckTier), let s = poi.signals else { return false }
            return s.independent && s.quality >= 0.6 && s.fame < 0.3
        }
    }
}

extension POI {
    /// Tier for deck order: `tier`, else 1 when `popular`, else 3 (older files).
    var deckTier: Int { tier ?? (popular == true ? 1 : 3) }
}

/// A planned swipe walk.
public struct WalkPlan: Hashable, Sendable {
    /// Legs, highlights and polyline for walking mode and the map.
    public var plan: WanderPlan
    /// Stops in walking order (every must-visit plus the optional places that fit).
    public var included: [POI]
    /// Optional places left out.
    public var skipped: [POI]
    /// True when the must-visit places alone need more than the budget.
    public var stretched: Bool
    /// Offline estimate of the walk in minutes (haversine × tortuosity).
    public var estimatedMinutes: Double

    // Inputs kept for `Planner.insertCheapest`.
    public var start: Coordinate
    public var end: WalkEnd
    public var budget: TimeInterval
    public var mustVisitIDs: Set<String>
    /// Places shown as pass-by highlights when the route passes them.
    public var passing: [POI]

    public init(plan: WanderPlan, included: [POI], skipped: [POI], stretched: Bool, estimatedMinutes: Double,
                start: Coordinate, end: WalkEnd, budget: TimeInterval, mustVisitIDs: Set<String>,
                passing: [POI] = []) {
        self.plan = plan
        self.included = included
        self.skipped = skipped
        self.stretched = stretched
        self.estimatedMinutes = estimatedMinutes
        self.start = start
        self.end = end
        self.budget = budget
        self.mustVisitIDs = mustVisitIDs
        self.passing = passing
    }
}

/// Grid cell size in metres for spreading a deck across its area.
let deckCellSize = 150.0

/// Places for a swipe deck, best first (CONTRACTS §2 "Swipe walks").
///
/// Keeps places of the chosen `kinds` inside `area`, drops places noped in the
/// last 90 days, and orders tier 1, then 2, then 3. Within a tier the deck is
/// spread over ~150 m grid cells: the best place of every cell, then the
/// second best of every cell, and so on; within a round higher score first,
/// then higher `memory.affinity`, then id. Places in `seen` go to the end
/// (same order rules). Deterministic.
public func deck(pois: [POI], area: DeckArea, kinds: Set<DeckKind>, memory: SwipeMemory,
                 seen: Set<String>, now: Date) -> [POI] {
    let hidden = memory.hidden(now: now)
    let projection = LocalProjection(origin: area.origin)
    var unique: Set<String> = []
    let kept = pois.filter { poi in
        !hidden.contains(poi.id) && kinds.contains { $0.matches(poi) }
            && area.contains(poi.coordinate) && unique.insert(poi.id).inserted
    }
    struct Card { var poi: POI; var affinity: Double; var cell: SIMD2<Int> }
    func better(_ a: Card, _ b: Card) -> Bool {
        if a.poi.score != b.poi.score { return a.poi.score > b.poi.score }
        if a.affinity != b.affinity { return a.affinity > b.affinity }
        return a.poi.id < b.poi.id
    }
    let cards = kept.map { poi -> Card in
        let p = projection.point(poi.coordinate) / deckCellSize
        return Card(poi: poi, affinity: memory.affinity(for: poi, now: now),
                    cell: SIMD2(Int(p.x.rounded(.down)), Int(p.y.rounded(.down))))
    }
    func spread(_ group: [Card]) -> [POI] {
        var cells: [SIMD2<Int>: [Card]] = [:]
        for card in group { cells[card.cell, default: []].append(card) }
        let queues = cells.values.map { $0.sorted(by: better) }
        var result: [POI] = []
        var round = 0
        while result.count < group.count {
            result += queues.compactMap { round < $0.count ? $0[round] : nil }.sorted(by: better).map(\.poi)
            round += 1
        }
        return result
    }
    var result: [POI] = []
    for wasSeen in [false, true] {
        for tier in Set(cards.map(\.poi.deckTier)).sorted() {
            result += spread(cards.filter { seen.contains($0.poi.id) == wasSeen && $0.poi.deckTier == tier })
        }
    }
    return result
}

/// Fast offline estimate of walking minutes from `start` through `stops` to
/// `end`: haversine × tortuosity at walking speed (`HaversineWalkingTime`
/// defaults), with the stops ordered by nearest insertion + 2-opt (and single
/// stop moves). With `.anywhere` the walk ends at the last stop.
public func estimateWalkMinutes(start: Coordinate, end: WalkEnd, stops: [POI]) -> Double {
    var tour = Tour(start: start, end: end.coordinate, stops: stops.map(\.coordinate),
                    estimator: HaversineWalkingTime())
    tour.build(tour.stopNodes)
    return tour.seconds / 60
}

/// A walk order over a fixed set of points, with estimated seconds between
/// them. Node 0 is the start, nodes 1...n the stops, node n+1 the end when fixed.
struct Tour {
    private(set) var matrix: [[Double]]
    let fixedEnd: Bool
    /// Node order, always starting with 0 and ending with the end node when fixed.
    private(set) var path: [Int]

    init(start: Coordinate, end: Coordinate?, stops: [Coordinate], estimator: HaversineWalkingTime) {
        let points = [start] + stops + (end.map { [$0] } ?? [])
        matrix = points.map { a in points.map { b in estimator.seconds(from: a, to: b) } }
        fixedEnd = end != nil
        path = fixedEnd ? [0, points.count - 1] : [0]
    }

    var stopCount: Int { matrix.count - (fixedEnd ? 2 : 1) }
    var stopNodes: [Int] { Array(1..<(1 + stopCount)) }
    /// Stop nodes in walking order.
    var stops: [Int] { path.filter { $0 != 0 && !(fixedEnd && $0 == matrix.count - 1) } }

    var seconds: Double {
        zip(path, path.dropFirst()).reduce(0) { $0 + matrix[$1.0][$1.1] }
    }

    /// Cheapest place to put `node`: its index in `path` and the extra seconds.
    func cheapestInsertion(of node: Int) -> (index: Int, extra: Double) {
        var best = (index: path.count, extra: Double.infinity)
        let last = fixedEnd ? path.count - 1 : path.count
        for k in 1...last {
            let prev = path[k - 1]
            let extra = k < path.count
                ? matrix[prev][node] + matrix[node][path[k]] - matrix[prev][path[k]]
                : matrix[prev][node]
            if extra < best.extra - 1e-9 { best = (k, extra) }
        }
        return best
    }

    mutating func insert(_ node: Int, at index: Int) {
        path.insert(node, at: index)
    }

    /// Nearest insertion of `nodes`, then local improvement.
    mutating func build(_ nodes: [Int]) {
        guard stopCount > 0 else { return }
        var remaining = nodes
        while !remaining.isEmpty {
            var pick = 0, pickDistance = Double.infinity
            for (i, r) in remaining.enumerated() {
                let d = path.reduce(Double.infinity) { min($0, matrix[$1][r]) }
                if d < pickDistance - 1e-9 { pick = i; pickDistance = d }
            }
            let node = remaining.remove(at: pick)
            insert(node, at: cheapestInsertion(of: node).index)
        }
        improve()
    }

    /// Moves `path[i..<i+size]` (reversed if better) to the cheapest other
    /// place when that shortens the walk. Returns whether it moved.
    private mutating func moveSegment(at i: Int, size: Int) -> Bool {
        let segment = Array(path[i..<(i + size)])
        let prev = path[i - 1]
        let next = i + size < path.count ? path[i + size] : nil
        let first = segment.first!, last = segment.last!
        let saving = matrix[prev][first] + (next.map { matrix[last][$0] - matrix[prev][$0] } ?? 0)
        var rest = path
        rest.removeSubrange(i..<(i + size))
        let lastSlot = fixedEnd ? rest.count - 1 : rest.count
        var best: (k: Int, cost: Double, reversed: Bool)?
        for k in 1...lastSlot where k != i {
            let a = rest[k - 1]
            let b = k < rest.count ? rest[k] : nil
            let removed = b.map { matrix[a][$0] } ?? 0
            for reversed in [false, true] {
                let head = reversed ? last : first, tail = reversed ? first : last
                let cost = matrix[a][head] + (b.map { matrix[tail][$0] } ?? 0) - removed
                if cost < (best?.cost ?? .infinity) - 1e-9 { best = (k, cost, reversed) }
            }
        }
        // Reversing in place is covered by 2-opt.
        guard let best, best.cost < saving - 1e-6 else { return false }
        rest.insert(contentsOf: best.reversed ? segment.reversed() : segment, at: best.k)
        path = rest
        return true
    }

    /// 2-opt segment reversals and moves of short runs of stops until neither helps.
    mutating func improve() {
        let firstMovable = 1
        let lastMovable = fixedEnd ? path.count - 2 : path.count - 1
        guard lastMovable > firstMovable else { return }
        var improved = true
        var rounds = 0
        while improved && rounds < 100 {
            improved = false
            rounds += 1
            // 2-opt: reverse path[i...j].
            for i in firstMovable..<lastMovable {
                for j in (i + 1)...lastMovable {
                    let a = path[i - 1], b = path[i], c = path[j]
                    let next = j + 1 < path.count ? path[j + 1] : nil
                    let before = matrix[a][b] + (next.map { matrix[c][$0] } ?? 0)
                    let after = matrix[a][c] + (next.map { matrix[b][$0] } ?? 0)
                    if after < before - 1e-6 {
                        path[i...j].reverse()
                        improved = true
                    }
                }
            }
            // Or-opt: move a run of 1–3 stops (either way round) to its cheapest other place.
            for size in 1...3 {
                var i = firstMovable
                while i + size - 1 <= (fixedEnd ? path.count - 2 : path.count - 1) {
                    if moveSegment(at: i, size: size) { improved = true }
                    i += 1
                }
            }
        }
    }
}

extension Planner {
    /// Plans a swipe walk (CONTRACTS §2 "Swipe walks").
    ///
    /// Every `mustVisit` place is included; when they alone need more than
    /// `budget` (seconds), the walk stretches and `stretched` is true.
    /// Otherwise `optional` places are added by value per extra estimated
    /// minute (value: `weights` over signals, else `score`) while the estimate
    /// fits the budget. Stops are ordered by nearest insertion + 2-opt with the
    /// end constraint, then verified with real legs; while the real walk is over
    /// budget × (1 + `verificationTolerance`), the optional stop with the least
    /// value per marginal minute is dropped (never a must-visit). `passing`
    /// places show as pass-by highlights when the route passes them.
    public func planWalk(start: Coordinate, end: WalkEnd, mustVisit: [POI], optional: [POI],
                         budget: TimeInterval, weights: SignalWeights? = nil, passing: [POI] = [],
                         provider: WalkingTimeProvider) async throws -> WalkPlan {
        let store = LegStore(provider: provider)
        let scorer = Scorer(config: config, interests: Set(POICategory.allCases), weights: weights)
        var ids: Set<String> = []
        let must = mustVisit.filter { ids.insert($0.id).inserted }
        let candidates = optional.filter { ids.insert($0.id).inserted && scorer.value($0) > 0 }
        let all = must + candidates

        // 1. Must-visit places, in the shortest order found.
        var tour = Tour(start: start, end: end.coordinate, stops: all.map(\.coordinate), estimator: config.estimator)
        tour.build(must.indices.map { $0 + 1 })

        // 2. Optional places by value per extra minute while the estimate fits.
        var remaining = candidates.indices.map { $0 + must.count + 1 }
        while !remaining.isEmpty {
            let total = tour.seconds
            var best: (node: Int, index: Int, ratio: Double, value: Double)?
            for node in remaining {
                let insertion = tour.cheapestInsertion(of: node)
                guard total + insertion.extra <= budget else { continue }
                let value = scorer.value(all[node - 1])
                let ratio = value / (max(insertion.extra, config.minExtraTimeForRatio) / 60)
                if let b = best {
                    let id = all[node - 1].id, bestID = all[b.node - 1].id
                    let better = ratio > b.ratio
                        || (ratio == b.ratio && (value > b.value || (value == b.value && id < bestID)))
                    guard better else { continue }
                }
                best = (node, insertion.index, ratio, value)
            }
            guard let best else { break }
            remaining.removeAll { $0 == best.node }
            tour.insert(best.node, at: best.index)
            tour.improve()   // only ever shortens, so the estimate still fits
        }

        // 3. Verify with real legs; drop the weakest optional stops while over budget.
        var stops = tour.stops.map { all[$0 - 1] }
        var legs = try await walkLegs(start: start, end: end, stops: stops, store: store)
        var dropped: [POI] = []
        let limit = budget * (1 + config.verificationTolerance)
        while legs.reduce(0, { $0 + $1.duration }) > limit {
            let points = [start] + stops.map(\.coordinate) + (end.coordinate.map { [$0] } ?? [])
            let estimatedTotal = zip(points, points.dropFirst()).reduce(0) { $0 + config.estimator.seconds(from: $1.0, to: $1.1) }
            let realTotal = legs.reduce(0) { $0 + $1.duration }
            let scale = estimatedTotal > 0 ? realTotal / estimatedTotal : 1
            var weakest: (index: Int, perMinute: Double)?
            for (i, poi) in stops.enumerated() where !must.contains(where: { $0.id == poi.id }) {
                let marginal: Double
                if i + 2 < points.count {
                    marginal = legs[i].duration + legs[i + 1].duration
                        - config.estimator.seconds(from: points[i], to: points[i + 2]) * scale
                } else {
                    marginal = legs[i].duration
                }
                let perMinute = scorer.value(poi) / (max(marginal, config.minExtraTimeForRatio) / 60)
                if weakest.map({ perMinute < $0.perMinute }) ?? true { weakest = (i, perMinute) }
            }
            guard let weakest else { break }
            dropped.append(stops.remove(at: weakest.index))
            legs = try await walkLegs(start: start, end: end, stops: stops, store: store)
        }

        var baseline: Leg?
        if let destination = end.coordinate { baseline = try await store.leg(from: start, to: destination) }
        let includedIDs = Set(stops.map(\.id))
        let skipped = candidates.filter { !includedIDs.contains($0.id) }
        var plan = makeWanderPlan(start: start, legs: legs, stops: stops, others: skipped + passing,
                                  baseline: baseline)
        let droppedIDs = Set(dropped.map(\.id))
        let passbyIDs = Set(plan.highlights.filter { $0.role == .passby }.map(\.poi.id))
        plan.candidates = all.map { poi in
            let status: CandidateStatus = includedIDs.contains(poi.id) ? .waypoint
                : passbyIDs.contains(poi.id) ? .passby
                : .rejected(droppedIDs.contains(poi.id) ? .failedVerification : .overBudget)
            return CandidateDebug(poi: poi, value: scorer.value(poi), estimatedExtraTime: nil, status: status)
        }
        return WalkPlan(plan: plan, included: stops, skipped: skipped,
                        stretched: plan.totalTime > limit,
                        estimatedMinutes: estimatedSeconds(start: start, end: end, stops: stops) / 60,
                        start: start, end: end, budget: budget, mustVisitIDs: Set(must.map(\.id)),
                        passing: passing)
    }

    /// Adds `poi` (an add-on such as coffee or a shop) where it adds the least
    /// real time. Positions are ranked by the estimate and the best
    /// `maxInsertChecks` are checked with real legs (two requests each, one
    /// when appended to an open walk); the rest of the walk keeps its legs.
    /// The added place counts as a must-visit from then on.
    public func insertCheapest(_ poi: POI, into walk: WalkPlan,
                               provider: WalkingTimeProvider) async throws -> WalkPlan {
        guard !walk.included.contains(where: { $0.id == poi.id }) else { return walk }
        let store = LegStore(provider: provider, known: walk.plan.legs + [walk.plan.baseline])
        let estimator = config.estimator
        let points = [walk.start] + walk.included.map(\.coordinate) + (walk.end.coordinate.map { [$0] } ?? [])
        let p = poi.coordinate
        // Insert before points[k]; k == points.count appends (open walks only).
        let positions = Array(1...(walk.end.coordinate == nil ? points.count : points.count - 1))
        let ranked = positions.map { k -> (k: Int, estimate: Double) in
            k < points.count
                ? (k, estimator.seconds(from: points[k - 1], to: p) + estimator.seconds(from: p, to: points[k])
                    - estimator.seconds(from: points[k - 1], to: points[k]))
                : (k, estimator.seconds(from: points[k - 1], to: p))
        }.sorted { ($0.estimate, $0.k) < ($1.estimate, $1.k) }
        var best: (k: Int, extra: Double)?
        for (k, _) in ranked.prefix(max(1, config.maxInsertChecks)) {
            let extra: Double
            if k < points.count {
                extra = try await store.leg(from: points[k - 1], to: p).duration
                    + store.leg(from: p, to: points[k]).duration
                    - store.leg(from: points[k - 1], to: points[k]).duration
            } else {
                extra = try await store.leg(from: points[k - 1], to: p).duration
            }
            if best.map({ (extra, k) < ($0.extra, $0.k) }) ?? true { best = (k, extra) }
        }
        var stops = walk.included
        stops.insert(poi, at: best!.k - 1)
        let legs = try await walkLegs(start: walk.start, end: walk.end, stops: stops, store: store)
        let skipped = walk.skipped.filter { $0.id != poi.id }
        var plan = makeWanderPlan(start: walk.start, legs: legs, stops: stops, others: skipped + walk.passing,
                                  baseline: walk.end.coordinate == nil ? nil : walk.plan.baseline)
        plan.candidates = walk.plan.candidates.filter { $0.poi.id != poi.id }.map { c in
            var c = c
            if c.status == .passby && !plan.highlights.contains(where: { $0.poi.id == c.poi.id }) {
                c.status = .rejected(.overBudget)
            }
            return c
        } + [CandidateDebug(poi: poi, value: Double(poi.score), estimatedExtraTime: nil, status: .waypoint)]
        let limit = walk.budget * (1 + config.verificationTolerance)
        return WalkPlan(plan: plan, included: stops, skipped: skipped,
                        stretched: walk.stretched || plan.totalTime > limit,
                        estimatedMinutes: estimatedSeconds(start: walk.start, end: walk.end, stops: stops) / 60,
                        start: walk.start, end: walk.end, budget: walk.budget,
                        mustVisitIDs: walk.mustVisitIDs.union([poi.id]), passing: walk.passing)
    }

    /// Estimated seconds for `stops` in the given order.
    func estimatedSeconds(start: Coordinate, end: WalkEnd, stops: [POI]) -> Double {
        let points = [start] + stops.map(\.coordinate) + (end.coordinate.map { [$0] } ?? [])
        return zip(points, points.dropFirst()).reduce(0) { $0 + config.estimator.seconds(from: $1.0, to: $1.1) }
    }

    /// Real legs start → stops → end. A walk with no legs gets one empty leg at
    /// the start so the plan always has a polyline.
    func walkLegs(start: Coordinate, end: WalkEnd, stops: [POI], store: LegStore) async throws -> [Leg] {
        let points = [start] + stops.map(\.coordinate) + (end.coordinate.map { [$0] } ?? [])
        guard points.count > 1 else {
            return [Leg(from: start, to: start, duration: 0, distance: 0, polyline: [start, start])]
        }
        var legs: [Leg] = []
        for i in 1..<points.count { legs.append(try await store.leg(from: points[i - 1], to: points[i])) }
        return legs
    }

    /// A `WanderPlan` for walking mode: stops as waypoints, `others` within
    /// `passbyRadius` as pass-by highlights. Without a baseline (open walks) the
    /// baseline is an empty leg at the start, so `extraTime == totalTime`.
    func makeWanderPlan(start: Coordinate, legs: [Leg], stops: [POI], others: [POI], baseline: Leg?) -> WanderPlan {
        let base = baseline ?? Leg(from: start, to: start, duration: 0, distance: 0, polyline: [start, start])
        let total = legs.reduce(0) { $0 + $1.duration }
        var plan = WanderPlan(baseline: base, waypoints: stops, legs: legs, totalTime: total,
                              extraTime: total - base.duration, highlights: [], noDetourFit: false, candidates: [])
        let line = MeasuredPolyline(plan.polyline, projection: LocalProjection(origin: start))
        var ids = Set(stops.map(\.id))
        for poi in stops {
            let near = line.nearest(to: poi.coordinate)
            plan.highlights.append(Highlight(poi: poi, role: .waypoint, distanceAlongRoute: near.along,
                                             distanceFromRoute: near.distance))
        }
        for poi in others where ids.insert(poi.id).inserted {
            let near = line.nearest(to: poi.coordinate)
            if near.distance <= config.passbyRadius {
                plan.highlights.append(Highlight(poi: poi, role: .passby, distanceAlongRoute: near.along,
                                                 distanceFromRoute: near.distance))
            }
        }
        plan.highlights.sort { ($0.distanceAlongRoute, $0.poi.id) < ($1.distanceAlongRoute, $1.poi.id) }
        return plan
    }
}
