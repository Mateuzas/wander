import CoreLocation
import Foundation
import MapKit
import Observation
import RouteEngine

/// Plans for the chosen destination (PLAN.md §7.2). One plan per mode is cached,
/// so switching modes is instant; the selected mode is planned first and the
/// others follow in the background. Interests, profile and removed or added
/// stops change every mode, so they clear the cache.
@MainActor
@Observable
final class PlannerModel {
    enum Failure: Equatable {
        case noLocation
        case noRoute
        case offline
        case other
    }

    enum Phase: Equatable {
        case loading
        case ready
        case failed(Failure)
    }

    /// What tapping an unplanned bead can offer.
    enum AddOption: Equatable {
        case add
        case directMode
        case full
        case doesntFit
    }

    enum AddResult {
        case added
        case doesntFit
        case failed
    }

    private(set) var destination: Destination?
    private(set) var origin: Coordinate?

    var mode: Mode = .relaxed {
        didSet { if mode != oldValue { ensurePlan(for: mode) } }
    }
    var interests: Set<POICategory> = Set(POICategory.allCases) {
        didSet { if interests != oldValue { invalidate() } }
    }
    var profile: RouteProfile = .balanced {
        didSet { if profile != oldValue { invalidate() } }
    }

    /// POIs the user removed from the walk; left out of every plan.
    private(set) var excluded: Set<String> = []
    /// POIs the user added; re-inserted into each mode's plan when they fit.
    private(set) var pinned: [POI] = []

    private(set) var plans: [Mode: WanderPlan] = [:]
    private(set) var phases: [Mode: Phase] = [:]

    var plan: WanderPlan? { plans[mode] }
    var phase: Phase { phases[mode] ?? .loading }

    let provider = MapKitWalkingTime()
    let connectivity: Connectivity

    @ObservationIgnored private var pois: [POI] = []
    @ObservationIgnored private var timeZone: TimeZone = .current
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tasks: [Mode: Task<Void, Never>] = [:]

    init(connectivity: Connectivity) {
        self.connectivity = connectivity
    }

    // MARK: - Lifecycle

    /// Starts planning to `destination`. With no `origin` yet, plans once `setOrigin` is called.
    func start(destination: Destination, origin: Coordinate?, pois: [POI], timeZone: TimeZone) {
        cancelAll()
        self.destination = destination
        self.origin = origin
        self.pois = pois
        self.timeZone = timeZone
        excluded = []
        pinned = []
        ensurePlan(for: mode)
    }

    /// Supplies the start point when the first location fix arrives after `start`.
    func setOrigin(_ coordinate: Coordinate) {
        guard destination != nil, origin == nil else { return }
        origin = coordinate
        invalidate()
    }

    /// Location became unavailable before there was a start point.
    func originUnavailable() {
        guard destination != nil, origin == nil else { return }
        for mode in Mode.allCases { phases[mode] = .failed(.noLocation) }
    }

    func close() {
        cancelAll()
        destination = nil
        origin = nil
        excluded = []
        pinned = []
    }

    func retry() {
        invalidate()
    }

    // MARK: - Editing

    func remove(_ poi: POI) {
        excluded.insert(poi.id)
        pinned.removeAll { $0.id == poi.id }
        invalidate()
    }

    func addOption(for poi: POI) -> AddOption {
        guard let plan else { return .doesntFit }
        if mode == .direct { return .directMode }
        if plan.waypoints.count >= PlanEditor.config.maxWaypoints { return .full }
        return PlanEditor.estimateFits(poi, in: plan, budget: mode.budget) ? .add : .doesntFit
    }

    func add(_ poi: POI) async -> AddResult {
        guard let plan else { return .failed }
        let mode = self.mode, gen = generation
        excluded.remove(poi.id)
        do {
            let outcome = try await PlanEditor.adding(
                poi, to: plan, budget: mode.budget, pois: activePOIs, interests: interests, provider: provider)
            guard gen == generation, mode == self.mode else { return .failed }
            switch outcome {
            case .added(let newPlan):
                pinned.append(poi)
                // Other modes recompute with the new stop; this one keeps the edited plan.
                generation += 1
                cancelAll(keepingPlans: false)
                plans = [mode: newPlan]
                phases = [mode: .ready]
                prefetchOtherModes()
                return .added
            case .doesntFit, .full:
                return .doesntFit
            }
        } catch {
            return .failed
        }
    }

    // MARK: - Planning

    private var activePOIs: [POI] { pois.filter { !excluded.contains($0.id) } }

    private func invalidate() {
        generation += 1
        cancelAll(keepingPlans: false)
        ensurePlan(for: mode)
    }

    private func cancelAll(keepingPlans: Bool = false) {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        if !keepingPlans {
            plans = [:]
            phases = [:]
        }
    }

    private func ensurePlan(for mode: Mode) {
        guard let destination, plans[mode] == nil, tasks[mode] == nil else { return }
        guard let origin else {
            phases[mode] = .loading
            return
        }
        phases[mode] = .loading
        let request = PlanRequest(
            origin: origin, destination: Coordinate(destination.coordinate), mode: mode,
            interests: interests, weights: profile.weights, pois: activePOIs,
            time: Date(), timeZone: timeZone)
        let pinned = self.pinned, interests = self.interests, provider = self.provider
        let gen = generation

        tasks[mode] = Task {
            let result: Result<WanderPlan, Error>
            do {
                var plan = try await Planner().plan(request, provider: provider)
                for poi in pinned where !plan.waypoints.contains(where: { $0.id == poi.id }) {
                    if case .added(let edited) = try await PlanEditor.adding(
                        poi, to: plan, budget: mode.budget, pois: request.pois,
                        interests: interests, provider: provider) {
                        plan = edited
                    }
                }
                result = .success(plan)
            } catch {
                result = .failure(error)
            }
            guard gen == self.generation, !Task.isCancelled else { return }
            self.tasks[mode] = nil
            switch result {
            case .success(let plan):
                self.plans[mode] = plan
                self.phases[mode] = .ready
                if mode == self.mode { self.prefetchOtherModes() }
            case .failure(let error):
                self.phases[mode] = .failed(self.classify(error))
            }
        }
    }

    private func prefetchOtherModes() {
        for other in Mode.allCases where other != mode {
            ensurePlan(for: other)
        }
    }

    private func classify(_ error: Error) -> Failure {
        if !connectivity.isOnline { return .offline }
        if case RoutingError.noRoute = error { return .noRoute }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .offline }
        if let mk = error as? MKError, mk.code == .serverFailure { return .offline }
        return .other
    }
}
