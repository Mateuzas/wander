import Foundation

/// Caches real legs so verification rounds (and plans for several modes)
/// never ask the provider for the same leg twice. MKDirections is rate-limited.
actor LegStore {
    private struct Key: Hashable {
        var from: Coordinate
        var to: Coordinate
    }

    private let provider: WalkingTimeProvider
    private var cache: [Key: Leg] = [:]
    /// Provider calls made, for tests and diagnostics.
    private(set) var requests = 0

    /// `known` legs are cached up front and cost no requests.
    init(provider: WalkingTimeProvider, known: [Leg] = []) {
        self.provider = provider
        for leg in known { cache[Key(from: leg.from, to: leg.to)] = leg }
    }

    func leg(from: Coordinate, to: Coordinate) async throws -> Leg {
        let key = Key(from: from, to: to)
        if let leg = cache[key] { return leg }
        requests += 1
        let leg = try await provider.leg(from: from, to: to)
        cache[key] = leg
        return leg
    }

    /// Legs origin → waypoints → destination.
    func legs(origin: Coordinate, waypoints: [POI], destination: Coordinate) async throws -> [Leg] {
        let stops = [origin] + waypoints.map(\.coordinate) + [destination]
        var legs: [Leg] = []
        for i in 1..<stops.count {
            legs.append(try await leg(from: stops[i - 1], to: stops[i]))
        }
        return legs
    }
}
