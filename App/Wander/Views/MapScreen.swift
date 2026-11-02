import MapKit
import RouteEngine
import SwiftUI

/// Home, plan and walking states (PLAN.md §7.1–7.4) on one full-bleed map. The
/// sheet shows search, the plan, a tapped bead's details, or the walk. No tab or
/// navigation bar.
struct MapScreen: View {
    /// Unplanned beads drawn at once; the highest-scoring POIs in view win.
    private static let beadLimit = 40
    /// §10 Motion: the Wander line draws in over ~0.9 s.
    private static let drawDuration = 0.9

    @State private var location = LocationService()
    @State private var search = SearchService()
    @State private var store = POIStore()
    @State private var recents = RecentDestinations()
    @State private var connectivity: Connectivity
    @State private var planner: PlannerModel

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var visiblePOIs: [POI] = []
    @State private var detent: PresentationDetent = .peek
    @State private var selectedPOI: POI?
    @State private var debugOverlay = false
    @AppStorage(WanderMapStyle.storageKey) private var mapStyle = WanderMapStyle.map
    @State private var walk: WalkModel?

    // Draw-in state for the current plan.
    @State private var routeLine: [Coordinate] = []
    @State private var routeLengths: [Double] = []
    @State private var reveal: Double = 1
    @State private var routeOpacity: Double = 1
    @State private var drawTask: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {
        let connectivity = Connectivity()
        _connectivity = State(initialValue: connectivity)
        _planner = State(initialValue: PlannerModel(connectivity: connectivity))
    }

    var body: some View {
        map
            .overlay(alignment: .topTrailing) {
                // Hidden while walking: the turn card owns the top of the screen.
                if walk == nil {
                    MapStyleControl(style: $mapStyle).padding(Layout.margin)
                }
            }
            .overlay(alignment: .top) {
                if let walk, walk.phase == .walking {
                    TurnCard(walk: walk)
                        .padding(.horizontal, Layout.margin)
                        .padding(.top, Layout.grid)
                }
            }
            .overlay(alignment: .bottom) {
                upAhead
                    .padding(.horizontal, Layout.margin)
                    .padding(.bottom, Layout.peekHeight + Layout.grid)
            }
            .sheet(isPresented: .constant(true)) {
                sheetContent
                    .presentationDetents(walk == nil ? [.peek, .medium, .large] : [.peek, .medium], selection: $detent)
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
                if access == .denied {
                    planner.originUnavailable()
                    if detent == .peek, planner.destination == nil { detent = .medium }
                }
            }
            .onChange(of: location.location) { _, fix in
                guard let fix else { return }
                if let walk {
                    walk.handle(fix)
                } else {
                    planner.setOrigin(Coordinate(fix.coordinate))
                }
            }
            .onChange(of: displayedPlan) { _, plan in
                showPlan(plan)
            }
            .onChange(of: walk?.phase) { _, phase in
                if phase == .arrived || phase == .ended {
                    location.setWalking(false)
                    detent = .medium
                }
            }
            .onDisappear { walk?.tearDown() }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $position) {
            UserAnnotation()

            if let plan = displayedPlan {
                if mapStyle.isImagery {
                    // Casings keep both lines readable on imagery.
                    if walk == nil, !plan.waypoints.isEmpty {
                        MapPolyline(coordinates: plan.baseline.polyline.map(\.clLocation))
                            .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [2, 7]))
                    }
                    MapPolyline(coordinates: revealedRoute.map(\.clLocation))
                        .stroke(.white.opacity(0.9 * routeOpacity),
                                style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                }
                if walk == nil, !plan.waypoints.isEmpty {
                    // Fast route: thin, dashed, grey (§7.2).
                    MapPolyline(coordinates: plan.baseline.polyline.map(\.clLocation))
                        .stroke(Color.inkMuted, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 7]))
                }
                // Wander route: thick, solid, violet.
                MapPolyline(coordinates: revealedRoute.map(\.clLocation))
                    .stroke(Color.wander.opacity(routeOpacity),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }

            ForEach(beads) { bead in
                Annotation(bead.poi.name, coordinate: bead.poi.coordinate.clLocation, anchor: .center) {
                    Bead(category: bead.poi.category, isSelected: selectedPOI?.id == bead.poi.id, isPopular: bead.poi.popular ?? false, name: bead.poi.name)
                        .opacity(bead.dimmed ? 0.55 : 1)
                        .scaleEffect(bead.shown ? 1 : 0.01)
                        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.4), value: bead.shown)
                        .frame(width: Layout.minTouch, height: Layout.minTouch)
                        .contentShape(Circle())
                        .onTapGesture { if walk == nil { select(bead.poi) } }
                        .accessibilityAddTraits(.isButton)
                }
                .annotationTitles(.hidden)
            }

            if let destination = planner.destination {
                Marker(destination.name, coordinate: destination.coordinate)
                    .tint(Color.wander)
            }

            #if DEBUG
            if debugOverlay, let plan = planner.plan {
                ForEach(debugRecords(plan), id: \.poi.id) { record in
                    Annotation("", coordinate: record.poi.coordinate.clLocation, anchor: .top) {
                        DebugLabel(record: record)
                    }
                    .annotationTitles(.hidden)
                }
            }
            #endif
        }
        .mapStyle(mapStyle.mapStyle)
        .mapControls {}
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            search.region = context.region
            visiblePOIs = store.top(in: context.region, limit: Self.beadLimit)
        }
        #if DEBUG
        .simultaneousGesture(LongPressGesture(minimumDuration: 1).onEnded { _ in debugOverlay.toggle() })
        #endif
        .ignoresSafeArea()
    }

    private struct BeadItem: Identifiable {
        let poi: POI
        /// Not on the planned route; drawn quieter so the route beads lead.
        let dimmed: Bool
        /// False until the draw-in passes it.
        let shown: Bool
        var id: String { poi.id }
    }

    /// Route highlights first, then the top POIs in view.
    private var beads: [BeadItem] {
        var items: [BeadItem] = []
        var seen: Set<String> = []
        if let plan = displayedPlan {
            let total = max(routeLengths.last ?? 1, 1)
            for highlight in plan.highlights where seen.insert(highlight.poi.id).inserted {
                items.append(BeadItem(poi: highlight.poi, dimmed: false,
                                      shown: highlight.distanceAlongRoute / total <= reveal + 0.001))
            }
        }
        // While walking, only the walk's highlights show.
        guard walk == nil else { return items }
        let dim = planner.plan != nil
        for poi in visiblePOIs where seen.insert(poi.id).inserted && !planner.excluded.contains(poi.id) {
            items.append(BeadItem(poi: poi, dimmed: dim, shown: true))
        }
        if let selected = selectedPOI, seen.insert(selected.id).inserted {
            items.append(BeadItem(poi: selected, dimmed: false, shown: true))
        }
        // MapKit draws annotations in order, so popular beads go last to sit on top.
        return items.filter { $0.poi.popular != true } + items.filter { $0.poi.popular == true }
    }

    private var revealedRoute: [Coordinate] {
        guard reveal < 1, let total = routeLengths.last else { return routeLine }
        return RouteGeometry.prefix(routeLine, lengths: routeLengths, length: total * reveal)
    }

    // MARK: - Sheet

    /// The walk's (possibly rerouted) plan while walking, otherwise the selected mode's plan.
    private var displayedPlan: WanderPlan? { walk?.plan ?? planner.plan }

    @ViewBuilder
    private var upAhead: some View {
        Group {
            if let walk, let nudge = walk.nudge {
                UpAheadCard(nudge: nudge, onSkip: walk.skipNudge)
                    .id(nudge.highlight.poi.id)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.3), value: walk?.nudge?.highlight.poi.id)
    }

    @ViewBuilder
    private var sheetContent: some View {
        if let walk {
            WalkSheet(walk: walk, onDone: finishWalk)
        } else if let poi = selectedPOI {
            POIDetail(
                poi: poi,
                action: detailAction(for: poi),
                onAdd: {
                    let result = await planner.add(poi)
                    if case .added = result { selectedPOI = nil }
                    return result
                },
                onRemove: {
                    planner.remove(poi)
                    selectedPOI = nil
                },
                onClose: { selectedPOI = nil })
        } else if let destination = planner.destination {
            planSheet(destination)
        } else {
            HomeSheet(
                search: search,
                recents: recents,
                locationDenied: location.access == .denied,
                offline: !connectivity.isOnline,
                detent: $detent,
                onChoose: choose)
        }
    }

    private func planSheet(_ destination: Destination) -> some View {
        #if DEBUG
        PlanSheet(planner: planner, destination: destination, onClose: closePlan,
                  onFocus: focus, onStartWalk: startWalk, debugOverlay: $debugOverlay)
        #else
        PlanSheet(planner: planner, destination: destination, onClose: closePlan,
                  onFocus: focus, onStartWalk: startWalk)
        #endif
    }

    private func detailAction(for poi: POI) -> POIDetail.Action {
        guard let plan = planner.plan else { return .none }
        if plan.highlights.contains(where: { $0.poi.id == poi.id }) { return .remove }
        switch planner.addOption(for: poi) {
        case .add:
            return .add
        case .directMode:
            return .unavailable("Direct takes the fastest route. Switch to Relaxed or Explorer to add stops.")
        case .full:
            return .unavailable("This walk already has \(planner.mode.maxWaypoints) stops. Remove one to add this.")
        case .doesntFit:
            return .unavailable(planner.mode == .explorer
                ? "Too far for a \(planner.mode.budgetLabel) detour."
                : "Doesn't fit the \(planner.mode.budgetLabel) detour. Try Explorer.")
        }
    }

    // MARK: - Actions

    private func choose(_ place: Destination) {
        recents.add(place)
        selectedPOI = nil
        planner.start(
            destination: place,
            origin: location.location.map { Coordinate($0.coordinate) },
            pois: store.pois,
            timeZone: store.timeZone)
        if location.access == .denied { planner.originUnavailable() }
        detent = .medium
        move(to: .camera(MapCamera(centerCoordinate: place.coordinate, distance: 2500)))
    }

    private func closePlan() {
        planner.close()
        selectedPOI = nil
        detent = .peek
    }

    private func select(_ poi: POI) {
        selectedPOI = poi
        if detent == .peek || detent == .large { detent = .medium }
    }

    private func focus(_ poi: POI) {
        select(poi)
        move(to: .camera(MapCamera(centerCoordinate: poi.coordinate.clLocation, distance: 700)))
    }

    private func startWalk(_ plan: WanderPlan) {
        guard let destination = planner.destination else { return }
        let walk = WalkModel(
            plan: plan, destinationName: destination.name, provider: planner.provider,
            pois: store.pois.filter { !planner.excluded.contains($0.id) }, interests: planner.interests)
        self.walk = walk
        selectedPOI = nil
        debugOverlay = false
        location.setWalking(true)
        if let fix = location.location { walk.handle(fix) }
        detent = .peek
        move(to: .userLocation(followsHeading: false, fallback: .automatic))
    }

    /// Done after arriving or ending: back to the home screen.
    private func finishWalk() {
        walk?.end()
        walk?.tearDown()
        walk = nil
        location.setWalking(false)
        closePlan()
        move(to: .userLocation(fallback: .automatic))
    }

    private func move(to camera: MapCameraPosition) {
        if reduceMotion {
            position = camera
        } else {
            withAnimation(.easeInOut(duration: 0.6)) { position = camera }
        }
    }

    /// Frames the route above the medium sheet and runs the draw-in.
    private func showPlan(_ plan: WanderPlan?) {
        drawTask?.cancel()
        guard let plan else {
            routeLine = []
            routeLengths = []
            return
        }
        routeLine = plan.polyline
        routeLengths = RouteGeometry.cumulativeLengths(routeLine)
        if walk != nil {
            // A reroute mid-walk: no draw-in, and the camera keeps following the walker.
            reveal = 1
            routeOpacity = 1
            return
        }
        if let region = Self.region(fitting: routeLine + plan.baseline.polyline) {
            move(to: .region(region))
        }

        if reduceMotion {
            // §10: replace the draw-in with a simple fade.
            reveal = 1
            routeOpacity = 0
            drawTask = animate(duration: 0.3) { routeOpacity = $0 }
        } else {
            routeOpacity = 1
            reveal = 0
            drawTask = animate(duration: Self.drawDuration) { t in
                reveal = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2  // ease in-out
            }
        }
    }

    /// Steps `update` from 0 to 1 over `duration`, once per frame. MapPolyline
    /// can't be trimmed with a SwiftUI animation, so the line is redrawn per frame.
    private func animate(duration: Double, update: @escaping (Double) -> Void) -> Task<Void, Never> {
        Task {
            let start = Date()
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(start) / duration)
                update(t)
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Region around `line` with the route in the top half, clear of the medium sheet.
    private static func region(fitting line: [Coordinate]) -> MKCoordinateRegion? {
        guard let first = line.first else { return nil }
        var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
        for c in line {
            minLat = min(minLat, c.lat); maxLat = max(maxLat, c.lat)
            minLon = min(minLon, c.lon); maxLon = max(maxLon, c.lon)
        }
        let latSpan = max(maxLat - minLat, 0.003) * 1.25
        let lonSpan = max(maxLon - minLon, 0.003) * 1.25
        let visibleLat = latSpan / 0.5  // route fills the top ~half of the screen
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2 - visibleLat * 0.22,
                                            longitude: (minLon + maxLon) / 2)
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: visibleLat, longitudeDelta: lonSpan))
    }

    // MARK: - Debug overlay

    #if DEBUG
    /// Candidates in view, most valuable first, capped so the map stays usable.
    private func debugRecords(_ plan: WanderPlan) -> [CandidateDebug] {
        let region = visibleRegion
        return plan.candidates
            .filter { record in
                if case .rejected(.notInInterests) = record.status { return false }
                guard let region else { return true }
                return abs(record.poi.lat - region.center.latitude) <= region.span.latitudeDelta / 2
                    && abs(record.poi.lon - region.center.longitude) <= region.span.longitudeDelta / 2
            }
            .sorted { $0.value > $1.value }
            .prefix(120)
            .map { $0 }
    }
    #endif
}

#if DEBUG
/// Debug-only label: value, status or rejection reason, estimated extra minutes.
private struct DebugLabel: View {
    let record: CandidateDebug

    var body: some View {
        VStack(spacing: 1) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.ink)
                .padding(.horizontal, 3)
                .background(Color.surfaceRaised.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
        }
        .padding(.top, 12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var text: String {
        var parts = ["\(Int(record.value.rounded()))"]
        switch record.status {
        case .waypoint: parts.append("chosen")
        case .passby: parts.append("on route")
        case .rejected(let reason): parts.append(reason.rawValue)
        }
        if let extra = record.estimatedExtraTime { parts.append("+\(Int((extra / 60).rounded()))m") }
        return parts.joined(separator: " ")
    }

    private var color: Color {
        switch record.status {
        case .waypoint: .green
        case .passby: .blue
        case .rejected: .gray
        }
    }
}
#endif

#Preview {
    MapScreen()
}
