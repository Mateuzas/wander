import MapKit
import SwiftUI

/// The three base maps. Every style hides Apple's own POIs so only our beads show.
enum WanderMapStyle: String, CaseIterable, Identifiable {
    /// Today's muted standard map.
    case map
    /// Imagery only.
    case satellite
    /// Imagery with street names.
    case hybrid

    var id: String { rawValue }

    /// `@AppStorage` key, so the choice survives launches.
    static let storageKey = "mapStyle"

    var title: String {
        switch self {
        case .map: "Map"
        case .satellite: "Satellite"
        case .hybrid: "Hybrid"
        }
    }

    var symbol: String {
        switch self {
        case .map: "map"
        case .satellite: "globe.europe.africa"
        case .hybrid: "globe.europe.africa.fill"
        }
    }

    /// Imagery is busy and often dark, so route lines get a white casing there.
    var isImagery: Bool { self != .map }

    var mapStyle: MapStyle {
        switch self {
        case .map:
            .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll)
        case .satellite:
            .imagery(elevation: .flat)
        case .hybrid:
            .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
        }
    }
}

/// One 44 × 44 pt button in the top-right map-controls area; it opens a small
/// menu with the three styles (§10: `surfaceRaised`, `ink`, `wander` for selection).
struct MapStyleControl: View {
    @Binding var style: WanderMapStyle

    var body: some View {
        Menu {
            Picker("Map style", selection: $style) {
                ForEach(WanderMapStyle.allCases) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }
        } label: {
            Image(systemName: "map")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.ink)
                .frame(width: Layout.minTouch, height: Layout.minTouch)
                .background(.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
        .accessibilityLabel("Map style")
        .accessibilityValue(style.title)
        .accessibilityHint("Choose Map, Satellite or Hybrid")
    }
}

#Preview {
    @Previewable @State var style = WanderMapStyle.map
    MapStyleControl(style: $style).padding()
}
