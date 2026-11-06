import Foundation

/// Route options (ADR 008, CONTRACTS §2 "Direct + Recommended").
public enum Mode: String, CaseIterable, Codable, Hashable, Sendable {
    /// The fastest route. No detour stops; highlights on the way are still listed.
    case direct
    /// A detour the engine sizes itself: up to `PlannerConfig.recommendedMaxExtra`
    /// extra, keeping only stops worth their minutes (`minValuePerMinute`).
    case recommended

    /// Most stops the route may be bent to visit.
    public var maxWaypoints: Int {
        switch self {
        case .direct: 0
        case .recommended: 5
        }
    }
}

/// Everything the planner needs for one plan.
public struct PlanRequest: Sendable {
    public var origin: Coordinate
    public var destination: Coordinate
    /// Extra seconds allowed over the fast route.
    public var budget: TimeInterval
    /// Categories the user wants. Default: all.
    public var interests: Set<POICategory>
    /// How to value POIs from their signals. Nil uses each POI's `score`.
    public var weights: SignalWeights?
    public var pois: [POI]
    /// When the walk starts. If set, POIs whose `openingHours` say they are
    /// closed at this time are left out. Nil skips the check.
    public var time: Date?
    /// Time zone for reading `openingHours`: the city's, not the phone's.
    public var timeZone: TimeZone
    /// POI ids the walker has already been shown (e.g. earlier walks today).
    /// Their value is cut by `PlannerConfig.seenFactor` so repeat walks
    /// favour new places; they still show as free highlights when passed.
    public var seen: Set<String>
    /// Most waypoints for this plan. Nil uses `PlannerConfig.maxWaypoints`;
    /// the `mode:` initializer sets it from the mode.
    public var maxWaypoints: Int?
    /// The route option, when planned by mode. The planner then takes the
    /// budget from its config (`PlannerConfig.budget(for:)`) and, for
    /// `.recommended`, keeps only stops worth their extra minutes.
    public var mode: Mode?

    public init(origin: Coordinate, destination: Coordinate, budget: TimeInterval,
                interests: Set<POICategory> = Set(POICategory.allCases), weights: SignalWeights? = nil,
                pois: [POI], time: Date? = nil,
                timeZone: TimeZone = .current, maxWaypoints: Int? = nil, seen: Set<String> = []) {
        self.origin = origin
        self.destination = destination
        self.budget = max(0, budget)
        self.interests = interests
        self.weights = weights
        self.pois = pois
        self.time = time
        self.timeZone = timeZone
        self.maxWaypoints = maxWaypoints
        self.seen = seen
    }

    public init(origin: Coordinate, destination: Coordinate, mode: Mode,
                interests: Set<POICategory> = Set(POICategory.allCases), weights: SignalWeights? = nil,
                pois: [POI], time: Date? = nil,
                timeZone: TimeZone = .current, seen: Set<String> = []) {
        self.init(origin: origin, destination: destination, budget: PlannerConfig.default.budget(for: mode),
                  interests: interests, weights: weights, pois: pois, time: time, timeZone: timeZone,
                  maxWaypoints: mode.maxWaypoints, seen: seen)
        self.mode = mode
    }
}

/// Weights profile for valuing POIs from their `signals`, e.g. a photo hunter
/// (photos high) or hidden gems (independent high, fame low or negative).
///
/// value = 100 × Σ weight × signal / Σ |weight|, with `independent` as 0 or 1.
/// Dividing by the weight total keeps values on the 0–100 `score` scale, so
/// POIs without signals (which fall back to `score`) compare fairly.
public struct SignalWeights: Codable, Hashable, Sendable {
    public var photos: Double
    public var fame: Double
    public var quality: Double
    public var independent: Double

    public init(photos: Double = 0, fame: Double = 0, quality: Double = 0, independent: Double = 0) {
        self.photos = photos
        self.fame = fame
        self.quality = quality
        self.independent = independent
    }

    /// Value 0–100 for `signals`, or nil when every weight is zero.
    public func value(of signals: Signals) -> Double? {
        let total = abs(photos) + abs(fame) + abs(quality) + abs(independent)
        guard total > 0 else { return nil }
        let sum = photos * signals.photos + fame * signals.fame + quality * signals.quality
            + independent * (signals.independent ? 1 : 0)
        return 100 * sum / total
    }
}

/// A POI the walk passes or visits.
public struct Highlight: Hashable, Sendable {
    public enum Role: String, Hashable, Sendable {
        /// The route was bent to visit it.
        case waypoint
        /// Already within reach of the route, at no extra cost.
        case passby
    }

    public var poi: POI
    public var role: Role
    /// Metres from the start, measured along the route polyline.
    public var distanceAlongRoute: Double
    /// Metres between the POI and the closest point of the route.
    public var distanceFromRoute: Double

    public init(poi: POI, role: Role, distanceAlongRoute: Double, distanceFromRoute: Double) {
        self.poi = poi
        self.role = role
        self.distanceAlongRoute = distanceAlongRoute
        self.distanceFromRoute = distanceFromRoute
    }
}

/// Why a POI did not become part of the plan. Shown in the debug overlay.
public enum RejectionReason: String, Hashable, Sendable {
    /// Its category is not in the request's interests.
    case notInInterests
    /// Value is zero or negative under the request's weights.
    case noValue
    /// Value is below `PlannerConfig.minWaypointValue`, too low to detour for.
    case lowValue
    /// Its opening hours say it is closed at the request's time.
    case closed
    /// Budget is zero (Direct mode), so no detours are considered.
    case noBudget
    /// Fails the straight-line corridor check (PLAN.md section 6, step 3).
    case outsideCorridor
    /// Every insertion would push the estimated time over budget.
    case overBudget
    /// The route already has the maximum number of waypoints.
    case maxWaypoints
    /// Too close to an already chosen waypoint.
    case tooClose
    /// The route already has the maximum number of waypoints of this category.
    case categoryCap
    /// Fits the budget, but a set of waypoints with more total value was chosen.
    case outvalued
    /// Under a minute off the walk (`PlannerConfig.freeBelow`): never worth a
    /// Already shown on an earlier walk (`PlanRequest.seen`), and its reduced
    /// value is too low to detour for.
    case seen
    /// slot. It shows as a highlight if the route passes within `passbyRadius`.
    case onTheWay
    /// Every insertion that fits the budget would make the route backtrack.
    case backtracks
    /// Chosen by the estimate, then dropped because real routing went over budget.
    case failedVerification
    /// Lay on the fast route, but the chosen detour no longer passes it.
    case bypassedByDetour
}

/// What happened to one POI during planning.
public enum CandidateStatus: Hashable, Sendable {
    case waypoint
    case passby
    case rejected(RejectionReason)
}

/// Debug record for one POI, for the debug overlay (Milestone 4).
public struct CandidateDebug: Hashable, Sendable {
    public var poi: POI
    /// Value used for ranking: weighted signals (or score) × interest weight.
    public var value: Double
    /// Best estimated extra seconds for inserting it, when it was evaluated.
    public var estimatedExtraTime: TimeInterval?
    public var status: CandidateStatus

    public init(poi: POI, value: Double, estimatedExtraTime: TimeInterval?, status: CandidateStatus) {
        self.poi = poi
        self.value = value
        self.estimatedExtraTime = estimatedExtraTime
        self.status = status
    }
}

/// The planner's result (PLAN.md section 6, Output).
public struct WanderPlan: Hashable, Sendable {
    /// The fast route origin → destination.
    public var baseline: Leg
    /// Chosen waypoints, in walking order. Empty for Direct or when nothing fits.
    public var waypoints: [POI]
    /// Legs origin → w1 → … → destination. Just `[baseline]` without waypoints.
    public var legs: [Leg]
    /// Seconds, sum of `legs`.
    public var totalTime: TimeInterval
    /// Seconds over the baseline. For Recommended, the engine's choice.
    public var extraTime: TimeInterval
    /// Waypoints and pass-by POIs, ordered along the route.
    public var highlights: [Highlight]
    /// True when the budget allowed a detour but none fit (for Recommended:
    /// no stop was worth its extra minutes, so the plan equals Direct).
    public var noDetourFit: Bool
    /// One record per POI in the request, in the request's order.
    public var candidates: [CandidateDebug]

    public init(baseline: Leg, waypoints: [POI], legs: [Leg], totalTime: TimeInterval,
                extraTime: TimeInterval, highlights: [Highlight], noDetourFit: Bool,
                candidates: [CandidateDebug]) {
        self.baseline = baseline
        self.waypoints = waypoints
        self.legs = legs
        self.totalTime = totalTime
        self.extraTime = extraTime
        self.highlights = highlights
        self.noDetourFit = noDetourFit
        self.candidates = candidates
    }

    /// Whole route geometry, legs joined.
    public var polyline: [Coordinate] {
        legs.reduce(into: []) { line, leg in
            line.append(contentsOf: line.last == leg.polyline.first ? leg.polyline.dropFirst() : leg.polyline[...])
        }
    }

    /// Metres, sum of `legs`.
    public var totalDistance: Double { legs.reduce(0) { $0 + $1.distance } }
}
