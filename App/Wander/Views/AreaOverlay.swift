import RouteEngine
import SwiftUI

/// Geometry for the swipe walk's area on the map (ADR 016 step 2), in metres around
/// the start, on a local flat projection (fine at walking scale).
enum AreaShape {
    private static let metresPerDegree = 111_320.0

    /// The point `distance` metres from `origin` toward `bearing` (degrees, 0 = north).
    static func point(from origin: Coordinate, bearing: Double, distance: Double) -> Coordinate {
        let radians = bearing * .pi / 180
        let north = cos(radians) * distance, east = sin(radians) * distance
        return Coordinate(lat: origin.lat + north / metresPerDegree,
                          lon: origin.lon + east / (metresPerDegree * max(cos(origin.lat * .pi / 180), 0.01)))
    }

    /// The band around start → end: `halfWidth` either side, with round ends (a stadium).
    static func band(from start: Coordinate, to end: Coordinate, halfWidth: Double) -> [Coordinate] {
        let scale = metresPerDegree * max(cos(start.lat * .pi / 180), 0.01)
        let dx = (end.lon - start.lon) * scale, dy = (end.lat - start.lat) * metresPerDegree
        // Bearing of start → end, degrees from north.
        let bearing = atan2(dx, dy) * 180 / .pi
        var points: [Coordinate] = []
        // Round end around the destination, then around the start.
        for step in 0...12 {
            points.append(point(from: end, bearing: bearing - 90 + Double(step) * 15, distance: halfWidth))
        }
        for step in 0...12 {
            points.append(point(from: start, bearing: bearing + 90 + Double(step) * 15, distance: halfWidth))
        }
        return points
    }
}

/// The knob on the circle's edge: drag to resize. VoiceOver adjusts it in steps.
struct ResizeHandle: View {
    let radius: Double
    let onAdjust: (Double) -> Void

    var body: some View {
        Image(systemName: "arrow.left.and.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.wander)
            .frame(width: 28, height: 28)
            .background(Color.surfaceRaised, in: Circle())
            .overlay(Circle().strokeBorder(Color.wander, lineWidth: 2))
            .frame(width: Layout.minTouch, height: Layout.minTouch)
            .contentShape(Circle())
            .accessibilityElement()
            .accessibilityLabel("Area size")
            .accessibilityValue(Format.distance(radius) + " across half")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onAdjust(radius * 1.25)
                case .decrement: onAdjust(radius / 1.25)
                @unknown default: break
                }
            }
    }
}

/// The walk's start when it isn't the user's location: a violet dot with a surface ring.
struct StartDot: View {
    var body: some View {
        Circle()
            .fill(Color.wander)
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(Color.surfaceRaised, lineWidth: 3))
            .accessibilityLabel("Walk starts here")
    }
}
