import MapKit
import RouteEngine
import SwiftUI

/// Milestone 0 placeholder: full-bleed muted map with a peek sheet.
/// The real home screen (search, recents) arrives in milestone 3.
struct MapScreen: View {
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $position) {
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Where to?")
                    .font(.title2.weight(.semibold))
                Text("RouteEngine linked · walking speed \(HaversineWalkingTime.defaultSpeed, specifier: "%.2f") m/s")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .presentationDetents([.height(120)])
            .presentationBackgroundInteraction(.enabled)
            .interactiveDismissDisabled()
        }
    }
}

#Preview {
    MapScreen()
}
