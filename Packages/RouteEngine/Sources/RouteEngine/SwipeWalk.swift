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

        public init(reaction: Reaction, date: Date, category: POICategory? = nil, type: String? = nil) {
            self.reaction = reaction
            self.date = date
            self.category = category
            self.type = type
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
        entries[poi.id] = Entry(reaction: reaction, date: date, category: poi.category, type: poi.type)
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
    public func affinity(for poi: POI) -> Double {
        0
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

/// Places for a swipe deck, best first (CONTRACTS §2 "Swipe walks").
public func deck(pois: [POI], area: DeckArea, kinds: Set<DeckKind>, memory: SwipeMemory,
                 seen: Set<String>, now: Date) -> [POI] {
    pois.sorted { ($0.tier ?? 3, -$0.score, $0.id) < ($1.tier ?? 3, -$1.score, $1.id) }
}

/// Fast offline estimate of walking minutes from `start` through `stops`
/// (in the shortest order found) to `end`.
public func estimateWalkMinutes(start: Coordinate, end: WalkEnd, stops: [POI]) -> Double {
    let estimator = HaversineWalkingTime()
    var points = [start] + stops.map(\.coordinate)
    if let e = end.coordinate { points.append(e) }
    return zip(points, points.dropFirst()).reduce(0) { $0 + estimator.seconds(from: $1.0, to: $1.1) } / 60
}

extension Planner {
    /// Plans a swipe walk: every `mustVisit` place, then `optional` places by
    /// value per extra minute until `budget` (seconds). `passing` places show as
    /// pass-by highlights when the route passes them.
    public func planWalk(start: Coordinate, end: WalkEnd, mustVisit: [POI], optional: [POI],
                         budget: TimeInterval, passing: [POI] = [],
                         provider: WalkingTimeProvider) async throws -> WalkPlan {
        let store = LegStore(provider: provider)
        let stops = mustVisit
        let legs = try await walkLegs(start: start, end: end, stops: stops, store: store)
        let plan = makeWanderPlan(start: start, legs: legs, stops: stops, others: optional + passing,
                                  baseline: nil)
        return WalkPlan(plan: plan, included: stops, skipped: optional,
                        stretched: plan.totalTime > budget, estimatedMinutes: estimateWalkMinutes(start: start, end: end, stops: stops),
                        start: start, end: end, budget: budget, mustVisitIDs: Set(mustVisit.map(\.id)), passing: passing)
    }

    /// Adds `poi` (an add-on such as coffee) where it adds the least real time.
    public func insertCheapest(_ poi: POI, into walk: WalkPlan,
                               provider: WalkingTimeProvider) async throws -> WalkPlan {
        var must = walk.included
        must.append(poi)
        var result = try await planWalk(start: walk.start, end: walk.end, mustVisit: must, optional: [],
                                        budget: walk.budget, passing: walk.passing, provider: provider)
        result.mustVisitIDs = walk.mustVisitIDs.union([poi.id])
        return result
    }

    func walkLegs(start: Coordinate, end: WalkEnd, stops: [POI], store: LegStore) async throws -> [Leg] {
        var points = [start] + stops.map(\.coordinate)
        if let e = end.coordinate { points.append(e) }
        guard points.count > 1 else {
            return [Leg(from: start, to: start, duration: 0, distance: 0, polyline: [start, start])]
        }
        var legs: [Leg] = []
        for i in 1..<points.count { legs.append(try await store.leg(from: points[i - 1], to: points[i])) }
        return legs
    }

    func makeWanderPlan(start: Coordinate, legs: [Leg], stops: [POI], others: [POI], baseline: Leg?) -> WanderPlan {
        let base = baseline ?? Leg(from: start, to: start, duration: 0, distance: 0, polyline: [start, start])
        let total = legs.reduce(0) { $0 + $1.duration }
        var plan = WanderPlan(baseline: base, waypoints: stops, legs: legs, totalTime: total,
                              extraTime: total - base.duration, highlights: [], noDetourFit: false, candidates: [])
        let line = MeasuredPolyline(plan.polyline, projection: LocalProjection(origin: start))
        let stopIDs = Set(stops.map(\.id))
        var seenIDs: Set<String> = []
        for poi in stops {
            let near = line.nearest(to: poi.coordinate)
            plan.highlights.append(Highlight(poi: poi, role: .waypoint, distanceAlongRoute: near.along,
                                             distanceFromRoute: near.distance))
            seenIDs.insert(poi.id)
        }
        for poi in others where !stopIDs.contains(poi.id) && seenIDs.insert(poi.id).inserted {
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
