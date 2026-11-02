import Foundation

/// Plans Wander routes (PLAN.md section 6).
public struct Planner: Sendable {
    public var config: PlannerConfig

    public init(config: PlannerConfig = .default) {
        self.config = config
    }

    /// Builds a plan. Real routing goes only through `provider`; detours are
    /// estimated offline with `config.estimator`.
    public func plan(_ request: PlanRequest, provider: WalkingTimeProvider) async throws -> WanderPlan {
        // API placeholder for Milestone 2: returns the baseline only.
        let baseline = try await provider.leg(from: request.origin, to: request.destination)
        return WanderPlan(baseline: baseline, waypoints: [], legs: [baseline],
                          totalTime: baseline.duration, extraTime: 0, highlights: [],
                          noDetourFit: false, candidates: [])
    }
}

/// Tunable planner constants (PLAN.md section 6).
public struct PlannerConfig: Hashable, Sendable {
    /// Metres. A `passby` POI this close to the route is a free highlight.
    public var passbyRadius: Double = 40
    public var maxWaypoints: Int = 3
    /// Metres between any two chosen waypoints.
    public var minWaypointSpacing: Double = 150
    /// Waypoints of one category.
    public var maxPerCategory: Int = 2
    /// Degrees. A leg whose heading differs from the A→B heading by more than
    /// this counts as backtracking.
    public var maxLegDeviation: Double = 120
    /// Metres. Shorter legs are not checked for backtracking (headings are noisy).
    public var minLegForBacktrackCheck: Double = 100
    /// Real routing may exceed the budget by this fraction before dropping a waypoint.
    public var verificationTolerance: Double = 0.1
    public var maxVerificationRetries: Int = 2
    /// Seconds. Floor for extra time in `value / extraTime`, so POIs right on
    /// the route don't get an infinite ratio.
    public var minExtraTimeForRatio: TimeInterval = 30
    /// Offline estimator for the corridor filter and insertion.
    public var estimator: HaversineWalkingTime = HaversineWalkingTime()

    public static let `default` = PlannerConfig()

    public init() {}
}
