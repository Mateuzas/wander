import CoreLocation
import Foundation
import Observation
import RouteEngine

/// A kind of food place in the search panel's "Nearby" row (FE-19,
/// docs/CONTRACTS.md §2 "Food nearby"). Each maps to POI `type` values in the
/// food category.
enum FoodKind: String, CaseIterable, Identifiable {
    case coffee, bakery, restaurant, bar

    var id: Self { self }

    var title: String {
        switch self {
        case .coffee: "Coffee"
        case .bakery: "Bakery"
        case .restaurant: "Restaurant"
        case .bar: "Bar"
        }
    }

    var types: Set<String> {
        switch self {
        case .coffee: ["cafe", "coffee", "tea"]
        case .bakery: ["bakery", "pastry", "confectionery", "chocolate"]
        case .restaurant: ["restaurant"]
        case .bar: ["bar", "pub"]
        }
    }

    /// The bead glyph for this kind's places (`POI.foodGlyphs`).
    var glyph: String {
        POI.foodGlyphs.first { !$0.types.isDisjoint(with: types) }?.glyph ?? POI.foodFallbackGlyph
    }
}

/// The pure part of "take me to the closest good one" (FE-19).
enum FoodPick {
    /// Straight-line reach of "nearby".
    static let maxDistance: CLLocationDistance = 3000
    /// Radius for the cuisine chips.
    static let cuisineRadius: CLLocationDistance = 1500
    static let maxCuisines = 8
    /// How many of the nearest open places get a real walking time per pick.
    static let timedCount = 3
    /// A tier 1–2 place wins over a nearer tier 3 one when it's at most this much further.
    static let tierSlack: TimeInterval = 180

    struct Candidates: Equatable {
        /// Open (or of unknown hours), nearest first.
        var open: [POI]
        /// The nearest place that is closed now, for "Nothing open nearby".
        var nearestClosed: POI?
    }

    static func distance(_ a: Coordinate, _ b: Coordinate) -> CLLocationDistance {
        CLLocation(latitude: a.lat, longitude: a.lon).distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
    }

    /// `kind` places (of `cuisine`, if given) within `maxDistance` of `origin`,
    /// split into open and closed by their opening hours. Unparseable or
    /// missing hours count as open.
    static func candidates(kind: FoodKind, cuisine: String?, pois: [POI], origin: Coordinate,
                           at date: Date, timeZone: TimeZone) -> Candidates {
        let wanted = cuisine?.lowercased()
        func matches(_ poi: POI) -> Bool {
            guard poi.category == .food, let type = poi.type, kind.types.contains(type) else { return false }
            guard let wanted else { return true }
            let values: [String] = poi.cuisine ?? []
            return values.contains { $0.lowercased() == wanted }
        }
        var matching: [(poi: POI, distance: CLLocationDistance)] = []
        for poi in pois where matches(poi) {
            let d = distance(origin, poi.coordinate)
            if d <= maxDistance { matching.append((poi, d)) }
        }
        matching.sort { $0.distance != $1.distance ? $0.distance < $1.distance : $0.poi.id < $1.poi.id }
        var open: [POI] = [], nearestClosed: POI?
        for item in matching {
            if isClosed(item.poi, at: date, timeZone: timeZone) {
                if nearestClosed == nil { nearestClosed = item.poi }
            } else {
                open.append(item.poi)
            }
        }
        return Candidates(open: open, nearestClosed: nearestClosed)
    }

    static func isClosed(_ poi: POI, at date: Date, timeZone: TimeZone) -> Bool {
        guard let raw = poi.openingHours, let hours = OpeningHours(raw) else { return false }
        return !hours.isOpen(at: date, in: timeZone)
    }

    /// From timed candidates, the shortest walk; but a tier 1–2 place beats a
    /// tier 3 one when it is at most `tierSlack` further. Nil for an empty list.
    static func choose(_ timed: [(poi: POI, walk: TimeInterval)]) -> (poi: POI, walk: TimeInterval)? {
        let byWalk = timed.sorted { $0.walk != $1.walk ? $0.walk < $1.walk : $0.poi.id < $1.poi.id }
        guard let shortest = byWalk.first else { return nil }
        guard shortest.poi.mapTier == 3 else { return shortest }
        return byWalk.first { $0.poi.mapTier <= 2 && $0.walk <= shortest.walk + tierSlack } ?? shortest
    }

    /// The `maxCuisines` most common cuisines of restaurants within
    /// `cuisineRadius` of `origin`, as stored (lowercase OSM values).
    static func cuisines(pois: [POI], near origin: Coordinate) -> [String] {
        var counts: [String: Int] = [:]
        for poi in pois where poi.category == .food && FoodKind.restaurant.types.contains(poi.type ?? "")
            && distance(origin, poi.coordinate) <= cuisineRadius {
            for value in Set((poi.cuisine ?? []).map { $0.lowercased() }) where !value.isEmpty {
                counts[value, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxCuisines)
            .map(\.key)
    }

    /// "steak_house" → "Steak house".
    static func cuisineTitle(_ value: String) -> String {
        let words = value.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Rough walk time from the straight line, for when MapKit can't route.
    static func estimatedWalk(from origin: Coordinate, to poi: POI) -> TimeInterval {
        distance(origin, poi.coordinate) * 1.3 / 1.35
    }
}

/// Runs the food-nearby flow (FE-19): picks the closest good open place of a
/// kind, with real walking times for the nearest few, and steps to the next
/// option on request.
@MainActor
@Observable
final class FoodFinder {
    struct Request: Equatable {
        var kind: FoodKind
        var cuisine: String?

        /// "Coffee", or the cuisine for a restaurant ("Georgian").
        var title: String { cuisine.map(FoodPick.cuisineTitle) ?? kind.title }
    }

    struct Result: Equatable {
        var poi: POI
        var walk: TimeInterval
        var minutes: Int { max(1, Int((walk / 60).rounded())) }
    }

    enum Phase: Equatable {
        /// Waiting for the first location fix.
        case locating
        case searching
        case found(Result)
        /// Nothing open; the nearest closed place if there is one.
        case nothingOpen(POI?)
        case noLocation
    }

    private(set) var request: Request?
    private(set) var phase: Phase = .searching
    /// Open places not shown yet, nearest first.
    private(set) var remaining: [POI] = []

    var hasNext: Bool { !remaining.isEmpty }

    @ObservationIgnored private let provider: MapKitWalkingTime
    @ObservationIgnored private var origin: Coordinate?
    @ObservationIgnored private var pois: [POI] = []
    @ObservationIgnored private var timeZone: TimeZone = .current
    @ObservationIgnored private var task: Task<Void, Never>?

    init(provider: MapKitWalkingTime) {
        self.provider = provider
    }

    func start(_ request: Request, origin: Coordinate?, locationDenied: Bool, pois: [POI], timeZone: TimeZone) {
        task?.cancel()
        self.request = request
        self.origin = origin
        self.pois = pois
        self.timeZone = timeZone
        remaining = []
        if let origin {
            begin(from: origin)
        } else {
            phase = locationDenied ? .noLocation : .locating
        }
    }

    /// The first fix after `start` without one.
    func setOrigin(_ coordinate: Coordinate) {
        guard request != nil, origin == nil else { return }
        origin = coordinate
        begin(from: coordinate)
    }

    func locationDenied() {
        guard request != nil, origin == nil else { return }
        phase = .noLocation
    }

    /// "Next option": the next candidate, re-ranked among those left.
    func next() {
        guard let origin, hasNext else { return }
        pick(from: origin)
    }

    func close() {
        task?.cancel()
        task = nil
        request = nil
        remaining = []
        origin = nil
    }

    // MARK: - Private

    private func begin(from origin: Coordinate) {
        guard let request else { return }
        let candidates = FoodPick.candidates(kind: request.kind, cuisine: request.cuisine, pois: pois,
                                             origin: origin, at: .now, timeZone: timeZone)
        remaining = candidates.open
        if remaining.isEmpty {
            phase = .nothingOpen(candidates.nearestClosed)
        } else {
            pick(from: origin)
        }
    }

    /// Times the nearest few of `remaining` and shows the best; it leaves `remaining`.
    private func pick(from origin: Coordinate) {
        task?.cancel()
        phase = .searching
        let nearest = Array(remaining.prefix(FoodPick.timedCount))
        let provider = provider
        task = Task {
            var timed: [(poi: POI, walk: TimeInterval)] = []
            // One at a time: the provider spaces requests and caches legs, so the
            // two not chosen cost nothing on "Next option".
            for poi in nearest {
                let walk: TimeInterval
                do {
                    walk = try await provider.leg(from: origin, to: poi.coordinate).duration
                } catch {
                    if Task.isCancelled { return }
                    walk = FoodPick.estimatedWalk(from: origin, to: poi)
                }
                timed.append((poi, walk))
            }
            guard !Task.isCancelled, let best = FoodPick.choose(timed) else { return }
            remaining.removeAll { $0.id == best.poi.id }
            phase = .found(Result(poi: best.poi, walk: best.walk))
        }
    }
}
