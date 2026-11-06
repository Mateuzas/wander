import MapKit
import RouteEngine

enum RoutingError: Error {
    /// MapKit has no walking route between the two points.
    case noRoute
}

/// Real walking routes from MKDirections (PLAN.md §4, §6 step 5).
///
/// MKDirections is rate-limited (about 50 requests a minute, §6). This provider
/// caches every leg, shares in-flight requests, and spaces requests so no more
/// than `requestsPerMinute` go out in any 60 s window. A plan costs about 4–6
/// requests, so both options for one destination fit comfortably.
actor MapKitWalkingTime: WalkingTimeProvider {
    static let requestsPerMinute = 40

    private struct Key: Hashable {
        let a, b, c, d: Int64
        init(_ from: Coordinate, _ to: Coordinate) {
            func q(_ v: Double) -> Int64 { Int64((v * 100_000).rounded()) }  // ~1 m
            a = q(from.lat); b = q(from.lon); c = q(to.lat); d = q(to.lon)
        }
    }

    private var legs: [Key: Leg] = [:]
    private var inFlight: [Key: Task<Leg, Error>] = [:]
    private var sent: [Date] = []

    func leg(from: Coordinate, to: Coordinate) async throws -> Leg {
        let key = Key(from, to)
        if let leg = legs[key] { return leg }
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await self.fetch(from: from, to: to, key: key) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    // MARK: - Private

    private func fetch(from: Coordinate, to: Coordinate, key: Key) async throws -> Leg {
        let route: MKRoute
        do {
            route = try await calculate(from: from, to: to)
        } catch let error as MKError where error.code == .loadingThrottled {
            // Over Apple's limit despite our spacing: wait once, then try again.
            try await Task.sleep(for: .seconds(15))
            route = try await calculate(from: from, to: to)
        }
        let leg = Leg(from: from, to: to, duration: route.expectedTravelTime,
                      distance: route.distance, polyline: Self.coordinates(of: route.polyline),
                      steps: route.steps.map { RouteStep(instruction: $0.instructions, distance: $0.distance) })
        legs[key] = leg
        return leg
    }

    private func calculate(from: Coordinate, to: Coordinate) async throws -> MKRoute {
        try await waitForSlot()
        let request = MKDirections.Request()
        request.source = Self.mapItem(from)
        request.destination = Self.mapItem(to)
        request.transportType = .walking
        request.requestsAlternateRoutes = false
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else { throw RoutingError.noRoute }
            return route
        } catch let error as MKError where error.code == .directionsNotFound {
            throw RoutingError.noRoute
        }
    }

    /// Sleeps until sending one more request keeps the last 60 s under the limit.
    private func waitForSlot() async throws {
        while true {
            let now = Date()
            sent.removeAll { now.timeIntervalSince($0) >= 60 }
            if sent.count < Self.requestsPerMinute {
                sent.append(now)
                return
            }
            let wait = 60 - now.timeIntervalSince(sent[0]) + 0.1
            try await Task.sleep(for: .seconds(wait))
        }
    }

    private static func mapItem(_ c: Coordinate) -> MKMapItem {
        if #available(iOS 26, *) {
            return MKMapItem(location: CLLocation(latitude: c.lat, longitude: c.lon), address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: c.clLocation))
    }

    private static func coordinates(of polyline: MKPolyline) -> [Coordinate] {
        var points = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: polyline.pointCount))
        return points.map { Coordinate(lat: $0.latitude, lon: $0.longitude) }
    }
}
