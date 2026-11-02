import Foundation

/// Detour budget presets (PLAN.md section 6, Inputs).
public enum Mode: String, CaseIterable, Codable, Hashable, Sendable {
    case direct
    case relaxed
    case explorer

    /// Extra minutes allowed over the fast route.
    public var extraMinutes: Int {
        switch self {
        case .direct: 0
        case .relaxed: 10
        case .explorer: 25
        }
    }

    /// Extra time allowed over the fast route, in seconds.
    public var budget: TimeInterval { TimeInterval(extraMinutes) * 60 }
}

/// Everything the planner needs for one plan.
public struct PlanRequest: Sendable {
    public var origin: Coordinate
    public var destination: Coordinate
    /// Extra seconds allowed over the fast route.
    public var budget: TimeInterval
    /// Categories the user wants. Default: all.
    public var interests: Set<Category>
    public var pois: [POI]
    /// Local time of the walk. Accepted but not used yet: pois.json has no
    /// opening hours, so there is nothing to filter on (decided for Milestone 2).
    public var time: Date?

    public init(origin: Coordinate, destination: Coordinate, budget: TimeInterval,
                interests: Set<Category> = Set(Category.allCases), pois: [POI], time: Date? = nil) {
        self.origin = origin
        self.destination = destination
        self.budget = max(0, budget)
        self.interests = interests
        self.pois = pois
        self.time = time
    }

    public init(origin: Coordinate, destination: Coordinate, mode: Mode,
                interests: Set<Category> = Set(Category.allCases), pois: [POI], time: Date? = nil) {
        self.init(origin: origin, destination: destination, budget: mode.budget,
                  interests: interests, pois: pois, time: time)
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
    /// Value used for ranking: score × interest weight.
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
    /// Seconds over the baseline.
    public var extraTime: TimeInterval
    /// Waypoints and pass-by POIs, ordered along the route.
    public var highlights: [Highlight]
    /// True when the budget allowed a detour but none fit.
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
