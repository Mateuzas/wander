import Foundation
@testable import RouteEngine

/// Walks along streets in an L: first east/west, then north/south, with
/// MapKit-like steps. Stands in for MKDirections in walk tests.
struct LShapedWalkingTime: WalkingTimeProvider {
    func leg(from: Coordinate, to: Coordinate) async throws -> Leg {
        let corner = Coordinate(lat: from.lat, lon: to.lon)
        let first = from.distance(to: corner), second = corner.distance(to: to)
        let goesEast = to.lon >= from.lon, goesNorth = to.lat >= from.lat
        // Turning left when heading east means heading north next, and so on.
        let turn = goesEast == goesNorth ? "left" : "right"
        let steps = [
            RouteStep(instruction: "", distance: 0),
            RouteStep(instruction: "Head \(goesEast ? "east" : "west")", distance: first),
            RouteStep(instruction: "Turn \(turn)", distance: second),
            RouteStep(instruction: "Arrive", distance: 0),
        ]
        let distance = first + second
        return Leg(from: from, to: to, duration: distance / 1.35, distance: distance,
                   polyline: [from, corner, to], steps: steps)
    }
}

/// Moves a coordinate by metres east/north.
func offset(_ c: Coordinate, east: Double, north: Double) -> Coordinate {
    let ky = Coordinate.earthRadius * .pi / 180
    let kx = ky * cos(c.lat * .pi / 180)
    return Coordinate(lat: c.lat + north / ky, lon: c.lon + east / kx)
}

/// Points every `spacing` metres along a polyline.
func samples(along line: [Coordinate], every spacing: Double) -> [Coordinate] {
    guard var previous = line.first else { return [] }
    var points = [previous]
    var carry = 0.0
    for next in line.dropFirst() {
        let length = previous.distance(to: next)
        var d = spacing - carry
        while d <= length {
            let t = d / length
            points.append(Coordinate(lat: previous.lat + t * (next.lat - previous.lat),
                                     lon: previous.lon + t * (next.lon - previous.lon)))
            d += spacing
        }
        carry = length - (d - spacing)
        previous = next
    }
    if points.last != line.last, let last = line.last { points.append(last) }
    return points
}

/// A wrong turn off `route` (points 1.4 m apart along a plan's polyline) at
/// index `turnAt`, or the first point after it where one fits (where the
/// route is tangled, every way out passes close to another of its streets):
/// a straight walk away that ends more than 120 m from every
/// part of the route and, once 70 m out, stays more than 60 m from all of it
/// (so it can't brush past another street of the route on the way). Tries
/// the shortest length first, and directions square to the route before
/// slanted ones. Returns where the turn is and the points walked out, 1.4 m
/// apart, starting there.
func wrongTurn(off route: [Coordinate], from turnAt: Int, polyline: [Coordinate]) -> (at: Int, path: [Coordinate])? {
    let line = MeasuredPolyline(polyline, projection: LocalProjection(origin: polyline[0]))
    for index in stride(from: turnAt, to: route.count - 6, by: 20) {
        if let path = wrongTurn(off: route, at: index, line: line) { return (index, path) }
    }
    return nil
}

private func wrongTurn(off route: [Coordinate], at turnAt: Int, line: MeasuredPolyline) -> [Coordinate]? {
    let a = route[turnAt], b = route[turnAt + 5]
    let routeBearing = atan2((b.lon - a.lon) * cos(a.lat * .pi / 180), b.lat - a.lat)
    let skews: [Double] = [0, 15, -15, 30, -30, 45, -45, 60, -60, 75, -75, 90]
    for length in stride(from: 150.0, through: 600, by: 25) {
        for skew in skews {
            for side in [90.0, -90.0] {
                let bearing = routeBearing + (side + skew) * .pi / 180
                let end = offset(a, east: sin(bearing) * length, north: cos(bearing) * length)
                guard line.nearest(to: end).distance > 120 else { continue }
                let path = samples(along: [a, end], every: 1.4)
                if path.enumerated().allSatisfy({ i, c in Double(i) * 1.4 < 70 || line.nearest(to: c).distance > 60 }) {
                    return path
                }
            }
        }
    }
    return nil
}

/// Gaussian noise in metres (Box–Muller on a seeded generator).
struct GPSNoise {
    var rng: SplitMix64
    var sigma: Double

    mutating func gaussian() -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &rng), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &rng)
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    mutating func jitter(_ c: Coordinate) -> Coordinate {
        offset(c, east: gaussian(), north: gaussian())
    }
}

/// Feeds coordinates to a tracker one second apart and collects the updates.
func walk(_ tracker: inout WalkTracker, through points: [Coordinate], start: Date = Date(timeIntervalSince1970: 0),
          accuracy: Double = 10) -> [WalkUpdate] {
    points.enumerated().map { i, c in
        tracker.update(LocationFix(coordinate: c, horizontalAccuracy: accuracy,
                                   timestamp: start.addingTimeInterval(Double(i))))
    }
}

/// Golden routes and POIs from the repo (Packages/RouteEngine/golden_routes.json).
enum Golden {
    struct File: Decodable {
        struct Route: Decodable { var name: String; var from: [Double]; var to: [Double] }
        var pois: String
        var routes: [Route]
    }

    static let packageDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func load() throws -> (routes: [File.Route], pois: [POI]) {
        let url = packageDir.appendingPathComponent("golden_routes.json")
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        let poisURL = URL(fileURLWithPath: file.pois, relativeTo: packageDir)
        let pois = try JSONDecoder().decode(POIFile.self, from: Data(contentsOf: poisURL)).pois
        return (file.routes, pois)
    }

    /// The Recommended plan for golden route `index` (up to 5 stops, often
    /// with out-and-back legs), on L-shaped streets: what users walk.
    static func recommendedPlan(_ index: Int) async throws -> WanderPlan {
        try await recommendedPlans.value[index]
    }

    /// Planned once and shared: the walk tests run each route many times.
    private static let recommendedPlans = Task { () throws -> [WanderPlan] in
        let golden = try load()
        return try await withThrowingTaskGroup(of: (Int, WanderPlan).self) { group in
            for (i, route) in golden.routes.enumerated() {
                let request = PlanRequest(origin: Coordinate(lat: route.from[0], lon: route.from[1]),
                                          destination: Coordinate(lat: route.to[0], lon: route.to[1]),
                                          mode: .recommended, pois: golden.pois)
                group.addTask { (i, try await Planner().plan(request, provider: LShapedWalkingTime())) }
            }
            var plans: [Int: WanderPlan] = [:]
            for try await (i, plan) in group { plans[i] = plan }
            return golden.routes.indices.map { plans[$0]! }
        }
    }
}
