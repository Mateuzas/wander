import CoreLocation
import Foundation
import MapKit
import Observation
import RouteEngine

/// Plans one walk with `Planner.planWalk` (ADR 016): a finished swipe deck (loved
/// places must be visited, liked places fill the time) or "Walk here" (a walk to
/// one place, no swipes). Holds the plan for the summary sheet, re-plans when a
/// stop is removed, and inserts places added from a card and the coffee and shop
/// add-ons where they cost the least.
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

    enum AddResult {
        case added
        case failed
    }

    /// The summary's add-ons (ADR 016 step 4).
    enum AddOn: CaseIterable, Identifiable {
        case coffee
        case shop

        var id: Self { self }

        var title: String {
            switch self {
            case .coffee: "Add coffee"
            case .shop: "Add a shop"
            }
        }

        var glyph: String {
            switch self {
            case .coffee: FoodKind.coffee.glyph
            case .shop: POICategory.shop.glyph
            }
        }

        var nothingFound: String {
            switch self {
            case .coffee: "No open café near this walk."
            case .shop: "No open shop near this walk."
            }
        }

        func matches(_ poi: POI) -> Bool {
            switch self {
            case .coffee: poi.category == .food && FoodKind.coffee.types.contains(poi.type ?? "")
            case .shop: poi.category == .shop
            }
        }
    }

    enum AddOnState: Equatable {
        case working
        case added(POI)
        case nothing
        case failed
    }

    /// What to plan.
    struct Request {
        /// The sheet's heading: the destination's name, or "Your walk".
        var title: String
        /// The destination's name for the map marker and walking mode; nil for "anywhere".
        var endName: String?
        var end: WalkEnd
        /// Loved places, places added from a card, and add-ons.
        var mustVisit: [POI]
        /// Liked places, best first.
        var optional: [POI]
        /// Seconds; 0 for "Walk here".
        var budget: TimeInterval
        /// Shown as highlights when the walk passes them, and nudged while walking.
        var passing: [POI]
        /// Categories drawn as beads and nudged.
        var interests: Set<POICategory>
        var lovedIDs: Set<String> = []
        var likedIDs: Set<String> = []
        /// A swipe walk (loved / liked counts) rather than "Walk here".
        var swiped: Bool { budget > 0 }
    }

    private(set) var request: Request?
    private(set) var origin: Coordinate?
    private(set) var walk: WalkPlan?
    private(set) var phase: Phase = .loading
    private(set) var addOns: [AddOn: AddOnState] = [:]

    var plan: WanderPlan? { walk?.plan }
    var isActive: Bool { request != nil }
    var interests: Set<POICategory> { request?.interests ?? Set(POICategory.allCases) }

    /// The map's marker for a walk to a destination.
    var destinationMarker: (name: String, coordinate: CLLocationCoordinate2D)? {
        guard let request, let name = request.endName, case .destination(let c) = request.end else { return nil }
        return (name, c.clLocation)
    }

    /// Where the walk ends, for walking mode: the destination, else the last stop.
    var endName: String {
        request?.endName ?? walk?.plan.waypoints.last?.name ?? "the last stop"
    }

    let provider = MapKitWalkingTime()
    let connectivity: Connectivity

    @ObservationIgnored private var pois: [POI] = []
    @ObservationIgnored private var timeZone: TimeZone = .current
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    /// How far from the route an add-on may be, metres.
    static let addOnReach: Double = 250
    /// A tier 1–2 add-on wins over a nearer tier 3 one when at most this much further from the route.
    static let addOnTierSlack: Double = 100

    init(connectivity: Connectivity) {
        self.connectivity = connectivity
    }

    // MARK: - Lifecycle

    /// Plans `request`. With no `origin` yet, plans once `setOrigin` is called.
    func start(_ request: Request, origin: Coordinate?, pois: [POI], timeZone: TimeZone) {
        self.request = request
        self.origin = origin
        self.pois = pois
        self.timeZone = timeZone
        addOns = [:]
        replan()
    }

    /// Supplies the start point when the first location fix arrives after `start`.
    func setOrigin(_ coordinate: Coordinate) {
        guard request != nil, origin == nil else { return }
        origin = coordinate
        replan()
    }

    /// Location became unavailable before there was a start point.
    func originUnavailable() {
        guard request != nil, origin == nil else { return }
        phase = .failed(.noLocation)
    }

    func close() {
        cancel()
        request = nil
        origin = nil
        walk = nil
        addOns = [:]
    }

    func retry() { replan() }

    // MARK: - Editing

    func contains(_ poi: POI) -> Bool {
        walk?.included.contains { $0.id == poi.id } ?? false
    }

    /// Removes a stop and plans again without it.
    func remove(_ poi: POI) {
        guard var request else { return }
        request.mustVisit.removeAll { $0.id == poi.id }
        request.optional.removeAll { $0.id == poi.id }
        request.passing.removeAll { $0.id == poi.id }
        self.request = request
        for (kind, state) in addOns where state == .added(poi) { addOns[kind] = nil }
        replan()
    }

    /// "Add to walk" from a place card: the place becomes a must-visit stop.
    func add(_ poi: POI) async -> AddResult {
        guard request != nil, let walk else { return .failed }
        let gen = generation
        do {
            let result = try await Planner().insertCheapest(poi, into: walk, provider: provider)
            guard gen == generation else { return .failed }
            request?.mustVisit.append(poi)
            self.walk = result
            return .added
        } catch {
            return .failed
        }
    }

    /// "Add coffee" / "Add a shop": the best open place near the route, put where it adds the least time.
    func add(_ addOn: AddOn) async {
        guard let walk else { return }
        guard let pick = Self.addOnPick(addOn, near: walk.plan, pois: pois, at: .now, timeZone: timeZone) else {
            addOns[addOn] = .nothing
            return
        }
        addOns[addOn] = .working
        let gen = generation
        do {
            let result = try await Planner().insertCheapest(pick, into: walk, provider: provider)
            guard gen == generation else { return }
            request?.mustVisit.append(pick)
            self.walk = result
            addOns[addOn] = .added(pick)
        } catch {
            guard gen == generation else { return }
            addOns[addOn] = .failed
        }
    }

    /// The add-on candidate (FoodFinder's pick rules, measured from the route): open now
    /// (or unknown hours), within `addOnReach` of the line, not already a stop; the nearest
    /// to the route, but a tier 1–2 place beats a nearer tier 3 one within `addOnTierSlack`.
    static func addOnPick(_ addOn: AddOn, near plan: WanderPlan, pois: [POI], at date: Date,
                          timeZone: TimeZone) -> POI? {
        let line = plan.polyline
        guard let first = line.first, line.count > 1 else { return nil }
        let stops = Set(plan.waypoints.map(\.id))
        var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
        for c in line {
            minLat = min(minLat, c.lat); maxLat = max(maxLat, c.lat)
            minLon = min(minLon, c.lon); maxLon = max(maxLon, c.lon)
        }
        let pad = addOnReach / 111_000
        let lonPad = pad / max(cos(minLat * .pi / 180), 0.2)
        let latRange = minLat - pad...maxLat + pad, lonRange = minLon - lonPad...maxLon + lonPad
        var near: [(poi: POI, distance: Double)] = []
        for poi in pois where addOn.matches(poi) && !stops.contains(poi.id)
            && latRange.contains(poi.lat) && lonRange.contains(poi.lon)
            && !FoodPick.isClosed(poi, at: date, timeZone: timeZone) {
            let distance = RouteGeometry.nearest(poi.coordinate, on: line).distance
            if distance <= addOnReach { near.append((poi, distance)) }
        }
        let sorted = near.sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.poi.id < $1.poi.id }
        guard let nearest = sorted.first else { return nil }
        guard nearest.poi.mapTier == 3 else { return nearest.poi }
        return (sorted.first { $0.poi.mapTier <= 2 && $0.distance <= nearest.distance + addOnTierSlack } ?? nearest).poi
    }

    // MARK: - Planning

    private func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    private func replan() {
        cancel()
        walk = nil
        phase = .loading
        guard let request, let origin else { return }
        let provider = self.provider
        let gen = generation
        task = Task {
            do {
                let walk = try await Planner().planWalk(
                    start: origin, end: request.end, mustVisit: request.mustVisit, optional: request.optional,
                    budget: request.budget, passing: request.passing, provider: provider)
                guard gen == self.generation, !Task.isCancelled else { return }
                self.walk = walk
                self.phase = .ready
            } catch {
                guard gen == self.generation, !Task.isCancelled else { return }
                self.phase = .failed(self.classify(error))
            }
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

extension PlannerModel.Request {
    /// "Walk here" (ADR 016 "Resolved"): a walk to one place, no swipes; notable
    /// places the walk passes still show as highlights.
    static func walkHere(to destination: Destination, from origin: Coordinate?, pois: [POI]) -> Self {
        let end = Coordinate(destination.coordinate)
        return Self(title: destination.name, endName: destination.name, end: .destination(end),
                    mustVisit: [], optional: [], budget: 0,
                    passing: passing(pois, between: origin ?? end, and: end, reach: 200),
                    interests: Set(POICategory.allCases))
    }

    /// Notable places (tier 1–2) in the box around `a` and `b`, padded by `reach` metres.
    static func passing(_ pois: [POI], between a: Coordinate, and b: Coordinate, reach: Double) -> [POI] {
        let pad = reach / 111_000
        let lonPad = pad / max(cos(min(a.lat, b.lat) * .pi / 180), 0.2)
        let lat = min(a.lat, b.lat) - pad...max(a.lat, b.lat) + pad
        let lon = min(a.lon, b.lon) - lonPad...max(a.lon, b.lon) + lonPad
        return pois.filter { $0.mapTier <= 2 && lat.contains($0.lat) && lon.contains($0.lon) }
    }
}
