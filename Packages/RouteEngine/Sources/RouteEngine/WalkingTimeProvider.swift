import Foundation

/// One walking leg between two points.
public struct Leg: Hashable, Sendable {
    public var from: Coordinate
    public var to: Coordinate
    /// Seconds.
    public var duration: Double
    /// Metres.
    public var distance: Double
    /// Path geometry. The haversine provider returns just the two endpoints.
    public var polyline: [Coordinate]
    /// Turn-by-turn steps in order (from `MKRoute.steps` in the app). Empty
    /// when the provider has none, e.g. the haversine estimate.
    public var steps: [RouteStep]

    public init(from: Coordinate, to: Coordinate, duration: Double, distance: Double,
                polyline: [Coordinate], steps: [RouteStep] = []) {
        self.from = from
        self.to = to
        self.duration = duration
        self.distance = distance
        self.polyline = polyline
        self.steps = steps
    }
}

/// One turn-by-turn instruction and the distance it covers.
public struct RouteStep: Hashable, Sendable {
    /// e.g. "Turn left onto Piotrkowska". May be empty (MapKit's first step often is).
    public var instruction: String
    /// Metres covered by this step.
    public var distance: Double

    public init(instruction: String, distance: Double) {
        self.instruction = instruction
        self.distance = distance
    }
}

/// Source of walking times. The app uses MapKit (MKDirections); tests use `HaversineWalkingTime`.
public protocol WalkingTimeProvider: Sendable {
    func leg(from: Coordinate, to: Coordinate) async throws -> Leg
}

/// Offline estimate: straight-line distance × tortuosity / walking speed.
public struct HaversineWalkingTime: WalkingTimeProvider, Hashable {
    public static let defaultSpeed = 1.35       // m/s
    public static let defaultTortuosity = 1.3   // street path vs straight line

    public var speed: Double
    public var tortuosity: Double

    public init(speed: Double = defaultSpeed, tortuosity: Double = defaultTortuosity) {
        self.speed = speed
        self.tortuosity = tortuosity
    }

    public func seconds(from: Coordinate, to: Coordinate) -> Double {
        from.distance(to: to) * tortuosity / speed
    }

    public func leg(from: Coordinate, to: Coordinate) async throws -> Leg {
        let distance = from.distance(to: to) * tortuosity
        return Leg(from: from, to: to, duration: distance / speed, distance: distance, polyline: [from, to])
    }
}
