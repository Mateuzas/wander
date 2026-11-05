import MapKit
import SwiftUI

/// What the map camera is doing relative to the walker, as shown on `LocationButton`.
enum LocationFollowMode: Equatable {
    /// The map is somewhere else (panned away, a plan, a place).
    case none
    /// Centred on the user and following them, north up.
    case follow
    /// Following the user and turning with their heading.
    case followHeading

    init(_ position: MapCameraPosition) {
        if position.followsUserHeading {
            self = .followHeading
        } else if position.followsUserLocation {
            self = .follow
        } else {
            self = .none
        }
    }

    var symbol: String {
        switch self {
        case .none: "location"
        case .follow: "location.fill"
        case .followHeading: "location.north.line.fill"
        }
    }

    var spoken: String {
        switch self {
        case .none: "Not following"
        case .follow: "Following your location"
        case .followHeading: "Following your heading"
        }
    }
}

/// 44 × 44 pt button under the map-style control (same look): centres the map on
/// the user, and a second tap turns the map with their heading, like Apple and
/// Google Maps. `wander` marks an active follow mode (§10: selection).
struct LocationButton: View {
    let mode: LocationFollowMode
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: mode.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(mode == .none ? Color.ink : Color.wander)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Layout.minTouch, height: Layout.minTouch)
                .background(.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("My location")
        .accessibilityValue(mode.spoken)
        .accessibilityHint(hint)
    }

    private var hint: String {
        switch mode {
        case .none: "Centres the map on you"
        case .follow: "Turns the map with the way you're facing"
        case .followHeading: "Keeps north up"
        }
    }
}

#Preview {
    VStack(spacing: Layout.grid) {
        LocationButton(mode: .none) {}
        LocationButton(mode: .follow) {}
        LocationButton(mode: .followHeading) {}
    }
    .padding()
    .background(.surface)
}
