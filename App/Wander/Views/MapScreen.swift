import MapKit
import RouteEngine
import SwiftUI

/// Home (PLAN.md §7.1): full-bleed muted map, the user's location, POI beads,
/// and a bottom sheet with "Where to?" and recent destinations. No tab or navigation bar.
struct MapScreen: View {
    /// Beads drawn at once; the highest-scoring POIs in view win.
    private static let beadLimit = 40

    @State private var location = LocationService()
    @State private var search = SearchService()
    @State private var store = POIStore()
    @State private var recents = RecentDestinations()

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visiblePOIs: [POI] = []
    @State private var destination: Destination?
    @State private var detent: PresentationDetent = .peek

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Map(position: $position) {
            UserAnnotation()
            ForEach(visiblePOIs) { poi in
                Annotation(poi.name, coordinate: poi.coordinate.clLocation, anchor: .center) {
                    Bead(category: poi.category, name: poi.name)
                }
                .annotationTitles(.hidden)
            }
            if let destination {
                Marker(destination.name, coordinate: destination.coordinate)
                    .tint(.wander)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {}
        .onMapCameraChange(frequency: .onEnd) { context in
            search.region = context.region
            visiblePOIs = store.top(in: context.region, limit: Self.beadLimit)
        }
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            HomeSheet(
                search: search,
                recents: recents,
                locationDenied: location.access == .denied,
                detent: $detent,
                onChoose: choose
            )
            .presentationDetents([.peek, .medium, .large], selection: $detent)
            .presentationBackground(.surface)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .interactiveDismissDisabled()
        }
        .task {
            if let region = store.region {
                position = .userLocation(fallback: .region(region))
            }
            location.requestAccess()
        }
        .onChange(of: location.access) { _, access in
            // Raise the sheet once so the location message is visible.
            if access == .denied, detent == .peek { detent = .medium }
        }
    }

    private func choose(_ place: Destination) {
        recents.add(place)
        destination = place
        detent = .peek
        let camera = MapCamera(centerCoordinate: place.coordinate, distance: 1500)
        if reduceMotion {
            position = .camera(camera)
        } else {
            withAnimation(.easeInOut(duration: 0.6)) { position = .camera(camera) }
        }
    }
}

#Preview {
    MapScreen()
}
