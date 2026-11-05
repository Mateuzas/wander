import CoreLocation
import Observation
import SwiftUI

/// The map camera's rotation, updated continuously. Kept out of `MapScreen`'s own
/// state so turning the map redraws only the cone, not the whole screen.
@MainActor
@Observable
final class MapRotation {
    /// Degrees clockwise from north at the top of the screen.
    var heading: CLLocationDirection = 0
}

/// A soft `wander` beam under the user dot pointing the way the phone faces, so
/// the walker can tell which way they're facing. SwiftUI's `UserAnnotation` doesn't
/// draw the system heading cone, so this draws one. Hidden without a reliable heading.
struct HeadingCone: View {
    let location: LocationService
    let rotation: MapRotation

    static let size: CGFloat = 96
    /// Beam width in degrees.
    private static let spread: Double = 70

    var body: some View {
        if let heading = location.heading {
            Beam(spread: Self.spread)
                .fill(RadialGradient(
                    colors: [Color.wander.opacity(0.45), Color.wander.opacity(0)],
                    center: .center, startRadius: 6, endRadius: Self.size / 2))
                .frame(width: Self.size, height: Self.size)
                // Annotations stay upright, so take away the map's own rotation.
                .rotationEffect(.degrees(heading - rotation.heading))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// A wedge from the centre, pointing up, `spread` degrees wide.
    private struct Beam: Shape {
        let spread: Double

        func path(in rect: CGRect) -> Path {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            var path = Path()
            path.move(to: center)
            path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                        startAngle: .degrees(-90 - spread / 2), endAngle: .degrees(-90 + spread / 2),
                        clockwise: false)
            path.closeSubpath()
            return path
        }
    }
}
