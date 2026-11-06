import CoreLocation
import Foundation
import MapKit
import Observation
import RouteEngine

/// Plans for the chosen destination (PLAN.md §7.2). Direct and Recommended
/// are planned together in one `Planner.plans` call (Recommended's extra time is
/// the engine's choice) and kept, so switching between them is instant.
/// Interests, route style and removed or added stops re-plan both; interest and
/// style changes are debounced, and the selected option is kept.
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

    /// The selected option. Set by the user through `select(_:)`; until then it
    /// follows the default (Recommended, or Direct when no detour is worth it).
    private(set) var mode: Mode = .recommended
    var interests: Set<POICategory> = Set(POICategory.allCases) {
        didSet { if interests != oldValue { invalidate(debounced: true) } }
    }
    var profile: WeightPreset = .balanced {
        didSet { if profile != oldValue { invalidate(debounced: true) } }
    }

    /// POIs the user removed from the walk; left out of every plan.
    private(set) var excluded: Set<String> = []
    /// POIs the user added; re-inserted into the Recommended plan when they fit.
    private(set) var pinned: [POI] = []

    private(set) var plans: [Mode: WanderPlan] = [:]
    private(set) var phase: Phase = .loading

    var plan: WanderPlan? { plans[mode] }

    let provider = MapKitWalkingTime()
    let connectivity: Connectivity

    @ObservationIgnored private var pois: [POI] = []
    @ObservationIgnored private var timeZone: TimeZone = .current
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var userChoseMode = false

    /// Wait after a chip or style change before re-planning, so quick taps plan once.
    static let debounce: Duration = .milliseconds(400)

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
        mode = .recommended
        userChoseMode = false
        planModes(debounced: false)
    }

    /// Supplies the start point when the first location fix arrives after `start`.
    func setOrigin(_ coordinate: Coordinate) {
        guard destination != nil, origin == nil else { return }
        origin = coordinate
        invalidate(debounced: false)
    }

    /// Location became unavailable before there was a start point.
    func originUnavailable() {
        guard destination != nil, origin == nil else { return }
        phase = .failed(.noLocation)
    }

    func close() {
        cancelAll()
        destination = nil
        origin = nil
        excluded = []
        pinned = []
    }

    func retry() {
        invalidate(debounced: false)
    }

    /// The user picked an option; it is kept across re-plans.
    func select(_ mode: Mode) {
        userChoseMode = true
        self.mode = mode
    }

    // MARK: - Editing

    func remove(_ poi: POI) {
        excluded.insert(poi.id)
        pinned.removeAll { $0.id == poi.id }
        invalidate(debounced: false)
    }

    /// Stops are always added to the Recommended plan. In Direct, a successful
    /// add switches to Recommended so the user sees the stop on the walk.
    func addOption(for poi: POI) -> AddOption {
        guard let plan = plans[.recommended] else { return .doesntFit }
        if plan.waypoints.count >= PlanEditor.maxStops { return .full }
        return PlanEditor.estimateFits(poi, in: plan) ? .add : .doesntFit
    }

    func add(_ poi: POI) async -> AddResult {
        guard let plan = plans[.recommended] else { return .failed }
        let gen = generation
        do {
            let outcome = try await PlanEditor.adding(
                poi, to: plan, pois: activePOIs, interests: interests, provider: provider)
            guard gen == generation else { return .failed }
            switch outcome {
            case .added(let newPlan):
                excluded.remove(poi.id)
                pinned.append(poi)
                plans[.recommended] = newPlan
                select(.recommended)
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

    private func invalidate(debounced: Bool) {
        generation += 1
        cancelAll()
        planModes(debounced: debounced)
    }

    private func cancelAll() {
        task?.cancel()
        task = nil
        plans = [:]
        phase = .loading
    }

    /// Plans Direct and Recommended together, then re-inserts the user's added
    /// stops into Recommended.
    private func planModes(debounced: Bool) {
        guard let destination, task == nil else { return }
        phase = .loading
        guard let origin else { return }

        let request = PlanRequest(
            origin: origin, destination: Coordinate(destination.coordinate), budget: 0,
            interests: interests, weights: profile.weights, pois: activePOIs,
            time: Date(), timeZone: timeZone)
        let pinned = self.pinned, interests = self.interests, provider = self.provider
        let gen = generation

        task = Task {
            if debounced {
                try? await Task.sleep(for: Self.debounce)
                guard gen == self.generation, !Task.isCancelled else { return }
            }
            do {
                var plans = try await Planner().plans(request, provider: provider)
                if var recommended = plans[.recommended] {
                    for poi in pinned where !recommended.waypoints.contains(where: { $0.id == poi.id }) {
                        if case .added(let edited) = try await PlanEditor.adding(
                            poi, to: recommended, pois: request.pois,
                            interests: interests, provider: provider) {
                            recommended = edited
                        }
                    }
                    plans[.recommended] = recommended
                }
                guard gen == self.generation, !Task.isCancelled else { return }
                self.plans = plans
                self.phase = .ready
                if !self.userChoseMode {
                    self.mode = self.noDetourFit ? .direct : .recommended
                }
            } catch {
                guard gen == self.generation, !Task.isCancelled else { return }
                self.phase = .failed(self.classify(error))
            }
            if gen == self.generation { self.task = nil }
        }
    }

    /// No stop is worth a detour: Recommended is the same walk as Direct.
    var noDetourFit: Bool { plans[.recommended]?.noDetourFit ?? false }

    private func classify(_ error: Error) -> Failure {
        if !connectivity.isOnline { return .offline }
        if case RoutingError.noRoute = error { return .noRoute }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .offline }
        if let mk = error as? MKError, mk.code == .serverFailure { return .offline }
        return .other
    }
}
