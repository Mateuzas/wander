import Foundation

/// A WGS84 coordinate. RouteEngine has its own type so it never imports CoreLocation.
public struct Coordinate: Hashable, Codable, Sendable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    static let earthRadius = 6_371_000.0

    /// Great-circle distance in metres.
    public func distance(to other: Coordinate) -> Double {
        let φ1 = lat * .pi / 180, φ2 = other.lat * .pi / 180
        let dφ = (other.lat - lat) * .pi / 180
        let dλ = (other.lon - lon) * .pi / 180
        let a = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * Coordinate.earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }
}
