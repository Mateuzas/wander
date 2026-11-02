import Foundation
@testable import RouteEngine

/// Synthetic city around a fixed point; positions are given in metres east/north.
enum Grid {
    static let center = Coordinate(lat: 51.76, lon: 19.46)

    static func at(east: Double, north: Double) -> Coordinate {
        let ky = Coordinate.earthRadius * .pi / 180
        let kx = ky * cos(center.lat * .pi / 180)
        return Coordinate(lat: center.lat + north / ky, lon: center.lon + east / kx)
    }

    static func poi(_ id: String, east: Double, north: Double, category: POICategory = .photo,
                    score: Int = 80, kind: POIKind = .stop) -> POI {
        let c = at(east: east, north: north)
        return POI(id: id, name: id, lat: c.lat, lon: c.lon, category: category, score: score, kind: kind)
    }

    /// A→B is 2 km due east.
    static let origin = at(east: 0, north: 0)
    static let destination = at(east: 2000, north: 0)
}

/// Deterministic random numbers for property tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Haversine times multiplied by a fixed pseudo-random factor (1.0–1.4) per leg,
/// to stand in for real routing that is slower than the estimate.
struct NoisyWalkingTime: WalkingTimeProvider {
    var base = HaversineWalkingTime()

    func leg(from: Coordinate, to: Coordinate) async throws -> Leg {
        var leg = try await base.leg(from: from, to: to)
        let x = sin(from.lat * 12.9898 + from.lon * 78.233 + to.lat * 37.719 + to.lon * 4.581) * 43758.5453
        leg.duration *= 1 + 0.4 * (x - x.rounded(.down))
        return leg
    }
}

/// Real routing that is much slower than the estimate for every leg except A→B.
struct SlowDetourWalkingTime: WalkingTimeProvider {
    var origin: Coordinate
    var destination: Coordinate
    var factor: Double

    func leg(from: Coordinate, to: Coordinate) async throws -> Leg {
        var leg = try await HaversineWalkingTime().leg(from: from, to: to)
        if !(from == origin && to == destination) { leg.duration *= factor }
        return leg
    }
}

/// Counts provider calls.
actor CallCounter {
    var count = 0
    func increment() { count += 1 }
}

struct CountingWalkingTime: WalkingTimeProvider {
    let counter = CallCounter()
    func leg(from: Coordinate, to: Coordinate) async throws -> Leg {
        await counter.increment()
        return try await HaversineWalkingTime().leg(from: from, to: to)
    }
}

func randomPOIs(count: Int, using rng: inout SplitMix64) -> [POI] {
    (0..<count).map { i in
        Grid.poi("p\(i)",
                 east: Double.random(in: -500...2500, using: &rng),
                 north: Double.random(in: -1200...1200, using: &rng),
                 category: POICategory.allCases.randomElement(using: &rng)!,
                 score: Int.random(in: 0...100, using: &rng),
                 kind: Bool.random(using: &rng) ? .passby : .stop)
    }
}

/// Real routing faster than the estimate (like Apple Maps on a direct street grid).
struct FastWalkingTime: WalkingTimeProvider {
    var factor = 0.6
    func leg(from: Coordinate, to: Coordinate) async throws -> Leg {
        var leg = try await HaversineWalkingTime().leg(from: from, to: to)
        leg.duration *= factor
        return leg
    }
}

extension PlannerConfig {
    /// Defaults without freeing near-free waypoints: the synthetic POIs sit
    /// 150 m off the route (about 20 s of detour) and would all be freed,
    /// hiding the selection rules these tests check.
    static var selection: PlannerConfig {
        var config = PlannerConfig()
        config.freeBelow = 0
        return config
    }
}
